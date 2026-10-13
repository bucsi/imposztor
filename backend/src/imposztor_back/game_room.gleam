import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import imposztor_common/player.{type Player, type PlayerId, Player}
import imposztor_common/words

pub type GameRoomId =
  String

pub type PlayerConnection {
  PlayerConnection(
    subject: Subject(PublishMessage),
    player: Player,
    monitor: process.Monitor,
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
    connections: Dict(process.Pid, PlayerConnection),
    current_round: Option(RoundState),
  )
}

pub type PublishMessage {
  PlayerListUpdated(players: List(Player))
  LeaderChangedMsg(leader_id: PlayerId)
  RoundStartedMsg(word: String, is_imposter: Bool, is_first: Bool)
}

pub type Message {
  Subscribe(
    player: Player,
    reply_to: Subject(PublishMessage),
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
    Subscribe(player:, reply_to:, subject:) ->
      handle_subscribe(state, subject, player, reply_to)
    Unsubscribe(subject:) -> handle_unsubscribe(state, subject)
    StartRound(subject:) -> handle_start_round(state, subject)
    PlayerProcessDown(pid:) -> handle_player_down(state, pid)
    Noop -> actor.continue(state)
  }
}

fn handle_subscribe(
  state: State,
  subject: Subject(PublishMessage),
  player: Player,
  reply_to: Subject(PublishMessage),
) -> actor.Next(State, a) {
  let pid = process.subject_owner(subject)

  case pid {
    Error(_) -> actor.continue(state)
    Ok(pid) ->
      case dict.get(state.connections, pid) {
        Ok(_) -> actor.continue(state)
        Error(_) -> new_player(pid, state, subject, player, reply_to)
      }
  }
}

fn new_player(
  pid: process.Pid,
  state: State,
  subject: process.Subject(PublishMessage),
  player: Player,
  reply_to: Subject(PublishMessage),
) -> actor.Next(State, a) {
  let monitor = process.monitor(pid)
  let connections =
    dict.insert(
      state.connections,
      pid,
      PlayerConnection(subject:, player:, monitor:),
    )

  let players = get_player_list(connections, state.current_round)
  publish(connections, PlayerListUpdated(players:))
  process.send(reply_to, PlayerListUpdated(players:))
  send_round_in_progress(reply_to, player, state.current_round)

  actor.continue(State(..state, connections:))
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
    Ok(pid) -> remove_player(state, pid)
    Error(_) -> actor.continue(state)
  }
}

fn handle_start_round(
  state: State,
  subject: Subject(PublishMessage),
) -> actor.Next(State, a) {
  let enough_players = dict.size(state.connections) >= 2
  case requesting_leader(state, subject), enough_players {
    Ok(_leader), True -> start_round(state)
    _, _ -> actor.continue(state)
  }
}

fn requesting_leader(
  state: State,
  subject: Subject(PublishMessage),
) -> Result(PlayerConnection, Nil) {
  use pid <- result.try(process.subject_owner(subject))
  use conn <- result.try(dict.get(state.connections, pid))
  case conn.player.is_leader {
    True -> Ok(conn)
    False -> Error(Nil)
  }
}

fn start_round(state: State) -> actor.Next(State, a) {
  let round = build_round(state.connections)

  let players = get_player_list(state.connections, Some(round))
  publish(state.connections, PlayerListUpdated(players:))
  broadcast_round(state.connections, round)

  actor.continue(State(..state, current_round: Some(round)))
}

fn build_round(connections: Dict(process.Pid, PlayerConnection)) -> RoundState {
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
  connections: Dict(process.Pid, PlayerConnection),
  round: RoundState,
) -> Nil {
  dict.each(connections, fn(_, conn) {
    process.send(conn.subject, round_message_for(round, conn.player.id))
  })
}

fn player_ids(
  connections: Dict(process.Pid, PlayerConnection),
) -> List(PlayerId) {
  dict.values(connections)
  |> list.map(fn(c) { c.player.id })
}

fn handle_player_down(state: State, pid: process.Pid) -> actor.Next(State, a) {
  remove_player(state, pid)
}

