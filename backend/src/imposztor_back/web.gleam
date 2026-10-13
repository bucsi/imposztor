import gleam/erlang/process
import gleam/http/request
import gleam/otp/actor
import gleam/result
import gleam/string
import imposztor_back/game_room
import imposztor_back/ws
import mist
import wisp
import wisp/wisp_mist

pub fn init(
  game_room_subject: process.Subject(game_room.Message),
  port: Int,
  secret_key_base: String,
) {
  let assert Ok(priv) = wisp.priv_directory("imposztor_back")

  let wisp_side = wisp_mist.handler(handle_request(_, priv), secret_key_base)

  fn(req) {
    case request.path_segments(req) {
      ["ws"] ->
        mist.websocket(
          request: req,
          on_init: ws.on_init(_, game_room_subject),
          on_close: ws.on_close,
          handler: ws.handle_message,
        )
      _ -> wisp_side(req)
    }
  }
  |> mist.new()
  |> mist.port(port)
  |> mist.start()
  |> result.map_error(fn(glisten_error) {
    actor.InitFailed(string.inspect(glisten_error))
  })
}

fn handle_request(req: wisp.Request, priv: String) -> wisp.Response {
  use <- wisp.serve_static(req, under: "/", from: priv <> "/static")

  case wisp.path_segments(req) {
    [] -> wisp.redirect("/index.html")
    _ -> wisp.not_found()
  }
}
