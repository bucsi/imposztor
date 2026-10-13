import dot_env
import dot_env/env
import gleam/erlang/process
import gleam/int
import gleam/otp/actor
import imposztor_back/game_room
import imposztor_back/web
import logging

pub fn main() {
  logging.configure()
  logging.set_level(logging.Info)

  dot_env.new_with_path("./.env")
  |> dot_env.set_ignore_missing_file(True)
  |> dot_env.load()

  let assert Ok(port) = env.get_int("PORT")
  let assert Ok(secret_key_base) = env.get_string("SECRET_KEY_BASE")

  // Start the main game room
  let assert Ok(actor.Started(_name, game_room_subject)) =
    game_room.start("main")

  let assert Ok(_) = web.init(game_room_subject, port, secret_key_base)

  logging.log(
    logging.Info,
    "Server running on http://localhost:" <> int.to_string(port),
  )

  process.sleep_forever()
}
