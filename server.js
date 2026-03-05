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
  }));

const assignNewLeader = () => {
  if (players.size === 0) return;

  const firstPlayer = players.entries().next().value;
  if (!firstPlayer) return;

  const [id, player] = firstPlayer;
  player.isLeader = true;
  io.emit('leaderChanged', id);
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
    if (!player?.isLeader) return;

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
