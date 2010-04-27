(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2010 Savonet team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details, fully stated in the COPYING
  file at the root of the liquidsoap distribution.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

 *****************************************************************************)

(** Decode files using an external decoder. *)

let log = Dtools.Log.make ["decoder";"external"]

let priority = Tutils.Non_blocking
let buf_size = 1024

(** First, an external decoder that receives
  * on its stdin. *)

(** This function is used to wrap around the "real" input.
  * It pipes its data to the external process and read
  * the available output. *)
let external_input process input =
  (** Open the external process, get its stdin/stdout *)
  let pull,push = Unix.open_process process in
  (** We operate on the Unix descriptors of 
    * the processe's stdio. *)
  let push_e = Unix.descr_of_out_channel push in
  let pull_e = Unix.descr_of_in_channel pull in
  (** We also need a pipe to wake up the task
    * when we want to force it to terminate. *)
  let pull_p,push_p = Unix.pipe () in
  (** We gonna wait on these events. *)
  let events = [`Read pull_p; `Write push_e] in
  (** These variables are used to synchronize 
    * between the main thread and the task's thread
    * when we terminate the task.. *)
  let is_task = ref true in
  let task_m = Mutex.create () in
  let task_c = Condition.create () in
  (** The function used to close the task. *)
  let close_task () =
    (** First, close the processes' stdout
      * as well as the task's side of the pipe. *)
    Unix.close push_e ;
    Unix.close pull_p ;
    (** Now grab the synchronization
      * lock, set is_task to false
      * and signal it to wake-up the main
      * thread waiting for the task to end.. *)
    Mutex.lock task_m ;
    is_task := false ;
    Condition.signal task_c ;
    Mutex.unlock task_m ;
    (** Finally, tell duppy that we are done
      * by returning an empty list of new tasks. *)
    []
  in
  (** The main task function. (rem,ofs,len)
    * is the remaining string to write. *)
  let rec task (rem,ofs,len) l =
    let rem,ofs,len = 
      (* If we are done with the current string,
       * try to get a new one from the original input. *)
      if ofs = len then
        let s,read = input buf_size in
        s,0,read
      else
        rem,ofs,len
   in
   let must_close = List.mem (`Read pull_p) l in
   (* If we could not get something to write or
    * if the close pipe contains something, we 
    * close the task. *)
   if len = 0 || must_close then begin
      close_task ()
   end else
     try
      (* Otherwise, we write and keep track of 
       * what was not written yet. *)
      let written = Unix.write push_e rem ofs len in
        if written <= 0 then close_task () else
          [{ Duppy.Task.
              priority = priority;
              events   = events;
              handler  = task (rem,ofs+written,len)
          }]
     with _ ->
       close_task ()
  in
    (** This initiates the task. *)
    Duppy.Task.add Tutils.scheduler
      { Duppy.Task.
          priority = priority;
          events   = events;
          handler  = task ("",0,0)
      } ;
    (* Now the new input, which reads the process's output *)
    (fun inlen ->
       let tmpbuf = String.create inlen in
       let read = Unix.read pull_e tmpbuf 0 inlen in
         tmpbuf, read),
    (* And a function to close the process *)
    (fun () -> 
      (* We grab the task's mutex. *)
      Mutex.lock task_m ;
      (* If the task has not yet ended, 
       * we write a char in the close pipe 
       * and wait for a signal from the task. *)
      if !is_task then
       begin
        ignore(Unix.write push_p " " 0 1) ;
        Condition.wait task_c task_m 
       end ;
      Mutex.unlock task_m ;
      (* Now we can close our side of 
       * the close pipe as well as the 
       * encoding process. *)
      Unix.close push_p ;
      ignore(Unix.close_process (pull,push)))

module Generator = Generator.From_audio_video
module Buffered = Decoder.Buffered(Generator)

(** A function to wrap around the Wav_decoder *)
let create process kind filename = 
  let close = ref (fun () -> ()) in
  let create input =
    let input,actual_close = external_input process input in
      close := actual_close ;
      Wav_decoder.D.create input
  in
  let generator = Generator.create `Audio in
  let dec = Buffered.file_decoder filename kind create generator in
  { dec with
     Decoder.close = 
      (fun () ->
         Tutils.finalize
          ~k:(fun () -> dec.Decoder.close ()) 
          !close) }

let test_kind f filename = 
  (* 0 = no audio, >= 1 = fixed number of channels,
   * -1 = variable audio channels. *)
  let ret = f filename in
  let audio =
    match ret with
      | 0 -> Frame.Zero
      | -1 -> Frame.Succ Frame.Variable
      | x -> Frame.mul_of_int x
  in
  { Frame.
      audio = audio ;
      video = Frame.Zero ;
      midi = Frame.Zero }

let register_stdin name sdoc test process =
    Decoder.file_decoders#register name ~sdoc
      (fun ~metadata filename kind ->
         let out_kind = test_kind test filename in
         (* Check that kind is more permissive than out_kind and
          * declare that our decoding function will respect out_kind. *)
         if Frame.kind_sub_kind kind out_kind then
           Some (fun () -> create process out_kind filename)
         else None)

(** Now an external decoder that directly operates
  * on the file. The remaining time in this case
  * can only be approximative. It is -1 while
  * the file is being decoded and the length
  * of the buffer when the external decoder
  * has exited. *)

let log = Dtools.Log.make ["decoder";"external";"oblivious"]

let external_input_oblivious process filename = 
  let process = process filename in
  let process_done = ref false in
  let pull = Unix.open_process_in process in
  let pull_e = Unix.descr_of_in_channel pull in
  let close () =
    if not !process_done then
     begin
      ignore(Unix.close_process_in pull);
      process_done := true
     end
  in
  let input len = 
    if not !process_done then
      let ret = String.create len in
      let read = Unix.read pull_e ret 0 len in
      if read = 0 then close () ; 
      ret,read
    else
      "",0
  in
  let gen = Generator.create `Audio in
  let prebuf = Frame.master_of_seconds 0.5 in
  let Decoder.Decoder decoder = Wav_decoder.D.create input in
  let fill frame = 
     begin try
      while Generator.length gen < prebuf && (not !process_done) do
        decoder gen
      done
     with
       | e ->
          log#f 4 "Decoding %s ended: %s." process (Printexc.to_string e) ;
          close ()
     end ;
     Generator.fill gen frame ;
     (** We return -1 while the process is not yet
       * finished. *)
    if !process_done then Generator.length gen else -1
  in 
  { Decoder.
     fill = fill ;
     close = close }

let register_oblivious name sdoc test process =
    Decoder.file_decoders#register name ~sdoc
      (fun ~metadata filename kind ->
         let out_kind = test_kind test filename in
         (* Check that kind is more permissive than out_kind and
          * declare that our decoding function will respect out_kind. *)
         if Frame.kind_sub_kind kind out_kind then
           Some (fun () -> external_input_oblivious process filename)
         else None)