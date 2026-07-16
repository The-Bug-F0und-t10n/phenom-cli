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

CASCADE    = 1.2    # segundos para a frente de transição cruzar a tela
EASE       = 0.65   # segundos para cada coluna completar sua mudança


# ============================================================
# FÓRMULAS DE RUÍDO POR ESTADO
#
# Cada estado tem sua própria função de render, desenhada para
# expressar a qualidade visual pedida:
#
#   idle       — silêncio total, sem movimento
#   listening  — montanhas lentas e constantes
#   thinking   — ondulação contínua com pulsos ocasionais
#   confused   — caos rápido, harmônicos descasados + ruído
#   solving    — linha estável com ripple mínimo
#   responding — alto e constante, micro-oscilações rápidas
# ============================================================

def _wave_idle(xn, t):
    return 0.0


def _wave_listening(xn, t):
    # 2-3 montanhas visíveis, velocidade média, suave
    w = (
        math.sin(xn * math.pi * 2.5 + t * 1.0) * 0.65 +
        math.sin(xn * math.pi * 5.0 + t * 1.6) * 0.22 +
        math.sin(xn * math.pi * 0.8 + t * 0.5) * 0.13
    )
    return (w + 1.0) / 2.0 * 0.62 + 0.10  # → [0.10, 0.72]


def _wave_thinking(xn, t):
    # ondulação constante de fundo
    base = (
        math.sin(xn * math.pi * 4.5 + t * 2.2) * 0.38 +
        math.sin(xn * math.pi * 8.0 + t * 3.1) * 0.18 +
        math.sin(xn * math.pi * 2.0 + t * 1.1) * 0.14
    )
    # pulso gaussiano que percorre a tela periodicamente
    pulse_pos = (t * 0.22) % 1.0
    pulse = math.exp(-((xn - pulse_pos) ** 2) / 0.006) * 0.60
    return max(0.0, min(1.0, (base + pulse + 1.0) / 2.0 * 0.68 + 0.10))


def _wave_confused(xn, t):
    # frequências primas para evitar periodicidade aparente
    w = (
        math.sin(xn * math.pi * 13.0 + t * 8.3)  * 0.28 +
        math.sin(xn * math.pi *  7.0 + t * 5.7)  * 0.25 +
        math.sin(xn * math.pi * 19.0 + t * 11.3) * 0.20 +
        math.sin(xn * math.pi *  3.0 + t * 3.1)  * 0.17 +
        math.sin(xn * math.pi * 23.0 + t * 7.1)  * 0.10
    )
    rnd = (random.random() - 0.5) * 0.32
    return max(0.0, min(1.0, (w + rnd + 1.0) / 2.0))


def _wave_solving(xn, t):
    # linha reta com ripple muito baixo — foco e estabilidade
    ripple = (
        math.sin(xn * math.pi * 3.0 + t * 1.5) * 0.09 +
        math.sin(xn * math.pi * 7.0 + t * 2.5) * 0.04
    )
    breath = math.sin(t * 0.8) * 0.05
    return max(0.0, min(1.0, 0.60 + ripple + breath))


def _wave_responding(xn, t):
    # nível alto com micro-oscilações de alta frequência
    micro = (
        math.sin(xn * math.pi * 28.0 + t * 14.0) * 0.07 +
        math.sin(xn * math.pi * 41.0 + t * 19.0) * 0.05 +
        math.sin(xn * math.pi * 16.0 + t *  9.0) * 0.06 +
        math.sin(               t * 22.0)          * 0.03
    )
    return max(0.0, min(1.0, 0.76 + micro))


WAVE_FN = {
    "idle":       _wave_idle,
    "listening":  _wave_listening,
    "thinking":   _wave_thinking,
    "confused":   _wave_confused,
    "solving":    _wave_solving,
    "responding": _wave_responding,
}


# ============================================================
# ESTADOS — label e função de onda
# ============================================================

STATES = {
    "idle":       "em silêncio",
    "listening":  "ouvindo você",
    "thinking":   "pensando",
    "confused":   "com dúvidas",
    "solving":    "resolvendo",
    "responding": "respondendo",
}


# ============================================================
# SEQUÊNCIA DE DEMONSTRAÇÃO
# ============================================================

CHAIN = [
    ("idle",       5),
    ("listening",  7),
    ("thinking",  11),
    ("confused",   5),
    ("thinking",   8),
    ("solving",    9),
    ("responding", 7),
    ("idle",       4),
]


# ============================================================
# EASING — cúbico ease-in-out
# Derivada zero nas pontas → sem tranco na entrada ou saída.
# ============================================================

def ease_cubic(p):
    p = max(0.0, min(1.0, p))
    if p < 0.5:
        return 4.0 * p * p * p
    q = 2.0 * p - 2.0
    return 0.5 * q * q * q + 1.0


