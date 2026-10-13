import gleam/dynamic/decode
import gleam/json.{type Json}

pub type PlayerId =
  String

pub type Player {
  Player(
    id: PlayerId,
    name: String,
    is_leader: Bool,
    is_first: Bool,
    connected: Bool,
  )
}

pub fn player_encoder(player: Player) -> Json {
  json.object([
    #("id", json.string(player.id)),
    #("name", json.string(player.name)),
    #("isLeader", json.bool(player.is_leader)),
    #("isFirst", json.bool(player.is_first)),
    #("connected", json.bool(player.connected)),
  ])
}

pub fn player_decoder() {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use is_leader <- decode.field("isLeader", decode.bool)
  use is_first <- decode.field("isFirst", decode.bool)
  use connected <- decode.optional_field("connected", True, decode.bool)
  decode.success(Player(id:, name:, is_leader:, is_first:, connected:))
}
