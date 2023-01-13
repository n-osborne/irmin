(*
 * Copyright (c) 2022-2022 Tarides <contact@tarides.com>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Import
include Sparse_file_intf
module BigArr1 = Bigarray.Array1

type int_bigarray = (int, Bigarray.int_elt, Bigarray.c_layout) BigArr1.t
type int64_bigarray = (int64, Bigarray.int64_elt, Bigarray.c_layout) BigArr1.t

module Int_mmap : sig
  type t = private {
    fn : string;
    fd : Unix.file_descr;
    mutable arr : int_bigarray;
  }

  val open_rw : string -> t
  val close : t -> unit
end = struct
  type t = { fn : string; fd : Unix.file_descr; mutable arr : int_bigarray }

  (* NOTE following mmap is shared *)

  let open_rw fn =
    let shared = true in
    assert (Sys.file_exists fn);
    let fd = Unix.(openfile fn [ O_RDWR ] 0o660) in
    let arr =
      let open Bigarray in
      Unix.map_file fd Int c_layout shared [| -1 |] |> array1_of_genarray
    in
    { fn; fd; arr }

  let close t =
    Unix.close t.fd;
    (* following tries to make the array unreachable, so GC'able; however, no guarantee
       that arr actually is unreachable *)
    t.arr <- Bigarray.(Array1.create Int c_layout 0);
    ()
end

module Int64_mmap : sig
  type t = private {
    fn : string;
    fd : Unix.file_descr;
    mutable arr : int64_bigarray;
  }

  val open_ro : fn:string -> sz:int -> t
  (** NOTE [open_ ~fn ~sz] can use [sz=-1] to open with size based on the size
      of the underlying file *)

  val close : t -> unit
end = struct
  type t = { fn : string; fd : Unix.file_descr; mutable arr : int64_bigarray }

  (* NOTE sz=-1 is recognized by [map_file] as "derive from size of file"; if we want a
     different size (eg because we want the file to grow) we can provide it explicitly *)
  let open_ro ~fn ~sz =
    let shared = false in
    assert (Sys.file_exists fn);
    let fd = Unix.(openfile fn [ O_RDONLY ] 0o660) in
    let arr =
      let open Bigarray in
      Unix.map_file fd Int64 c_layout shared [| sz |] |> array1_of_genarray
    in
    { fn; fd; arr }

  let close t =
    Unix.close t.fd;
    (* following tries to make the array unreachable, so GC'able; however, no guarantee
       that arr actually is unreachable *)
    t.arr <- Bigarray.(Array1.create Int64 c_layout 0);
    ()
end

module Make (Io : Io.S) = struct
  module Io = Io
  module Errs = Io_errors.Make (Io)
  module Ao = Append_only_file.Make (Io) (Errs)

  module Mapping_file = struct
    (** The mapping file is created from a decreasing list of
        [(virtual_offset, 0, length)]. We first need to reverse it such that
        virtual offsets are in increasing order. *)
    let rev_inplace (src : int_bigarray) : unit =
      let src_sz = BigArr1.dim src in
      let _ =
        assert (src_sz >= 3);
        assert (src_sz mod 3 = 0)
      in
      let rec rev i j =
        if i < j then (
          let ioff, ilen = (src.{i}, src.{i + 2}) in
          let joff, jlen = (src.{j}, src.{j + 2}) in
          src.{i} <- joff;
          src.{i + 2} <- jlen;
          src.{j} <- ioff;
          src.{j + 2} <- ilen;
          rev (i + 3) (j - 3))
      in
      rev 0 (src_sz - 3)

    (** We then replace the [0] component of the triplets with the accumulated
        length. This yields triplets
        [(virtual_offset, physical_offset, length)], which will allow us to map
        virtual offsets to their physical location in the prefix file. *)
    let set_prefix_offsets src =
      let src_sz = BigArr1.dim src in
      let rec go i poff =
        if i < src_sz then (
          src.{i + 1} <- poff;
          let len = src.{i + 2} in
          go (i + 3) (poff + len))
      in
      go 0 0

    type t = { arr : int64_bigarray; path : string }

    let open_map ~path =
      match Io.classify_path path with
      | `File -> (
          let mmap = Int64_mmap.open_ro ~fn:path ~sz:(-1) in
          let arr = mmap.arr in
          let len = BigArr1.dim arr in
          match len > 0 && len mod 3 = 0 with
          | true ->
              Int64_mmap.close mmap;
              Ok { path; arr }
          | false ->
              Error
                (`Corrupted_mapping_file
                  (__FILE__
                  ^ ": mapping mmap size did not meet size requirements")))
      | _ -> Error (`No_such_file_or_directory path)

    let create ?report_mapping_size ~path ~register_entries () =
      let open Result_syntax in
      let* () =
        if Sys.word_size <> 64 then Error `Gc_forbidden_on_32bit_platforms
        else Ok ()
      in

      (* Unlink residual and ignore errors (typically no such file) *)
      Io.unlink path |> ignore;

      (* Create [file] *)
      let* file =
        Ao.create_rw ~path ~overwrite:true ~auto_flush_threshold:1_000_000
          ~auto_flush_procedure:`Internal
      in

      (* Fill and close [file] *)
      let append_entry ~off ~len =
        (* Write [off, 0, len] in native-endian encoding because it will be read
           with mmap. The [0] reserves the space for the future prefix offset. *)
        let buffer = Bytes.create 24 in
        Bytes.set_int64_ne buffer 0 (Int63.to_int64 off);
        Bytes.set_int64_ne buffer 8 Int64.zero;
        Bytes.set_int64_ne buffer 16 (Int64.of_int len);
        (* Bytes.unsafe_to_string usage: buffer is uniquely owned; we assume
           Bytes.set_int64_ne returns unique ownership; we give up ownership of buffer in
           conversion to string. This is safe. *)
        Ao.append_exn file (Bytes.unsafe_to_string buffer)
      in
      (* Check if we can collapse consecutive entries *)
      let current_entry = ref None in
      let register_entry ~off ~len =
        let current =
          match !current_entry with
          | None -> (off, len)
          | Some (off', len') ->
              if off >= off' then
                invalid_arg
                  "register_entry: offsets are not strictly decreasing";
              let dist = Int63.to_int (Int63.sub off' off) in
              if dist <= len then (off, dist + len')
              else (
                append_entry ~off:off' ~len:len';
                (off, len))
        in
        current_entry := Some current
      in
      let* () =
        Errs.catch (fun () ->
            register_entries ~register_entry;
            (* Flush pending entry *)
            match !current_entry with
            | None -> ()
            | Some (off, len) -> append_entry ~off ~len)
      in
      let* () = Ao.flush file in
      let* () = Ao.close file in

      (* Reopen [file] but as an mmap *)
      let file = Int_mmap.open_rw path in
      let* () =
        Errs.catch (fun () ->
            rev_inplace file.arr;
            set_prefix_offsets file.arr)
      in

      (* Flush and close new mapping [file] *)
      let* () = Errs.catch (fun () -> Unix.fsync file.fd) in
      Int_mmap.close file;

      let* mapping_size = Io.size_of_path path in
      Option.iter (fun f -> f mapping_size) report_mapping_size;

      (* Open created map *)
      open_map ~path

    let entry_count arr = BigArr1.dim arr / 3
    let entry_idx i = i * 3

    let conv_int64 : int64 -> int =
     fun i ->
      (if Sys.big_endian then (
       (* We are currently on a BE platform but the ints are encoded as LE in the
          file. We've just read a LE int using a BE decoding scheme. Let's fix
          this.

          The first step is to set [buf] to contain exactly what is stored on
          disk. Since the current platform is BE, we've interpreted what was
          written on disk using a BE decoding scheme. To do the opposite operation
          we must use a BE encoding scheme, hence [set_int64_be].

          Now that [buf] mimics what was on disk, the second step consist of
          decoding it using a LE function, hence [get_int64_le]. *)
       let buf = Bytes.create 8 in
       Bytes.set_int64_be buf 0 i;
       Bytes.get_int64_le buf 0)
      else i)
      |> Int64.to_int

    let entry_off arr i = arr.{entry_idx i} |> conv_int64 |> Int63.of_int
    let entry_poff arr i = arr.{entry_idx i + 1} |> conv_int64 |> Int63.of_int
    let entry_len arr i = arr.{entry_idx i + 2} |> conv_int64

    let iter_exn { arr; _ } f =
      for i = 0 to entry_count arr - 1 do
        f ~off:(entry_off arr i) ~len:(entry_len arr i)
      done

    let iter t f =
      Errs.catch (fun () ->
          iter_exn t f;
          ())

    type entry = { off : int63; poff : int63; len : int }

    let find_nearest_geq { arr; _ } off =
      let get arr i =
        let start = arr.{entry_idx i} |> conv_int64 in
        let len = entry_len arr i in
        start + len - 1
      in
      match
        Utils.nearest_geq ~arr ~get ~lo:0
          ~hi:(entry_count arr - 1)
          ~key:(Int63.to_int off)
      with
      | None -> None
      | Some i ->
          let off = entry_off arr i in
          let poff = entry_poff arr i in
          let len = entry_len arr i in
          Some { off; poff; len }
  end

  type t = { mapping : Mapping_file.t; data : Io.t }

  let v ~mapping ~data = { mapping; data }

  let open_ro ~mapping ~data =
    let open Result_syntax in
    let* mapping = Mapping_file.open_map ~path:mapping in
    let+ data = Io.open_ ~path:data ~readonly:true in
    v ~mapping ~data

  let get_mapping t = t.mapping
  let get_data t = t.data
  let close t = Io.close t.data
  let fsync t = Io.fsync t.data

  let get_poff { mapping; _ } ~off =
    match Mapping_file.find_nearest_geq mapping off with
    | None ->
        let s = Fmt.str "offset %a is after the sparse file" Int63.pp off in
        raise (Errors.Pack_error (`Invalid_sparse_read s))
    | Some entry when entry.off > off ->
        let s = Fmt.str "offset %a is in a sparse hole" Int63.pp off in
        raise (Errors.Pack_error (`Invalid_sparse_read s))
    | Some entry ->
        let open Int63.Syntax in
        let shift_in_entry = off - entry.off in
        let max_entry_len = Int63.of_int entry.len - shift_in_entry in
        let poff = entry.poff + off - entry.off in
        (poff, Int63.to_int max_entry_len)

  let read_exn t ~off ~len buf =
    let poff, max_entry_len = get_poff t ~off in
    if max_entry_len < len then raise (Errors.Pack_error `Read_out_of_bounds);
    Io.read_exn t.data ~off:poff ~len buf

  let read_range_exn t ~off ~min_len ~max_len buf =
    let poff, max_entry_len = get_poff t ~off in
    if max_entry_len < min_len then
      raise (Errors.Pack_error `Read_out_of_bounds);
    let len = min max_len max_entry_len in
    Io.read_exn t.data ~off:poff ~len buf

  let write_exn t ~off ~len str =
    let poff, max_entry_len = get_poff t ~off in
    assert (len <= max_entry_len);
    Io.write_exn t.data ~off:poff ~len str

  let next_valid_offset { mapping; _ } ~off =
    match Mapping_file.find_nearest_geq mapping off with
    | None -> None
    | Some entry ->
        let open Int63.Syntax in
        Some (if entry.off < off then off else entry.off)
end
