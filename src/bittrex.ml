open Core
open Async

open Bs_devkit
open Btrex
open Btrex_async

module Encoding = Dtc_pb.Encoding
module DTC = Dtc_pb.Dtcprotocol_piqi

let write_message w (typ : DTC.dtcmessage_type) gen msg =
  if Writer.is_open w then begin
    let typ =
      Piqirun.(DTC.gen_dtcmessage_type typ |> to_string |> init_from_string |> int_of_varint) in
    let msg = (gen msg |> Piqirun.to_string) in
    let header = Bytes.create 4 in
    Binary_packing.pack_unsigned_16_little_endian ~buf:header ~pos:0 (4 + String.length msg) ;
    Binary_packing.pack_unsigned_16_little_endian ~buf:header ~pos:2 typ ;
    Writer.write w header ;
    Writer.write w msg
  end

let rec loop_log_errors ?log f =
  let rec inner () =
    Monitor.try_with_or_error ~name:"loop_log_errors" f >>= function
    | Ok _ -> assert false
    | Error err ->
      Option.iter log ~f:(fun log -> Log.error log "run: %s" @@ Error.to_string_hum err);
      inner ()
  in inner ()

let conduit_server ~tls ~crt_path ~key_path =
  if tls then
    Sys.file_exists crt_path >>= fun crt_exists ->
    Sys.file_exists key_path >>| fun key_exists ->
    match crt_exists, key_exists with
    | `Yes, `Yes -> `OpenSSL (`Crt_file_path crt_path, `Key_file_path key_path)
    | _ -> failwith "TLS crt/key file not found"
  else
  return `TCP

let my_exchange = "BTREX"
let exchange_account = "exchange"
let margin_account = "margin"
let update_client_span = ref @@ Time_ns.Span.of_int_sec 30
let sc_mode = ref false

let log_btrex =
  Log.create ~level:`Error ~on_error:`Raise ~output:Log.Output.[stderr ()]
let log_dtc =
  Log.create ~level:`Error ~on_error:`Raise ~output:Log.Output.[stderr ()]

let subid_to_sym : String.t Int.Table.t = Int.Table.create ()

let currencies : Currency.t String.Table.t = String.Table.create ()
let tickers : (Time_ns.t * Ticker.t) String.Table.t = String.Table.create ()

module Book = struct
  type t = {
    ts : Time_ns.t ;
    book : Float.t Float.Map.t ;
  }

  let empty = {
    ts = Time_ns.epoch ;
    book = Float.Map.empty
  }

  let bids : t String.Table.t = String.Table.create ()
  let asks : t String.Table.t = String.Table.create ()

  let get_bids = String.Table.find_or_add bids ~default:(fun () -> empty)
  let get_asks = String.Table.find_or_add asks ~default:(fun () -> empty)

  let set_bids ~symbol ~ts ~book = String.Table.set bids ~key:symbol ~data:{ ts ; book }
  let set_asks ~symbol ~ts ~book = String.Table.set asks ~key:symbol ~data:{ ts ; book }
end

let latest_trades : MarketHistory.t String.Table.t = String.Table.create ()

let buf_json = Bi_outbuf.create 4096

let secdef_of_ticker ?request_id ?(final=true)
    ({ symbol; quote; base; quote_descr; base_descr; ticksize; active; created } : Market.t) =
  let description = quote_descr ^ " / " ^ base_descr in
  let request_id = match request_id with
    | Some reqid -> reqid
    | None when !sc_mode -> 110_000_000l
    | None -> 0l in
  let secdef = DTC.default_security_definition_response () in
  secdef.request_id <- Some request_id ;
  secdef.is_final_message <- Some final ;
  secdef.symbol <- Some symbol ;
  secdef.exchange <- Some my_exchange ;
  secdef.security_type <- Some `security_type_forex ;
  secdef.description <- Some description ;
  secdef.min_price_increment <- Some 1e-8 ;
  secdef.currency_value_per_increment <- Some 1e-8 ;
  secdef.price_display_format <- Some `price_display_format_decimal_8 ;
  secdef.has_market_depth_data <- Some true ;
  secdef

module RestSync : sig
  type t

  val create : unit -> t

  val push : t -> (unit -> unit Deferred.t) -> unit Deferred.t
  val push_nowait : t -> (unit -> unit Deferred.t) -> unit

  val run : t -> unit

  val start : t -> unit
  val stop : t -> unit

  val is_running : t -> bool

  module Default : sig
    val push : (unit -> unit Deferred.t) -> unit Deferred.t
    val push_nowait : (unit -> unit Deferred.t) -> unit
    val run : unit -> unit
    val start : unit -> unit
    val stop : unit -> unit
    val is_running : unit -> bool
  end
end = struct
  type t = {
    r : (unit -> unit Deferred.t) Pipe.Reader.t ;
    w : (unit -> unit Deferred.t) Pipe.Writer.t ;
    mutable run : bool ;
    condition : unit Condition.t ;
  }

  let create () =
    let r, w = Pipe.create () in
    let condition = Condition.create () in
    { r ; w ; run = true ; condition }

  let push { w } thunk =
    Pipe.write w thunk

  let push_nowait { w } thunk =
    Pipe.write_without_pushback w thunk

  let run { r ; run ; condition } =
    let rec inner () =
      if run then
        Pipe.read r >>= function
        | `Eof -> Deferred.unit
        | `Ok thunk ->
          thunk () >>=
          inner
      else
        Condition.wait condition >>=
        inner
    in
    don't_wait_for (inner ())

  let start t =
    t.run <- true ;
    Condition.signal t.condition ()

  let stop t = t.run <- false
  let is_running { run } = run

  module Default = struct
    let default = create ()

    let push thunk = push default thunk
    let push_nowait thunk = push_nowait default thunk

    let run () = run default
    let start () = start default
    let stop () = stop default
    let is_running () = is_running default
  end
end

module ROSet = struct
  include Caml.Set.Make(struct
    include RespObj
    let compare a b =
      String.compare (string_exn a "OrderUuid") (string_exn b "OrderUuid")
  end)

  let of_table t =
    Uuid.Table.fold t ~init:empty ~f:(fun ~key:_ ~data a -> add data a)

  let to_table t =
    let table = Uuid.Table.create () in
    iter begin fun ro ->
      let key = RespObj.string_exn ro "OrderUuid" |> Uuid.of_string in
      Uuid.Table.set table key ro
    end t ;
    table
end

