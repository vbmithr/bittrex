(* Continuously pump data from Bittrex and serves it with DTC *)

open Core
open Async
open Log.Global
open Cohttp_async

open Bs_devkit
open Btrex
module REST = Btrex_async
module DTC = Dtc_pb.Dtcprotocol_piqi

module DB = struct
  include Tick.MakeLDB(LevelDB)
  let store_trade_in_db ?sync db ~ts ~price ~qty ~side =
    put_tick ?sync db @@ Tick.create ~ts ~side ~p:price ~v:qty ()
end

module CtrlFile = struct
  type t = {
    fn : string ;
    bitv : Bitv.t
  }

  let open_file fn =
    try
      let ic = Caml.open_in_bin fn in
      try
        let bitv = Bitv.input_bin ic in
        Caml.close_in ic ;
        { fn ; bitv }
      with exn ->
        Caml.close_in ic ;
        raise exn
    with exn ->
      error "CtrlFile.open_file: %s" (Exn.to_string exn) ;
      { fn ; bitv = Bitv.create (365 * 24 * 10) false }

  let close { fn ; bitv } =
    let oc = Caml.open_out_bin fn in
    try
      Bitv.output_bin oc bitv ;
      Caml.close_out oc
    with exn ->
      Caml.close_out oc ;
      raise exn

  let genesis_date =
    Date.create_exn ~y:2017 ~m:Month.Jan ~d:1

  let genesis_ts =
    Time_ns.(of_date_ofday ~zone:Time.Zone.utc genesis_date Ofday.start_of_day)

  let jobs ?(start=genesis_date) { bitv } f =
    let idx = 24 * Date.diff start genesis_date in
    let now_ts = Time_ns.now () in
    let rec inner (i, thunks) =
      let start_ts = Time_ns.(add genesis_ts (Span.of_int_sec (i * 3600))) in
      let end_ts = Time_ns.(add start_ts (Span.of_int_sec 3600)) in
      let latest = Time_ns.(end_ts >= now_ts) in
      let thunks =
        if i >= 0 then begin
            if not (Bitv.get bitv i) || latest then
              begin fun () -> f ~start_ts ~end_ts >>| function
                | Error err -> error "%s" (REST.RestError.to_string err)
                | Ok _ -> Bitv.set bitv i true
              end :: thunks
            else thunks
          end
        else begin fun () ->
          f ~start_ts ~end_ts >>| Result.iter_error ~f:begin fun err ->
            error "%s" (REST.RestError.to_string err)
          end
        end :: thunks
      in
      if latest then thunks
      else inner (succ i, thunks)
    in inner (idx, [])
end

