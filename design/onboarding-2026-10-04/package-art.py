"""Package the generated first-run art with its alpha: crop the transparent padding, resample.

Nothing else is done to the pixels (no grade, no retouch). Run with a Python that has Pillow.
"""
import json
from pathlib import Path
from PIL import Image

HERE = Path(__file__).resolve().parent
CATALOG = HERE.parents[1] / "ios/Resources/Assets.xcassets"
# name → the slot in points it is drawn in (the empty states' 128 × 100; the alerts row's 56).
ASSETS = {
    "empty-home-flap-board-v1": (128, 100),
    "first-run-alert-bell-v1": (56, 56),
}

for name, (w, h) in ASSETS.items():
    source = Image.open(HERE / "source" / f"{name}.png").convert("RGBA")
    # Ignore isolated near-transparent pixels when measuring the padding; keep the generated alpha.
    left, top, right, bottom = source.getchannel("A").point(lambda a: 255 if a > 8 else 0).getbbox()
    pad = 12
    art = source.crop((max(0, left - pad), max(0, top - pad),
                       min(source.width, right + pad), min(source.height, bottom + pad)))
    dest = CATALOG / f"{name}.imageset"
    dest.mkdir(parents=True, exist_ok=True)
    entries = [{"idiom": "universal", "scale": "1x"}]
    for scale in (2, 3):
        filename = f"{name}@{scale}x.png"
        output = art.copy()
        output.thumbnail((w * scale, h * scale), Image.Resampling.LANCZOS)
        canvas = Image.new("RGBA", (w * scale, h * scale))
        canvas.alpha_composite(output, ((canvas.width - output.width) // 2, (canvas.height - output.height) // 2))
        canvas.save(dest / filename, optimize=True)
        entries.append({"idiom": "universal", "scale": f"{scale}x", "filename": filename})
        print(filename, canvas.size, (dest / filename).stat().st_size)
    (dest / "Contents.json").write_text(
        json.dumps({"images": entries, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
