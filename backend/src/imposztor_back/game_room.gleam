import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import imposztor_common/player.{type Player, type PlayerId, Player}
import imposztor_common/words
import lanyard

pub type GameRoomId =
  String

pub type PlayerConnection {
  PlayerConnection(
    subject: Subject(PublishMessage),
    player: Player,
    monitor: process.Monitor,
    pid: process.Pid,
  )
}

pub type RoundState {
  RoundState(
    word: String,
    similar_word: String,
    imposter_id: PlayerId,
    first_player_id: PlayerId,
  )
}

pub type State {
  State(
    self_subject: Subject(Message),
    id: GameRoomId,
    connections: Dict(PlayerId, PlayerConnection),
    current_round: Option(RoundState),
  )
}

pub type PublishMessage {
  PlayerListUpdated(players: List(Player))
  LeaderChangedMsg(leader_id: PlayerId)
  RoundStartedMsg(word: String, is_imposter: Bool, is_first: Bool)
}

pub type JoinResult {
  JoinResult(token: PlayerId, is_leader: Bool)
}

pub type Message {
  Subscribe(
    player: Player,
    token: Option(PlayerId),
    reply_to: Subject(JoinResult),
    subject: Subject(PublishMessage),
  )
  Unsubscribe(subject: Subject(PublishMessage))
  StartRound(subject: Subject(PublishMessage))
  PlayerProcessDown(pid: process.Pid)
  Noop
}

pub fn start(
  id: GameRoomId,
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  let spec =
    actor.new_with_initialiser(5000, fn(self_subject) {
      let selector =
        process.new_selector()
        |> process.select(self_subject)
        |> process.select_monitors(fn(down) {
          case down {
            process.ProcessDown(pid:, ..) -> PlayerProcessDown(pid:)
            _ -> Noop
          }
        })

      Ok(
        actor.initialised(State(
          self_subject:,
          id:,
          connections: dict.new(),
          current_round: None,
        ))
        |> actor.selecting(selector)
        |> actor.returning(self_subject),
      )
    })
    |> actor.on_message(handle_message)

  actor.start(spec)
}

pub fn handle_message(state: State, message: Message) -> actor.Next(State, a) {
  case message {
    Subscribe(player:, token:, reply_to:, subject:) ->
      handle_subscribe(state, subject, token, player, reply_to)
    Unsubscribe(subject:) -> handle_unsubscribe(state, subject)
    StartRound(subject:) -> handle_start_round(state, subject)
    PlayerProcessDown(pid:) -> handle_player_down(state, pid)
    Noop -> actor.continue(state)
  }
}

fn handle_subscribe(
  state: State,
  subject: Subject(PublishMessage),
  token: Option(PlayerId),
  player: Player,
  reply_to: Subject(JoinResult),
) -> actor.Next(State, a) {
  case process.subject_owner(subject) {
    Error(_) -> actor.continue(state)
    Ok(pid) ->
      case known_connection(state.connections, token) {
        Some(existing) -> reclaim(pid, state, subject, existing, reply_to)
        None -> mint_player(pid, state, subject, player, reply_to)
      }
  }
}

fn known_connection(
  connections: Dict(PlayerId, PlayerConnection),
  token: Option(PlayerId),
) -> Option(PlayerConnection) {
  use t <- option.then(token)
  option.from_result(dict.get(connections, t))
}

fn mint_player(
  pid: process.Pid,
  state: State,
  subject: Subject(PublishMessage),
  player: Player,
  reply_to: Subject(JoinResult),
) -> actor.Next(State, a) {
  let lanyard.NanoID(token) = lanyard.custom_length(8)
  let is_leader = !has_connected_leader(state.connections)
  let player = Player(..player, id: token, is_leader:)
  let monitor = process.monitor(pid)
  let connections =
    dict.insert(
      state.connections,
      token,
      PlayerConnection(subject:, player:, monitor:, pid:),
    )

  process.send(reply_to, JoinResult(token:, is_leader:))
  announce(connections, state.current_round, subject, player)

  actor.continue(State(..state, connections:))
}

