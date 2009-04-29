(* Lightweight thread library for Objective Caml
 * http://www.ocsigen.org/lwt
 * Module Lwt_main
 * Copyright (C) 2009 Jérémie Dimino
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as
 * published by the Free Software Foundation, with linking exceptions;
 * either version 2.1 of the License, or (at your option) any later
 * version. See COPYING file for details.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA
 * 02111-1307, USA.
 *)

open Lwt

type 'a hook = 'a ref
type 'a hooks = 'a hook list ref

let add_hook hook hooks = hooks := hook :: !hooks
let remove_hook hook hooks = hooks := List.filter ((!=) hook) !hooks

type fd_set = Unix.file_descr list
type current_time = float Lazy.t
type select = fd_set -> fd_set -> fd_set -> float option -> current_time * fd_set * fd_set * fd_set

let select_filters = ref []

let min_timeout a b = match a, b with
  | None, b -> b
  | a, None -> a
  | Some a, Some b -> Some(min a b)

let apply_filters select =
  let now = Lazy.lazy_from_fun Unix.gettimeofday in
  List.fold_left (fun select filter -> !filter now select) select !select_filters

let bad_fd fd =
  try ignore (Unix.LargeFile.fstat fd); false with
      Unix.Unix_error (_, _, _) ->
        true

let default_select set_r set_w set_e timeout =
  let set_r, set_w, set_e =
    if (set_r = [] && set_w = [] && set_e = [] && timeout = Some 0.0) then
      (* If there is nothing to monitor and there is no timeout,
         save one system call: *)
      ([], [], [])
    else
      (* Blocking call to select: *)
      try
        Unix.select set_r set_w set_e (match timeout with None -> -1.0 | Some t -> t)
      with
        | Unix.Unix_error (Unix.EINTR, _, _) ->
            ([], [], [])
        | Unix.Unix_error (Unix.EBADF, _, _) ->
            (* On failure, keeps only bad file
               descriptors. Actions registered on them have to
               handle the error: *)
            (List.filter bad_fd set_r,
             List.filter bad_fd set_w,
             List.filter bad_fd set_e)
  in
  (Lazy.lazy_from_fun Unix.gettimeofday, set_r, set_w, set_e)

let default_iteration _ = ignore (apply_filters default_select [] [] [] None)

let main_loop_iteration = ref default_iteration

let rec run t =
  match Lwt.poll t with
    | Some x ->
        x
    | None ->
        !main_loop_iteration ();
        run t

let exit_hooks = ref []

let rec call_hooks _ = match !exit_hooks with
  | [] ->
      return ()
  | hook :: rest ->
      exit_hooks := rest;
      (try_lwt !hook () with _ -> return ()) >>= call_hooks

let _ = at_exit (fun _ -> run (call_hooks ()))