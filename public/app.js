const socket = io();

const joinScreen = document.getElementById('joinScreen');
const lobbyScreen = document.getElementById('lobbyScreen');
const gameScreen = document.getElementById('gameScreen');
const nameInput = document.getElementById('nameInput');
const joinBtn = document.getElementById('joinBtn');
const playerList = document.getElementById('playerList');
const startBtn = document.getElementById('startBtn');
const waitingText = document.getElementById('waitingText');
const wordDisplay = document.getElementById('wordDisplay');
const firstPlayerBadge = document.getElementById('firstPlayerBadge');
const nextRoundBtn = document.getElementById('nextRoundBtn');

let isLeader = false;

function showScreen(screen) {
  joinScreen.classList.add('hidden');
  lobbyScreen.classList.add('hidden');
  gameScreen.classList.add('hidden');
  screen.classList.remove('hidden');
}

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
  playerList.innerHTML = '';
  players.forEach((player) => {
    const li = document.createElement('li');
    li.textContent = player.name;
    if (player.isLeader) {
      li.classList.add('leader');
    }
    playerList.appendChild(li);
  });
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

  if (isLeader) {
    nextRoundBtn.classList.remove('hidden');
  } else {
    nextRoundBtn.classList.add('hidden');
  }
});

socket.on('error', (message) => {
  alert(message);
});

function updateLeaderUI() {
  if (isLeader) {
    startBtn.classList.remove('hidden');
    waitingText.classList.add('hidden');
  } else {
    startBtn.classList.add('hidden');
    waitingText.classList.remove('hidden');
  }
}
