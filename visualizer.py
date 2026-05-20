#!/usr/bin/env python3

import math
import random
import shutil
import signal
import sys
import time


# ============================================================
# CONFIG
# ============================================================

FPS        = 30
FRAME_TIME = 1.0 / FPS

BLOCKS     = " ▁▂▃▄▅▆▇█"

# cascata esquerda → direita
CASCADE    = 1.2    # segundos para a frente percorrer a tela inteira
EASE       = 0.65   # segundos para cada coluna completar sua transição individual

# normalização do ruído
NOISE_NORM = 0.8110


# ============================================================
# ESTADOS
# ============================================================

STATES = {
    "idle": {
        "label":      "em silêncio",
        "energy":     0.00,
        "density":    0.0,
        "chaos":      0.00,
        "spd_factor": 0.0,
    },
    "listening": {
        "label":      "ouvindo você",
        "energy":     0.22,
        "density":    1.6,
        "chaos":      0.00,
        "spd_factor": 10.0,
    },
    "thinking": {
        "label":      "pensando",
        "energy":     0.52,
        "density":    2.6,
        "chaos":      0.03,
        "spd_factor": 8.0,
    },
    "confused": {
        "label":      "com dúvidas",
        "energy":     0.78,
        "density":    3.4,
        "chaos":      0.18,
        "spd_factor": 11.0,
    },
    "solving": {
        "label":      "resolvendo",
        "energy":     0.63,
        "density":    3.0,
        "chaos":      0.04,
        "spd_factor": 9.0,
    },
    "responding": {
        "label":      "respondendo",
        "energy":     0.90,
        "density":    4.2,
        "chaos":      0.02,
        "spd_factor": 10.0,
    },
}

ANIM_KEYS = ("energy", "density", "chaos", "spd_factor")


# ============================================================
# SEQUÊNCIA DE DEMONSTRAÇÃO
# ============================================================

CHAIN = [
    ("idle",       5),
    ("listening",  6),
    ("thinking",  10),
    ("confused",   5),
    ("thinking",   7),
    ("solving",    9),
    ("responding", 6),
    ("idle",       4),
]


# ============================================================
# ESTADO GLOBAL DA ANIMAÇÃO
# ============================================================

t_anim           = 0.0       # tempo acumulado para o ruído
chain_index      = 0
current_name     = "idle"
target_name      = "idle"
transitioning    = False
t_elapsed        = 0.0       # segundos desde o begin_transition atual
state_clock      = time.monotonic()

# snap[i][key]  = valor de cada coluna no momento do disparo da transição
# target_vals[key] = destino da transição atual
snap             = []
target_vals      = {k: STATES["idle"][k] for k in ANIM_KEYS}
_buf_size        = 0


# ============================================================
# TERMINAL
# ============================================================

def cleanup(sig=None, frame=None):
    sys.stdout.write("\033[?25h\033[0m\n")
    sys.stdout.flush()
    sys.exit(0)

signal.signal(signal.SIGINT,  cleanup)
signal.signal(signal.SIGTERM, cleanup)

sys.stdout.write("\033[?25l")
sys.stdout.flush()


# ============================================================
# EASING
# Cúbico ease-in-out: começa devagar, acelera no meio, desacelera no fim.
# Garante zero overshoot e derivada zero nas pontas (sem "tranco").
# ============================================================

def ease_cubic(p):
    p = max(0.0, min(1.0, p))
    if p < 0.5:
        return 4.0 * p * p * p
    q = 2.0 * p - 2.0
    return 0.5 * q * q * q + 1.0


# ============================================================
# RUÍDO
# ============================================================

def _n1(x):
    return (
        math.sin(x * 0.35) * 0.60 +
        math.sin(x * 0.90) * 0.25 +
        math.sin(x * 1.70) * 0.15
    )

def _n2(x):
    return (
        math.sin(x * 0.55) * 0.50 +
        math.sin(x * 1.30) * 0.35 +
        math.sin(x * 2.10) * 0.15
    )

def raw_noise(nx1, nx2):
    return min(
        (abs(_n1(nx1)) * 0.65 + abs(_n2(nx2)) * 0.35) / NOISE_NORM,
        1.0
    )


# ============================================================
# BUFFERS
# Ao redimensionar, preserva colunas existentes e inicializa novas
# com o target atual já interpolado (evita flash).
# ============================================================

