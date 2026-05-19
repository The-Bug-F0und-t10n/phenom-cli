import readline from 'node:readline';
import os from 'node:os';

const WIDTH  = 60;
const HEIGHT = 22;

// ── Mood state ────────────────────────────────────────────────────────────────
// Transição suave: targetMood acumula ticks antes de virar currentMood
let currentMood   = "idle";
let targetMood    = "idle";
let moodCountdown = 0;
const MOOD_DELAY  = 8;   // ticks para a transição (~800 ms)

// Escudo de usuário: impede sistema de sobrescrever humores interativos
let userShield           = 0;
const SHIELD_DURATION    = 50; // ~5 s

let tick        = 0;
let lastMessage = "";

// ── Buffer ────────────────────────────────────────────────────────────────────

function createBuffer() {
  return Array.from({ length: HEIGHT }, () => Array(WIDTH).fill(" "));
}

// FIX: guarda explicitamente os 4 limites antes de escrever
function draw(buf, x, y, ch) {
  if (y >= 0 && y < HEIGHT && x >= 0 && x < WIDTH) buf[y][x] = ch;
}

function drawText(buf, x, y, text) {
  for (let i = 0; i < text.length; i++) draw(buf, x + i, y, text[i]);
}

// ── Máquina de humor suave ────────────────────────────────────────────────────

function requestMood(newMood) {
  if (newMood === targetMood) return;   // já encaminhado
  targetMood    = newMood;
  moodCountdown = MOOD_DELAY;
}

function tickMood() {
  if (currentMood !== targetMood) {
    moodCountdown--;
    if (moodCountdown <= 0) {
      currentMood   = targetMood;
      moodCountdown = 0;
    }
  }
}

// ── Partes do avatar ──────────────────────────────────────────────────────────

// Olhos: piscam periodicamente em dois momentos distintos
function getEyeChar() {
  const t = tick % 70;
  return (t >= 66 || (t >= 33 && t <= 34)) ? "-" : "o";
}

// Sobrancelhas reativas ao humor — 11 chars exatos
function getEyebrows() {
  switch (currentMood) {
    case "happy":    return "~~~     ~~~";
    case "thinking": return "/--     --/";
    case "alert":    return "/^-     -^/";
    case "sad":      return "\\--     --/"; // eslint-disable-line no-useless-escape
    default:         return "---     ---";
  }
}

// Boca animada — 5 chars exatos, fase alterna a cada 10 ticks
function getMouth() {
  const ph = (tick % 20) < 10;
  switch (currentMood) {
    case "happy":    return ph ? "\\___/" : "\\_-_/";
    case "thinking": return ph ? ". . ." : " ... ";
    case "alert":    return ph ? ">!!!<" : ">! !<";
    case "sad":      return ph ? "/---\\" : "/___\\";
    default:         return ph ? "-----" : "-- --";
  }
}

// ── Desenha avatar ────────────────────────────────────────────────────────────
//
//  Rosto: 20 chars (cx-10 .. cx+9), 10 linhas (cy-5 .. cy+4)
//  Interior: 18 chars (cx-9 .. cx+8), centro em cx
//
//  cy-5  .-------------------.    <- cabeça topo
//  cy-4  |                   |
//  cy-3  |   ~~~     ~~~     |    <- sobrancelhas @ cx-5 (11 chars)
//  cy-2  |   .====|====.     |    <- óculos topo  @ cx-5 (11 chars)
//  cy-1  |   | o  |  o |     |    <- olhos        @ cx-5
//  cy    |   '====|===='     |    <- óculos base  @ cx-5
//  cy+1  |                   |
//  cy+2  |      \___/        |    <- boca         @ cx-2 (5 chars)
//  cy+3  |                   |
//  cy+4  '-------------------'    <- cabeça base
//
//  Oculus: divisória central no cx; olhos em cx-3 e cx+3 (simétrico)

function drawAvatar(buf) {
  const cx = Math.floor(WIDTH  / 2); // 30
  const cy = Math.floor(HEIGHT / 2); // 11

  // Contorno da cabeça (20 chars)
  drawText(buf, cx - 10, cy - 5, ".------------------.");
  for (let dy = -4; dy <= 3; dy++) {
    drawText(buf, cx - 10, cy + dy, "|                  |");
  }
  drawText(buf, cx - 10, cy + 4, "'------------------'");

  // Sobrancelhas (11 chars, âncora cx-5 → divisória cai em cx)
  drawText(buf, cx - 5, cy - 3, getEyebrows());

  // Óculos Oculus (11 chars, âncora cx-5)
  //   .====|====.   posição da divisória: cx-5+5 = cx ✓
  //   | o  |  o |   olho esquerdo: cx-3, direito: cx+3 ✓
  //   '====|===='
  const e = getEyeChar();
  drawText(buf, cx - 5, cy - 2, ".====|====.");
  drawText(buf, cx - 5, cy - 1, `| ${e}  |  ${e} |`);
  drawText(buf, cx - 5, cy,     "'====|===='");

  // Boca (5 chars, centrada em cx → âncora cx-2)
  drawText(buf, cx - 2, cy + 2, getMouth());
}

