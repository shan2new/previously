#!/bin/bash
# Photograph Today (the feed, a story and a post page — 25 Sep: the feed replaced
# Today's billboard) and the billboards (five show pages), and FILM a Search query (simctl
# recordVideo + idb text), then lay the film out as a 12-fps contact sheet — how a "glitch" is
# diagnosed. The feed shots use the DEBUG capture flags (FeedCapture): a Debug build.
# Usage: hero_check.sh <out-dir>   (compare two dirs with hero_pairs.py)
set -u
# idb needs SimulatorKit under a developer dir (simkit_shadow.sh builds the shadow bundle); xcrun is fine with it too.
export DEVELOPER_DIR="${IDB_DEVELOPER_DIR:-$(cd "$(dirname "$0")/../.." && pwd)/build/Xcode-shadow.app/Contents/Developer}"
IDB="${IDB:-$HOME/Library/Python/3.9/bin/idb}"; U="${PERF_UDID:-C2AED006-C1A7-49DF-B7B4-764B35373C11}"; B=com.cognipin.previously; D="$1"; mkdir -p "$D"
SL=03ded211-224c-4e83-9815-5a7fec3caacc; GOT=c101456a-89e6-45e4-8842-4e4b07894b32; AOT=578f9465-c44c-4ac6-a622-7b78082149aa; WED=1820ef11-5175-4155-b2c6-544469358e2c; REZ=faa8903d-3b27-4c26-8924-7e89f937b370
shot() { xcrun simctl io $U screenshot "$D/$1.png" >/dev/null 2>&1; echo "shot $1"; }
launch() { xcrun simctl terminate $U $B 2>/dev/null; sleep 0.5; xcrun simctl launch $U $B "$@" >/dev/null 2>&1; }
launch; sleep 10; shot feed
launch -feedStory first; sleep 10; shot story
launch -feedThread first; sleep 10; shot post
for pair in "wed:$WED" "got:$GOT" "aot:$AOT" "slime:$SL" "rezero:$REZ"; do n=${pair%%:*}; id=${pair##*:}; launch -openDetail $id; sleep 8; shot detail-$n; done
# Search: film the typing.
launch -openTab discover; sleep 8
xcrun simctl io $U recordVideo --codec h264 --force "$D/search.mp4" >/dev/null 2>&1 &
REC=$!; sleep 1.5
$IDB ui tap 196 137 --udid $U >/dev/null 2>&1; sleep 1.2
$IDB ui text 'one piece' --udid $U >/dev/null 2>&1; sleep 3.5
$IDB ui tap 357 52 --udid $U >/dev/null 2>&1; sleep 1.2
sleep 0.3
$IDB ui text 'bleach' --udid $U >/dev/null 2>&1; sleep 3
kill -INT $REC; wait $REC 2>/dev/null
xcrun simctl terminate $U $B 2>/dev/null
mkdir -p "$D/search-frames"; rm -f "$D"/search-frames/*.png
ffmpeg -loglevel error -y -i "$D/search.mp4" -vf "fps=12,scale=196:-1" "$D/search-frames/%03d.png"
python3 - "$D" <<'PY'
import sys, os
from PIL import Image
d = sys.argv[1]; fr = sorted(os.listdir(f'{d}/search-frames'))
ims = [Image.open(f'{d}/search-frames/{f}') for f in fr]
if ims:
    w, h = ims[0].size; cols = 12; rows = (len(ims) + cols - 1) // cols
    sheet = Image.new('RGB', (cols * (w + 4) + 4, rows * (h + 4) + 4), (30, 30, 32))
    for i, im in enumerate(ims): sheet.paste(im, (4 + (i % cols) * (w + 4), 4 + (i // cols) * (h + 4)))
    sheet.save(f'{d}/search-sheet.png'); print('search sheet', sheet.size, len(ims), 'frames')
PY
echo done
