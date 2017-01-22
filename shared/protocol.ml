open Core_kernel.Std
open Async_rpc_kernel.Std

let default_async_rpc_port = 58828
let default_websocket_port = 58829

module Round_results = struct
  type t = {
    gold : Card.Suit.t;
    hands : Market.Size.t Card.Hand.t Username.Map.t;
    scores_this_round : Market.Price.t Username.Map.t;
  } [@@deriving bin_io, sexp]
end

module Broadcast = struct
  type t =
    | Player_joined of Username.t
    | Player_ready of { who : Username.t; is_ready : bool }
    | Chat of Username.t * string
    | New_round
    | Exec of Market.Order.t * Market.Exec.t
    | Out of Market.Order.t
    | Round_over of Round_results.t
    | Scores of Market.Price.t Username.Map.t
    [@@deriving bin_io, sexp]
end

module Time_remaining = struct
  type span = Time_ns.Span.t [@@deriving bin_io]
  let sexp_of_span = Time_ns.Span.Alternate_sexp.sexp_of_t
  let span_of_sexp = Time_ns.Span.Alternate_sexp.t_of_sexp

  type query = unit [@@deriving bin_io, sexp]
  type response = (span, [ `Game_not_in_progress ]) Result.t
    [@@deriving bin_io, sexp]
  let rpc =
    Rpc.Rpc.create ~name:"time-left" ~version:1 ~bin_query ~bin_response
end

module Player_update = struct
  type t =
    | Broadcast of Broadcast.t
    | Hand of Market.Size.t Card.Hand.t
    | Market of Market.Book.t
    [@@deriving bin_io, sexp]
end

module Login = struct
  type query = Username.t [@@deriving bin_io, sexp]
  type error = [ `Game_is_full | `Game_already_started | `Already_logged_in ]
    [@@deriving bin_io, sexp]
  type response = Player_update.t [@@deriving bin_io, sexp]
  let rpc =
    Rpc.Pipe_rpc.create
      ~name:"login" ~version:1 ~bin_query ~bin_response ~bin_error
      ()
end

module Is_ready = struct
  type query = bool [@@deriving bin_io, sexp]
  type response = (unit, [ `Login_first | `Already_playing ]) Result.t
    [@@deriving bin_io, sexp]
  let rpc = Rpc.Rpc.create ~name:"ready" ~version:1 ~bin_query ~bin_response
end

module Chat = struct
  type query = string [@@deriving bin_io, sexp]
  type response = (unit, [ `Login_first ]) Result.t
    [@@deriving bin_io, sexp]
  let rpc = Rpc.Rpc.create ~name:"chat" ~version:1 ~bin_query ~bin_response
end

type not_playing =
  [ `Login_first | `Game_not_in_progress | `You're_not_playing ]
  [@@deriving bin_io, sexp]

let playing_exn =
  function
  | Ok x -> x
  | Error not_playing ->
    Error.raise_s [%message
      "Protocol.playing_exn"
        (not_playing : not_playing)
    ]

(* The response comes via the updates stream rather than in the RPC response,
   so that it has guaranteed ordering wrt other updates. *)
module Get_update = struct
  type query =
    | Hand
    | Market
    [@@deriving bin_io, sexp]
  type response = (unit, not_playing) Result.t [@@deriving bin_io, sexp]
  let rpc =
    Rpc.Rpc.create ~name:"get-update" ~version:1 ~bin_query ~bin_response
end

module Order = struct
  type query = Market.Order.t [@@deriving bin_io, sexp]

  type bad_price =
    [ `Price_must_be_nonnegative
    | `Price_too_high
    ] [@@deriving bin_io, sexp]

  type error =
    [ not_playing
    | `Owner_is_not_sender
    | `Duplicate_order_id
    | bad_price
    | `Size_must_be_positive
    | `Not_enough_to_sell
    ] [@@deriving bin_io, sexp]
  type response = ([ `Ack ], error) Result.t [@@deriving bin_io, sexp]
  let rpc = Rpc.Rpc.create ~name:"order" ~version:1 ~bin_query ~bin_response
end

(* Note that when you get the ack back, the order is cancelled, but it's
   possible that fills on it that already happened are still in flight. You
   should wait for an Out to show up in the updates pipe before assuming
   nothing more can be done on the order. *)
module Cancel = struct
  type query = Market.Order.Id.t [@@deriving bin_io, sexp]
  type error =
    [ not_playing
    | `No_such_order
    ] [@@deriving bin_io, sexp]
  type response = ([ `Ack ], error) Result.t [@@deriving bin_io, sexp]
  let rpc = Rpc.Rpc.create ~name:"cancel" ~version:1 ~bin_query ~bin_response
end

module Cancel_all = struct
  type query = unit [@@deriving bin_io, sexp]
  type error = not_playing [@@deriving bin_io, sexp]
  type response = ([ `Ack ], error) Result.t [@@deriving bin_io, sexp]
  let rpc = Rpc.Rpc.create ~name:"cxl-all" ~version:1 ~bin_query ~bin_response
end
