import imposztor_common/ws_api
import lustre_websocket

pub type Msg {
  // UI Events
  UpdateName(String)
  JoinClicked
  StartRoundClicked

  // WebSocket Events
  WsConnected(lustre_websocket.WebSocket)
  WsDisconnected
  WsMessage(ws_api.ServerMessage)
  WsError(String)

  // Internal
  NoOp
}
