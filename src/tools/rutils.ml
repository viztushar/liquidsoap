(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2009 Savonet team

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

 (** Resampling module *)
 
 (** TODO: video *)

 type audio_converter =
            ?audio_src_rate:float ->
            Frame.audio_t array -> Frame.audio_t array*int

 let create_audio () = 
    let audio_converters = Hashtbl.create 2 in 
    let audio_dst_rate = 
      float (Lazy.force Frame.audio_rate)
    in
    (fun ?audio_src_rate audio_buf ->
      let process_audio audio_src_rate =  
        (** Create new converters if needed, 
          * remove unused converters *)
        let new_audio_chans = Array.length audio_buf in
        let old_audio_chans = Hashtbl.length audio_converters in
        if old_audio_chans < new_audio_chans then
          for i = old_audio_chans to new_audio_chans - 1 do 
            Hashtbl.add audio_converters i (Audio_converter.Samplerate.create 1)
          done ;
        if new_audio_chans < old_audio_chans then
          for i = new_audio_chans to new_audio_chans - 1 do
            Hashtbl.remove audio_converters i
          done ;
        let resample_chan n buf =
          let resampler = Hashtbl.find audio_converters n in 
          let ret = 
            Audio_converter.Samplerate.resample
            resampler (audio_dst_rate /. audio_src_rate)
            [|buf|] 0 (Array.length buf)
          in
          ret.(0)
        in
        let ret = Array.mapi resample_chan audio_buf in
        ret,Array.length ret.(0)
      in
      let audio_rate = 
        match audio_src_rate with
          | Some rate -> rate
          | None -> audio_dst_rate
      in
      process_audio audio_rate)

  type s16le_converter = 
          audio_src_rate:float ->
          string -> Frame.audio_t array * int

  let create_from_s16le ~channels ~samplesize ~signed ~big_endian () = 
    let audio_dst_rate =
      float (Lazy.force Frame.audio_rate)
    in
    (fun ~audio_src_rate src ->
      let sample_bytes = samplesize / 8 in
      let ratio = audio_dst_rate /. audio_src_rate in
      (* Compute the length in samples, in the source data,
       * then in the destination format, adding 1 to prevent rounding bugs. *)
      let len_src = (String.length src) / (sample_bytes*channels) in
      (* Adding 1 just in case the resampler doesn't round like us.
       * Currently it always truncates which means that data is dropped:
       * a proper resampling would have to be stateful. *)
      let len_dst = 1 + int_of_float (float len_src *. ratio) in
      let dst = Array.init channels (fun _ -> Array.make len_dst 0.) in
      let len_dst =
        Float_pcm.resample_s16le
          src 0 len_src signed samplesize big_endian
          ratio dst 0
      in
        dst, Frame.master_of_audio len_dst)
