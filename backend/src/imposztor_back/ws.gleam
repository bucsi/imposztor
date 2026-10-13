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
    Player(id: player_id, name: "", is_leader: False, is_first: False)

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
    mist.Text(msg) -> {
      case json.parse(msg, ws_api.client_decoder()) {
        Ok(ws_api.Join(name:)) -> handle_join(conn, state, name)
        Ok(ws_api.StartRound) -> handle_start_round(state)
        Error(_) -> mist.continue(state)
      }
    }
    mist.Custom(RoomMessage(game_room.PlayerListUpdated(players:))) -> {
      let assert Ok(_) = send_msg(conn, ws_api.PlayerList(players:))
      mist.continue(state)
    }
    mist.Custom(RoomMessage(game_room.LeaderChangedMsg(leader_id:))) -> {
      let assert Ok(_) = send_msg(conn, ws_api.LeaderChanged(leader_id:))
      mist.continue(state)
    }
    mist.Custom(RoomMessage(game_room.RoundStartedMsg(
      word:,
      is_imposter:,
      is_first:,
    ))) -> {
      let assert Ok(_) =
        send_msg(conn, ws_api.RoundStarted(word:, is_imposter:, is_first:))
      mist.continue(state)
    }
    mist.Closed | mist.Shutdown -> {
      // Clean up room subscription
      case state.user {
        InRoom(room_subject:, reply_subject:, ..) -> {
          game_room.unsubscribe(room_subject, reply_subject)
        }
        _ -> Nil
      }
      mist.stop()
    }
    _ -> mist.continue(state)
  }
}

fn handle_join(conn: mist.WebsocketConnection, state: State, name: String) {
  // Limit name length
  let name = string.slice(name, 0, 20)

  let player = case state.user {
    InLobby(player:) | InRoom(player:, ..) -> Player(..player, name: name)
  }

  case state.user {
    InLobby(..) -> {
      // Subscribe to game room
      let reply_subject = process.new_subject()
      let _initial_msg =
        game_room.subscribe(state.game_room_subject, player, reply_subject)

      let new_selector =
        process.select_map(state.selector, reply_subject, RoomMessage)

      // Check if this is the first player (leader)
      // Will be set by game room
      let is_leader = False

      let assert Ok(_) = send_msg(conn, ws_api.Joined(is_leader:))

      let user_state =
        InRoom(player:, room_subject: state.game_room_subject, reply_subject:)

      mist.continue(State(..state, selector: new_selector, user: user_state))
      |> mist.with_selector(new_selector)
    }
    InRoom(room_subject:, reply_subject:, ..) -> {
      // Update name only
      let user_state = InRoom(player:, room_subject:, reply_subject:)
      mist.continue(State(..state, user: user_state))
    }
  }
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
