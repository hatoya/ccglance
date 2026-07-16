#!/usr/bin/env python3
"""Verify no foreign session rows leaked into the recording.

The demo layout is fixed (docs/demo-sessions.js), so the group-header rows
sit at constant y positions. Any extra row shifts them and shows up as a
large mean diff against frame 0. Usage: check_stability.py <framesDir>
"""
import sys

import numpy as np
from PIL import Image

d = sys.argv[1]
ref = np.asarray(Image.open(f"{d}/frame0000.png").convert("L")).astype(int)
# Strips over the "ccglance" and "my-webapp" group headers (2x pixels)
STRIPS = [(300, 330), (500, 530)]
bad = []
for i in range(240):
    im = np.asarray(Image.open(f"{d}/frame{i:04d}.png").convert("L")).astype(int)
    diffs = [abs(im[y0:y1, 100:300] - ref[y0:y1, 100:300]).mean() for y0, y1 in STRIPS]
    if max(diffs) > 6:
        bad.append((i, [round(float(x), 1) for x in diffs]))
print("unstable frames:", bad if bad else "none")
sys.exit(1 if bad else 0)
