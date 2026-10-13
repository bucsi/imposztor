import gleam/option.{type Option, None}
import imposztor_common/player.{type Player}
import lustre_websocket

pub type Screen {
  JoinScreen
  LobbyScreen
  GameScreen
}

pub type ConnectionStatus {
  StatusConnected
  StatusDisconnected
  StatusReconnecting(attempt: Int)
}

pub type Model {
  Model(
    current_screen: Screen,
    player_name: String,
    is_leader: Bool,
    players: List(Player),
    current_word: Option(String),
    is_imposter: Bool,
    is_first_player: Bool,
    connection_status: ConnectionStatus,
    socket: Option(lustre_websocket.WebSocket),
  )
}


pub fn init() -> Model {
  Model(
    current_screen: JoinScreen,
    player_name: "",
    is_leader: False,
    players: [],
    current_word: None,
    is_imposter: False,
    is_first_player: False,
    connection_status: StatusDisconnected,
    socket: None,
  )
}
