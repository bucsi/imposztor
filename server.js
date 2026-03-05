const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const path = require('path');
const fs = require('fs');

const app = express();
const server = http.createServer(app);
const io = new Server(server);

app.use(express.static(path.join(__dirname, 'public')));

const words = JSON.parse(fs.readFileSync(path.join(__dirname, 'data', 'words.json'), 'utf8'));

const players = new Map();
let currentRound = null;

function getPlayerList() {
  return Array.from(players.entries()).map(([id, player]) => ({
    id,
    name: player.name,
    isLeader: player.isLeader
  }));
}

function assignNewLeader() {
  if (players.size === 0) return;

  const firstPlayer = players.entries().next().value;
  if (firstPlayer) {
    const [id, player] = firstPlayer;
    player.isLeader = true;
    io.emit('leaderChanged', id);
  }
}

function hasLeader() {
  for (const player of players.values()) {
    if (player.isLeader) return true;
  }
  return false;
}

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
        isFirst
      });
    }

    console.log(`${name} joined. Players: ${players.size}`);
  });

  socket.on('startRound', () => {
    const player = players.get(socket.id);
    if (!player || !player.isLeader) return;

    if (players.size < 2) {
      socket.emit('error', 'Legalább 2 játékos kell a játékhoz!');
      return;
    }

    const wordPair = words[Math.floor(Math.random() * words.length)];
    const playerIds = Array.from(players.keys());
    const imposterId = playerIds[Math.floor(Math.random() * playerIds.length)];
    const firstPlayerId = playerIds[Math.floor(Math.random() * playerIds.length)];

    currentRound = {
      word: wordPair.word,
      similarWord: wordPair.similar,
      imposterId,
      firstPlayerId
    };

    for (const [id, p] of players.entries()) {
      const isImposter = id === imposterId;
      const isFirst = id === firstPlayerId;
      io.to(id).emit('roundStarted', {
        word: isImposter ? wordPair.similar : wordPair.word,
        isImposter,
        isFirst
      });
    }

    console.log(`Round started. Word: ${wordPair.word}, Imposztor: ${players.get(imposterId).name}`);
  });

  socket.on('disconnect', () => {
    const player = players.get(socket.id);
    if (player) {
      const wasLeader = player.isLeader;
      players.delete(socket.id);

      if (wasLeader && players.size > 0) {
        assignNewLeader();
      }

      io.emit('playerList', getPlayerList());
      console.log(`${player.name} left. Players: ${players.size}`);
    }
  });
});

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => {
  console.log(`Server running on http://localhost:${PORT}`);
});
