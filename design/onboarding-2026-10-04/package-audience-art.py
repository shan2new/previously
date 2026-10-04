"""Package the chosen "What do you watch?" pictures: crop to the cards' 2:1 band, resample, encode.

No grade and no retouch — the pixels are the generator's. The other candidates stay in source/.
Run with a Python that has Pillow.
"""
import json
from pathlib import Path
from PIL import Image

HERE = Path(__file__).resolve().parent
CATALOG = HERE.parents[1] / "ios/Resources/Assets.xcassets"
# asset name → the chosen source
CHOSEN = {
    "audience-anime-v1": "audience-anime-a.png",
    "audience-tv-v1": "audience-tv-a.png",
    "audience-both-v1": "audience-both-a.png",
}
POINTS = (361, 180)   # the widest card the app draws, in points (2:1)

for name, source in CHOSEN.items():
    im = Image.open(HERE / "source" / source).convert("RGB")
    w, h = im.size
    band = round(w * POINTS[1] / POINTS[0])
    top = (h - band) // 2
    art = im.crop((0, top, w, top + band))
    dest = CATALOG / f"{name}.imageset"
    dest.mkdir(parents=True, exist_ok=True)
    entries = [{"idiom": "universal", "scale": "1x"}]
    for scale in (2, 3):
        filename = f"{name}@{scale}x.jpg"
        out = art.resize((POINTS[0] * scale, POINTS[1] * scale), Image.Resampling.LANCZOS)
        out.save(dest / filename, quality=90, optimize=True, progressive=True)
        entries.append({"idiom": "universal", "scale": f"{scale}x", "filename": filename})
        print(filename, out.size, (dest / filename).stat().st_size)
    (dest / "Contents.json").write_text(
        json.dumps({"images": entries, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