module Instrument = struct
  type t = {
    db : DB.db
  }

  let create ~db = { db }

  let ( // ) = Filename.concat

  let datadir = ref ("data" // "poloniex")
  let set_datadir d = datadir := d

  let db_path symbol =
    !datadir // symbol

  let load symbols =
    Deferred.Result.bind
      (REST.markets ~log:(Lazy.force log) ()) ~f:begin fun (resp, markets) ->
      let markets =
        List.fold_left markets ~init:String.Set.empty
          ~f:(fun a { Market.base ; quote } -> String.Set.add a (base ^ "-" ^ quote)) in
      let symbols_in_use =
        if String.Set.is_empty symbols then markets
        else String.Set.inter markets symbols in
      String.Set.fold symbols_in_use ~init:[] ~f:begin fun a symbol ->
        let db = DB.open_db (db_path symbol) in
        info "Loaded instrument %s" symbol ;
        (symbol, create ~db) :: a
      end |> fun res ->
      return (Ok res)
    end

  let active : t String.Table.t = String.Table.create ()
  let find = String.Table.find active
  let find_exn = String.Table.find_exn active

  let load symbols =
    Deferred.Result.map (load symbols) ~f:begin fun instruments ->
      List.fold_left instruments ~init:[] ~f:begin fun a (symbol, i) ->
        String.Table.add_exn active symbol i ;
        symbol :: a
      end
    end

  let close { db } =
    DB.close db

  let shutdown () =
    let nb_closed =
      String.Table.fold active ~init:0 ~f:begin fun ~key:_ ~data a ->
        close data ;
        succ a
      end in
    info "Saved %d dbs" nb_closed
end

let dry_run = ref false

let time_ns_of_ptime t =
  Ptime.to_float_s t |> fun s ->
  Int.of_float (s *. 1e9) |>
  Time_ns.of_int_ns_since_epoch

let mk_store_trade_in_db () =
  let tss = String.Table.create () in
  fun symbol { MarketHistory.timestamp ; price; qty; side } ->
    let ts = time_ns_of_ptime timestamp in
    if !dry_run || side = `buy_sell_unset then ()
    else
      let { Instrument.db } = Instrument.find_exn symbol in
      let ts = match String.Table.find tss symbol with
        | None ->
          String.Table.add_exn tss symbol (ts, 0); ts
        | Some (old_ts, _) when old_ts <> ts ->
          String.Table.set tss symbol (ts, 0); ts
        | Some (_, n) ->
          String.Table.set tss symbol (ts, succ n);
          Time_ns.(add ts @@ Span.of_int_ns @@ succ n)
      in
      let price = satoshis_int_of_float_exn price |> Int63.of_int in
      let qty = satoshis_int_of_float_exn qty |> Int63.of_int in
      DB.store_trade_in_db db ~ts ~price ~qty ~side

let store_trade_in_db = mk_store_trade_in_db ()

let write_message w (typ : DTC.dtcmessage_type) gen msg =
  let typ =
    Piqirun.(DTC.gen_dtcmessage_type typ |> to_string |> init_from_string |> int_of_varint) in
  let msg = (gen msg |> Piqirun.to_string) in
  let header = Bytes.create 4 in
  Binary_packing.pack_unsigned_16_little_endian ~buf:header ~pos:0 (4 + String.length msg) ;
  Binary_packing.pack_unsigned_16_little_endian ~buf:header ~pos:2 typ ;
  Writer.write w header ;
  Writer.write w msg

module Granulator = struct
  type t = {
    nb_streamed : int ;
    nb_processed : int ;
    start_ts : Time_ns.t ;
    end_ts : Time_ns.t ;
    record : DTC.Historical_price_data_record_response.t ;
  }

  let create
      ?(nb_streamed=0) ?(nb_processed=0) ?request_id
      ~ts ~price ~qty ~side ~span () =
    let record = DTC.default_historical_price_data_record_response () in
    record.request_id <- request_id ;
    record.start_date_time <- Some (seconds_int64_of_ts ts) ;
    record.open_price <- Some price ;
    record.high_price <- Some price ;
    record.low_price <- Some price ;
    record.last_price <- Some price ;
    record.volume <- Some qty ;
    record.num_trades <- Some 1l ;
    record.bid_volume <- if side = `buy then Some qty else None ;
    record.ask_volume <- if side = `sell then Some qty else None ;
    {
      nb_streamed ;
      nb_processed ;
      start_ts = ts ;
      end_ts = Time_ns.(add ts @@ Span.(span - nanosecond)) ;
      record ;
    }

  let add_tick ?request_id ~w ~span ~ts ~price ~qty ~side = function
    | None ->
      create ?request_id ~span ~ts ~price ~qty ~side ()
    | Some r ->
      if Time_ns.between ts ~low:r.start_ts ~high:r.end_ts then begin
        r.record.high_price <-
          Option.map r.record.high_price ~f:(Float.max price) ;
        r.record.low_price <-
          Option.map r.record.low_price ~f:(Float.min price) ;
        r.record.last_price <- Some price ;
        r.record.volume <-
          Option.map r.record.volume ~f:Float.(( + ) qty) ;
        r.record.num_trades <-
          Option.map r.record.num_trades ~f:Int32.succ ;
        r.record.bid_volume <-
          Option.map r.record.bid_volume ~f:begin fun b ->
            if side = `buy then b +. qty else b
          end ;
        r.record.ask_volume <-
          Option.map r.record.ask_volume ~f:begin fun a ->
            if side = `sell then a +. qty else a
          end ;
        { r with nb_processed = succ r.nb_processed }
      end
      else begin
        write_message w `historical_price_data_record_response
          DTC.gen_historical_price_data_record_response r.record ;
        create
          ?request_id
          ~nb_streamed:(succ r.nb_streamed)
          ~nb_processed:r.nb_processed
          ~span ~ts ~price ~qty ~side ()
      end
end

module TSet = Caml.Set.Make(MarketHistory)

let pump cache symbol =
  REST.markethistory symbol >>| Result.map ~f:begin fun (resp, trades) ->
    let trades =
      List.fold_left trades ~init:TSet.empty ~f:(fun a e -> TSet.add e a) in
    let new_trades = TSet.diff trades cache in
    let nb_trades, first_ts, last_ts = TSet.fold
        begin fun t (nb_trades, first_ts, last_ts) ->
          store_trade_in_db symbol t ;
          succ nb_trades,
          min first_ts t.timestamp,
          max last_ts t.timestamp
        end
        new_trades
        (0, Ptime.max, Ptime.min)
    in
    debug "%s: pumped %d trades from %s to %s" symbol nb_trades
      (Ptime.to_rfc3339 first_ts) (Ptime.to_rfc3339 last_ts) ;
    new_trades
  end

let pump_forever big_period_int symbols =
  let caches = String.Table.create () in
  let nb_symbols = List.length symbols in
  let big_period = Time_ns.Span.of_int_sec big_period_int in
  let small_period = big_period_int // nb_symbols |> Time_ns.Span.of_sec in
  List.fold_left symbols ~init:Time_ns.Span.zero ~f:begin fun start symbol ->
    String.Table.set caches symbol TSet.empty ;
    let span = Time_ns.Span.(start + small_period) in
    let start = Clock_ns.after span in
    Clock_ns.every big_period ~start ~continue_on_error:true begin fun () ->
      let cache = String.Table.find_exn caches symbol in
      don't_wait_for begin
        pump cache symbol >>| function
        | Ok new_cache ->
          String.Table.set caches symbol new_cache
        | Error err -> error "%s" (REST.RestError.to_string err)
      end
    end ;
    span
  end |> ignore

(* A DTC Historical Price Server. *)

let encoding_request addr w req =
  debug "<- [%s] Encoding Request" addr ;
  Dtc_pb.Encoding.(to_string (Response { version = 7 ; encoding = Protobuf })) |>
  Writer.write w ;
  debug "-> [%s] Encoding Response" addr

let accept_logon_request addr w req =
  let r = DTC.default_logon_response () in
  r.protocol_version <- Some 7l ;
  r.server_name <- Some "Bittrex Data" ;
  r.result <- Some `logon_success ;
  r.result_text <- Some "OK" ;
  r.symbol_exchange_delimiter <- Some "-" ;
  r.historical_price_data_supported <- Some true ;
  r.one_historical_price_data_request_per_connection <- Some true ;
  write_message w `logon_response DTC.gen_logon_response r ;
  debug "-> [%s] Logon Response" addr

let logon_request addr w msg =
  let req = DTC.parse_logon_request msg in
  debug "<- [%s] Logon Request" addr ;
  accept_logon_request addr w req

let heartbeat addr w msg =
  debug "<- [%s] Heartbeat" addr

let reject_historical_price_data_request ?reason_code w (req : DTC.Historical_price_data_request.t) k =
  let rej = DTC.default_historical_price_data_reject () in
  rej.request_id <- req.request_id ;
  rej.reject_reason_code <- reason_code ;
  Printf.ksprintf begin fun reject_text ->
    rej.reject_text <- Some reject_text ;
    write_message w `historical_price_data_reject
      DTC.gen_historical_price_data_reject rej ;
    debug "-> HistoricalPriceData reject %s" reject_text
  end k

let span_of_interval = function
  | `interval_10_seconds -> Time_ns.Span.of_int_sec 10
  | `interval_1_day -> Time_ns.Span.of_day 1.
  | `interval_1_minute -> Time_ns.Span.of_int_sec 60
  | `interval_1_second -> Time_ns.Span.of_int_sec 1
  | `interval_1_week -> Time_ns.Span.of_day 7.
  | `interval_2_seconds -> Time_ns.Span.of_int_sec 2
  | `interval_30_seconds -> Time_ns.Span.of_int_sec 30
  | `interval_4_seconds -> Time_ns.Span.of_int_sec 4
  | `interval_5_seconds -> Time_ns.Span.of_int_sec 5
  | `interval_tick -> Time_ns.Span.zero

let max_int_value = Int64.of_int_exn Int.max_value
let start_key = Bytes.create 8

let stream_tick_responses symbol
    ?stop db w (req : DTC.Historical_price_data_request.t) start =
  info "Streaming %s from %s (tick)" symbol Time_ns.(to_string start) ;
  let resp = DTC.default_historical_price_data_tick_record_response () in
  resp.request_id <- req.request_id ;
  resp.is_final_record <- Some false ;
  let nb_streamed =
    DB.HL.fold_left db ?stop ~start ~init:0 ~f:begin fun a t ->
      let p = Int63.to_float t.Tick.p /. 1e8 in
      let v = Int63.to_float t.v /. 1e8 in
      let side = match t.side with
        | `buy -> `at_ask
        | `sell -> `at_bid
        | `buy_sell_unset -> `bid_ask_unset in
      resp.date_time <- Some (float_of_ts t.ts) ;
      resp.price <- Some p ;
      resp.volume <- Some v ;
      resp.at_bid_or_ask <- Some side ;
      write_message w `historical_price_data_tick_record_response
        DTC.gen_historical_price_data_tick_record_response resp ;
      succ a ;
    end in
  let resp = DTC.default_historical_price_data_tick_record_response () in
  resp.request_id <- req.request_id ;
  resp.is_final_record <- Some true ;
  write_message w `historical_price_data_tick_record_response
    DTC.gen_historical_price_data_tick_record_response resp ;
  nb_streamed, nb_streamed

let stream_record_responses symbol
    ?stop db w (req : DTC.Historical_price_data_request.t) start span =
  info "Streaming %s from %s (%s)" symbol
    Time_ns.(to_string start) (Time_ns.Span.to_string span) ;
  let add_tick = Granulator.add_tick ~w ?request_id:req.request_id ~span in
  let r =
    DB.HL.fold_left db ~start ?stop ~init:None ~f:begin fun a t ->
      let price = Int63.to_float t.p /. 1e8 in
      let qty = Int63.to_float t.v /. 1e8 in
      Some (add_tick ~ts:t.ts ~price ~qty ~side:t.side a)
    end in
  Option.iter r ~f:begin fun r ->
    write_message w `historical_price_data_record_response
      DTC.gen_historical_price_data_record_response r.record ;
  end ;
  let resp = DTC.default_historical_price_data_record_response () in
  resp.request_id <- req.request_id ;
  resp.is_final_record <- Some true ;
  write_message w `historical_price_data_record_response
    DTC.gen_historical_price_data_record_response resp ;
  Option.value_map r ~default:0 ~f:(fun r -> r.nb_streamed),
  Option.value_map r ~default:0 ~f:(fun r -> r.nb_processed)

let accept_historical_price_data_request
    w (req : DTC.Historical_price_data_request.t) db symbol span =
  let hdr = DTC.default_historical_price_data_response_header () in
  hdr.request_id <- req.request_id ;
  hdr.record_interval <- req.record_interval ;
  hdr.use_zlib_compression <- Some false ;
  hdr.int_to_float_price_divisor <- Some 1e8 ;
  write_message w `historical_price_data_response_header
    DTC.gen_historical_price_data_response_header hdr ;
  let start =
    Option.value_map req.start_date_time ~default:0L ~f:Int64.(( * ) 1_000_000_000L) |>
    Int64.to_int_exn |>
    Time_ns.of_int_ns_since_epoch |>
    Time_ns.(max epoch) in
  let stop =
    Option.value_map req.end_date_time ~default:0L ~f:Int64.(( * ) 1_000_000_000L) |>
    Int64.to_int_exn |>
    Time_ns.of_int_ns_since_epoch in
  let stop = if stop = Time_ns.epoch then None else Some stop in
  if span = Time_ns.Span.zero then (* streaming tick responses *)
    stream_tick_responses symbol ?stop db w req start
  else
    stream_record_responses symbol ?stop db w req start span

let historical_price_data_request addr w msg =
  let req = DTC.parse_historical_price_data_request msg in
  begin match req.symbol, req.exchange with
    | Some symbol, Some exchange ->
      debug "<- [%s] Historical Data Request %s %s" addr symbol exchange ;
    | _ -> ()
  end ;
  let span =
    Option.value_map ~default:Time_ns.Span.zero
      ~f:span_of_interval req.record_interval in
  match req.symbol, req.exchange with
  | None, _ ->
    reject_historical_price_data_request
      ~reason_code:`hpdr_unable_to_serve_data_do_not_retry
      w req "Symbol not specified" ;
    raise Exit
  | Some symbol, _ ->
    match Instrument.find symbol with
    | None ->
      reject_historical_price_data_request
        ~reason_code:`hpdr_unable_to_serve_data_do_not_retry
        w req "No such symbol" ;
      raise Exit
    | Some { db } -> don't_wait_for begin
        In_thread.run begin fun () ->
          accept_historical_price_data_request w req db symbol span
        end >>| fun (nb_streamed, nb_processed) ->
        info "Streamed %d/%d records from %s"
          nb_streamed nb_processed symbol
      end

let dtcserver ~server ~port =
  let server_fun addr r w =
    let addr = Socket.Address.Inet.to_string addr in
    (* So that process does not allocate all the time. *)
    let rec handle_chunk consumed buf ~pos ~len =
      if len < 2 then return @@ `Consumed (consumed, `Need_unknown)
      else
        let msglen = Bigstring.unsafe_get_int16_le buf ~pos in
        debug "handle_chunk: pos=%d len=%d, msglen=%d" pos len msglen;
        if len < msglen then return @@ `Consumed (consumed, `Need msglen)
        else begin
          let msgtype_int = Bigstring.unsafe_get_int16_le buf ~pos:(pos+2) in
          let msgtype : DTC.dtcmessage_type =
            DTC.parse_dtcmessage_type (Piqirun.Varint msgtype_int) in
          let msg_str = Bigstring.To_string.subo buf ~pos:(pos+4) ~len:(msglen-4) in
          let msg = Piqirun.init_from_string msg_str in
          begin match msgtype with
            | `encoding_request ->
              begin match (Dtc_pb.Encoding.read (Bigstring.To_string.subo buf ~pos ~len:16)) with
                | None -> error "Invalid encoding request received"
                | Some msg -> encoding_request addr w msg
              end
            | `logon_request -> logon_request addr w msg
            | `heartbeat -> heartbeat addr w msg
            | `historical_price_data_request -> historical_price_data_request addr w msg
            | #DTC.dtcmessage_type ->
              error "Unknown msg type %d" msgtype_int
          end ;
          handle_chunk (consumed + msglen) buf (pos + msglen) (len - msglen)
        end
    in
    let on_connection_io_error exn =
      error "on_connection_io_error (%s): %s" addr Exn.(to_string exn)
    in
    let cleanup () =
      info "client %s disconnected" addr ;
      Deferred.all_unit [Writer.close w; Reader.close r]
    in
    Deferred.ignore @@ Monitor.protect ~finally:cleanup begin fun () ->
      Monitor.detach_and_iter_errors Writer.(monitor w) ~f:on_connection_io_error;
      Reader.(read_one_chunk_at_a_time r ~handle_chunk:(handle_chunk 0))
    end
  in
  let on_handler_error_f addr exn =
    match Monitor.extract_exn exn with
    | Exit -> ()
    | exn ->
      error "on_handler_error (%s): %s"
        Socket.Address.(to_string addr) Exn.(to_string exn)
  in
  Conduit_async.serve
    ~on_handler_error:(`Call on_handler_error_f)
    server (Tcp.on_port port) server_fun

let run ?start port no_pump symbols =
  Instrument.load symbols >>= function
  | Error err ->
    error "%s" (REST.RestError.to_string err) ;
    Deferred.unit
  | Ok symbols ->
    info "Data server starting";
    dtcserver ~server:`TCP ~port >>= fun server ->
    if not no_pump then
      pump_forever 20 symbols ;
    Tcp.Server.close_finished server

let main dry_run' no_pump start port daemon datadir pidfile logfile loglevel symbols () =
  dry_run := dry_run';
  Instrument.set_datadir datadir ;
  set_level @@ loglevel_of_int loglevel;
  if daemon then Daemon.daemonize ~cd:"." ();
  Signal.handle Signal.terminating ~f:begin fun _ ->
    info "Data server stopping";
    don't_wait_for begin
      Instrument.shutdown () ;
      Shutdown.exit 0
    end
  end ;
  stage begin fun `Scheduler_started ->
    Core.Unix.RLimit.(set num_file_descriptors { cur = Limit 4096L ; max = Limit 4096L }) ;
    Lock_file.create_exn pidfile >>= fun () ->
    Writer.open_file ~append:true logfile >>= fun log_writer ->
    set_output Log.Output.[stderr (); writer `Text log_writer];
    run ?start port no_pump (String.Set.of_list symbols)
  end

let command =
  let spec =
    let open Command.Spec in
    empty
    +> flag "-dry-run" no_arg ~doc:" Do not write trades in DBs"
    +> flag "-no-pump" no_arg ~doc:" Do not pump trades"
    +> flag "-start" (optional date) ~doc:"float Start gathering history N days in the past (default: use start file)"
    +> flag "-port" (optional_with_default 5576 int) ~doc:"int TCP port to use (5576)"
    +> flag "-daemon" no_arg ~doc:" Run as a daemon"
    +> flag "-datadir" (optional_with_default (Filename.concat "data" "bittrex") string) ~doc:"path Where to store DBs (data)"
    +> flag "-pidfile" (optional_with_default (Filename.concat "run" "btrex_data.pid") string) ~doc:"filename Path of the pid file (run/btrex_data.pid)"
    +> flag "-logfile" (optional_with_default (Filename.concat "log" "btrex_data.log") string) ~doc:"filename Path of the log file (log/btrex_data.log)"
    +> flag "-loglevel" (optional_with_default 1 int) ~doc:"1-3 loglevel"
    +> anon (sequence ("symbol" %: string))
  in
  Command.Staged.async ~summary:"Bittrex data aggregator" spec main

let () = Command.run command
