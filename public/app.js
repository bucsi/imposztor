const socket = io();

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

console.log('gamePlayerList element:', gamePlayerList);

let isLeader = false;

const showScreen = (screen) => {
  joinScreen.classList.add('hidden');
  lobbyScreen.classList.add('hidden');
  gameScreen.classList.add('hidden');
  screen.classList.remove('hidden');
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