fn remove_player(state: State, pid: process.Pid) -> actor.Next(State, a) {
  case dict.get(state.connections, pid) {
    Error(_) -> actor.continue(state)
    Ok(PlayerConnection(monitor:, player:, ..)) -> {
      process.demonitor_process(monitor)
      let connections = dict.delete(state.connections, pid)

      case dict.is_empty(connections) {
        True -> actor.stop()
        False -> handle_departure(state, connections, player)
      }
    }
  }
}

fn handle_departure(
  state: State,
  connections: Dict(process.Pid, PlayerConnection),
  leaver: Player,
) -> actor.Next(State, a) {
  let new_round = recompute_round(state.current_round, leaver.id, connections)
  let connections = promote_leader_if_needed(connections, leaver)

  let players = get_player_list(connections, new_round)
  publish(connections, PlayerListUpdated(players:))
  rebroadcast_if_roles_changed(connections, state.current_round, new_round)
  announce_leader_if_changed(connections, leaver)

  actor.continue(State(..state, connections:, current_round: new_round))
}

fn recompute_round(
  current_round: Option(RoundState),
  leaver_id: PlayerId,
  connections: Dict(process.Pid, PlayerConnection),
) -> Option(RoundState) {
  use round <- option.then(current_round)
  let candidates = player_ids(connections)
  Some(
    RoundState(
      ..round,
      imposter_id: replace_if_leaving(round.imposter_id, leaver_id, candidates),
      first_player_id: replace_if_leaving(
        round.first_player_id,
        leaver_id,
        candidates,
      ),
    ),
  )
}

fn replace_if_leaving(
  current_id: PlayerId,
  leaver_id: PlayerId,
  candidates: List(PlayerId),
) -> PlayerId {
  case current_id == leaver_id {
    True -> pick_one(candidates, or: current_id)
    False -> current_id
  }
}

fn promote_leader_if_needed(
  connections: Dict(process.Pid, PlayerConnection),
  leaver: Player,
) -> Dict(process.Pid, PlayerConnection) {
  case leaver.is_leader {
    True -> reassign_leader(connections)
    False -> connections
  }
}

fn rebroadcast_if_roles_changed(
  connections: Dict(process.Pid, PlayerConnection),
  old_round: Option(RoundState),
  new_round: Option(RoundState),
) -> Nil {
  case new_round, old_round {
    Some(new_r), Some(old_r) ->
      case roles_changed(old_r, new_r) {
        True -> broadcast_round(connections, new_r)
        False -> Nil
      }
    _, _ -> Nil
  }
}

fn roles_changed(old_round: RoundState, new_round: RoundState) -> Bool {
  old_round.imposter_id != new_round.imposter_id
  || old_round.first_player_id != new_round.first_player_id
}

fn announce_leader_if_changed(
  connections: Dict(process.Pid, PlayerConnection),
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
  connections: Dict(process.Pid, PlayerConnection),
) -> Dict(process.Pid, PlayerConnection) {
  case dict.to_list(connections) {
    [] -> connections
    [#(pid, first_conn), ..rest] -> {
      let updated_first =
        PlayerConnection(
          ..first_conn,
          player: Player(..first_conn.player, is_leader: True),
        )

      let updated_rest =
        list.map(rest, fn(pair) {
          let #(p, conn) = pair
          #(
            p,
            PlayerConnection(
              ..conn,
              player: Player(..conn.player, is_leader: False),
            ),
          )
        })

      dict.from_list([#(pid, updated_first), ..updated_rest])
    }
  }
}

fn get_player_list(
  connections: Dict(process.Pid, PlayerConnection),
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
  connections: Dict(process.Pid, PlayerConnection),
  message: PublishMessage,
) -> Nil {
  connections |> dict.each(fn(_, conn) { process.send(conn.subject, message) })
}

pub fn subscribe(
  actor: Subject(Message),
  player: Player,
  subject: Subject(PublishMessage),
) -> PublishMessage {
  process.call(actor, 5000, fn(self) {
    Subscribe(player:, reply_to: self, subject:)
  })
}

pub fn unsubscribe(
  actor: Subject(Message),
  subject: Subject(PublishMessage),
) -> Nil {
  process.send(actor, Unsubscribe(subject:))
}
