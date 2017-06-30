open Core
open Async

open Figgie
open Market

type t =
  { username : Username.t
  ; conn     : Rpc.Connection.t
  ; updates  : Protocol.Game_update.t Pipe.Reader.t
  ; state    : State.t
  }

let username t = t.username
let updates  t = t.updates

let unacked_orders t =
  Hashtbl.fold t.state.orders
    ~init:[]
    ~f:(fun ~key:_ ~data:order_state acc ->
        if order_state.is_acked then (
          acc
        ) else (
          order_state.order :: acc
        )
      )

let open_orders t =
  Hashtbl.fold t.state.orders
    ~init:(Card.Hand.create_all (Dirpair.create_both []))
    ~f:(fun ~key:_ ~data:order_state orders ->
        let order = order_state.order in
        Card.Hand.modify orders ~suit:order.symbol
          ~f:(Dirpair.modify ~dir:order.dir ~f:(fun halfbook ->
              Halfbook.add_order halfbook order
            ))
      )

let hand_if_no_fills t = t.state.hand

let hand_if_filled t =
  Option.map (hand_if_no_fills t) ~f:(fun hand_if_no_fills ->
      Card.Hand.map2
        hand_if_no_fills
        (open_orders t)
        ~f:(fun from_hand open_orders ->
            Dirpair.mapi open_orders ~f:(fun dir orders ->
                let total_size =
                  List.sum (module Size) orders ~f:(fun o -> o.size)
                in
                Dir.fold dir ~buy:Size.(+) ~sell:Size.(-)
                  from_hand total_size
              )
          )
    )

let sellable_hand t =
  match hand_if_filled t with
  | None -> Card.Hand.create_all Size.zero
  | Some hif -> Card.Hand.map hif ~f:(Dirpair.get ~dir:Sell)

module Staged_order = struct
  type t = Order.t

  let create bot ~symbol ~dir ~price ~size : t =
    { owner = username bot
    ; id = State.new_order_id bot.state
    ; symbol; dir; price; size
    }

  let id (t : t) = t.id

  let send_exn t bot =
    State.send_order bot.state ~conn:bot.conn ~order:t
end

let cancel t id = Rpc.Rpc.dispatch_exn Protocol.Cancel.rpc t.conn id

let request_update_exn t thing_to_get =
  match%map Rpc.Rpc.dispatch_exn Protocol.Get_update.rpc t.conn thing_to_get with
  | Error (`Not_logged_in | `Not_in_a_room | `You're_not_playing) -> assert false
  | Error `Game_not_in_progress
  | Ok () -> ()

let try_set_ready_on_conn ~conn =
  Rpc.Rpc.dispatch_exn Protocol.Is_ready.rpc conn true
  |> Deferred.ignore

let try_set_ready t = try_set_ready_on_conn ~conn:t.conn

let start_playing ~conn ~username ~(room_choice : Room_choice.t) =
  let%bind () =
    match%map Rpc.Rpc.dispatch_exn Protocol.Login.rpc conn username with
    | Error (`Already_logged_in | `Invalid_username) -> assert false
    | Ok () -> ()
  in
  let%bind (_room_id, updates) =
    Room_choice.join room_choice ~conn ~my_name:username
  in
  match%map
    Rpc.Rpc.dispatch_exn Protocol.Start_playing.rpc conn Sit_anywhere
  with
  | Error (`Not_logged_in | `Not_in_a_room) -> assert false
  | Error ((`Game_already_started | `Seat_occupied) as error) ->
    raise_s [%message
      "Joined a room that didn't want new players"
        (error : Protocol.Start_playing.error)
    ]
  | Error `You're_already_playing
  | Ok (_ : Lobby.Room.Seat.t) -> updates

let run ~server ~config ~username ~room_choice ~auto_ready ~f =
  Rpc.Connection.with_client
    ~host:(Host_and_port.host server)
    ~port:(Host_and_port.port server)
    (fun conn ->
      let%bind updates = start_playing ~conn ~username ~room_choice in
      let state = State.create () in
      let ready_if_auto () =
        if auto_ready then (
          try_set_ready_on_conn ~conn
        ) else (
          Deferred.unit
        )
      in
      let handle_update : Protocol.Game_update.t -> unit =
        function
        | Broadcast (Round_over _) ->
          State.clear state;
          don't_wait_for (ready_if_auto ())
        | Broadcast (Exec exec) ->
          let fills = Exec.fills exec in
          if Username.equal username exec.order.owner then (
            let order_state =
              Hashtbl.find_exn state.orders exec.order.id
            in
            State.ack state ~order_state;
            List.iter fills ~f:(fun fill ->
                State.fill state ~order_state ~size:fill.size
              )
          );
          List.iter fills ~f:(fun fill ->
              Option.iter (Hashtbl.find state.orders fill.id)
                ~f:(fun order_state ->
                    State.fill state ~order_state ~size:fill.size
                  )
            )
        | Broadcast (Out order) ->
          State.out state ~id:order.id
        | Hand hand ->
          state.hand <- Some hand
        | _ -> ()
      in
      let updates = Pipe.map updates ~f:(fun u -> handle_update u; u) in
      let%bind () = ready_if_auto () in
      f { username; conn; updates; state } ~config)
  >>| Or_error.of_exn_result

let make_command ~summary ~config_param ~username_stem
    ?(auto_ready=false)
    f =
  let open Command.Let_syntax in
  Command.async_or_error'
    ~summary
    [%map_open
      let server =
        flag "-server" (required (Arg_type.create Host_and_port.of_string))
          ~doc:"HOST:PORT where to connect"
      and log_level =
        flag "-log-level" (optional_with_default `Info Log.Level.arg)
          ~doc:"L Debug, Info, or Error"
      and which =
        flag "-which" (optional int)
          ~doc:"N modulate username"
      and config = config_param
      and room_choice = Room_choice.param
      in
      fun () ->
        let username =
          username_stem ^ Option.value_map which ~default:"" ~f:Int.to_string
          |> Username.of_string
        in
        Log.Global.set_level log_level;
        Log.Global.sexp ~level:`Debug [%message
          "started"
            (username : Username.t)
        ];
        run ~server ~config ~username ~room_choice
          ~auto_ready
          ~f
    ]
