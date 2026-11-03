#!/usr/bin/env python3
"""Writes needs/done/fail WAVs (44.1 kHz mono 16-bit, 180 ms) into Sources/NotchTasks/Sounds."""
import math, struct, wave, pathlib
R, DUR, PEAK = 44100, 0.18, 0.4
out = pathlib.Path(__file__).resolve().parent.parent / "Sources/NotchTasks/Sounds"
out.mkdir(parents=True, exist_ok=True)

def tone(f1, f2):
    n, half = int(R * DUR), int(R * DUR) // 2
    s = []
    for i in range(n):
        j = i if i < half else i - half
        f = f1 if i < half else f2
        t = j / R
        env = min(1.0, t / 0.010) * math.exp(-t * 18)
        s.append(PEAK * env * math.sin(2 * math.pi * f * t))
    return s

for name, (a, b) in {"needs": (660, 880), "done": (523, 784), "fail": (330, 220)}.items():
    with wave.open(str(out / f"{name}.wav"), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(R)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, v)) * 32767)) for v in tone(a, b)))
