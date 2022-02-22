(** Alternative IO interface for pack_store.

This uses the object store, suffix file, control and meta to implement the normal
irmin-pack [IO] interface. 

6GB snapshot size, 30M objects, 6000/30 = 200 bytes average object size; 




*)

[@@@warning "-27"]

open! Import
(* open Util *)

open struct
  module Sparse = Sparse_file
end

type commit_hash_s = string

(** Setting this to Some will trigger GC on the next IO operation (this is just for
    initial testing) *)
let trigger_gc : commit_hash_s option ref = ref None


(** NOTE this interface is documented also in https://github.com/mirage/irmin/pull/1758 *)
module type S = sig 
  type t
    
  val v : version:Lyr_version.t option -> fresh:bool -> readonly:bool -> string -> t
  (** Handling of version is a bit subtle in the existing implementation in IO.ml; eg
      opening a V2 with V1 fails! *)

  (* NOTE that there is a kind of caching of IO.t instances in irmin-pack, and this may
     assume that an IO.t has a name that refers to a non-directory file; for this reason,
     we might want to implement our layers via a control file, rather than storing
     everything in a subdir; but since a subdir is so much cleaner, let's just patch up
     the caching if it is broken *)

  (* following are file-like *)
  val readonly : t -> bool


  val flush : t -> unit
  val close : t -> unit
  val offset : t -> int63
  (** For readonly instances, offset is the last offset returned by force_offset; this is
      used to trigger updates to the dictionary and index *)

  val read : t -> off:int63 -> bytes -> int
  val append : t -> string -> unit
  (* NOTE this is an append-only file *)

  val truncate : t -> unit
  (* FIXME not clear that we can implement this using layers; removing for time being as
     probably not needed? Although if we allow "fresh" as an open option, we presumably do
     have to implement it; OK; just start from a fresh instance *)

  (* These are not file-like; some doc added in {!IO_intf}. *)
  val version : t -> Lyr_version.t
  val set_version : t -> Lyr_version.t -> unit
  val name : t -> string
  (* This is just the "filename"/path used when opening the IO instance *)

  val force_offset : t -> int63 
  (* 
I think this is for readonly instances, to allow them to detect that there is more data to
read... except that RO instances only read from particular offsets - there is no need for
them to "keep up with" a log file, for example. Instead, it is used to indicate to the RO instance that it needs to resync the dict and index

     
See doc in ../IO_intf.ml We probably have something like this for the layers: the
     suffix file likely contains metadata for the last synced position. NOTE there are
     various bits of metadata, some of which we consult more often than others; for
     example, the layered store has a "generation" incremented on each GC; but we also
     have "version" which changes rarely, and "max_flushed_offset" which probably changes
     quite a lot. If these are all in the same file, then potentially changes to eg
     "max_flushed_offset" are detected as "some change to metadata" and RO instances then
     reload the entire metadata. This is a bit inefficient. We really want to detect
     changes to one piece of metadata independently of another piece. The best way to do
     this is with an mmap'ed file for the per-file changes (version, max_flushed_offset,
     etc) and only change the control file when the generation changes. *)

  (* val set_read_logger: t -> out_channel option -> unit   *)

end


(** Private implementation *)
module Private = struct

  include Pre_io

  
  (* FIXME is fresh=true ever used in the codebase? what about fresh=true, readonly=true?
     is this allowed?
     
     is fresh,version allowed?

     Documentation from IO_intf:

If [path] exists: 
  if [fresh]:
    - version must be (Some _)
    - version meta is updated to match that supplied as argument (even if this results in a
      downgrade of the version from [`V2] to [`V1]; even in readonly mode)
    - the offset is positioned at zero (the intent is probably to make the file appear
      truncated, but this is not what actually happens)
  if [not fresh]:
    - meta version is loaded
    - if meta version is > than that supplied as argument, fail
    
If [path] does not exist:
  - version must be (Some _)
  - instance is created with the supplied version (even if readonly is true)

  *)
  let v ~version:(ver0:Lyr_version.t option) ~fresh ~readonly path = 
    let exists = Sys.file_exists path in
    let ( --> ) a b = (not a) || b in
    assert(not exists --> Option.is_some ver0);
    assert(not (readonly && fresh)); (* FIXME this is allowed in the existing code *)
    match exists with 
    | false -> (
        assert(not exists);
        assert(Option.is_some ver0);
        ignore(fresh);
        match readonly with
        | true -> 
          (* FIXME in the existing code, opening readonly will create the file if it
             doesn't exist *)
          Fmt.failwith 
            "%s: Cannot open a non-existent file %s in readonly mode." __FILE__ path
        | false -> 
          assert(not exists);
          assert(not readonly);
          assert(Option.is_some ver0);
          let t = create ~fn:path in
          let ver0 = Option.get ver0 in
          let _ = set_version t ver0 in
          let _ = flush t in
          t)
    | true -> (
        assert(exists);
        assert(fresh --> Option.is_some ver0);        
        let t = open_ ~readonly ~fn:path in
        (* handle fresh and ver0 *)
        begin 
          match fresh with
          | false -> 
            assert(exists);
            assert(not fresh);
            assert(List.mem (version t) [`V1;`V2]);
            let _check_versions =
              let version_lt v1 v2 = Lyr_version.compare v1 v2 < 0 in
              match ver0 with
              | None -> ()
              | Some ver0 -> 
                match version_lt ver0 (version t) with
                | true ->
                  Fmt.failwith 
                    "%s: attempt to open %s, V%d file, using older V%d version" __FILE__ 
                    path 
                    (version t |> Lyr_version.to_int) 
                    (ver0 |> Lyr_version.to_int)
                | false -> ()
            in
            ()
          | true -> 
            assert(exists);
            assert(fresh);
            assert(not readonly); (* FIXME *)
            assert(Option.is_some ver0);
            let ver0 = Option.get ver0 in
            (* if fresh, then we want to bump the generation number and switch to a new
               suffix/sparse *)
            let gen' = Control.get_generation t.control +1 in
            let sparse = Sparse.create ~path:(sparse_name ~generation:gen') in
            let suffix = 
              let suffix_offset = 0 in
              Suffix.create ~root:(suffix_name ~generation:gen') ~suffix_offset in
            let old_sparse,old_suffix = t.sparse,t.suffix in
            t.sparse <- sparse;
            t.suffix <- suffix;
            Control.(set t.control generation_field gen');
            (* FIXME potential problem if update to generation is seen without the update to
               last_synced_offset_field? *)
            Control.(set t.control last_synced_offset_field 0); 
            set_version t ver0; (* use the provided version, not any in the existing file *)
            Control.fsync t.control;
            Sparse.close old_sparse;
            Suffix.close old_suffix;
            (* FIXME delete old generation sparse+suffix here *)            
        end;
        t)


end (* Private *)

module _  = (Private : S) (* check it matches the intf *)

include (Private (*: S *)) (* expose the underlying impl for now *)
