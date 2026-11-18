#!/usr/bin/env python3
"""Draws GlucOS's alert sounds (docs/AlertSounds.md) as 16-bit mono WAV files.

    python3 scripts/make_alert_sounds.py   # writes Sources/App/Sounds/glucos-*.wav

Synthesised rather than recorded, so they carry no licence and can be redrawn. Each one is under
2 seconds (notifications allow 30) and peaks at -3 dBFS. Standard library only.
"""
import math
import os
import struct
import wave

RATE = 44100
OUT = os.path.join(os.path.dirname(__file__), "..", "Sources", "App", "Sounds")


def silence(seconds):
    return [0.0] * int(RATE * seconds)


def tone(freq, seconds, partials=((1, 1.0),), decay=None, attack=0.005, release=0.02):
    """A note: summed sine partials, a short attack, then an exponential decay (or a flat hold)."""
    n = int(RATE * seconds)
    out = []
    for i in range(n):
        t = i / RATE
        v = sum(a * math.sin(2 * math.pi * freq * k * t) for k, a in partials)
        env = min(1.0, t / attack) if attack else 1.0
        if decay:
            env *= math.exp(-t / decay)
        tail = (seconds - t) / release
        if tail < 1:
            env *= max(0.0, tail)
        out.append(v * env)
    return out


def mix(*tracks):
    """Overlays (offset seconds, samples) pairs."""
    length = max(int(off * RATE) + len(s) for off, s in tracks)
    out = [0.0] * length
    for off, s in tracks:
        start = int(off * RATE)
        for i, v in enumerate(s):
            out[start + i] += v
    return out


def write(name, samples):
    peak = max(abs(v) for v in samples) or 1.0
    gain = 10 ** (-3 / 20) / peak
    path = os.path.join(OUT, name)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, v * gain)) * 32767)) for v in samples))
    print(f"{path}: {len(samples) / RATE:.2f} s")


BELL = ((1, 1.0), (2.0, 0.35), (3.0, 0.12), (4.2, 0.05))
SOFT_SQUARE = ((1, 1.0), (3, 0.22), (5, 0.08))
TRIANGLE = ((1, 1.0), (3, -0.11), (5, 0.04))


def chime():
    # Two bell notes falling a third, twice: E6 then C6.
    note = lambda f: tone(f, 0.9, BELL, decay=0.32)
    return mix((0.0, note(1318.5)), (0.22, note(1046.5)), (0.75, note(1318.5)), (0.97, note(1046.5)))


def pulse():
    # Three short beeps, a breath, three more: hard to sleep through, never shrill.
    beep = lambda: tone(988.0, 0.11, SOFT_SQUARE, release=0.015)
    track = []
    for group in range(2):
        for b in range(3):
            track += beep() + silence(0.07)
        if group == 0:
            track += silence(0.22)
    return track


def beacon():
    # A rising arpeggio, C5 E5 G5 C6, the last note held.
    notes = [(523.25, 0.16), (659.25, 0.16), (783.99, 0.16), (1046.5, 0.7)]
    tracks, at = [], 0.0
    for f, d in notes:
        tracks.append((at, tone(f, d + 0.25, TRIANGLE, decay=0.28 if d < 0.5 else 0.5)))
        at += d
    return mix(*tracks)


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    write("glucos-chime.wav", chime())
    write("glucos-pulse.wav", pulse())
    write("glucos-beacon.wav", beacon())