// ── Partículas ────────────────────────────────────────────────────────────────
// FIX: evitam a área do rosto para não poluir o avatar

const SPARKS = [".", "·", "+", "°", "*"];

function drawParticles(buf) {
  const cx = Math.floor(WIDTH  / 2);
  const cy = Math.floor(HEIGHT / 2);
  // Bounding box do rosto com margem de 1
  const fx1 = cx - 11, fx2 = cx + 10;
  const fy1 = cy - 6,  fy2 = cy + 5;

  for (let i = 0; i < 8; i++) {
    if (Math.random() < 0.25) {
      const x = Math.floor(Math.random() * WIDTH);
      const y = Math.floor(Math.random() * HEIGHT);
      if (x < fx1 || x > fx2 || y < fy1 || y > fy2) {
        draw(buf, x, y, SPARKS[Math.floor(Math.random() * SPARKS.length)]);
      }
    }
  }
}

// ── Monitor de sistema ────────────────────────────────────────────────────────

function checkSystem() {
  if (userShield > 0) {          // usuário está no controle
    userShield--;
    return;
  }
  const load = os.loadavg()[0];
  if      (load > 2) requestMood("alert");
  else if (load > 1) requestMood("thinking");
  else               requestMood("idle");
}

// ── API pública (retrocompatibilidade) ────────────────────────────────────────

const AvatarAPI = {
  setMood(newMood) { requestMood(newMood); userShield = SHIELD_DURATION; },
  speak(msg)       { lastMessage = msg; },
};

// ── Render ────────────────────────────────────────────────────────────────────
// FIX: cursor home (\x1b[H) em vez de console.clear() → sem flickering

const COLORS = {
  idle:     "\x1b[36m",   // ciano
  happy:    "\x1b[32m",   // verde
  thinking: "\x1b[35m",   // magenta
  alert:    "\x1b[31m",   // vermelho
  sad:      "\x1b[34m",   // azul
};

function render(buf) {
  process.stdout.write("\x1b[H");                            // cursor ao topo
  process.stdout.write(COLORS[currentMood] ?? "\x1b[36m");
  process.stdout.write(buf.map(r => r.join("")).join("\n") + "\n");
  process.stdout.write("\x1b[0m");

  // Linha de status: exibe transição em andamento
  const moodLabel = currentMood !== targetMood
    ? `${currentMood} \x1b[33m→ ${targetMood}\x1b[0m`
    : currentMood;
  process.stdout.write(`\nMood: ${moodLabel}            \n`);
  process.stdout.write(lastMessage
    ? `AI: ${lastMessage}            \n`
    : "                              \n");
  process.stdout.write("> ");
}

// ── Loop principal ────────────────────────────────────────────────────────────

process.stdout.write("\x1b[2J\x1b[H"); // limpa apenas na inicialização

setInterval(() => {
  tick++;
  tickMood();
  checkSystem();
  const buf = createBuffer();
  drawParticles(buf);
  drawAvatar(buf);
  render(buf);
}, 100);

// ── Input interativo ──────────────────────────────────────────────────────────

const TRIGGERS = [
  { keywords: ["oi", "olá", "ola", "hello", "hi"],       mood: "happy",    msg: "Oi! Como vai?" },
  { keywords: ["trabalhar", "processar", "pensar"],       mood: "thinking", msg: "Ok, estou processando..." },
  { keywords: ["erro", "falha", "perigo", "alerta"],      mood: "alert",    msg: "Ops! Algo deu errado!" },
  { keywords: ["triste", "tchau", "bye", "sad"],          mood: "sad",      msg: "Tudo bem, vai melhorar." },
];

const rl = readline.createInterface({ input: process.stdin, output: process.stdout });

rl.on("line", line => {
  const input   = line.toLowerCase().trim();
  let   matched = false;

  for (const { keywords, mood, msg } of TRIGGERS) {
    if (keywords.some(k => input.includes(k))) {
      AvatarAPI.setMood(mood);
      AvatarAPI.speak(msg);
      matched = true;
      break;
    }
  }

  if (!matched) {
    requestMood("idle");
    lastMessage = "";
    userShield  = 0; // devolve controle ao sistema
  }
});
