open Lwt.Infix

let src = Logs.Src.create "tcp.mirage" ~doc:"TCP mirage"
module Log = (val Logs.src_log src : Logs.LOG)

module Make (R : Mirage_random.S) (Mclock : Mirage_clock.MCLOCK) (Time : Mirage_time.S) (Ip : Tcpip.Ip.S with type ipaddr = Ipaddr.t) = struct

  let now () = Mtime.of_uint64_ns (Mclock.elapsed_ns ())

  type error = Tcpip.Tcp.error

  let pp_error = Tcpip.Tcp.pp_error

  type write_error = Tcpip.Tcp.write_error

  let pp_write_error = Tcpip.Tcp.pp_write_error

  type ipaddr = Ipaddr.t

  module Port_map = Map.Make (struct
      type t = int
      let compare (a : int) (b : int) = compare a b
    end)

  type t = {
    mutable tcp : Utcp.state ;
    ip : Ip.t ;
    mutable waiting : (unit, [ `Eof | `Msg of string ]) result Lwt_condition.t Utcp.FM.t ;
    mutable listeners : (flow -> unit Lwt.t) Port_map.t ;
  }
  and flow = t * Utcp.flow

  let dst (_t, flow) =
    let _, (dst, dst_port) = Utcp.peers flow in
    dst, dst_port

  let output_ip t (src, dst, seg) =
    let size = Utcp.Segment.length seg in
    Log.debug (fun m -> m "output to %a: %a" Ipaddr.pp dst Utcp.Segment.pp seg);
    Ip.write t.ip ~src dst `TCP ~size
      (fun buf ->
         Utcp.Segment.encode_and_checksum_into (now ()) buf ~src ~dst seg;
         size) []

  let output_ign t segs =
    List.fold_left (fun r seg ->
        r >>= fun () ->
        output_ip t seg >|= function
        | Error e ->
          let _, dst, _ = seg in
          Log.err (fun m -> m "error sending data to %a: %a" Ipaddr.pp dst Ip.pp_error e)
        | Ok () -> ())
      Lwt.return_unit segs

  let read (t, flow) =
    match Utcp.recv t.tcp (now ()) flow with
    | Ok (tcp, data, segs) ->
      t.tcp <- tcp ;
      output_ign t segs >>= fun () ->
      if Cstruct.length data = 0 then (
        let cond = Lwt_condition.create () in
        t.waiting <- Utcp.FM.add flow cond t.waiting;
        Lwt_condition.wait cond >>= fun r ->
        t.waiting <- Utcp.FM.remove flow t.waiting;
        match r with
        | Error `Eof ->
          Lwt.return (Ok `Eof)
        | Error `Msg msg ->
          Log.err (fun m -> m "%a error %s from condition while recv" Utcp.pp_flow flow msg);
          (* TODO better error *)
          Lwt.return (Error `Refused)
        | Ok () ->
          match Utcp.recv t.tcp (now ()) flow with
          | Ok (tcp, data, segs) ->
            t.tcp <- tcp ;
            output_ign t segs >>= fun () ->
            if Cstruct.length data = 0 then
              Lwt.return (Ok `Eof) (* can this happen? *)
            else
              Lwt.return (Ok (`Data data))
          | Error `Eof ->
            Lwt.return (Ok `Eof)
          | Error `Msg msg ->
            Log.err (fun m -> m "%a error while read (second recv) %s" Utcp.pp_flow flow msg);
            (* TODO better error *)
            Lwt.return (Error `Refused)
      ) else (
        Lwt.return (Ok (`Data data)))
    | Error `Eof ->
      Lwt.return (Ok `Eof)
    | Error `Msg msg ->
      Log.err (fun m -> m "%a error while read %s" Utcp.pp_flow flow msg);
      (* TODO better error *)
      Lwt.return (Error `Refused)

  let write (t, flow) buf =
    match Utcp.send t.tcp (now ()) flow buf with
    | Ok (tcp, segs) ->
      t.tcp <- tcp ;
      output_ign t segs >|= fun () ->
      Ok ()
    | Error `Msg msg ->
      Log.err (fun m -> m "%a error while write %s" Utcp.pp_flow flow msg);
      (* TODO better error *)
      Lwt.return (Error `Refused)

  let writev flow bufs = write flow (Cstruct.concat bufs)

  let close (t, flow) =
    (* TODO at some point, in FM the condition must be signalled *)
    match Utcp.close t.tcp (now ()) flow with
    | Ok (tcp, segs) ->
      t.tcp <- tcp ;
      output_ign t segs
    | Error `Msg msg ->
      Log.err (fun m -> m "%a error in close: %s" Utcp.pp_flow flow msg);
      Lwt.return_unit

  let write_nodelay flow buf = write flow buf

  let writev_nodelay flow bufs = write flow (Cstruct.concat bufs)

  let create_connection ?keepalive:_ t (dst, dst_port) =
    let src = Ip.src t.ip ~dst in
    let tcp, id, seg = Utcp.connect ~src ~dst ~dst_port t.tcp (now ()) in
    t.tcp <- tcp;
    output_ip t seg >>= function
    | Error e ->
      Log.err (fun m -> m "%a error sending syn: %a" Utcp.pp_flow id Ip.pp_error e);
      Lwt.return (Error `Refused)
    | Ok () ->
      let cond = Lwt_condition.create () in
      t.waiting <- Utcp.FM.add id cond t.waiting;
      Lwt_condition.wait cond >|= fun r ->
      t.waiting <- Utcp.FM.remove id t.waiting;
      match r with
      | Ok () -> Ok (t, id)
      | Error `Eof ->
        Log.err (fun m -> m "%a error establishing connection (timeout)" Utcp.pp_flow id);
        (* TODO better error *)
        Error `Timeout
      | Error `Msg msg ->
        Log.err (fun m -> m "%a error establishing connection: %s" Utcp.pp_flow id msg);
        (* TODO better error *)
        Error `Timeout

  let input t ~src ~dst data =
    let tcp, ev, segs = Utcp.handle_buf t.tcp (now ()) ~src ~dst data in
    t.tcp <- tcp;
    let find ?f ctx id r =
      match Utcp.FM.find_opt id t.waiting with
      | Some c -> Lwt_condition.signal c r
      | None -> match f with
        | Some f -> f ()
        | None -> Log.debug (fun m -> m "%a not found in waiting (%s)" Utcp.pp_flow id ctx)
    in
    Option.fold ~none:()
      ~some:(function
          | `Established id ->
            let ctx = "established" in
            let f () =
              let (_, port), _ = Utcp.peers id in
              match Port_map.find_opt port t.listeners with
              | None ->
                Log.debug (fun m -> m "%a not found in waiting or listeners (%s)"
                              Utcp.pp_flow id ctx)
              | Some cb ->
                (* NOTE we start an asynchronous task with the callback *)
                Lwt.async (fun () -> cb (t, id))
            in
            find ~f ctx id (Ok ())
          | `Drop (id, recv) ->
            if recv then
              find "drop" id (Ok ())
            else
              find "drop" id (Error `Eof)
          | `Received id -> find "received" id (Ok ()))
      ev;
    (* TODO do not ignore IP write error *)
    output_ign t segs

  let connect id ip =
    Log.info (fun m -> m "starting µTCP on %S" id);
    let tcp = Utcp.empty id R.generate in
    let t = { tcp ; ip ; waiting = Utcp.FM.empty ; listeners = Port_map.empty } in
    Lwt.async (fun () ->
        let timer () =
          let tcp, drops, outs = Utcp.timer t.tcp (now ()) in
          t.tcp <- tcp;
          List.iter (fun (id, err) ->
              match Utcp.FM.find_opt id t.waiting with
              | None -> Log.debug (fun m -> m "%a not found in waiting" Utcp.pp_flow id)
              | Some c ->
                let err = match err with
                  | `Retransmission_exceeded -> `Msg "retransmission exceeded"
                  | `Timer_2msl -> `Eof
                  | `Timer_connection_established -> `Eof
                  | `Timer_fin_wait_2 -> `Eof
                in
                Lwt_condition.signal c (Error err))
            drops ;
          (* TODO do not ignore IP write error *)
          Lwt_list.iter_p (fun data -> output_ip t data >|= ignore) outs
        and timeout () =
          Time.sleep_ns (Duration.of_ms 100)
        in
        let rec go () =
          Lwt.join [ timer () ; timeout () ] >>= fun () ->
          (go [@tailcall]) ()
        in
        go ());
    t

  let listen t ~port ?keepalive:_ callback =
    let tcp = Utcp.start_listen t.tcp port in
    t.tcp <- tcp;
    t.listeners <- Port_map.add port callback t.listeners

  let unlisten t ~port =
    let tcp = Utcp.stop_listen t.tcp port in
    t.tcp <- tcp;
    t.listeners <- Port_map.remove port t.listeners

  let disconnect _t =
    Lwt.return_unit
end
