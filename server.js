import express from 'express';
import { createServer } from 'http';
import { Server } from 'socket.io';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { readFile } from 'fs/promises';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const app = express();
const server = createServer(app);
const io = new Server(server);

app.use(express.static(join(__dirname, 'public')));

const words = JSON.parse(
  await readFile(join(__dirname, 'data', 'words.json'), 'utf8')
);

const players = new Map();
let currentRound = null;

const getPlayerList = () =>
  Array.from(players.entries(), ([id, player]) => ({
    id,
    name: player.name,
    isLeader: player.isLeader,
    isFirst: currentRound?.firstPlayerId === id,
  }));

const assignNewLeader = () => {
  if (players.size === 0) return;

  // Clear all existing leader flags
  for (const player of players.values()) {
    player.isLeader = false;
  }

  // Assign first player as leader
  const firstPlayer = players.entries().next().value;
  if (!firstPlayer) return;

  const [id, player] = firstPlayer;
  player.isLeader = true;

  io.emit('leaderChanged', id);
  io.emit('playerList', getPlayerList());
};

const hasLeader = () => Array.from(players.values()).some((p) => p.isLeader);

const pickRandom = (array) => array[Math.floor(Math.random() * array.length)];

io.on('connection', (socket) => {
  console.log('User connected:', socket.id);

  socket.on('join', (name) => {
    const isLeader = players.size === 0;
    players.set(socket.id, { name, isLeader });

    io.emit('playerList', getPlayerList());
    socket.emit('joined', { isLeader });

    if (currentRound) {
      const isImposter = currentRound.imposterId === socket.id;
      const isFirst = currentRound.firstPlayerId === socket.id;
      socket.emit('roundStarted', {
        word: isImposter ? currentRound.similarWord : currentRound.word,
        isImposter,
        isFirst,
      });
    }

    console.log(`${name} joined. Players: ${players.size}`);
  });

  socket.on('startRound', () => {
    const player = players.get(socket.id);
    console.log(`startRound called by ${socket.id}, player:`, player);

    if (!player?.isLeader) {
      console.log(`Player is not leader. isLeader: ${player?.isLeader}`);
      return;
    }

    if (players.size < 2) {
      socket.emit('error', 'Legalább 2 játékos kell a játékhoz!');
      return;
    }

    const wordPair = pickRandom(words);
    const playerIds = [...players.keys()];
    const imposterId = pickRandom(playerIds);
    const firstPlayerId = pickRandom(playerIds);

    currentRound = {
      word: wordPair.word,
      similarWord: wordPair.similar,
      imposterId,
      firstPlayerId,
    };

    for (const [id] of players.entries()) {
      const isImposter = id === imposterId;
      const isFirst = id === firstPlayerId;
      io.to(id).emit('roundStarted', {
        word: isImposter ? wordPair.similar : wordPair.word,
        isImposter,
        isFirst,
      });
    }

    console.log(
      `Round started. Word: ${wordPair.word}, Imposztor: ${players.get(imposterId).name}`
    );
  });

  socket.on('disconnect', () => {
    const player = players.get(socket.id);
    if (!player) return;

    const wasLeader = player.isLeader;
    players.delete(socket.id);

    // If a round is active and the disconnected player was involved
    if (currentRound) {
      const wasImposter = currentRound.imposterId === socket.id;
      const wasFirstPlayer = currentRound.firstPlayerId === socket.id;

      if (wasImposter || wasFirstPlayer) {
        // Reassign roles if the disconnected player had a special role
        const remainingPlayerIds = [...players.keys()];

        if (remainingPlayerIds.length > 0) {
          if (wasImposter) {
            currentRound.imposterId = pickRandom(remainingPlayerIds);
          }
          if (wasFirstPlayer) {
            currentRound.firstPlayerId = pickRandom(remainingPlayerIds);
          }

          // Notify all players of the updated round state
          for (const [id] of players.entries()) {
            const isImposter = id === currentRound.imposterId;
            const isFirst = id === currentRound.firstPlayerId;
            io.to(id).emit('roundStarted', {
              word: isImposter ? currentRound.similarWord : currentRound.word,
              isImposter,
              isFirst,
            });
          }

          console.log(`Reassigned roles after ${player.name} left`);
        }
      }
    }

    if (wasLeader && players.size > 0) {
      assignNewLeader();
    }

    io.emit('playerList', getPlayerList());
    console.log(`${player.name} left. Players: ${players.size}`);
  });
});

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => {
  console.log(`Server running on http://localhost:${PORT}`);
});
