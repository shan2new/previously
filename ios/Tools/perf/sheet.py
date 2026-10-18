#!/usr/bin/env python3
"""Contact sheet of a capture set: sheet.py <dir> [out.png]"""
import sys, os
from PIL import Image
d = sys.argv[1]; out = sys.argv[2] if len(sys.argv) > 2 else f'{d}/sheet.png'
# Today is the feed (25 Sep): `feed`, the story viewer and a post page replace the billboard's five
# states (today, today-upnext, today-watching, today-calm, today-recap). The feed's For you page
# (`feed-foryou`) went on 16 Oct.
names = ['feed','story','post','activity','schedule','library','library-all','search','discover-genre','profile','saved','detail-slime','detail-got','detail-aot','detail-wed','detail-trailers','detail-people','detail-watch','detail-stage','receipt-inplace','receipt-lane']
tiles = []
for n in names:
    p = f'{d}/{n}.png'
    if not os.path.exists(p): continue
    im = Image.open(p); im.thumbnail((262, 568)); tiles.append(im)
cols = 7; w, h = 262, 568; rows = (len(tiles) + cols - 1) // cols
sheet = Image.new('RGB', (cols * (w + 8) + 8, rows * (h + 8) + 8), (20, 20, 22))
for i, im in enumerate(tiles): sheet.paste(im, (8 + (i % cols) * (w + 8), 8 + (i // cols) * (h + 8)))
sheet.save(out); print(out, sheet.size, len(tiles))