module Connection = struct
  type t = {
    addr: string;
    w: Writer.t;
    key : string ;
    secret : string ;
    mutable dropped: int;
    subs: Int32.t String.Table.t;
    rev_subs : string Int32.Table.t;
    subs_depth: Int32.t String.Table.t;
    rev_subs_depth : string Int32.Table.t;
    (* Balances *)
    b_exchange: Balance.t String.Table.t;
    b_margin: Float.t String.Table.t;
    (* Orders & Trades *)
    client_orders : DTC.Submit_new_single_order.t Int.Table.t ;
    mutable orders: RespObj.t Uuid.Table.t;
    mutable trades: RespObj.t Uuid.Table.t;
    send_secdefs : bool ;
  }

  let active : t String.Table.t = String.Table.create ()

  let find = String.Table.find active
  let find_exn = String.Table.find_exn active
  let set = String.Table.set active
  let remove = String.Table.remove active

  let iter = String.Table.iter active

  let update_orders ({ addr ; key ; secret } as c) =
    openorders ~key ~secret ~buf:buf_json () >>| function
    | Error err ->
      Log.error log_btrex
        "update orders (%s): %s" addr @@ RestError.to_string err
    | Ok (resp, orders) ->
      let orders = List.map orders ~f:RespObj.of_json in
      c.orders <- ROSet.(of_list orders |> to_table)

  let update_trades ({ addr ; key ; secret ; trades } as c) =
    orderhistory ~buf:buf_json ~key ~secret () >>| function
    | Error err ->
      Log.error log_btrex
        "update trades (%s): %s" addr (RestError.to_string err)
    | Ok (resp, newtrades) ->
      let newtrades = List.map newtrades ~f:RespObj.of_json in
      let old_ts = ROSet.of_table trades in
      let cur_ts = ROSet.of_list newtrades in
      let new_ts = ROSet.diff cur_ts old_ts in
      c.trades <- ROSet.to_table cur_ts ;
      ROSet.iter ignore new_ts (* TODO: send order update messages *)

  let write_balance
      ?request_id
      ?(nb_msgs=1)
      ?(msg_number=1) { addr; w; b_exchange } =
    let b = String.Table.find b_exchange "BTC" |>
            Option.map ~f:begin fun { Rest.Balance.available; on_orders } ->
              available *. 1e3, (available -. on_orders) *. 1e3
            end
    in
    let securities_value =
      String.Table.fold b_exchange ~init:0.
        ~f:begin fun ~key:_ ~data:{ Rest.Balance.btc_value } a ->
          a +. btc_value end *. 1e3 in
    let balance = DTC.default_account_balance_update () in
    balance.request_id <- request_id ;
    balance.cash_balance <- Option.map b ~f:fst ;
    balance.securities_value <- Some securities_value ;
    balance.margin_requirement <- Some 0. ;
    balance.balance_available_for_new_positions <- Option.map b ~f:snd ;
    balance.account_currency <- Some "mBTC" ;
    balance.total_number_messages <- Int32.of_int nb_msgs ;
    balance.message_number <- Int32.of_int msg_number ;
    balance.trade_account <- Some exchange_account ;
    write_message w `account_balance_update DTC.gen_account_balance_update balance ;
    Log.debug log_dtc "-> %s AccountBalanceUpdate %s (%d/%d)"
      addr exchange_account msg_number nb_msgs

  let update_balances ({ key ; secret ; b_exchange } as conn) =
    balances ~buf:buf_json ~all:false ~key ~secret () >>| function
    | Error err -> Log.error log_btrex "%s" @@ Rest.Http_error.to_string err
    | Ok bs ->
      String.Table.clear b_exchange;
      List.iter bs ~f:(fun (c, b) -> String.Table.add_exn b_exchange c b) ;
      write_exchange_balance conn

  let update_connection conn span =
    Clock_ns.every
      ~stop:(Writer.close_started conn.w)
      ~continue_on_error:true
      span
      begin fun () ->
        let open RestSync.Default in
        push_nowait (fun () -> update_orders conn) ;
        push_nowait (fun () -> update_trades conn) ;
        push_nowait (fun () -> update_balances conn) ;
      end

  let setup ~addr ~w ~key ~secret ~send_secdefs =
    let conn = {
      addr ;
      w ;
      key ;
      secret ;
      send_secdefs ;
      dropped = 0 ;
      subs = String.Table.create () ;
      rev_subs = Int32.Table.create () ;
      subs_depth = String.Table.create () ;
      rev_subs_depth = Int32.Table.create () ;
      b_exchange = String.Table.create () ;
      b_margin = String.Table.create () ;
      client_orders = Int.Table.create () ;
      orders = Uuid.Table.create () ;
      trades = Uuid.Table.create () ;
    } in
    set ~key:addr ~data:conn ;
    if key = "" || secret = "" then Deferred.return false
    else begin
      Rest.margin_account_summary ~buf:buf_json ~key ~secret () >>| function
      | Error _ -> false
      | Ok _ ->
        update_connection conn !update_client_span ;
        true
    end
end

let send_update_msgs depth symbol_id w ts (t:Ticker.t) (t':Ticker.t) =
  if t.base_volume <> t'.base_volume then begin
    let update = DTC.default_market_data_update_session_volume () in
    update.symbol_id <- Some symbol_id ;
    update.volume <- Some (t'.base_volume) ;
    write_message w `market_data_update_session_volume
      DTC.gen_market_data_update_session_volume update
  end;
  if t.low24h <> t'.low24h then begin
    let update = DTC.default_market_data_update_session_low () in
    update.symbol_id <- Some symbol_id ;
    update.price <- Some (t'.low24h) ;
    write_message w `market_data_update_session_low
      DTC.gen_market_data_update_session_low update
  end;
  if t.high24h <> t'.high24h then begin
    let update = DTC.default_market_data_update_session_high () in
    update.symbol_id <- Some symbol_id ;
    update.price <- Some (t'.high24h) ;
    write_message w `market_data_update_session_high
      DTC.gen_market_data_update_session_high update
  end;
  (* if t.last <> t'.last then begin *)
  (*   let float_of_ts ts = Time_ns.to_int_ns_since_epoch ts |> Float.of_int |> fun date -> date /. 1e9 in *)
  (*   let update = DTC.default_market_data_update_last_trade_snapshot () in *)
  (*   update.symbol_id <- Some symbol_id ; *)
  (*   update.last_trade_date_time <- Some (float_of_ts ts) ; *)
  (*   update.last_trade_price <- Some (t'.last) ; *)
  (*   write_message w `market_data_update_last_trade_snapshot *)
  (*     DTC.gen_market_data_update_last_trade_snapshot update *)
  (* end; *)
  if (t.bid <> t'.bid || t.ask <> t'.ask) && not depth then begin
    let update = DTC.default_market_data_update_bid_ask () in
    update.symbol_id <- Some symbol_id ;
    update.bid_price <- Some (t'.bid) ;
    update.ask_price <- Some (t'.ask) ;
    write_message w `market_data_update_bid_ask
      DTC.gen_market_data_update_bid_ask update
  end

let on_ticker_update ts t t' =
  let send_secdef_msg w t =
    let secdef = secdef_of_ticker ~final:true t in
    write_message w `security_definition_response
      DTC.gen_security_definition_response secdef in
  let on_connection { Connection.addr; w; subs; subs_depth; send_secdefs } =
    let on_symbol_id ?(depth=false) symbol_id =
      send_update_msgs depth symbol_id w ts t t';
      Log.debug log_dtc "-> [%s] %s TICKER" addr t.symbol
    in
    if send_secdefs && phys_equal t t' then send_secdef_msg w t ;
    match String.Table.(find subs t.symbol, find subs_depth t.symbol) with
    | Some sym_id, None -> on_symbol_id ~depth:false sym_id
    | Some sym_id, _ -> on_symbol_id ~depth:true sym_id
    | _ -> ()
  in
  Connection.iter ~f:on_connection

let update_tickers () =
  let now = Time_ns.now () in
  Rest.tickers () >>| function
  | Error err ->
    Log.error log_btrex "get tickers: %s" (Rest.Http_error.to_string err)
  | Ok ts ->
    List.iter ts ~f:begin fun t ->
      let old_ts, old_t =
        String.Table.find_or_add tickers t.symbol ~default:(fun () -> (now, t)) in
      String.Table.set tickers t.symbol (now, t) ;
      on_ticker_update now old_t t ;
    end

let rec loop_update_tickers () =
  Clock_ns.every
    ~continue_on_error:true
    (Time_ns.Span.of_int_sec 60)
    (fun () -> RestSync.Default.push_nowait update_tickers)

let float_of_time ts = Int64.to_float (Int63.to_int64 (Time_ns.to_int63_ns_since_epoch ts)) /. 1e9
let int64_of_time ts = Int64.(Int63.to_int64 (Time_ns.to_int63_ns_since_epoch ts) / 1_000_000_000L)
let int32_of_time ts = Int32.of_int64_exn (int64_of_time ts)

let at_bid_or_ask_of_depth : Side.t -> DTC.at_bid_or_ask_enum = function
  | `buy -> `at_bid
  | `sell -> `at_ask
  | `buy_sell_unset -> `bid_ask_unset

let at_bid_or_ask_of_trade : Side.t -> DTC.at_bid_or_ask_enum = function
  | `buy -> `at_ask
  | `sell -> `at_bid
  | `buy_sell_unset -> `bid_ask_unset

let on_trade_update pair ({ Trade.ts; side; price; qty } as t) =
  Log.debug log_btrex "<- %s %s" pair (Trade.sexp_of_t t |> Sexplib.Sexp.to_string);
  (* Send trade updates to subscribers. *)
  let on_connection { Connection.addr; w; subs; _} =
    let on_symbol_id symbol_id =
      let update = DTC.default_market_data_update_trade () in
      update.symbol_id <- Some symbol_id ;
      update.at_bid_or_ask <- Some (at_bid_or_ask_of_trade side) ;
      update.price <- Some price ;
      update.volume <- Some qty ;
      update.date_time <- Some (float_of_time ts) ;
      write_message w `market_data_update_trade
        DTC.gen_market_data_update_trade update ;
      (* Log.debug log_dtc "-> [%s] %s T %s" *)
      (*   addr pair (Sexplib.Sexp.to_string (Trade.sexp_of_t t)); *)
    in
    Option.iter String.Table.(find subs pair) ~f:on_symbol_id
  in
  String.Table.iter Connection.active ~f:on_connection

let on_book_updates pair ts updates =
  let bids  = Book.get_bids pair in
  let asks = Book.get_asks pair in
  let fold_updates (bid, ask) { Plnx.Book.side; price; qty } =
    match side with
    | `buy_sell_unset -> invalid_arg "on_book_updates: side unset"
    | `buy ->
      (if qty > 0. then Float.Map.add bid ~key:price ~data:qty
       else Float.Map.remove bid price),
      ask
    | `sell ->
      (if qty > 0. then Float.Map.add ask ~key:price ~data:qty
       else Float.Map.remove ask price),
      bid
  in
  let bids, asks =
    List.fold_left ~init:(bids.book, asks.book) updates ~f:fold_updates in
  Book.set_bids ~symbol:pair ~ts ~book:bids ;
  Book.set_asks ~symbol:pair ~ts ~book:asks ;
  let send_depth_updates
      (update : DTC.Market_depth_update_level.t)
      addr_str w symbol_id u =
    Log.debug log_dtc "-> [%s] %s D %s"
      addr_str pair (Sexplib.Sexp.to_string (Plnx.Book.sexp_of_entry u));
    let update_type =
      if u.qty = 0.
      then `market_depth_delete_level
      else `market_depth_insert_update_level in
    update.side <- Some (at_bid_or_ask_of_depth u.side) ;
    update.update_type <- Some update_type ;
    update.price <- Some u.price ;
    update.quantity <- Some u.qty ;
    write_message w `market_depth_update_level
      DTC.gen_market_depth_update_level update
  in
  let update = DTC.default_market_depth_update_level () in
  let on_connection { Connection.addr; w; subs; subs_depth; _ } =
    let on_symbol_id symbol_id =
      update.symbol_id <- Some symbol_id ;
      List.iter updates ~f:(send_depth_updates update addr w symbol_id);
    in
    Option.iter String.Table.(find subs_depth pair) ~f:on_symbol_id
  in
  String.Table.iter Connection.active ~f:on_connection

let ws ?heartbeat timeout =
  let latest_ts = ref Time_ns.epoch in
  let to_ws, to_ws_w = Pipe.create () in
  let initialized = ref false in
  let on_event subid id now = function
    | Ws.Repr.Snapshot { symbol ; bid ; ask } ->
      Int.Table.set subid_to_sym subid symbol ;
      Book.set_bids ~symbol ~ts:now ~book:bid ;
      Book.set_asks ~symbol ~ts:now ~book:ask ;
    | Update entry ->
      let symbol = Int.Table.find_exn subid_to_sym subid in
      on_book_updates symbol now [entry]
    | Trade t ->
      let symbol = Int.Table.find_exn subid_to_sym subid in
      String.Table.set latest_trades symbol t ;
      on_trade_update symbol t
  in
  let on_msg msg =
    let now = Time_ns.now () in
    latest_ts := now ;
    match msg with
    | Ws.Repr.Error msg ->
      Log.error log_btrex "[WS]: %s" msg
    | Event { subid ; id ; events } ->
      if not !initialized then begin
        let symbols = String.Table.keys tickers in
        List.iter symbols ~f:begin fun symbol ->
          Pipe.write_without_pushback to_ws_w (Ws.Repr.Subscribe symbol)
        end ;
        initialized := true
      end ;
      List.iter events ~f:(on_event subid id now)
  in
  let connected = Condition.create () in
  let restart, ws =
    Ws.open_connection ?heartbeat ~log:log_btrex ~connected to_ws in
  let rec handle_init () =
    Condition.wait connected >>= fun () ->
    initialized := false ;
    handle_init () in
  don't_wait_for (handle_init ()) ;
  let watchdog () =
    let now = Time_ns.now () in
    let diff = Time_ns.diff now !latest_ts in
    if Time_ns.(!latest_ts <> epoch) && Time_ns.Span.(diff > timeout) then
      Condition.signal restart () in
  Clock_ns.every timeout watchdog ;
  Monitor.handle_errors
    (fun () -> Pipe.iter_without_pushback ~continue_on_error:true ws ~f:on_msg)
    (fun exn -> Log.error log_btrex "%s" @@ Exn.to_string exn)

let heartbeat addr w ival =
  let ival = Option.value_map ival ~default:60 ~f:Int32.to_int_exn in
  let msg = DTC.default_heartbeat () in
  let rec loop () =
    Clock_ns.after @@ Time_ns.Span.of_int_sec ival >>= fun () ->
    match Connection.find addr with
    | None -> Deferred.unit
    | Some { Connection.dropped } ->
      Log.debug log_dtc "-> [%s] Heartbeat" addr;
      msg.num_dropped_messages <- Some (Int32.of_int_exn dropped) ;
      write_message w `heartbeat DTC.gen_heartbeat msg ;
      loop ()
  in
  loop ()

let encoding_request addr w req =
  let open Encoding in
  Log.debug log_dtc "<- [%s] Encoding Request" addr ;
  Encoding.(to_string (Response { version = 7 ; encoding = Protobuf })) |>
  Writer.write w ;
  Log.debug log_dtc "-> [%s] Encoding Response" addr

let logon_response ~result_text ~trading_supported =
  let resp = DTC.default_logon_response () in
  resp.server_name <- Some "Bittrex" ;
  resp.protocol_version <- Some 7l ;
  resp.result <- Some `logon_success ;
  resp.result_text <- Some result_text ;
  resp.market_depth_updates_best_bid_and_ask <- Some true ;
  resp.trading_is_supported <- Some trading_supported ;
  resp.ocoorders_supported <- Some false ;
  resp.order_cancel_replace_supported <- Some true ;
  resp.security_definitions_supported <- Some true ;
  resp.historical_price_data_supported <- Some false ;
  resp.market_depth_is_supported <- Some true ;
  resp.bracket_orders_supported <- Some false ;
  resp.market_data_supported <- Some true ;
  resp.symbol_exchange_delimiter <- Some "-" ;
  resp

let logon_request addr w msg =
  let req = DTC.parse_logon_request msg in
  let int1 = Option.value ~default:0l req.integer_1 in
  let int2 = Option.value ~default:0l req.integer_2 in
  let send_secdefs = Int32.(bit_and int1 128l <> 0l) in
  Log.debug log_dtc "<- [%s] Logon Request" addr;
  let accept trading =
    let trading_supported, result_text =
      match trading with
      | Ok msg -> true, Printf.sprintf "Trading enabled: %s" msg
      | Error msg -> false, Printf.sprintf "Trading disabled: %s" msg
    in
    don't_wait_for @@ heartbeat addr w req.heartbeat_interval_in_seconds;
    write_message w `logon_response
      DTC.gen_logon_response (logon_response ~trading_supported ~result_text) ;
    Log.debug log_dtc "-> [%s] Logon Response (%s)" addr result_text ;
    if not !sc_mode || send_secdefs then begin
      String.Table.iter tickers ~f:begin fun (ts, t) ->
        let secdef = secdef_of_ticker ~final:true t in
        write_message w `security_definition_response
          DTC.gen_security_definition_response secdef ;
        Log.debug log_dtc "Written secdef %s" t.symbol
      end
    end
  in
  begin match req.username, req.password, int2 with
    | Some key, Some secret, 0l ->
      RestSync.Default.push_nowait begin fun () ->
        Connection.setup ~addr ~w ~key ~secret ~send_secdefs >>| function
        | true -> accept @@ Result.return "Valid Bittrex credentials"
        | false -> accept @@ Result.fail "Invalid Bittrex crendentials"
      end
    | _ ->
      RestSync.Default.push_nowait begin fun () ->
        Connection.setup ~addr ~w ~key:"" ~secret:"" ~send_secdefs >>| fun _ ->
        accept @@ Result.fail "No credentials"
      end
  end

let heartbeat addr w msg =
  (* Log.debug log_dtc "<- [%s] Heartbeat" addr *)
  ()

let security_definition_request addr w msg =
  let reject addr_str request_id symbol =
    Log.info log_dtc "-> [%s] (req: %ld) Unknown symbol %s" addr_str request_id symbol;
    let rej = DTC.default_security_definition_reject () in
    rej.request_id <- Some request_id ;
    rej.reject_text <- Some (Printf.sprintf "Unknown symbol %s" symbol) ;
    write_message w `security_definition_reject
      DTC.gen_security_definition_reject rej
  in
  let req = DTC.parse_security_definition_for_symbol_request msg in
  match req.request_id, req.symbol, req.exchange with
    | Some request_id, Some symbol, Some exchange ->
      Log.debug log_dtc "<- [%s] Sec Def Request %ld %s %s"
        addr request_id symbol exchange ;
      if exchange <> my_exchange then reject addr request_id symbol
      else begin match String.Table.find tickers symbol with
        | None -> reject addr request_id symbol
        | Some (ts, t) ->
          let secdef = secdef_of_ticker ~final:true ~request_id t in
          Log.debug log_dtc "-> [%s] Sec Def Response %ld %s %s"
            addr request_id symbol exchange ;
          write_message w `security_definition_response
            DTC.gen_security_definition_response secdef
      end
    | _ -> ()

let reject_market_data_request ?id addr w k =
  let rej = DTC.default_market_data_reject () in
  rej.symbol_id <- id ;
  Printf.ksprintf begin fun reject_text ->
    rej.reject_text <- Some reject_text ;
    Log.debug log_dtc "-> [%s] Market Data Reject: %s" addr reject_text;
    write_message w `market_data_reject DTC.gen_market_data_reject rej
  end k

let write_market_data_snapshot ?id symbol exchange addr w ts t =
  let snap = DTC.default_market_data_snapshot () in
  snap.symbol_id <- id ;
  snap.session_high_price <- Some t.Ticker.high24h ;
  snap.session_low_price <- Some t.low24h ;
  snap.session_volume <- Some t.base_volume ;
  begin match String.Table.find latest_trades symbol with
    | None -> ()
    | Some { gid; id; ts; side; price; qty } ->
      snap.last_trade_price <- Some price ;
      snap.last_trade_volume <- Some qty ;
      snap.last_trade_date_time <- Some (float_of_time ts) ;
  end ;
  let bid = Book.get_bids symbol in
  let ask = Book.get_asks symbol in
  let ts = Time_ns.max bid.ts ask.ts in
  if ts <> Time_ns.epoch then
    snap.bid_ask_date_time <- Some (float_of_time ts) ;
  Option.iter (Float.Map.max_elt bid.book) ~f:begin fun (price, qty) ->
    snap.bid_price <- Some price ;
    snap.bid_quantity <- Some qty
  end ;
  Option.iter (Float.Map.min_elt ask.book) ~f:begin fun (price, qty) ->
    snap.ask_price <- Some price ;
    snap.ask_quantity <- Some qty
  end ;
  write_message w `market_data_snapshot DTC.gen_market_data_snapshot snap

let market_data_request addr w msg =
  let req = DTC.parse_market_data_request msg in
  let { Connection.subs ; rev_subs } = Connection.find_exn addr in
  match req.request_action,
        req.symbol_id,
        req.symbol,
        req.exchange
  with
  | _, id, _, Some exchange when exchange <> my_exchange ->
    reject_market_data_request ?id addr w "No such exchange %s" exchange
  | _, id, Some symbol, _ when not (String.Table.mem tickers symbol) ->
    reject_market_data_request ?id addr w "No such symbol %s" symbol
  | Some `unsubscribe, Some id, _, _ ->
    begin match Int32.Table.find rev_subs id with
    | None -> ()
    | Some symbol -> String.Table.remove subs symbol
    end ;
    Int32.Table.remove rev_subs id
  | Some `snapshot, _, Some symbol, Some exchange ->
    let ts, t = String.Table.find_exn tickers symbol in
    write_market_data_snapshot symbol exchange addr w ts t ;
    Log.debug log_dtc "-> [%s] Market Data Snapshot %s %s" addr symbol exchange
  | Some `subscribe, Some id, Some symbol, Some exchange ->
    Log.debug log_dtc "<- [%s] Market Data Request %ld %s %s"
      addr id symbol exchange ;
    begin
      match Int32.Table.find rev_subs id with
      | Some symbol' when symbol <> symbol' ->
        reject_market_data_request addr w ~id
          "Already subscribed to %s-%s with a different id (was %ld)"
          symbol exchange id
      | _ ->
        String.Table.set subs symbol id ;
        Int32.Table.set rev_subs id symbol ;
        let ts, t = String.Table.find_exn tickers symbol in
        write_market_data_snapshot ~id symbol exchange addr w ts t ;
        Log.debug log_dtc "-> [%s] Market Data Snapshot %s %s" addr symbol exchange
    end
  | _ ->
    reject_market_data_request addr w "Market Data Request: wrong request"

let write_market_depth_snapshot ?id addr w ~symbol ~exchange ~num_levels =
  let bid = Book.get_bids symbol in
  let ask = Book.get_asks symbol in
  let bid_size = Float.Map.length bid.book in
  let ask_size = Float.Map.length ask.book in
  let snap = DTC.default_market_depth_snapshot_level () in
  snap.symbol_id <- id ;
  snap.side <- Some `at_bid ;
  snap.is_last_message_in_batch <- Some false ;
  (* ignore @@ Float.Map.fold_right bid ~init:1 ~f:begin fun ~key:price ~data:qty lvl -> *)
  (*   if lvl < num_levels then begin *)
  (*     snap.price <- Some price ; *)
  (*     snap.quantity <- Some qty ; *)
  (*     snap.level <- Some (Int32.of_int_exn lvl) ; *)
  (*     snap.is_first_message_in_batch <- Some (lvl = 1) ; *)
  (*     write_message w `market_depth_snapshot_level *)
  (*       DTC.gen_market_depth_snapshot_level snap *)
  (*   end ; *)
  (*   succ lvl *)
  (* end; *)
  (* snap.side <- Some `at_ask ; *)
  (* ignore @@ Float.Map.fold ask ~init:1 ~f:begin fun ~key:price ~data:qty lvl -> *)
  (*   if lvl < num_levels then begin *)
  (*     snap.price <- Some price ; *)
  (*     snap.quantity <- Some qty ; *)
  (*     snap.level <- Some (Int32.of_int_exn lvl) ; *)
  (*     snap.is_first_message_in_batch <- Some (lvl = 1 && Float.Map.is_empty bid) ; *)
  (*     write_message w `market_depth_snapshot_level *)
  (*       DTC.gen_market_depth_snapshot_level snap *)
  (*   end ; *)
  (*   succ lvl *)
  (* end; *)
  snap.side <- None ;
  snap.price <- None ;
  snap.quantity <- None ;
  snap.level <- None ;
  snap.is_first_message_in_batch <- Some false ;
  snap.is_last_message_in_batch <- Some true ;
  write_message w `market_depth_snapshot_level
    DTC.gen_market_depth_snapshot_level snap ;
  Log.debug log_dtc "-> [%s] Market Depth Snapshot %s %s (%d/%d)"
    addr symbol exchange (Int.min bid_size num_levels) (Int.min ask_size num_levels)

let reject_market_depth_request ?id addr w k =
  let rej = DTC.default_market_depth_reject () in
  rej.symbol_id <- id ;
  Printf.ksprintf begin fun reject_text ->
    rej.reject_text <- Some reject_text ;
    Log.debug log_dtc "-> [%s] Market Depth Reject: %s" addr reject_text;
    write_message w `market_depth_reject
      DTC.gen_market_depth_reject rej
  end k

let market_depth_request addr w msg =
  let req = DTC.parse_market_depth_request msg in
  let num_levels = Option.value_map req.num_levels ~default:50 ~f:Int32.to_int_exn in
  let { Connection.subs_depth ; rev_subs_depth } = Connection.find_exn addr in
  match req.request_action,
        req.symbol_id,
        req.symbol,
        req.exchange
  with
  | _, id, _, Some exchange when exchange <> my_exchange ->
    reject_market_depth_request ?id addr w "No such exchange %s" exchange
  | _, id, Some symbol, _ when not (String.Table.mem tickers symbol) ->
    reject_market_data_request ?id addr w "No such symbol %s" symbol
  | Some `unsubscribe, Some id, _, _ ->
    begin match Int32.Table.find rev_subs_depth id with
    | None -> ()
    | Some symbol -> String.Table.remove subs_depth symbol
    end ;
    Int32.Table.remove rev_subs_depth id
  | Some `snapshot, id, Some symbol, Some exchange ->
    write_market_depth_snapshot ?id addr w ~symbol ~exchange ~num_levels
  | Some `subscribe, Some id, Some symbol, Some exchange ->
    Log.debug log_dtc "<- [%s] Market Data Request %ld %s %s"
      addr id symbol exchange ;
    begin
      match Int32.Table.find rev_subs_depth id with
      | Some symbol' when symbol <> symbol' ->
        reject_market_data_request addr w ~id
          "Already subscribed to %s-%s with a different id (was %ld)"
          symbol exchange id
      | _ ->
        String.Table.set subs_depth symbol id ;
        Int32.Table.set rev_subs_depth id symbol ;
        write_market_depth_snapshot ~id addr w ~symbol ~exchange ~num_levels
    end
  | _ ->
    reject_market_data_request addr w "Market Data Request: wrong request"

let send_open_order_update w request_id nb_open_orders
    ~key:_ ~data:(symbol, { Rest.OpenOrder.id; side; price; qty; starting_qty; } ) i =
  let resp = DTC.default_order_update () in
  let status = if qty = starting_qty then
      `order_status_open else `order_status_partially_filled in
  resp.request_id <- Some request_id ;
  resp.total_num_messages <- Some (Int32.of_int_exn nb_open_orders) ;
  resp.message_number <- Some i ;
  resp.order_status <- Some status ;
  resp.order_update_reason <- Some `open_orders_request_response ;
  resp.symbol <- Some symbol ;
  resp.exchange <- Some my_exchange ;
  resp.server_order_id <- Some (Int.to_string id) ;
  resp.order_type <- Some `order_type_limit ;
  resp.buy_sell <- Some side ;
  resp.price1 <- Some price ;
  resp.order_quantity <- Some (starting_qty *. 1e4) ;
  resp.filled_quantity <- Some ((starting_qty -. qty) *. 1e4) ;
  resp.remaining_quantity <- Some (qty *. 1e4) ;
  resp.time_in_force <- Some `tif_good_till_canceled ;
  write_message w `order_update DTC.gen_order_update resp ;
  Int32.succ i

let open_orders_request addr w msg =
  let req = DTC.parse_open_orders_request msg in
  match req.request_id with
  | Some request_id ->
    let { Connection.orders } = Connection.find_exn addr in
    Log.debug log_dtc "<- [%s] Open Orders Request" addr ;
    let nb_open_orders = Int.Table.length orders in
    let (_:Int32.t) = Int.Table.fold orders
        ~init:1l ~f:(send_open_order_update w request_id nb_open_orders) in
    if nb_open_orders = 0 then begin
      let resp = DTC.default_order_update () in
      resp.total_num_messages <- Some 1l ;
      resp.message_number <- Some 1l ;
      resp.request_id <- Some request_id ;
      resp.order_update_reason <- Some `open_orders_request_response ;
      resp.no_orders <- Some true ;
      write_message w `order_update DTC.gen_order_update resp
    end;
    Log.debug log_dtc "-> [%s] %d order(s)" addr nb_open_orders
  | _ -> ()

let current_positions_request addr w msg =
  let { Connection.positions } = Connection.find_exn addr in
  Log.debug log_dtc "<- [%s] Positions" addr;
  let nb_msgs = String.Table.length positions in
  let req = DTC.parse_current_positions_request msg in
  let update = DTC.default_position_update () in
  let (_:Int32.t) =
    String.Table.fold positions
      ~init:1l ~f:begin fun ~key:symbol ~data:{ price; qty } msg_number ->
      update.trade_account <- Some margin_account ;
      update.total_number_messages <- Int32.of_int nb_msgs ;
      update.message_number <- Some msg_number ;
      update.request_id <- req.request_id ;
      update.symbol <- Some symbol ;
      update.exchange <- Some my_exchange ;
      update.average_price <- Some price ;
      update.quantity <- Some qty ;
      write_message w `position_update DTC.gen_position_update update ;
      Int32.succ msg_number
    end
  in
  if nb_msgs = 0 then begin
    update.total_number_messages <- Some 1l ;
    update.message_number <- Some 1l ;
    update.request_id <- req.request_id ;
    update.no_positions <- Some true ;
    write_message w `position_update DTC.gen_position_update update
  end ;
  Log.debug log_dtc "-> [%s] %d position(s)" addr nb_msgs

let historical_order_fills addr w msg =
  let { Connection.key; secret; trades } = Connection.find_exn addr in
  let req = DTC.parse_historical_order_fills_request msg in
  let resp = DTC.default_historical_order_fill_response () in
  Log.debug log_dtc "<- [%s] Historical Order Fills Req" addr ;
  let send_no_order_fills () =
    resp.request_id <- req.request_id ;
    resp.no_order_fills <- Some true ;
    resp.total_number_messages <- Some 1l ;
    resp.message_number <- Some 1l ;
    write_message w `historical_order_fill_response
      DTC.gen_historical_order_fill_response resp
  in
  let send_order_fill ?(nb_msgs=1) ~symbol msg_number
      { Rest.TradeHistory.gid; id; ts; price; qty; fee; order_id; side; category } =
    let trade_account = if margin_enabled symbol then margin_account else exchange_account in
    resp.request_id <- req.request_id ;
    resp.trade_account <- Some trade_account ;
    resp.total_number_messages <- Some (Int32.of_int_exn nb_msgs) ;
    resp.message_number <- Some msg_number ;
    resp.symbol <- Some symbol ;
    resp.exchange <- Some my_exchange ;
    resp.server_order_id <- Some (Int.to_string gid) ;
    resp.buy_sell <- Some side ;
    resp.price <- Some price ;
    resp.quantity <- Some qty ;
    resp.date_time <- Some (int64_of_time ts) ;
    write_message w `historical_order_fill_response
      DTC.gen_historical_order_fill_response resp ;
    Int32.succ msg_number
  in
  let nb_trades = String.Table.fold trades ~init:0 ~f:begin fun ~key:_ ~data a ->
      a + Rest.TradeHistory.Set.length data
    end in
  if nb_trades = 0 then send_no_order_fills ()
  else begin
    match req.server_order_id with
    | None -> ignore @@ String.Table.fold trades ~init:1l ~f:begin fun ~key:symbol ~data a ->
        Rest.TradeHistory.Set.fold data ~init:a ~f:(send_order_fill ~nb_msgs:nb_trades ~symbol);
      end
    | Some srv_ord_id ->
      let srv_ord_id = Int.of_string srv_ord_id in
      begin match String.Table.fold trades ~init:("", None) ~f:begin fun ~key:symbol ~data a ->
          match snd a, (Rest.TradeHistory.Set.find data ~f:(fun { gid } -> gid = srv_ord_id)) with
          | _, Some t -> symbol, Some t
          | _ -> a
        end
        with
        | _, None -> send_no_order_fills ()
        | symbol, Some t -> ignore @@ send_order_fill ~symbol 1l t
      end
  end

let trade_account_request addr w msg =
  let req = DTC.parse_trade_accounts_request msg in
  let resp = DTC.default_trade_account_response () in
  Log.debug log_dtc "<- [%s] TradeAccountsRequest" addr;
  let accounts = [exchange_account; margin_account] in
  let nb_msgs = List.length accounts in
  List.iteri accounts ~f:begin fun i trade_account ->
    let msg_number = Int32.(succ @@ of_int_exn i) in
    resp.request_id <- req.request_id ;
    resp.total_number_messages <- Some (Int32.of_int_exn nb_msgs) ;
    resp.message_number <- Some msg_number ;
    resp.trade_account <- Some trade_account ;
    write_message w `trade_account_response DTC.gen_trade_account_response resp ;
    Log.debug log_dtc "-> [%s] TradeAccountResponse: %s (%ld/%d)"
      addr trade_account msg_number nb_msgs
  end

let reject_account_balance_request addr request_id account =
  let rej = DTC.default_account_balance_reject () in
  rej.request_id <- request_id ;
  rej.reject_text <- Some ("Unknown account " ^ account) ;
  Log.debug log_dtc "-> [%s] AccountBalanceReject: unknown account %s" addr account

let account_balance_request addr w msg =
  let req = DTC.parse_account_balance_request msg in
  let c = Connection.find_exn addr in
  match req.trade_account with
  | None
  | Some "" ->
    Log.debug log_dtc "<- [%s] AccountBalanceRequest (all accounts)" c.addr ;
    Connection.write_exchange_balance ?request_id:req.request_id ~msg_number:1 ~nb_msgs:2 c;
    Connection.write_margin_balance ?request_id:req.request_id ~msg_number:2 ~nb_msgs:2 c
  | Some account when account = exchange_account ->
    Log.debug log_dtc "<- [%s] AccountBalanceRequest (%s)" c.addr account;
    Connection.write_exchange_balance ?request_id:req.request_id c
  | Some account when account = margin_account ->
    Log.debug log_dtc "<- [%s] AccountBalanceRequest (%s)" c.addr account;
    Connection.write_margin_balance ?request_id:req.request_id c
  | Some account ->
    reject_account_balance_request addr req.request_id account

let reject_new_order w (req : DTC.submit_new_single_order) k =
  let update = DTC.default_order_update () in
  update.client_order_id <- req.client_order_id ;
  update.symbol <- req.symbol ;
  update.exchange <- req.exchange ;
  update.order_status <- Some `order_status_rejected ;
  update.order_update_reason <- Some `new_order_rejected ;
  update.buy_sell <- req.buy_sell ;
  update.price1 <- req.price1 ;
  update.price2 <- req.price2 ;
  update.time_in_force <- req.time_in_force ;
  update.good_till_date_time <- req.good_till_date_time ;
  update.free_form_text <- req.free_form_text ;
  update.open_or_close <- req.open_or_close ;
  Printf.ksprintf begin fun info_text ->
    update.info_text <- Some info_text ;
    write_message w `order_update DTC.gen_order_update update
  end k

let send_new_order_update w (req : DTC.submit_new_single_order)
    ~server_order_id
    ~status
    ~reason
    ~filled_qty
    ~remaining_qty =
  let update = DTC.default_order_update () in
  update.message_number <- Some 1l ;
  update.total_num_messages <- Some 1l ;
  update.order_status <- Some status ;
  update.order_update_reason <- Some reason ;
  update.client_order_id <- req.client_order_id ;
  update.symbol <- req.symbol ;
  update.exchange <- Some my_exchange ;
  update.server_order_id <- Some (Int.to_string server_order_id) ;
  update.buy_sell <- req.buy_sell ;
  update.price1 <- req.price1 ;
  update.order_quantity <- req.quantity ;
  update.filled_quantity <- Some filled_qty ;
  update.remaining_quantity <- Some remaining_qty ;
  update.time_in_force <- req.time_in_force ;
  write_message w `order_update DTC.gen_order_update update

let open_order_of_submit_new_single_order id (req : DTC.Submit_new_single_order.t) margin =
  let side = Option.value ~default:`buy_sell_unset req.buy_sell in
  let price = Option.value ~default:0. req.price1 in
  let qty = Option.value_map req.quantity ~default:0. ~f:(( *. ) 1e-4) in
  let margin = if margin then 1 else 0 in
  Rest.OpenOrder.create ~id ~ts:(Time_ns.now ()) ~side
    ~price ~qty ~starting_qty:qty ~margin

(* req argument is normalized. *)
let submit_new_order conn (req : DTC.submit_new_single_order) =
  let { Connection.addr ; w ; key ; secret ; client_orders ; orders } = conn in
  let symbol = Option.value_exn req.symbol in
  let side = Option.value_exn ~message:"submit_order: side" req.buy_sell in
  let price = Option.value_exn req.price1 in
  let qty = Option.value_map req.quantity ~default:0. ~f:(( *. ) 1e-4) in
  let margin = margin_enabled symbol in
  let tif = match req.time_in_force with
    | Some `tif_fill_or_kill -> Some `Fill_or_kill
    | Some `tif_immediate_or_cancel -> Some `Immediate_or_cancel
    | _ -> None
  in
  let order_f =
    if margin then Rest.submit_margin_order ?max_lending_rate:None
    else Rest.submit_order
  in
  Log.debug log_dtc "-> [%s] Submit Order %s %f %f" addr symbol price qty ;
  order_f ~buf:buf_json ?tif ~key ~secret ~side ~symbol ~price ~qty () >>| function
  | Error Rest.Http_error.Bittrex msg ->
    reject_new_order w req "%s" msg
  | Error err ->
    Option.iter req.client_order_id ~f:begin fun id ->
      reject_new_order w req "%s: %s" id (Rest.Http_error.to_string err)
    end
  | Ok { id; trades; amount_unfilled } -> begin
      Int.Table.set client_orders id req ;
      Int.Table.set orders id
        (symbol, open_order_of_submit_new_single_order id req margin) ;
      Log.debug log_dtc "<- [%s] Submit Order OK %d" addr id ;
      match trades, amount_unfilled with
      | [], _ ->
        send_new_order_update w req
          ~status:`order_status_open
          ~reason:`new_order_accepted
          ~server_order_id:id
          ~filled_qty:0.
          ~remaining_qty:qty
      | trades, 0. ->
        send_new_order_update w req
          ~status:`order_status_filled
          ~reason:`order_filled
          ~server_order_id:id
          ~filled_qty:qty
          ~remaining_qty:0. ;
        if margin then
          RestSync.Default.push_nowait
            (fun () -> Connection.update_positions conn)
      | trades, unfilled ->
        let trades = Rest.OrderResponse.trades_of_symbol trades symbol in
        let filled_qty =
          List.fold_left trades ~init:0. ~f:(fun a { qty } -> a +. qty) in
        let remaining_qty = qty -. filled_qty in
        send_new_order_update w req
          ~status:`order_status_partially_filled
          ~reason:`order_filled_partially
          ~server_order_id:id
          ~filled_qty
          ~remaining_qty ;
        if margin then
          RestSync.Default.push_nowait
            (fun () -> Connection.update_positions conn)
    end

let submit_new_single_order conn (req : DTC.submit_new_single_order) =
  let { Connection.w } = conn in
  req.time_in_force <- begin
    match req.order_type with
    | Some `order_type_market -> Some `tif_fill_or_kill
    | _ -> req.time_in_force
  end ;
  begin match req.symbol, req.exchange with
    | Some symbol, Some exchange when
        String.Table.mem tickers symbol && exchange = my_exchange -> ()
    | _ ->
      reject_new_order w req "Unknown symbol or exchange" ;
      raise Exit
  end ;
  begin match Option.value ~default:`tif_unset req.time_in_force with
    | `tif_good_till_canceled
    | `tif_fill_or_kill
    | `tif_immediate_or_cancel -> ()
    | `tif_day ->
      req.time_in_force <- Some `tif_good_till_canceled
    | `tif_unset ->
      reject_new_order w req "Time in force unset" ;
      raise Exit
    | #DTC.time_in_force_enum ->
      reject_new_order w req "Unsupported time in force" ;
      raise Exit
  end ;
  begin match Option.value ~default:`order_type_unset req.order_type, req.price1 with
    | `order_type_market, _ ->
      req.price1 <-
        Option.bind req.symbol ~f:begin fun symbol ->
          Option.map (String.Table.find tickers symbol) ~f:begin fun (ts, t) ->
            t.high24h *. 2.
          end
        end
    | `order_type_limit, Some price ->
      req.price1 <- Some price
    | `order_type_limit, None ->
      reject_new_order w req "Limit order without a price" ;
      raise Exit
    | #DTC.order_type_enum, _ ->
      reject_new_order w req "Unsupported order type" ;
      raise Exit
  end ;
  RestSync.Default.push_nowait (fun () -> submit_new_order conn req)

let submit_new_single_order addr w msg =
  let conn = Connection.find_exn addr in
  let req = DTC.parse_submit_new_single_order msg in
  Log.debug log_dtc "<- [%s] Submit New Single Order" conn.addr ;
  try submit_new_single_order conn req with
  | Exit -> ()
  | exn -> Log.error log_dtc "%s" @@ Exn.to_string exn

let reject_cancel_order w (req : DTC.cancel_order) k =
  let update = DTC.default_order_update () in
  update.message_number <- Some 1l ;
  update.total_num_messages <- Some 1l ;
  update.client_order_id <- req.client_order_id ;
  update.server_order_id <- req.server_order_id ;
  update.order_status <- Some `order_status_open ;
  update.order_update_reason <- Some `order_cancel_rejected ;
  Printf.ksprintf begin fun info_text ->
    update.info_text <- Some info_text ;
    write_message w `order_update DTC.gen_order_update update
  end k

let send_cancel_update w server_order_id (req : DTC.Submit_new_single_order.t) =
  let update = DTC.default_order_update () in
  update.message_number <- Some 1l ;
  update.total_num_messages <- Some 1l ;
  update.symbol <- req.symbol ;
  update.exchange <- req.exchange ;
  update.order_type <- req.order_type ;
  update.buy_sell <- req.buy_sell ;
  update.order_quantity <- req.quantity ;
  update.price1 <- req.price1 ;
  update.price2 <- req.price2 ;
  update.order_status <- Some `order_status_canceled ;
  update.order_update_reason <- Some `order_canceled ;
  update.client_order_id <- req.client_order_id ;
  update.server_order_id <- Some server_order_id ;
  write_message w `order_update DTC.gen_order_update update

let submit_new_single_order_of_open_order symbol (order : Rest.OpenOrder.t) =
  let req = DTC.default_submit_new_single_order () in
  req.symbol <- Some symbol ;
  req.exchange <- Some my_exchange ;
  req.buy_sell <- Some order.side ;
  req.price1 <- Some order.price ;
  req.quantity <- Some order.starting_qty ;
  req

let cancel_order addr w msg =
  let ({ Connection.w ; key ; secret ; client_orders ; orders } as c) =
    Connection.find_exn addr in
    let req = DTC.parse_cancel_order msg in
    match Option.map req.server_order_id ~f:Int.of_string with
    | None ->
      reject_cancel_order w req "Server order id not set"
    | Some order_id ->
      Log.debug log_dtc "<- [%s] Order Cancel %d" addr order_id;
      RestSync.Default.push_nowait begin fun () ->
        Rest.cancel_order ~key ~secret ~order_id () >>| function
        | Error Rest.Http_error.Bittrex msg ->
          reject_cancel_order w req "%s" msg
        | Error _ ->
          reject_cancel_order w req
            "exception raised while trying to cancel %d" order_id
        | Ok () ->
          Log.debug log_dtc "-> [%s] Order Cancel OK %d" addr order_id ;
          let order_id_str = Int.to_string order_id in
          match Int.Table.find client_orders order_id,
                Int.Table.find orders order_id with
          | None, None ->
            Log.error log_dtc
              "<- [%s] Unable to find order id %d in tables" addr order_id ;
            send_cancel_update w order_id_str
              (DTC.default_submit_new_single_order ())
          | Some client_order, _ ->
            Int.Table.remove orders order_id ;
            send_cancel_update w order_id_str client_order ;
          | None, Some (symbol, order) ->
            Log.error log_dtc
              "[%s] Found open order %d but no matching client order" addr order_id ;
            send_cancel_update w order_id_str
              (submit_new_single_order_of_open_order symbol order)
      end

let reject_cancel_replace_order addr w (req : DTC.cancel_replace_order) k =
  let price1 =
    if Option.value ~default:false req.price1_is_set then req.price1 else None in
  let price2 =
    if Option.value ~default:false req.price2_is_set then req.price2 else None in
  let update = DTC.default_order_update () in
  update.client_order_id <- req.client_order_id ;
  update.server_order_id <- req.server_order_id ;
  update.order_status <- Some `order_status_open ;
  update.order_update_reason <- Some `order_cancel_replace_rejected ;
  update.message_number <- Some 1l ;
  update.total_num_messages <- Some 1l ;
  update.exchange <- Some my_exchange ;
  update.price1 <- price1 ;
  update.price2 <- price2 ;
  update.order_quantity <- req.quantity ;
  update.time_in_force <- req.time_in_force ;
  update.good_till_date_time <- req.good_till_date_time ;
  Printf.ksprintf begin fun info_text ->
    Log.debug log_dtc "-> [%s] Cancel Replace Reject: %s" addr info_text ;
    update.info_text <- Some info_text ;
    write_message w `order_update DTC.gen_order_update update
  end k

let send_cancel_replace_update
    ?filled_qty w server_order_id remaining_qty
    (req : DTC.Submit_new_single_order.t)
    (upd : DTC.Cancel_replace_order.t) =
  let update = DTC.default_order_update () in
  let price1_is_set = Option.value ~default:false upd.price1_is_set in
  let price2_is_set = Option.value ~default:false upd.price2_is_set in
  let price1 = match price1_is_set, upd.price1 with
    | true, Some price1 -> Some price1
    | _ -> None in
  let price2 = match price2_is_set, upd.price2 with
    | true, Some price2 -> Some price2
    | _ -> None in
  update.message_number <- Some 1l ;
  update.total_num_messages <- Some 1l ;
  update.symbol <- req.symbol ;
  update.exchange <- req.exchange ;
  update.trade_account <- req.trade_account ;
  update.order_status <- Some `order_status_open ;
  update.order_update_reason <- Some `order_cancel_replace_complete ;
  update.client_order_id <- req.client_order_id ;
  update.previous_server_order_id <- upd.server_order_id ;
  update.server_order_id <- Some server_order_id ;
  update.price1 <- price1 ;
  update.price2 <- price2 ;
  update.order_quantity <- req.quantity ;
  update.filled_quantity <- filled_qty ;
  update.remaining_quantity <- Some remaining_qty ;
  update.order_type <- req.order_type ;
  update.time_in_force <- req.time_in_force ;
  write_message w `order_update DTC.gen_order_update update

let cancel_replace_order addr w msg =
  let { Connection.addr ; w ; key ; secret ; client_orders ; orders }
    = Connection.find_exn addr in
  let req = DTC.parse_cancel_replace_order msg in
  Log.debug log_dtc "<- [%s] Cancel Replace Order" addr ;
  let order_type = Option.value ~default:`order_type_unset req.order_type in
  let tif = Option.value ~default:`tif_unset req.time_in_force in
  if order_type <> `order_type_unset then
    reject_cancel_replace_order addr w req
      "Modification of order type is not supported by Bittrex"
  else if tif <> `tif_unset then
    reject_cancel_replace_order addr w req
      "Modification of time in force is not supported by Bittrex"
  else
    match Option.map req.server_order_id ~f:Int.of_string, req.price1 with
    | None, _ ->
      reject_cancel_replace_order addr w req "Server order id is not set"
    | _, None ->
      reject_cancel_replace_order addr w req
        "Order modify without setting a price is not supported by Bittrex"
    | Some orig_server_id, Some price ->
      let qty = Option.map req.quantity ~f:(( *. ) 1e-4) in
      RestSync.Default.push_nowait begin fun () ->
        Rest.modify_order ~key ~secret ?qty ~price ~order_id:orig_server_id () >>| function
        | Error Rest.Http_error.Bittrex msg ->
          reject_cancel_replace_order addr w req
            "cancel order %d failed: %s" orig_server_id msg
        | Error _ ->
          reject_cancel_replace_order addr w req
            "cancel order %d failed" orig_server_id
        | Ok { id; trades; amount_unfilled } ->
          Log.debug log_dtc
            "<- [%s] Cancel Replace Order %d -> %d OK" addr orig_server_id id ;
          let order_id_str = Int.to_string id in
          let amount_unfilled = amount_unfilled *. 1e4 in
          match Int.Table.find client_orders orig_server_id,
                Int.Table.find orders orig_server_id with
          | None, None ->
            Log.error log_dtc
              "[%s] Unable to find order id %d in tables" addr orig_server_id ;
            send_cancel_replace_update w order_id_str amount_unfilled
              (DTC.default_submit_new_single_order ()) req
          | Some client_order, Some (symbol, open_order) ->
            Int.Table.remove client_orders orig_server_id ;
            Int.Table.remove orders orig_server_id ;
            Int.Table.set client_orders id client_order ;
            Int.Table.set orders id (symbol, { open_order with qty = amount_unfilled }) ;
            send_cancel_replace_update
              w order_id_str amount_unfilled client_order req
          | Some client_order, None ->
            Log.error log_dtc
              "[%s] Found client order %d but no matching open order"
              addr orig_server_id ;
            Int.Table.remove client_orders orig_server_id ;
            Int.Table.set client_orders id client_order ;
            send_cancel_replace_update
              w order_id_str amount_unfilled client_order req
          | None, Some (symbol, order) ->
            Log.error log_dtc
              "[%s] Found open order %d but no matching client order"
              addr orig_server_id ;
            send_cancel_replace_update w order_id_str amount_unfilled
              (submit_new_single_order_of_open_order symbol order) req
      end

let dtcserver ~server ~port =
  let server_fun addr r w =
    let addr = Socket.Address.Inet.to_string addr in
    (* So that process does not allocate all the time. *)
    let rec handle_chunk consumed buf ~pos ~len =
      if len < 2 then return @@ `Consumed (consumed, `Need_unknown)
      else
        let msglen = Bigstring.unsafe_get_int16_le buf ~pos in
        (* Log.debug log_dtc "handle_chunk: pos=%d len=%d, msglen=%d" pos len msglen; *)
        if len < msglen then return @@ `Consumed (consumed, `Need msglen)
        else begin
          let msgtype_int = Bigstring.unsafe_get_int16_le buf ~pos:(pos+2) in
          let msgtype : DTC.dtcmessage_type =
            DTC.parse_dtcmessage_type (Piqirun.Varint msgtype_int) in
          let msg_str = Bigstring.To_string.subo buf ~pos:(pos+4) ~len:(msglen-4) in
          let msg = Piqirun.init_from_string msg_str in
          begin match msgtype with
            | `encoding_request ->
              begin match (Encoding.read (Bigstring.To_string.subo buf ~pos ~len:16)) with
                | None -> Log.error log_dtc "Invalid encoding request received"
                | Some msg -> encoding_request addr w msg
              end
            | `logon_request -> logon_request addr w msg
            | `heartbeat -> heartbeat addr w msg
            | `security_definition_for_symbol_request -> security_definition_request addr w msg
            | `market_data_request -> market_data_request addr w msg
            | `market_depth_request -> market_depth_request addr w msg
            | `open_orders_request -> open_orders_request addr w msg
            | `current_positions_request -> current_positions_request addr w msg
            | `historical_order_fills_request -> historical_order_fills addr w msg
            | `trade_accounts_request -> trade_account_request addr w msg
            | `account_balance_request -> account_balance_request addr w msg
            | `submit_new_single_order -> submit_new_single_order addr w msg
            | `cancel_order -> cancel_order addr w msg
            | `cancel_replace_order -> cancel_replace_order addr w msg
            | #DTC.dtcmessage_type ->
              Log.error log_dtc "Unknown msg type %d" msgtype_int
          end ;
          handle_chunk (consumed + msglen) buf (pos + msglen) (len - msglen)
        end
    in
    let on_connection_io_error exn =
      Connection.remove addr ;
      Log.error log_dtc "on_connection_io_error (%s): %s" addr Exn.(to_string exn)
    in
    let cleanup () =
      Log.info log_dtc "client %s disconnected" addr ;
      Connection.remove addr ;
      Deferred.all_unit [Writer.close w; Reader.close r]
    in
    Deferred.ignore @@ Monitor.protect ~finally:cleanup begin fun () ->
      Monitor.detach_and_iter_errors Writer.(monitor w) ~f:on_connection_io_error;
      Reader.(read_one_chunk_at_a_time r ~handle_chunk:(handle_chunk 0))
    end
  in
  let on_handler_error_f addr exn =
    Log.error log_dtc "on_handler_error (%s): %s"
      Socket.Address.(to_string addr) Exn.(to_string exn)
  in
  Conduit_async.serve
    ~on_handler_error:(`Call on_handler_error_f)
    server (Tcp.on_port port) server_fun

let loglevel_of_int = function 2 -> `Info | 3 -> `Debug | _ -> `Error

let main update_client_span' heartbeat timeout tls port
    daemon pidfile logfile loglevel ll_dtc ll_btrex crt_path key_path sc () =
  let timeout = Time_ns.Span.of_string timeout in
  sc_mode := sc ;
  update_client_span := Time_ns.Span.of_string update_client_span';
  let heartbeat = Option.map heartbeat ~f:Time_ns.Span.of_string in
  let dtcserver ~server ~port =
    dtcserver ~server ~port >>= fun dtc_server ->
    Log.info log_dtc "DTC server started";
    Tcp.Server.close_finished dtc_server
  in

  Log.set_level log_dtc @@ loglevel_of_int @@ max loglevel ll_dtc;
  Log.set_level log_btrex @@ loglevel_of_int @@ max loglevel ll_btrex;

  if daemon then Daemon.daemonize ~cd:"." ();
  stage begin fun `Scheduler_started ->
    Lock_file.create_exn pidfile >>= fun () ->
    Writer.open_file ~append:true logfile >>= fun log_writer ->
    Log.(set_output log_dtc Output.[stderr (); writer `Text log_writer]);
    Log.(set_output log_btrex Output.[stderr (); writer `Text log_writer]);

    let now = Time_ns.now () in
    Rest.currencies () >>| begin function
    | Error err -> failwithf "currencies: %s" (Rest.Http_error.to_string err) ()
    | Ok currs ->
      List.iter currs ~f:(fun (c, t) -> String.Table.set currencies c t)
    end >>= fun () ->
    Rest.tickers () >>| begin function
    | Error err -> failwithf "tickers: %s" (Rest.Http_error.to_string err) ()
    | Ok ts ->
      List.iter ts ~f:(fun t -> String.Table.set tickers t.symbol (now, t))
    end >>= fun () ->
    RestSync.Default.run () ;
    loop_update_tickers () ;
    conduit_server ~tls ~crt_path ~key_path >>= fun server ->
    Deferred.all_unit [
      loop_log_errors ~log:log_dtc (fun () -> ws ?heartbeat timeout) ;
      loop_log_errors ~log:log_dtc (fun () -> dtcserver ~server ~port) ;
    ]
  end

let command =
  let spec =
    let open Command.Spec in
    empty
    +> flag "-update-client−span" (optional_with_default "30s" string) ~doc:"span Span between client updates (default: 10s)"
    +> flag "-heartbeat" (optional string) ~doc:" WS heartbeat period (default: 25s)"
    +> flag "-timeout" (optional_with_default "60s" string) ~doc:" max Disconnect if no message received in N seconds (default: 60s)"
    +> flag "-tls" no_arg ~doc:" Use TLS"
    +> flag "-port" (optional_with_default 5573 int) ~doc:"int TCP port to use (5573)"
    +> flag "-daemon" no_arg ~doc:" Run as a daemon"
    +> flag "-pidfile" (optional_with_default "run/btrex.pid" string) ~doc:"filename Path of the pid file (run/btrex.pid)"
    +> flag "-logfile" (optional_with_default "log/btrex.log" string) ~doc:"filename Path of the log file (log/btrex.log)"
    +> flag "-loglevel" (optional_with_default 2 int) ~doc:"1-3 global loglevel"
    +> flag "-loglevel-dtc" (optional_with_default 2 int) ~doc:"1-3 loglevel for DTC"
    +> flag "-loglevel-btrex" (optional_with_default 2 int) ~doc:"1-3 loglevel for BTREX"
    +> flag "-crt-file" (optional_with_default "ssl/bitsouk.com.crt" string) ~doc:"filename crt file to use (TLS)"
    +> flag "-key-file" (optional_with_default "ssl/bitsouk.com.key" string) ~doc:"filename key file to use (TLS)"
    +> flag "-sc" no_arg ~doc:" Sierra Chart mode."
  in
  Command.Staged.async ~summary:"Bittrex bridge" spec main

let () = Command.run command