fn reclaim(
  pid: process.Pid,
  state: State,
  subject: Subject(PublishMessage),
  existing: PlayerConnection,
  reply_to: Subject(JoinResult),
) -> actor.Next(State, a) {
  process.demonitor_process(existing.monitor)
  let monitor = process.monitor(pid)
  let player = Player(..existing.player, connected: True)
  let connections =
    dict.insert(
      state.connections,
      player.id,
      PlayerConnection(subject:, player:, monitor:, pid:),
    )

  process.send(reply_to, JoinResult(token: player.id, is_leader: player.is_leader))
  announce(connections, state.current_round, subject, player)

  actor.continue(State(..state, connections:))
}

fn announce(
  connections: Dict(PlayerId, PlayerConnection),
  current_round: Option(RoundState),
  subject: Subject(PublishMessage),
  player: Player,
) -> Nil {
  let players = get_player_list(connections, current_round)
  publish(connections, PlayerListUpdated(players:))
  send_round_in_progress(subject, player, current_round)
}

fn send_round_in_progress(
  reply_to: Subject(PublishMessage),
  player: Player,
  current_round: Option(RoundState),
) -> Nil {
  case current_round {
    None -> Nil
    Some(round) -> process.send(reply_to, round_message_for(round, player.id))
  }
}

fn round_message_for(round: RoundState, player_id: PlayerId) -> PublishMessage {
  let is_imposter = round.imposter_id == player_id
  let is_first = round.first_player_id == player_id
  let word = case is_imposter {
    True -> round.similar_word
    False -> round.word
  }
  RoundStartedMsg(word:, is_imposter:, is_first:)
}

fn pick_one(from items: List(a), or default: a) -> a {
  case list.sample(items, up_to: 1) {
    [item] -> item
    _ -> default
  }
}

fn handle_unsubscribe(
  state: State,
  subject: Subject(PublishMessage),
) -> actor.Next(State, a) {
  case process.subject_owner(subject) {
    Ok(pid) -> mark_disconnected(state, pid)
    Error(_) -> actor.continue(state)
  }
}

fn handle_start_round(
  state: State,
  subject: Subject(PublishMessage),
) -> actor.Next(State, a) {
  let enough_players = connected_count(state.connections) >= 2
  case requesting_leader(state, subject), enough_players {
    Ok(_leader), True -> start_round(state)
    _, _ -> actor.continue(state)
  }
}

fn connected_count(connections: Dict(PlayerId, PlayerConnection)) -> Int {
  dict.values(connections)
  |> list.count(fn(c) { c.player.connected })
}

fn requesting_leader(
  state: State,
  subject: Subject(PublishMessage),
) -> Result(PlayerConnection, Nil) {
  use pid <- result.try(process.subject_owner(subject))
  use #(_token, conn) <- result.try(find_by_pid(state.connections, pid))
  case conn.player.is_leader {
    True -> Ok(conn)
    False -> Error(Nil)
  }
}

fn find_by_pid(
  connections: Dict(PlayerId, PlayerConnection),
  pid: process.Pid,
) -> Result(#(PlayerId, PlayerConnection), Nil) {
  dict.to_list(connections)
  |> list.find(fn(pair) { { pair.1 }.pid == pid })
}

fn start_round(state: State) -> actor.Next(State, a) {
  let connections =
    dict.filter(state.connections, fn(_, c) { c.player.connected })
  let round = build_round(connections)

  let players = get_player_list(connections, Some(round))
  publish(connections, PlayerListUpdated(players:))
  broadcast_round(connections, round)

  actor.continue(State(..state, connections:, current_round: Some(round)))
}

fn build_round(connections: Dict(PlayerId, PlayerConnection)) -> RoundState {
  let word_pair =
    pick_one(words.word_pairs, or: words.WordPair("default", "default"))
  let player_ids = player_ids(connections)

  RoundState(
    word: word_pair.word,
    similar_word: word_pair.similar,
    imposter_id: pick_one(player_ids, or: ""),
    first_player_id: pick_one(player_ids, or: ""),
  )
}

fn broadcast_round(
  connections: Dict(PlayerId, PlayerConnection),
  round: RoundState,
) -> Nil {
  dict.each(connections, fn(_, conn) {
    process.send(conn.subject, round_message_for(round, conn.player.id))
  })
}

fn player_ids(
  connections: Dict(PlayerId, PlayerConnection),
) -> List(PlayerId) {
  dict.values(connections)
  |> list.map(fn(c) { c.player.id })
}

