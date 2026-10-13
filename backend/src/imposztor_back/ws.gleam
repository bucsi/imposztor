import gleam/erlang/process
import gleam/json
import gleam/option.{Some}
import gleam/string
import imposztor_back/game_room
import imposztor_common/player.{type Player, Player}
import imposztor_common/ws_api
import mist

pub type UserState {
  InLobby(player: Player)
  InRoom(
    player: Player,
    room_subject: process.Subject(game_room.Message),
    reply_subject: process.Subject(game_room.PublishMessage),
  )
}

pub type State {
  State(
    self: process.Subject(Message),
    selector: process.Selector(Message),
    user: UserState,
    game_room_subject: process.Subject(game_room.Message),
  )
}

pub type Message {
  RoomMessage(msg: game_room.PublishMessage)
}

pub fn on_init(
  _conn: mist.WebsocketConnection,
  game_room_subject: process.Subject(game_room.Message),
) {
  let self = process.new_subject()
  let selector = process.new_selector() |> process.select(self)

  // Generate unique player ID
  let player_id = string.inspect(process.self())
  let player =
    Player(id: player_id, name: "", is_leader: False, is_first: False, connected: True)

  let state =
    State(self:, user: InLobby(player:), game_room_subject:, selector:)

  #(state, Some(selector))
}

pub fn on_close(_state: State) {
  Nil
}

pub fn handle_message(
  state: State,
  message: mist.WebsocketMessage(Message),
  conn: mist.WebsocketConnection,
) {
  case message {
    mist.Text(msg) -> handle_client_message(conn, state, msg)
    mist.Custom(RoomMessage(room_msg)) -> {
      let assert Ok(_) = send_msg(conn, to_server_message(room_msg))
      mist.continue(state)
    }
    mist.Closed | mist.Shutdown -> {
      leave_room(state.user)
      mist.stop()
    }
    _ -> mist.continue(state)
  }
}

fn handle_client_message(
  conn: mist.WebsocketConnection,
  state: State,
  msg: String,
) {
  case json.parse(msg, ws_api.client_decoder()) {
    Ok(ws_api.Join(name:, token:)) -> handle_join(conn, state, name, token)
    Ok(ws_api.StartRound) -> handle_start_round(state)
    Error(_) -> mist.continue(state)
  }
}

fn to_server_message(msg: game_room.PublishMessage) -> ws_api.ServerMessage {
  case msg {
    game_room.PlayerListUpdated(players:) -> ws_api.PlayerList(players:)
    game_room.LeaderChangedMsg(leader_id:) -> ws_api.LeaderChanged(leader_id:)
    game_room.RoundStartedMsg(word:, is_imposter:, is_first:) ->
      ws_api.RoundStarted(word:, is_imposter:, is_first:)
  }
}

fn leave_room(user: UserState) -> Nil {
  case user {
    InRoom(room_subject:, reply_subject:, ..) ->
      game_room.unsubscribe(room_subject, reply_subject)
    _ -> Nil
  }
}

fn handle_join(
  conn: mist.WebsocketConnection,
  state: State,
  name: String,
  token: option.Option(String),
) {
  let name = string.slice(name, 0, 20)

  let player = case state.user {
    InLobby(player:) | InRoom(player:, ..) -> Player(..player, name:)
  }

  case state.user {
    InLobby(..) -> join_room(conn, state, player, token)
    InRoom(room_subject:, reply_subject:, ..) -> {
      let user_state = InRoom(player:, room_subject:, reply_subject:)
      mist.continue(State(..state, user: user_state))
    }
  }
}

fn join_room(
  conn: mist.WebsocketConnection,
  state: State,
  player: Player,
  token: option.Option(String),
) {
  let reply_subject = process.new_subject()
  let game_room.JoinResult(token:, is_leader:) =
    game_room.subscribe(state.game_room_subject, player, token, reply_subject)

  let new_selector =
    process.select_map(state.selector, reply_subject, RoomMessage)

  let assert Ok(_) = send_msg(conn, ws_api.Joined(token:, is_leader:))

  let player = Player(..player, id: token, is_leader:)
  let user_state =
    InRoom(player:, room_subject: state.game_room_subject, reply_subject:)

  mist.continue(State(..state, selector: new_selector, user: user_state))
  |> mist.with_selector(new_selector)
}

fn handle_start_round(state: State) {
  case state.user {
    InRoom(room_subject:, reply_subject:, ..) -> {
      process.send(room_subject, game_room.StartRound(reply_subject))
      mist.continue(state)
    }
    _ -> mist.continue(state)
  }
}

fn send_msg(conn: mist.WebsocketConnection, msg: ws_api.ServerMessage) {
  mist.send_text_frame(conn, json.to_string(ws_api.server_encoder(msg)))
}
