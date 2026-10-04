#!/usr/bin/env python3
"""Звуковой дизайн сторис: синтез эффектов по списку подсказок (без библиотек).

    python3 sfx.py cues.json 20 out.wav

cues.json — список {"t": секунды, "type": имя, "gain": 0..1, ...параметры}.
Все звуки собственные (синтез), лицензии не нужны. Стерео 48 кГц, 16 бит.
"""
import json
import math
import random
import struct
import sys
import wave

SR = 48000
random.seed(7)


def env_exp(i, decay):
    return math.exp(-i / (decay * SR))


class Mix:
    def __init__(self, seconds):
        self.n = int(seconds * SR)
        self.l = [0.0] * self.n
        self.r = [0.0] * self.n

    def add(self, t, samples, gain=1.0, pan=0.0):
        start = int(t * SR)
        gl = gain * math.cos((pan + 1) * math.pi / 4) * math.sqrt(2)
        gr = gain * math.sin((pan + 1) * math.pi / 4) * math.sqrt(2)
        for i, s in enumerate(samples):
            j = start + i
            if j < 0:
                continue
            if j >= self.n:
                break
            self.l[j] += s * gl
            self.r[j] += s * gr

    def write(self, path):
        peak = max(1e-9, max(max(abs(x) for x in self.l), max(abs(x) for x in self.r)))
        k = 0.89 / peak if peak > 0.89 else 1.0
        with wave.open(path, 'wb') as w:
            w.setnchannels(2)
            w.setsampwidth(2)
            w.setframerate(SR)
            frames = bytearray()
            for a, b in zip(self.l, self.r):
                a = math.tanh(a * k * 1.1) / math.tanh(1.1)
                b = math.tanh(b * k * 1.1) / math.tanh(1.1)
                frames += struct.pack('<hh', int(a * 32000), int(b * 32000))
            w.writeframes(bytes(frames))


def lowpass(samples, cutoff_fn):
    """Однополюсный ФНЧ с меняющейся частотой среза cutoff_fn(i)."""
    out, y = [], 0.0
    for i, x in enumerate(samples):
        a = 1 - math.exp(-2 * math.pi * cutoff_fn(i) / SR)
        y += a * (x - y)
        out.append(y)
    return out


def noise(n):
    return [random.uniform(-1, 1) for _ in range(n)]


# ---- эффекты ---------------------------------------------------------------

def whoosh(dur=0.55, lo=250, hi=5000, **_):
    n = int(dur * SR)
    cut = lambda i: lo + (hi - lo) * math.sin(math.pi * i / n) ** 1.5
    s = lowpass(noise(n), cut)
    s = lowpass(s, cut)
    return [x * math.sin(math.pi * i / n) ** 2 * 2.2 for i, x in enumerate(s)]


def tick(freq=2600, **_):
    n = int(0.03 * SR)
    return [(math.sin(2 * math.pi * freq * i / SR) * 0.8 + random.uniform(-1, 1) * 0.25) * env_exp(i, 0.004) for i in range(n)]


def ticks(dur=1.6, count=16, freq=2600, ease='out', **_):
    """Серия щелчков под бегущий счётчик: чаще в начале, реже к концу."""
    out = [0.0] * int((dur + 0.05) * SR)
    one = tick(freq)
    for k in range(count):
        x = k / max(1, count - 1)
        pos = (1 - (1 - x) ** 0.55) if ease == 'out' else x ** 1.8
        start = int(pos * dur * SR)
        g = 0.55 + 0.45 * (1 - x) if ease == 'out' else 0.6 + 0.4 * x
        f = freq * (1 + 0.04 * random.uniform(-1, 1))
        snd = tick(f)
        for i, v in enumerate(snd):
            if start + i < len(out):
                out[start + i] += v * g
    return out


def coin(**_):
    n = int(1.2 * SR)
    parts = [(1568, 1.0, 0.55), (2093, 0.6, 0.45), (3136, 0.35, 0.3), (4186, 0.2, 0.2)]
    s = []
    for i in range(n):
        v = sum(a * math.sin(2 * math.pi * f * i / SR) * env_exp(i, d) for f, a, d in parts)
        v += random.uniform(-1, 1) * 0.3 * env_exp(i, 0.003)
        s.append(v * 0.5)
    return s


