import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/result
import imposztor_common/player
import imposztor_common/ws_api
import imposztor_front/model.{
  type Model, GameScreen, JoinScreen, LobbyScreen, StatusConnected,
  StatusDisconnected, StatusFailed, StatusReconnecting,
}
import imposztor_front/msg.{type Msg}
import lustre
import lustre/attribute.{
  attribute, class, id, maxlength, placeholder, type_, value,
}
import lustre/effect.{type Effect}
import lustre/element.{type Element, text}
import lustre/element/html.{button, div, h1, h2, input, li, p, span, ul}
import lustre/event.{on_click, on_input}
import lustre_websocket
import plinth/browser/location
import plinth/browser/window
import plinth/javascript/console
import plinth/javascript/global
import plinth/javascript/storage
import varasto

const localstorage_key_prefix = "net.bucsi.imposztor."

const token_key = localstorage_key_prefix <> "token"

const name_key = localstorage_key_prefix <> "name"

const debug_key = localstorage_key_prefix <> "debug"

const max_reconnect_attempts = 10

const reconnect_delay_ms = 2000

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}

fn init(_flags) -> #(Model, Effect(Msg)) {
  let model =
    model.Model(
      ..model.init(),
      player_token: load_string(token_key),
      player_name: option.unwrap(load_string(name_key), ""),
      debug: load_raw(debug_key),
    )

  let ws_url = get_ws_url()
  let ws_effect = lustre_websocket.init(ws_url, handle_ws_event)

  #(model, ws_effect)
}

fn token_storage() -> Result(varasto.TypedStorage(String), Nil) {
  use raw <- result.map(varasto.local())
  varasto.new(raw, decode.string, json.string)
}

fn load_string(key: String) -> option.Option(String) {
  case token_storage() {
    Ok(typed) ->
      varasto.get(typed, key)
      |> result.map(option.Some)
      |> result.unwrap(option.None)
    Error(_) -> option.None
  }
}

fn load_raw(key: String) -> option.Option(String) {
  case storage.local() {
    Ok(raw) ->
      case storage.get_item(raw, key) {
        Ok("") | Error(_) -> option.None
        Ok(value) -> option.Some(value)
      }
    Error(_) -> option.None
  }
}

fn save_string(key: String, value: String) -> Nil {
  case token_storage() {
    Ok(typed) -> {
      let _ = varasto.set(typed, key, value)
      Nil
    }
    Error(_) -> Nil
  }
}

fn get_ws_url() -> String {
  let origin = location.origin(window.location(window.self()))
  let ws_origin = case origin {
    "https://" <> rest -> "wss://" <> rest
    "http://" <> rest -> "ws://" <> rest
    _ -> origin
  }
  ws_origin <> "/ws"
}

