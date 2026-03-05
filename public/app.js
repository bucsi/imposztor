const socket = io({
  reconnection: true,
  reconnectionDelay: 1000,
  reconnectionDelayMax: 5000,
  reconnectionAttempts: Infinity,
});

const joinScreen = document.getElementById('joinScreen');
const lobbyScreen = document.getElementById('lobbyScreen');
const gameScreen = document.getElementById('gameScreen');
const nameInput = document.getElementById('nameInput');
const joinBtn = document.getElementById('joinBtn');
const playerList = document.getElementById('playerList');
const gamePlayerList = document.getElementById('gamePlayerList');
const startBtn = document.getElementById('startBtn');
const waitingText = document.getElementById('waitingText');
const wordDisplay = document.getElementById('wordDisplay');
const firstPlayerBadge = document.getElementById('firstPlayerBadge');
const nextRoundBtn = document.getElementById('nextRoundBtn');
const connectionStatus = document.getElementById('connectionStatus');
const statusText = connectionStatus.querySelector('.status-text');

console.log('gamePlayerList element:', gamePlayerList);

let isLeader = false;
let playerName = '';
let currentScreen = joinScreen;

const showScreen = (screen) => {
  joinScreen.classList.add('hidden');
  lobbyScreen.classList.add('hidden');
  gameScreen.classList.add('hidden');
  screen.classList.remove('hidden');
  currentScreen = screen;
};

const updatePlayerList = (players, listElement) => {
  if (!listElement) {
    console.log('updatePlayerList called with null element');
    return;
  }
  console.log('Updating player list:', players, 'element:', listElement.id);
  listElement.innerHTML = '';
  players.forEach((player) => {
    const li = document.createElement('li');
    li.textContent = player.name;
    if (player.isLeader) {
      li.classList.add('leader');
    }
    if (player.isFirst) {
      li.classList.add('first');
    }
    listElement.appendChild(li);
  });
  console.log('Player list updated, children:', listElement.children.length);
};

const updateLeaderUI = () => {
  if (isLeader) {
    startBtn.classList.remove('hidden');
    waitingText.classList.add('hidden');
    nextRoundBtn.classList.remove('hidden');
  } else {
    startBtn.classList.add('hidden');
    waitingText.classList.remove('hidden');
    nextRoundBtn.classList.add('hidden');
  }
};

joinBtn.addEventListener('click', () => {
  const name = nameInput.value.trim();
  if (name) {
    playerName = name;
    socket.emit('join', name);
  }
});

nameInput.addEventListener('keypress', (e) => {
  if (e.key === 'Enter') {
    joinBtn.click();
  }
});

startBtn.addEventListener('click', () => {
  socket.emit('startRound');
});

nextRoundBtn.addEventListener('click', () => {
  socket.emit('startRound');
});

socket.on('joined', (data) => {
  isLeader = data.isLeader;
  showScreen(lobbyScreen);
  updateLeaderUI();
});

socket.on('playerList', (players) => {
  updatePlayerList(players, playerList);
  updatePlayerList(players, gamePlayerList);
});

socket.on('leaderChanged', (newLeaderId) => {
  isLeader = socket.id === newLeaderId;
  updateLeaderUI();
});

socket.on('roundStarted', (data) => {
  showScreen(gameScreen);

  wordDisplay.className = data.isImposter ? 'imposter' : 'normal';

  if (data.isImposter) {
    wordDisplay.innerHTML = `
      <span class="label">Te vagy az IMPOSZTOR!</span>
      <span class="word">${data.word}</span>
    `;
  } else {
    wordDisplay.innerHTML = `
      <span class="label">A szó:</span>
      <span class="word">${data.word}</span>
    `;
  }

  if (data.isFirst) {
    firstPlayerBadge.classList.remove('hidden');
  } else {
    firstPlayerBadge.classList.add('hidden');
  }

  updateLeaderUI();
});

socket.on('error', (message) => {
  alert(message);
});

// Connection status handlers
socket.on('connect', () => {
  console.log('Connected to server');
  connectionStatus.classList.add('hidden');

  // Auto-rejoin if we were previously in the game
  if (playerName && currentScreen !== joinScreen) {
    console.log('Reconnecting as:', playerName);
    socket.emit('join', playerName);
  }
});

socket.on('disconnect', () => {
  console.log('Disconnected from server');
  statusText.textContent = 'Kapcsolat megszakadt - Újracsatlakozás...';
  connectionStatus.classList.remove('hidden');
});

socket.on('connect_error', () => {
  console.log('Connection error');
  statusText.textContent = 'Kapcsolódás...';
  connectionStatus.classList.remove('hidden');
});

socket.on('reconnect', (attemptNumber) => {
  console.log('Reconnected after', attemptNumber, 'attempts');
  statusText.textContent = 'Újracsatlakozva!';
  setTimeout(() => {
    connectionStatus.classList.add('hidden');
  }, 2000);
});

socket.on('reconnecting', (attemptNumber) => {
  console.log('Reconnecting attempt', attemptNumber);
  statusText.textContent = `Újracsatlakozás... (${attemptNumber})`;
  connectionStatus.classList.remove('hidden');
});