fn handle_player_down(state: State, pid: process.Pid) -> actor.Next(State, a) {
  mark_disconnected(state, pid)
}

fn mark_disconnected(state: State, pid: process.Pid) -> actor.Next(State, a) {
  case find_by_pid(state.connections, pid) {
    Error(_) -> actor.continue(state)
    Ok(#(token, conn)) -> {
      process.demonitor_process(conn.monitor)
      let connections = disconnect_entry(state.connections, token, conn)

      case any_connected(connections) {
        False -> actor.stop()
        True -> handle_departure(state, connections, conn.player)
      }
    }
  }
}

fn disconnect_entry(
  connections: Dict(PlayerId, PlayerConnection),
  token: PlayerId,
  conn: PlayerConnection,
) -> Dict(PlayerId, PlayerConnection) {
  dict.insert(
    connections,
    token,
    PlayerConnection(..conn, player: Player(..conn.player, connected: False)),
  )
}

fn any_connected(connections: Dict(PlayerId, PlayerConnection)) -> Bool {
  dict.values(connections)
  |> list.any(fn(c) { c.player.connected })
}

fn has_connected_leader(connections: Dict(PlayerId, PlayerConnection)) -> Bool {
  dict.values(connections)
  |> list.any(fn(c) { c.player.connected && c.player.is_leader })
}

fn handle_departure(
  state: State,
  connections: Dict(PlayerId, PlayerConnection),
  leaver: Player,
) -> actor.Next(State, a) {
  let connections = promote_leader_if_needed(connections, leaver)

  let players = get_player_list(connections, state.current_round)
  publish(connections, PlayerListUpdated(players:))
  announce_leader_if_changed(connections, leaver)

  actor.continue(State(..state, connections:))
}

fn promote_leader_if_needed(
  connections: Dict(PlayerId, PlayerConnection),
  leaver: Player,
) -> Dict(PlayerId, PlayerConnection) {
  case leaver.is_leader {
    True -> reassign_leader(connections)
    False -> connections
  }
}

fn announce_leader_if_changed(
  connections: Dict(PlayerId, PlayerConnection),
  leaver: Player,
) -> Nil {
  case leaver.is_leader {
    False -> Nil
    True ->
      case list.find(dict.values(connections), fn(c) { c.player.is_leader }) {
        Ok(new_leader) ->
          publish(connections, LeaderChangedMsg(new_leader.player.id))
        Error(_) -> Nil
      }
  }
}

fn reassign_leader(
  connections: Dict(PlayerId, PlayerConnection),
) -> Dict(PlayerId, PlayerConnection) {
  let cleared =
    dict.map_values(connections, fn(_, conn) {
      PlayerConnection(..conn, player: Player(..conn.player, is_leader: False))
    })

  case first_connected_token(cleared) {
    Error(_) -> cleared
    Ok(token) ->
      dict.upsert(cleared, token, fn(entry) {
        let assert Some(conn) = entry
        PlayerConnection(..conn, player: Player(..conn.player, is_leader: True))
      })
  }
}

fn first_connected_token(
  connections: Dict(PlayerId, PlayerConnection),
) -> Result(PlayerId, Nil) {
  dict.to_list(connections)
  |> list.find(fn(pair) { { pair.1 }.player.connected })
  |> result.map(fn(pair) { pair.0 })
}

fn get_player_list(
  connections: Dict(PlayerId, PlayerConnection),
  current_round: Option(RoundState),
) -> List(Player) {
  dict.values(connections)
  |> list.map(fn(conn) {
    let is_first = case current_round {
      Some(round) -> round.first_player_id == conn.player.id
      None -> False
    }
    Player(..conn.player, is_first:)
  })
}

fn publish(
  connections: Dict(PlayerId, PlayerConnection),
  message: PublishMessage,
) -> Nil {
  connections |> dict.each(fn(_, conn) { process.send(conn.subject, message) })
}

pub fn subscribe(
  actor: Subject(Message),
  player: Player,
  token: Option(PlayerId),
  subject: Subject(PublishMessage),
) -> JoinResult {
  process.call(actor, 5000, fn(self) {
    Subscribe(player:, token:, reply_to: self, subject:)
  })
}

pub fn unsubscribe(
  actor: Subject(Message),
  subject: Subject(PublishMessage),
) -> Nil {
  process.send(actor, Unsubscribe(subject:))
}