fn handle_ws_event(event: lustre_websocket.WebSocketEvent) -> Msg {
  case event {
    lustre_websocket.OnOpen(socket) -> msg.WsConnected(socket)
    lustre_websocket.OnClose(_) -> msg.WsDisconnected
    lustre_websocket.OnTextMessage(text) -> {
      case json.parse(text, ws_api.server_decoder()) {
        Ok(server_msg) -> msg.WsMessage(server_msg)
        Error(_) -> msg.NoOp
      }
    }
    lustre_websocket.OnBinaryMessage(_) -> msg.NoOp
    lustre_websocket.InvalidUrl -> msg.NoOp
  }
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  log_debug(model, msg)

  case msg {
    msg.UpdateName(name) -> {
      save_string(name_key, name)
      #(model.Model(..model, player_name: name), effect.none())
    }

    msg.JoinClicked ->
      send_when_connected(
        model,
        ws_api.Join(name: model.player_name, token: model.player_token),
      )

    msg.StartRoundClicked -> send_when_connected(model, ws_api.StartRound)

    msg.WsConnected(socket) -> #(
      model.Model(
        ..model,
        connection_status: StatusConnected,
        socket: option.Some(socket),
      ),
      rejoin_effect(model, socket),
    )

    msg.WsDisconnected -> handle_disconnect(model)

    msg.WsMessage(ws_api.Joined(token:, is_leader:)) -> {
      save_string(token_key, token)
      #(
        model.Model(
          ..model,
          current_screen: LobbyScreen,
          is_leader:,
          player_token: option.Some(token),
        ),
        effect.none(),
      )
    }

    msg.WsMessage(ws_api.PlayerList(players:)) -> #(
      model.Model(..model, players: players),
      effect.none(),
    )

    msg.WsMessage(ws_api.LeaderChanged(leader_id:)) -> #(
      model.Model(..model, is_leader: is_new_leader(model.players, leader_id)),
      effect.none(),
    )

    msg.WsMessage(ws_api.RoundStarted(word:, is_imposter:, is_first:)) -> #(
      model.Model(
        ..model,
        current_screen: GameScreen,
        current_word: option.Some(word),
        is_imposter: is_imposter,
        is_first_player: is_first,
      ),
      effect.none(),
    )

    msg.WsMessage(ws_api.ErrorMsg(message: _)) -> {
      // TODO: Show error to user
      #(model, effect.none())
    }

    msg.WsError(_) -> #(model, effect.none())

    msg.ReconnectRequested -> #(
      model,
      lustre_websocket.init(get_ws_url(), handle_ws_event),
    )

    msg.NoOp -> #(model, effect.none())
  }
}

fn log_debug(model: Model, msg: Msg) -> Nil {
  case model.debug {
    option.Some(_) -> {
      console.group("debug")
      {
        console.log(model)
        console.log(msg)
      }
      console.group_end()
      Nil
    }
    option.None -> Nil
  }
}

fn send_when_connected(
  model: Model,
  message: ws_api.ClientMessage,
) -> #(Model, Effect(Msg)) {
  case model.socket {
    option.Some(socket) -> #(
      model,
      lustre_websocket.send(
        socket,
        json.to_string(ws_api.client_encoder(message)),
      ),
    )
    option.None -> #(model, effect.none())
  }
}

fn is_new_leader(players: List(player.Player), leader_id: String) -> Bool {
  case players {
    [first, ..] -> first.id == leader_id
    [] -> False
  }
}

fn handle_disconnect(model: Model) -> #(Model, Effect(Msg)) {
  let model = model.Model(..model, socket: option.None)
  case should_reconnect(model) {
    False -> #(
      model.Model(..model, connection_status: StatusDisconnected),
      effect.none(),
    )
    True -> {
      let next_attempt = case model.connection_status {
        StatusReconnecting(attempt:) -> attempt + 1
        _ -> 1
      }
      case next_attempt > max_reconnect_attempts {
        True -> #(
          model.Model(..model, connection_status: StatusFailed),
          effect.none(),
        )
        False -> #(
          model.Model(
            ..model,
            connection_status: StatusReconnecting(attempt: next_attempt),
          ),
          schedule_reconnect(),
        )
      }
    }
  }
}

fn should_reconnect(model: Model) -> Bool {
  model.current_screen != JoinScreen && option.is_some(model.player_token)
}

fn schedule_reconnect() -> Effect(Msg) {
  effect.from(fn(dispatch) {
    global.set_timeout(reconnect_delay_ms, fn() {
      dispatch(msg.ReconnectRequested)
    })
    Nil
  })
}

fn rejoin_effect(
  model: Model,
  socket: lustre_websocket.WebSocket,
) -> Effect(Msg) {
  case should_reconnect(model) {
    False -> effect.none()
    True ->
      lustre_websocket.send(
        socket,
        json.to_string(
          ws_api.client_encoder(ws_api.Join(
            name: model.player_name,
            token: model.player_token,
          )),
        ),
      )
  }
}

