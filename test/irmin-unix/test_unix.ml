(*
 * Copyright (c) 2013-2021 Thomas Gazagnaire <thomas@gazagnaire.org>
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

open! Import

let stats () =
  let stats = Irmin_watcher.stats () in
  (stats.Irmin_watcher.watchdogs, Irmin.Backend.Watch.workers ())

(* GIT *)

module Git = struct
  let test_db = Test_git.test_db

  let init ~config =
    let test_db =
      Irmin.Backend.Conf.find_root config |> Option.value ~default:test_db
    in
    assert (test_db <> ".git");
    let+ () =
      if Sys.file_exists test_db then
        Git_unix.Store.v (Fpath.v test_db) >>= function
        | Ok t -> Git_unix.Store.reset t >|= fun _ -> ()
        | Error _ -> Lwt.return_unit
      else Lwt.return_unit
    in
    Irmin_unix.set_listen_dir_hook ()

  module S = struct
    module G = Git_unix.Store
    include Irmin_unix.Git.FS.KV (Irmin.Contents.String)

    let init = init
  end

  let store = (module S : Test_git.G)

  let clean ~config:_ =
    Irmin.Backend.Watch.(set_listen_dir_hook none);
    Lwt.return_unit

  let config =
    let head = Git.Reference.v "refs/heads/test" in
    Irmin_git.config ~head ~bare:true test_db

  let suite =
    let store = (module S : Irmin_test.S) in
    Irmin_test.Suite.create ~name:"GIT" ~init ~store ~config ~clean ~stats ()

  let test_non_bare () =
    let config = Irmin_git.config ~bare:false test_db in
    init ~config >>= fun () ->
    let info = Irmin_unix.info in
    let* repo = S.Repo.v config in
    let* t = S.main repo in
    S.set_exn t ~info:(info "fst one") [ "fst" ] "ok" >>= fun () ->
    S.set_exn t ~info:(info "snd one") [ "fst"; "snd" ] "maybe?" >>= fun () ->
    S.set_exn t ~info:(info "fst one") [ "fst" ] "hoho"

  let misc : unit Alcotest.test_case list =
    [ ("non-bare", `Quick, fun () -> Lwt_main.run (test_non_bare ())) ]
end

module Http = struct
  let servers = [ (`Quick, Git.suite) ]
end

module Conf = struct
  let test_config () =
    let hash = Irmin_unix.Resolver.Hash.find "blake2b" in
    let _, cfg =
      Irmin_unix.Resolver.load_config ~config_path:"test/irmin-unix/test.yml"
        ~store:"pack" ~contents:"string" ~hash ()
    in
    let spec = Irmin.Backend.Conf.spec cfg in
    let index_log_size =
      Irmin.Backend.Conf.get cfg Irmin_pack.Conf.Key.index_log_size
    in
    let fresh = Irmin.Backend.Conf.get cfg Irmin_pack.Conf.Key.fresh in
    Alcotest.(check string)
      "Spec name" "pack"
      (Irmin.Backend.Conf.Spec.name spec);
    Alcotest.(check int) "index-log-size" 1234 index_log_size;
    Alcotest.(check bool) "fresh" true fresh;
    Lwt.return_unit

  let misc : unit Alcotest.test_case list =
    [ ("config", `Quick, fun () -> Lwt_main.run (test_config ())) ]
end
