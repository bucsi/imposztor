import gleam/int
import gleam/json
import gleam/list
import gleam/option
import imposztor_common/player
import imposztor_common/ws_api
import imposztor_front/model.{
  type Model, GameScreen, JoinScreen, LobbyScreen, StatusConnected,
  StatusDisconnected, StatusReconnecting,
}
import imposztor_front/msg.{type Msg}
import lustre
import lustre/attribute.{attribute, class, id, maxlength, placeholder, type_, value}
import lustre/effect.{type Effect}
import lustre/element.{type Element, text}
import lustre/element/html.{button, div, h1, h2, input, li, p, span, ul}
import lustre/event.{on_click, on_input}
import lustre_websocket
import plinth/browser/location
import plinth/browser/window

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}

fn init(_flags) -> #(Model, Effect(Msg)) {
  let model = model.init()

  let ws_url = get_ws_url()
  let ws_effect = lustre_websocket.init(ws_url, handle_ws_event)

  #(model, ws_effect)
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
  case msg {
    msg.UpdateName(name) -> #(
      model.Model(..model, player_name: name),
      effect.none(),
    )

    msg.JoinClicked -> {
      case model.socket {
        option.Some(socket) -> {
          let join_msg =
            ws_api.Join(name: model.player_name)
            |> encode_client_message

          #(model, lustre_websocket.send(socket, join_msg))
        }
        option.None -> #(model, effect.none())
      }
    }

    msg.StartRoundClicked -> {
      case model.socket {
        option.Some(socket) -> {
          let start_msg = encode_client_message(ws_api.StartRound)

          #(model, lustre_websocket.send(socket, start_msg))
        }
        option.None -> #(model, effect.none())
      }
    }

    msg.WsConnected(socket) -> #(
      model.Model(
        ..model,
        connection_status: StatusConnected,
        socket: option.Some(socket),
      ),
      effect.none(),
    )

    msg.WsDisconnected -> #(
      model.Model(..model, connection_status: StatusDisconnected, socket: option.None),
      effect.none(),
    )

    msg.WsMessage(ws_api.Joined(is_leader:)) -> #(
      model.Model(..model, current_screen: LobbyScreen, is_leader: is_leader),
      effect.none(),
    )

    msg.WsMessage(ws_api.PlayerList(players:)) -> #(
      model.Model(..model, players: players),
      effect.none(),
    )

    msg.WsMessage(ws_api.LeaderChanged(leader_id:)) -> {
      // Check if we are the new leader
      let is_leader = case model.players {
        [first, ..] -> first.id == leader_id
        [] -> False
      }
      #(model.Model(..model, is_leader: is_leader), effect.none())
    }

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

    msg.NoOp -> #(model, effect.none())
  }
}

fn encode_client_message(msg: ws_api.ClientMessage) -> String {
  case msg {
    ws_api.Join(name:) ->
      json.object([#("type", json.string("join")), #("name", json.string(name))])
      |> json.to_string
    ws_api.StartRound ->
      json.object([#("type", json.string("startRound"))])
      |> json.to_string
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
  }
}

fn view_join_screen(model: Model) -> Element(Msg) {
  div([class("screen")], [
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
  div([class("screen")], [
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
  div([class("screen")], [
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
      view_player_list(model.players),
    ]),
  ])
}

fn view_word_display(model: Model) -> Element(Msg) {
  let word = case model.current_word {
    option.Some(w) -> w
    option.None -> ""
  }

  let class_name = case model.is_imposter {
    True -> "imposter"
    False -> "normal"
  }

  div([id("wordDisplay"), class(class_name)], case model.is_imposter {
    True -> [
      span([class("label")], [text("Te vagy az IMPOSZTOR!")]),
      span([class("word")], [text(word)]),
    ]
    False -> [
      span([class("label")], [text("A szó:")]),
      span([class("word")], [text(word)]),
    ]
  })
}

fn view_player_list(players: List(player.Player)) -> Element(Msg) {
  ul([id("playerList")], list.map(players, view_player_item))
}

fn view_player_item(player: player.Player) -> Element(Msg) {
  let classes = case player.is_leader, player.is_first {
    True, True -> "leader first"
    True, False -> "leader"
    False, True -> "first"
    False, False -> ""
  }

  li([class(classes)], [text(player.name)])
}
