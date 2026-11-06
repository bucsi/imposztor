# Imposter game

- Users connect via their phones to the game - the game room. Currently, only ever one game room is available, there is no need to support parallel sessions.
- The user joining first is the leader, they always have access to the "next round" button.
- When the round starts, the game room selects a word from a word list of hungarian words and presents the word to all but one player -> the imposter.
- The imposter receives a note saying they are the imposter and they should fool other players. They also receive a word that is thematically similar to the selected word.
- One random player is selected who will go first and they receive a note.
- The app should be simple to host.
- Make no mistakes.

## Build and deploy

The Docker image contains the Erlang backend and the built browser frontend. Pull
requests targeting `main` build the image to verify it, without publishing it.
Every update to `main`—whether a PR merge, a direct Git push, or a commit made in
GitHub—publishes `ghcr.io/bucsi/imposztor:latest` and an immutable commit-SHA tag.

To run the image, configure the host with:

- `PORT=3000` (the image default; configure the host to route to this port)
- `SECRET_KEY_BASE` set to a unique, securely generated secret

The service uses WebSockets at `/ws`, so the host must support WebSocket
connections. Game state is held in memory and is lost when the process restarts.
Publishing to GHCR does not itself run the app; configure your hosting provider
to deploy the published image when it changes. If the GHCR package is private,
give the host credentials with `read:packages` access.