fn view(model: Model) -> Element(Msg) {
  div([class("app")], [
    view_connection_status(model.connection_status),
    div([class("container")], [
      h1([], [text("Imposztor")]),
      case model.current_screen {
        JoinScreen -> view_join_screen(model)
        LobbyScreen -> view_lobby_screen(model)
        GameScreen -> view_game_screen(model)
      },
    ]),
  ])
}

fn view_connection_status(status: model.ConnectionStatus) -> Element(Msg) {
  case status {
    StatusConnected -> div([class("connection-status hidden")], [])
    StatusDisconnected ->
      div([class("connection-status")], [
        span([class("status-icon")], [text("⚠️")]),
        span([class("status-text")], [
          text("Kapcsolat megszakadt - Újracsatlakozás..."),
        ]),
      ])
    StatusReconnecting(attempt:) ->
      div([class("connection-status")], [
        span([class("status-icon")], [text("⚠️")]),
        span([class("status-text")], [
          text("Újracsatlakozás... (" <> int.to_string(attempt) <> ")"),
        ]),
      ])
    StatusFailed ->
      div([class("connection-status failed")], [
        span([class("status-icon")], [text("❌")]),
        span([class("status-text")], [
          text("Kapcsolat megszakadt - töltsd újra az oldalt"),
        ]),
      ])
  }
}

fn view_join_screen(model: Model) -> Element(Msg) {
  div([class("screen join")], [
    input([
      type_("text"),
      id("nameInput"),
      placeholder("Neved"),
      maxlength(20),
      attribute("autocomplete", "off"),
      value(model.player_name),
      on_input(msg.UpdateName),
    ]),
    button([id("joinBtn"), on_click(msg.JoinClicked)], [text("Csatlakozás")]),
  ])
}

fn view_lobby_screen(model: Model) -> Element(Msg) {
  div([class("screen lobby")], [
    h2([], [text("Játékosok")]),
    view_player_list(model.players),
    case model.is_leader {
      True ->
        button([id("startBtn"), on_click(msg.StartRoundClicked)], [
          text("Új kör"),
        ])
      False -> p([id("waitingText")], [text("Várakozás a vezetőre...")])
    },
  ])
}

fn view_game_screen(model: Model) -> Element(Msg) {
  div([class("screen game")], [
    view_word_display(model),
    case model.is_first_player {
      True -> div([id("firstPlayerBadge")], [text("Te kezdesz!")])
      False -> div([id("firstPlayerBadge"), class("hidden")], [])
    },
    case model.is_leader {
      True ->
        button([id("nextRoundBtn"), on_click(msg.StartRoundClicked)], [
          text("Új kör"),
        ])
      False -> div([id("nextRoundBtn"), class("hidden")], [])
    },
    div([class("player-card")], [
      div([class("player-card-header")], [text("Játékosok")]),
      view_player_list_with_id("gamePlayerList", model.players),
    ]),
  ])
}

fn view_word_display(model: Model) -> Element(Msg) {
  let word = option.unwrap(model.current_word, "")
  let #(class_name, label) = case model.is_imposter {
    True -> #("imposter", "Te vagy az IMPOSZTOR!")
    False -> #("normal", "A szó:")
  }

  div([id("wordDisplay"), class(class_name)], [
    span([class("label")], [text(label)]),
    span([class("word")], [text(word)]),
  ])
}

fn view_player_list(players: List(player.Player)) -> Element(Msg) {
  view_player_list_with_id("playerList", players)
}

fn view_player_list_with_id(
  list_id: String,
  players: List(player.Player),
) -> Element(Msg) {
  ul([id(list_id)], list.map(players, view_player_item))
}

fn view_player_item(player: player.Player) -> Element(Msg) {
  li([class(player_item_classes(player))], [text(player.name)])
}

fn player_item_classes(player: player.Player) -> String {
  let role = case player.is_leader, player.is_first {
    True, True -> "leader first"
    True, False -> "leader"
    False, True -> "first"
    False, False -> ""
  }
  case player.connected {
    True -> role
    False -> role <> " disconnected"
  }
}
