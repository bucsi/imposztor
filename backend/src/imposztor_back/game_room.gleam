import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
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
    Ok(pid) ->
      case dict.get(state.connections, pid) {
        Ok(_) -> actor.continue(state)
        Error(_) -> {
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

          // If there's a current round, send it to the new player
          case state.current_round {
            Some(round) -> {
              let is_imposter = round.imposter_id == player.id
              let is_first = round.first_player_id == player.id
              let word = case is_imposter {
                True -> round.similar_word
                False -> round.word
              }
              process.send(
                reply_to,
                RoundStartedMsg(word:, is_imposter:, is_first:),
              )
            }
            None -> Nil
          }

          actor.continue(State(..state, connections:))
        }
      }
    Error(_) -> actor.continue(state)
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
  case process.subject_owner(subject) {
    Ok(pid) ->
      case dict.get(state.connections, pid) {
        Ok(conn) -> {
          // Check if player is leader
          let player_count = dict.size(state.connections)
          case conn.player.is_leader, player_count >= 2 {
            True, True -> {
              // Pick random word pair
              let word_pair_result = list.sample(words.word_pairs, up_to: 1)
              let word_pair = case word_pair_result {
                [wp] -> wp
                _ -> words.WordPair("default", "default")
              }

              // Pick random imposter and first player
              let player_ids =
                dict.values(state.connections)
                |> list.map(fn(c) { c.player.id })

              let imposter_result = list.sample(player_ids, up_to: 1)
              let imposter_id = case imposter_result {
                [id] -> id
                _ -> ""
              }

              let first_player_result = list.sample(player_ids, up_to: 1)
              let first_player_id = case first_player_result {
                [id] -> id
                _ -> ""
              }

              let round =
                RoundState(
                  word: word_pair.word,
                  similar_word: word_pair.similar,
                  imposter_id:,
                  first_player_id:,
                )

              // Update player list with first player indicator
              let players = get_player_list(state.connections, Some(round))
              publish(state.connections, PlayerListUpdated(players:))

              // Send round started messages
              let _ =
                dict.each(state.connections, fn(_, conn) {
                  let is_imposter = conn.player.id == imposter_id
                  let is_first = conn.player.id == first_player_id
                  let word = case is_imposter {
                    True -> word_pair.similar
                    False -> word_pair.word
                  }
                  process.send(
                    conn.subject,
                    RoundStartedMsg(word:, is_imposter:, is_first:),
                  )
                })

              actor.continue(State(..state, current_round: Some(round)))
            }
            False, True -> {
              // Player is not leader, ignore
              actor.continue(state)
            }
            _, False -> {
              // Not enough players
              actor.continue(state)
            }
          }
        }
        Error(_) -> actor.continue(state)
      }
    Error(_) -> actor.continue(state)
  }
}

fn handle_player_down(state: State, pid: process.Pid) -> actor.Next(State, a) {
  remove_player(state, pid)
}

fn remove_player(state: State, pid: process.Pid) -> actor.Next(State, a) {
  case dict.get(state.connections, pid) {
    Ok(PlayerConnection(monitor:, player:, ..)) -> {
      let connections = dict.delete(state.connections, pid)
      process.demonitor_process(monitor)

      case dict.size(connections) {
        0 -> actor.stop()
        _ -> {
          let was_leader = player.is_leader

          // Update current round if needed
          let new_round = case state.current_round {
            Some(round) -> {
              let player_ids =
                dict.values(connections)
                |> list.map(fn(c) { c.player.id })

              let new_round_opt = case list.is_empty(player_ids) {
                True -> None
                False -> {
                  let new_imposter = case round.imposter_id == player.id {
                    True -> {
                      let result = list.sample(player_ids, up_to: 1)
                      case result {
                        [new_id] -> new_id
                        _ -> round.imposter_id
                      }
                    }
                    False -> round.imposter_id
                  }

                  let new_first = case round.first_player_id == player.id {
                    True -> {
                      let result = list.sample(player_ids, up_to: 1)
                      case result {
                        [new_id] -> new_id
                        _ -> round.first_player_id
                      }
                    }
                    False -> round.first_player_id
                  }

                  Some(
                    RoundState(
                      ..round,
                      imposter_id: new_imposter,
                      first_player_id: new_first,
                    ),
                  )
                }
              }
              new_round_opt
            }
            None -> None
          }

          // Reassign leader if needed
          let connections = case was_leader {
            True -> reassign_leader(connections)
            False -> connections
          }

          // Notify all players
          let players = get_player_list(connections, new_round)
          publish(connections, PlayerListUpdated(players:))

          // If round changed, notify players
          let _ = case new_round, state.current_round {
            Some(new_r), Some(old_r)
              if new_r.imposter_id != old_r.imposter_id
              || new_r.first_player_id != old_r.first_player_id
            -> {
              dict.each(connections, fn(_, conn) {
                let is_imposter = conn.player.id == new_r.imposter_id
                let is_first = conn.player.id == new_r.first_player_id
                let word = case is_imposter {
                  True -> new_r.similar_word
                  False -> new_r.word
                }
                process.send(
                  conn.subject,
                  RoundStartedMsg(word:, is_imposter:, is_first:),
                )
              })
            }
            _, _ -> Nil
          }

          // Notify of leader change if needed
          case was_leader {
            True -> {
              let assert Ok(new_leader) =
                dict.values(connections)
                |> list.find(fn(c) { c.player.is_leader })
              publish(connections, LeaderChangedMsg(new_leader.player.id))
            }
            False -> Nil
          }

          actor.continue(State(..state, connections:, current_round: new_round))
        }
      }
    }
    Error(_) -> actor.continue(state)
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