def current_val(i, size):
    """Valor interpolado atual da coluna i."""
    delay = (i / max(size - 1, 1)) * CASCADE
    prog  = (t_elapsed - delay) / EASE
    blend = ease_cubic(prog)
    return {k: snap[i][k] * (1.0 - blend) + target_vals[k] * blend
            for k in ANIM_KEYS}

def ensure_buffers(size):
    global snap, _buf_size
    if _buf_size == size:
        return

    new_snap = []
    for i in range(size):
        if i < len(snap):
            new_snap.append(snap[i])
        else:
            # nova coluna entra já no estado atual (sem flash)
            new_snap.append(current_val(min(i, len(snap) - 1), size)
                            if snap else
                            {k: target_vals[k] for k in ANIM_KEYS})
    snap      = new_snap
    _buf_size = size


# ============================================================
# TRANSIÇÃO
# Congela o estado atual de cada coluna como snapshot,
# define o novo target e reinicia o cronômetro.
# ============================================================

def begin_transition(name):
    global target_name, target_vals, transitioning, t_elapsed, current_name

    size = _buf_size or 1

    # congela onde cada coluna está agora
    for i in range(size):
        snap[i] = current_val(i, size)

    target_name = name
    target_vals = {k: STATES[name][k] for k in ANIM_KEYS}
    t_elapsed   = 0.0
    transitioning = True

    # se o target for igual ao atual, não há transição real
    if name == current_name:
        transitioning = False


# ============================================================
# RENDER
# ============================================================

def render():
    global t_anim, t_elapsed, transitioning, current_name

    width  = shutil.get_terminal_size((80, 20)).columns
    usable = max(10, width - 30)

    ensure_buffers(usable)

    # verificar se a cascata completou (última coluna já chegou)
    last_delay   = CASCADE
    last_prog    = (t_elapsed - last_delay) / EASE
    if transitioning and last_prog >= 1.0:
        transitioning = False
        current_name  = target_name
        # fixar todas as colunas no target para eliminar drift numérico
        for i in range(usable):
            snap[i] = {k: target_vals[k] for k in ANIM_KEYS}
        t_elapsed = CASCADE + EASE + 1.0  # garante blend=1 em todas

    chars = []
    for x in range(usable):
        # blend desta coluna específica
        delay = (x / max(usable - 1, 1)) * CASCADE
        prog  = (t_elapsed - delay) / EASE
        blend = ease_cubic(prog)

        # interpolar cada parâmetro desta coluna
        s = {k: snap[x][k] * (1.0 - blend) + target_vals[k] * blend
             for k in ANIM_KEYS}

        e = s["energy"]
        if e < 1e-6:
            chars.append(" ")
            continue

        spd  = 0.4 + e * s["spd_factor"]
        nx1  = x * 0.07 * s["density"] + t_anim * spd
        nx2  = x * 0.12 * s["density"] + t_anim * spd * 1.2

        raw   = raw_noise(nx1, nx2)
        gamma = 0.25 + 4.5 * ((1.0 - e) ** 2)
        rnd   = (random.random() - 0.5) * s["chaos"]
        value = max(0.0, min(1.0, raw ** gamma + rnd))

        chars.append(BLOCKS[int(value * (len(BLOCKS) - 1))])

    wave = "".join(chars)

    cur_label = STATES[current_name]["label"]
    tgt_label = STATES[target_name]["label"]
    label     = f"{cur_label} → {tgt_label}" if transitioning else cur_label

    sys.stdout.write(f"\r\033[2K  {label:<26}  {wave}")
    sys.stdout.flush()

    t_anim    += FRAME_TIME
    t_elapsed += FRAME_TIME


# ============================================================
# LOOP PRINCIPAL
# ============================================================

next_frame = time.monotonic()

# inicializar buffers antes do primeiro begin_transition
_buf_size = max(10, shutil.get_terminal_size((80, 20)).columns - 30)
snap      = [{k: STATES["idle"][k] for k in ANIM_KEYS} for _ in range(_buf_size)]

begin_transition(CHAIN[0][0])

while True:
    _, duration = CHAIN[chain_index]
    if time.monotonic() - state_clock >= duration:
        chain_index = (chain_index + 1) % len(CHAIN)
        begin_transition(CHAIN[chain_index][0])
        state_clock = time.monotonic()

    render()

    next_frame += FRAME_TIME
    sleep_time  = next_frame - time.monotonic()

    if sleep_time > 0:
        time.sleep(sleep_time)
    else:
        next_frame = time.monotonic() + FRAME_TIME
