(* Compile with: ocamlopt -thread -compact -inline 0 -noassert unix.cmxa threads.cmxa lowfi_in_ocaml.ml -o lowfi_in_ocaml && sstrip lowfi_in_ocaml *)
open Unix

type song = {
  url : string;
  title : string;
  number : int;
}

type app = {
  downloaded : song bounded_queue;
}

and 'a bounded_queue = {
  queue : 'a Queue.t;
  capacity : int;
  mutex : Mutex.t;
  not_empty : Condition.t;
  not_full : Condition.t;
}

let song_local_dir = Filename.concat (Filename.get_temp_dir_name ()) "lowfi"

let song_counter = ref 0

let create_bounded_queue capacity =
  {
    queue = Queue.create ();
    capacity;
    mutex = Mutex.create ();
    not_empty = Condition.create ();
    not_full = Condition.create ();
  }

let bounded_queue_push q item =
  Mutex.lock q.mutex;
  while Queue.length q.queue >= q.capacity do
    Condition.wait q.not_full q.mutex
  done;
  Queue.add item q.queue;
  Condition.signal q.not_empty;
  Mutex.unlock q.mutex

let bounded_queue_pop q =
  Mutex.lock q.mutex;
  while Queue.is_empty q.queue do
    Condition.wait q.not_empty q.mutex
  done;
  let item = Queue.take q.queue in
  Condition.signal q.not_full;
  Mutex.unlock q.mutex;
  item

let shell_quote s =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '\'';
  String.iter
    (function
      | '\'' -> Buffer.add_string b "'\"'\"'"
      | c -> Buffer.add_char b c)
    s;
  Buffer.add_char b '\'';
  Buffer.contents b

let getenv_opt name =
  try Some (Sys.getenv name) with Not_found -> None

let index_opt s ch =
  try Some (String.index s ch) with Not_found -> None

let fnv1a_sum64_string s =
  let hash = ref 0xcbf29ce484222325L in
  let prime = 0x100000001b3L in
  for i = 0 to String.length s - 1 do
    let byte = Int64.of_int (Char.code s.[i]) in
    hash := Int64.logxor !hash byte;
    hash := Int64.mul !hash prime
  done;
  !hash

let local_path song =
  Filename.concat song_local_dir (Int64.to_string (fnv1a_sum64_string song.url) ^ ".mp3")

let read_all_lines path =
  let ic = open_in path in
  let rec loop acc =
    match input_line ic with
    | line -> loop (line :: acc)
    | exception End_of_file ->
        close_in_noerr ic;
        List.rev acc
  in
  loop []

let locate_data_file name =
  let exe_dir = Filename.dirname Sys.executable_name in
  let candidate = Filename.concat exe_dir name in
  if Sys.file_exists candidate then candidate else name

let new_song line =
  match index_opt line '!' with
  | None -> { url = line; title = ""; number = 0 }
  | Some sep ->
      let url = String.sub line 0 sep in
      let title = String.sub line (sep + 1) (String.length line - sep - 1) in
      { url; title; number = 0 }

let create_songs () =
  match read_all_lines (locate_data_file "chillhop.txt") with
  | [] -> []
  | base_url :: rest -> List.map (fun line -> new_song (base_url ^ line)) rest

let songs = create_songs ()

let random_element xs =
  match xs with
  | [] -> None
  | _ -> Some (List.nth xs (Random.int (List.length xs)))

let should_be_present cmd =
  let path =
    match getenv_opt "PATH" with
    | Some value -> value
    | None -> ""
  in
  let entries = String.split_on_char ':' path in
  let rec exists = function
    | [] -> false
    | dir :: rest ->
        let dir = if dir = "" then "." else dir in
        let candidate = Filename.concat dir cmd in
        if Sys.file_exists candidate then (
          try
            Unix.access candidate [ X_OK ];
            true
          with Unix_error _ -> exists rest)
        else exists rest
  in
  if not (exists entries) then (
    prerr_endline ("This program needs " ^ cmd ^ " to work.");
    exit 1)

let run_shell_command cmd =
  Sys.command cmd

let download_local_file app osong counter =
  let song = { osong with number = counter } in
  let lpath = local_path song in
  if not (Sys.file_exists lpath) then
    let rec retry attempts =
      if attempts > 0 then
        let cmd =
          Printf.sprintf "wget --quiet --output-document=%s %s"
            (shell_quote lpath) (shell_quote song.url)
        in
        if run_shell_command cmd <> 0 then (
          Thread.delay 0.5;
          retry (attempts - 1))
    in
    retry 6;
  bounded_queue_push app.downloaded song

let add_random_song app =
  match random_element songs with
  | None -> ()
  | Some song ->
      incr song_counter;
      let counter = !song_counter in
      ignore (Thread.create (fun () -> download_local_file app song counter) ())

let remove_song song =
  let path = local_path song in
  try Sys.remove path with Sys_error _ -> ()

let add_another app song =
  remove_song song;
  add_random_song app

let create_app () = { downloaded = create_bounded_queue 5 }

let main () =
  should_be_present "mpg321";
  should_be_present "wget";
  Random.self_init ();
  (try Unix.mkdir song_local_dir 0o755 with Unix_error (EEXIST, _, _) -> ());
  Printf.printf "Local folder: %s\n%!" song_local_dir;
  let app = create_app () in
  for _ = 1 to 6 do
    add_random_song app
  done;
  while true do
    let song = bounded_queue_pop app.downloaded in
    Printf.printf "Playing \"%s\" from URL: %-40.40s ...\n%!" song.title song.url;
    let res = run_shell_command (Printf.sprintf "mpg321 --quiet %s" (shell_quote (local_path song))) in
    Printf.eprintf "res = %d\n%!" res;
    if res = 4 then (
      prerr_endline "mpv was interrupted by Ctrl-C. Good bye.";
      exit 1);
    add_another app song
  done

let () = main ()
