import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/option.{type Option, None}
import imposztor_common/player.{type Player}

const type_key = "type"

// Client -> Server messages
pub type ClientMessage {
  Join(name: String, token: Option(String))
  StartRound
}

fn typed_object_decoder(
  expected_type: String,
  inner_decoder: decode.Decoder(a),
  zero: a,
) -> decode.Decoder(a) {
  use type_ <- decode.field(type_key, decode.string)
  case type_ {
    t if t == expected_type -> inner_decoder
    _ -> decode.failure(zero, expected_type)
  }
}

fn join_decoder() {
  typed_object_decoder(
    "join",
    {
      use name <- decode.field("name", decode.string)
      use token <- decode.optional_field(
        "token",
        None,
        decode.optional(decode.string),
      )
      decode.success(Join(name:, token:))
    },
    Join(name: "", token: None),
  )
}

fn start_round_decoder() {
  typed_object_decoder("startRound", decode.success(StartRound), StartRound)
}

pub fn client_decoder() {
  decode.one_of(join_decoder(), or: [start_round_decoder()])
}

pub fn client_encoder(msg: ClientMessage) -> Json {
  case msg {
    Join(name:, token:) ->
      json.object([
        #(type_key, json.string("join")),
        #("name", json.string(name)),
        #("token", json.nullable(token, json.string)),
      ])
    StartRound -> json.object([#(type_key, json.string("startRound"))])
  }
}

// Server -> Client messages
pub type ServerMessage {
  Joined(token: String, is_leader: Bool)
  PlayerList(players: List(Player))
  LeaderChanged(leader_id: String)
  RoundStarted(word: String, is_imposter: Bool, is_first: Bool)
  ErrorMsg(message: String)
}

pub fn server_encoder(msg: ServerMessage) -> Json {
  case msg {
    Joined(token:, is_leader:) ->
      json.object([
        #(type_key, json.string("joined")),
        #("token", json.string(token)),
        #("isLeader", json.bool(is_leader)),
      ])
    PlayerList(players:) ->
      json.object([
        #(type_key, json.string("playerList")),
        #("players", json.array(players, player.player_encoder)),
      ])
    LeaderChanged(leader_id:) ->
      json.object([
        #(type_key, json.string("leaderChanged")),
        #("leaderId", json.string(leader_id)),
      ])
    RoundStarted(word:, is_imposter:, is_first:) ->
      json.object([
        #(type_key, json.string("roundStarted")),
        #("word", json.string(word)),
        #("isImposter", json.bool(is_imposter)),
        #("isFirst", json.bool(is_first)),
      ])
    ErrorMsg(message:) ->
      json.object([
        #(type_key, json.string("error")),
        #("message", json.string(message)),
      ])
  }
}

fn joined_decoder() {
  typed_object_decoder(
    "joined",
    {
      use token <- decode.field("token", decode.string)
      use is_leader <- decode.field("isLeader", decode.bool)
      decode.success(Joined(token:, is_leader:))
    },
    Joined(token: "", is_leader: False),
  )
}

fn player_list_decoder() {
  typed_object_decoder(
    "playerList",
    {
      use players <- decode.field(
        "players",
        decode.list(player.player_decoder()),
      )
      decode.success(PlayerList(players:))
    },
    PlayerList(players: []),
  )
}

fn leader_changed_decoder() {
  typed_object_decoder(
    "leaderChanged",
    {
      use leader_id <- decode.field("leaderId", decode.string)
      decode.success(LeaderChanged(leader_id:))
    },
    LeaderChanged(leader_id: ""),
  )
}

fn round_started_decoder() {
  typed_object_decoder(
    "roundStarted",
    {
      use word <- decode.field("word", decode.string)
      use is_imposter <- decode.field("isImposter", decode.bool)
      use is_first <- decode.field("isFirst", decode.bool)
      decode.success(RoundStarted(word:, is_imposter:, is_first:))
    },
    RoundStarted(word: "", is_imposter: False, is_first: False),
  )
}

fn error_msg_decoder() {
  typed_object_decoder(
    "error",
    {
      use message <- decode.field("message", decode.string)
      decode.success(ErrorMsg(message:))
    },
    ErrorMsg(message: ""),
  )
}

pub fn server_decoder() {
  decode.one_of(joined_decoder(), or: [
    player_list_decoder(),
    leader_changed_decoder(),
    round_started_decoder(),
    error_msg_decoder(),
  ])
}