# ============================================================
# ESTADO DA CASCATA
#
# Para cada coluna i existe um "snapshot" do valor que ela
# tinha no instante do disparo da transição. A coluna então
# interpola desse snapshot para o target com um delay proporcional
# à sua posição — isso cria a cascata esquerda→direita.
#
# snap_a[i]  = valor da coluna i no instante do disparo (antigo estado)
# snap_b[i]  = valor da coluna i no instante do disparo (novo estado)
#   (snap_b é necessário para que o ponto de chegada também seja
#    um valor coerente do novo estado, não um valor fixo)
#
# Porém: interpolar diretamente valores numéricos entre dois estados
# que têm fórmulas completamente diferentes não faz sentido —
# o que precisa ser interpolado é a *saída visual* (o valor 0-1 do bloco).
#
# ARQUITETURA:
#   blend(i, t) = ease_cubic((t_elapsed - delay(i)) / EASE)
#   val(i, t)   = lerp(snap_val[i], target_fn(xn, t), blend)
#
# snap_val[i]: congela o valor de saída da coluna i no momento do disparo
# target_fn:   a função do novo estado, calculada com t corrente (animada)
#
# Isso garante:
#   - a coluna parte do valor exato que tinha (sem salto)
#   - chega suavemente no novo estado já animado
#   - interrupções são tratadas: novo snap_val congela onde estava
# ============================================================

snap_val     = []    # float[N]: valor visual congelado no disparo
current_fn   = WAVE_FN["idle"]
target_fn    = WAVE_FN["idle"]
current_name = "idle"
target_name  = "idle"
transitioning = False
t_elapsed    = CASCADE + EASE + 1.0   # começa "já completo"
state_clock  = time.monotonic()
chain_index  = 0
_buf_size    = 0
t_anim       = 0.0


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
# BUFFERS
# ============================================================

def _col_blend(i, size):
    delay = (i / max(size - 1, 1)) * CASCADE
    return ease_cubic((t_elapsed - delay) / EASE)

def ensure_buffers(size):
    global snap_val, _buf_size
    if _buf_size == size:
        return
    new_snap = []
    for i in range(size):
        if i < len(snap_val):
            new_snap.append(snap_val[i])
        else:
            # nova coluna: interpolar entre current e target no instante atual
            xn = i / max(size - 1, 1)
            b  = _col_blend(i, size)
            cv = current_fn(xn, t_anim)
            tv = target_fn(xn, t_anim)
            new_snap.append(cv * (1.0 - b) + tv * b)
    snap_val  = new_snap
    _buf_size = size


# ============================================================
# TRANSIÇÃO
# ============================================================

def begin_transition(name):
    global target_name, target_fn, t_elapsed, transitioning
    global current_name, current_fn, snap_val

    size = _buf_size or 1

    # congelar valor atual de cada coluna como snapshot
    for i in range(size):
        xn = i / max(size - 1, 1)
        b  = _col_blend(i, size)
        old_v = snap_val[i] if snap_val else 0.0
        new_v = target_fn(xn, t_anim)
        snap_val[i] = old_v * (1.0 - b) + new_v * b   # valor atual interpolado

    current_name = target_name
    current_fn   = target_fn
    target_name  = name
    target_fn    = WAVE_FN[name]
    t_elapsed    = 0.0
    transitioning = (name != current_name)


# ============================================================
# RENDER
# ============================================================

def render():
    global t_anim, t_elapsed, transitioning, current_name, current_fn

    width  = shutil.get_terminal_size((80, 20)).columns
    usable = max(10, width - 30)

    ensure_buffers(usable)

    # checar se a cascata completou
    if transitioning:
        last_delay = CASCADE
        if (t_elapsed - last_delay) / EASE >= 1.0:
            transitioning = False
            current_name  = target_name
            current_fn    = target_fn

    chars = []
    for x in range(usable):
        xn    = x / max(usable - 1, 1)
        delay = xn * CASCADE                              # ← delay proporcional à posição
        prog  = (t_elapsed - delay) / EASE
        blend = ease_cubic(prog)

        target_v = target_fn(xn, t_anim)

        if blend >= 1.0:
            value = target_v
        elif blend <= 0.0:
            # ainda no estado antigo — usar snapshot + animar com current_fn
            old_v  = snap_val[x]
            cur_v  = current_fn(xn, t_anim)
            # o snapshot define o "nível" e current_fn define a animação
            # interpolar entre o snapshot estático e a animação do estado atual
            anim_frac = min(1.0, t_elapsed / EASE)
            value = old_v * (1.0 - anim_frac) + cur_v * anim_frac
        else:
            # zona de blend: interpolar suavemente
            old_v = snap_val[x]
            value = old_v * (1.0 - blend) + target_v * blend

        chars.append(BLOCKS[int(max(0.0, min(1.0, value)) * (len(BLOCKS) - 1))])

    wave = "".join(chars)

    label = (f"{STATES[current_name]} → {STATES[target_name]}"
             if transitioning else STATES[current_name])

    sys.stdout.write(f"\r\033[2K  {label:<26}  {wave}")
    sys.stdout.flush()

    t_anim    += FRAME_TIME
    t_elapsed += FRAME_TIME


# ============================================================
# LOOP PRINCIPAL
# ============================================================

# inicializar buffers antes do primeiro begin_transition
_buf_size = max(10, shutil.get_terminal_size((80, 20)).columns - 30)
snap_val  = [0.0] * _buf_size

begin_transition(CHAIN[0][0])

next_frame  = time.monotonic()
state_clock = time.monotonic()

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