def drain(dur=2.4, f0=620, f1=140, **_):
    n = int(dur * SR)
    s, ph = [], 0.0
    for i in range(n):
        x = i / n
        f = f0 * (f1 / f0) ** x
        ph += 2 * math.pi * f / SR
        trem = 0.75 + 0.25 * math.sin(2 * math.pi * 7 * i / SR)
        a = math.sin(math.pi * min(1, x * 3)) if x < 0.33 else (1 - x) / 0.67
        s.append((math.sin(ph) + 0.3 * math.sin(2 * ph)) * a * trem * 0.5)
    return s


def thud(pitch=170, **_):
    n = int(0.28 * SR)
    s, ph = [], 0.0
    for i in range(n):
        f = pitch * (0.55 + 0.45 * env_exp(i, 0.03))
        ph += 2 * math.pi * f / SR
        s.append((math.sin(ph) * env_exp(i, 0.09) + random.uniform(-1, 1) * 0.15 * env_exp(i, 0.006)) * 0.9)
    return s


def impact(**_):
    n = int(2.2 * SR)
    sub, ph = [], 0.0
    for i in range(n):
        f = 34 + 40 * env_exp(i, 0.08)
        ph += 2 * math.pi * f / SR
        sub.append(math.sin(ph) * env_exp(i, 0.65))
    hit = lowpass(noise(int(0.5 * SR)), lambda i: 1800 * env_exp(i, 0.05) + 120)
    for i, v in enumerate(hit):
        sub[i] += v * 1.6 * env_exp(i, 0.12)
    return [v * 0.95 for v in sub]


def riser(dur=1.1, **_):
    n = int(dur * SR)
    cut = lambda i: 300 + 7000 * (i / n) ** 2
    s = lowpass(noise(n), cut)
    out, ph = [], 0.0
    for i, x in enumerate(s):
        p = i / n
        ph += 2 * math.pi * (180 + 720 * p ** 2) / SR
        a = p ** 2.2
        out.append((x * 1.6 + math.sin(ph) * 0.25) * a)
    return out


def tap(**_):
    n = int(0.06 * SR)
    return [(math.sin(2 * math.pi * 1400 * i / SR) * env_exp(i, 0.012) + random.uniform(-1, 1) * 0.4 * env_exp(i, 0.002)) * 0.9 for i in range(n)]


def success(**_):
    n = int(0.9 * SR)
    s = [0.0] * n
    for k, f in enumerate((880, 1318.5)):
        off = int(k * 0.085 * SR)
        for i in range(n - off):
            s[off + i] += (math.sin(2 * math.pi * f * i / SR) + 0.25 * math.sin(4 * math.pi * f * i / SR)) * env_exp(i, 0.22) * 0.45
    return s


def chime(**_):
    n = int(2.6 * SR)
    s = [0.0] * n
    for k, f in enumerate((1046.5, 1318.5, 1568.0, 2093.0)):
        off = int(k * 0.05 * SR)
        for i in range(n - off):
            vib = 1 + 0.002 * math.sin(2 * math.pi * 5 * i / SR)
            s[off + i] += math.sin(2 * math.pi * f * vib * i / SR) * env_exp(i, 0.9) * 0.28
    return s


def pad(dur=20.0, **_):
    n = int(dur * SR)
    notes = (55.0, 82.41, 110.0, 164.81, 220.5)
    s = []
    for i in range(n):
        t = i / SR
        v = sum(math.sin(2 * math.pi * f * t + k) * (0.6 if f < 100 else 0.25) for k, f in enumerate(notes))
        v *= 0.7 + 0.3 * math.sin(2 * math.pi * 0.11 * t)
        fade = min(1, t / 1.5, (dur - t) / 1.5)
        s.append(v * max(0.0, fade) * 0.18)
    return lowpass(s, lambda i: 900)


FX = dict(whoosh=whoosh, tick=tick, ticks=ticks, coin=coin, drain=drain, thud=thud,
          impact=impact, riser=riser, tap=tap, success=success, chime=chime, pad=pad)


def main():
    cues_path, seconds, out = sys.argv[1], float(sys.argv[2]), sys.argv[3]
    cues = json.load(open(cues_path, encoding='utf-8'))
    mix = Mix(seconds)
    for c in cues:
        params = {k: v for k, v in c.items() if k not in ('t', 'type', 'gain', 'pan')}
        mix.add(c['t'], FX[c['type']](**params), gain=c.get('gain', 0.5), pan=c.get('pan', 0.0))
    mix.write(out)
    print('звук:', out)


if __name__ == '__main__':
    main()
