#!/usr/bin/env python3
"""Every icon in the iOS app is a Tabler icon (https://tabler.io/icons, MIT — LICENSE beside this file).

26 Sep: "Replace ALL ICONS (SF/HugeIcons/etc) -> Tablar" (owner). Every icon in the app is drawn
through `AppGlyph(systemName:)` (ios/Shared/AppGlyph.swift), which looks its name up in
`AppGlyphCatalog` for a `Glyph-…` asset. This file maps each of those names to a Tabler icon
(`GLYPHS`) and redraws the assets — the names and every call site stay; only the drawings change.
It supersedes icon/glyphs/generate.py (the hand-authored glyphs of 25 Sep). Running it

  · copies each SVG into icon/tabler/svg/ (the vendored subset — the full set is not in the repo),
  · converts it to a vector PDF with rsvg-convert and rewrites ios/Shared/AppSymbols.xcassets/
    Glyph-….imageset (template, vector preserved — sharp at every size AppGlyph draws),
  · and redraws the tab bar's glyphs (TabHome/Today/Schedule/Library/Discover + Fill), with extra
    air so their ink lands ~21 pt inside the bar's 28-pt frame (X's 20.7).

    python3 icon/tabler/icons.py <path to the unpacked @tabler/icons package>

The package: `npm pack @tabler/icons` (3.48.0 at the time) or its tarball from the npm registry.
"""
import json
import pathlib
import re
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
HERE = ROOT / "icon" / "tabler"
ASSETS = ROOT / "ios" / "Resources" / "Assets.xcassets"
SHARED = ROOT / "ios" / "Shared" / "AppSymbols.xcassets"
CATALOG_SWIFT = ROOT / "ios" / "Shared" / "AppGlyphCatalog.swift"

# AppGlyph's names (ios/Shared/AppGlyphCatalog.swift — every icon in the app is drawn through
# `AppGlyph(systemName:)`) → the Tabler icon that draws it ("-filled" = Tabler's filled set). The
# asset keeps its catalog name (`Glyph-…`), so no call site changes; only the drawing does.
GLYPHS = {
    r"\\(index + 1).circle.fill": "circle-filled",   # the rule numeral is drawn over it by AppGlyph
    "arrow.clockwise": "reload", "arrow.counterclockwise": "rotate",
    "arrow.down.right.and.arrow.up.left": "arrows-minimize", "arrow.up.left.and.arrow.down.right": "arrows-maximize",
    "arrow.left": "arrow-left", "arrow.up": "arrow-up", "arrow.up.backward": "arrow-up-left",
    "arrow.up.forward": "arrow-up-right", "arrow.up.right": "arrow-up-right",
    "arrow.triangle.2.circlepath": "refresh", "at": "at",
    "bell": "bell", "bell.badge": "bell-ringing", "bell.fill": "bell-filled",
    "bookmark": "bookmark", "bookmark.fill": "bookmark-filled", "bookmark.slash": "bookmark-off",
    "bubble.left": "message-circle", "bubble.left.fill": "message-circle-filled", "bubble.left.and.bubble.right": "messages",
    "calendar": "calendar", "checkmark": "check", "checkmark.circle": "circle-check",
    "checkmark.circle.fill": "circle-check-filled", "checkmark.seal.fill": "rosette-discount-check-filled",
    "chevron.down": "chevron-down", "chevron.forward": "chevron-right", "chevron.left": "chevron-left",
    "chevron.right": "chevron-right", "chevron.up": "chevron-up", "chevron.up.chevron.down": "selector",
    "circle": "circle", "circle.fill": "circle-filled", "clock": "clock", "clock.arrow.circlepath": "history",
    "curlybraces": "braces", "doc.on.doc": "copy", "doc.text": "file-text",
    "dot.radiowaves.left.and.right": "broadcast", "ellipsis": "dots", "envelope": "mail",
    "exclamationmark.circle": "alert-circle", "exclamationmark.triangle.fill": "alert-triangle-filled",
    "eye": "eye", "eye.slash": "eye-off", "eye.slash.fill": "eye-off", "flag": "flag", "flag.fill": "flag-filled",
    "globe": "world", "gobackward.10": "rewind-backward-10", "goforward.10": "rewind-forward-10",
    "hand.raised": "hand-stop", "hand.tap": "hand-finger", "hand.thumbsdown": "thumb-down",
    "heart": "heart", "heart.fill": "heart-filled", "info.circle": "info-circle", "ladybug": "bug",
    "line.3.horizontal.decrease": "filter", "line.3.horizontal.decrease.circle.fill": "filter-filled",
    "link": "link", "lock.fill": "lock-filled", "magnifyingglass": "search", "minus": "minus",
    "minus.circle": "circle-minus", "newspaper": "news", "paperplane": "send",
    "pause.circle": "player-pause", "pause.fill": "player-pause-filled",
    "person.2.fill": "users", "person.crop.circle.badge.exclamationmark": "user-exclamation",
    "person.crop.circle.badge.xmark": "user-x", "person.fill": "user-filled", "photo": "photo",
    "pin.fill": "pin-filled", "play.circle": "player-play", "play.fill": "player-play-filled",
    "play.rectangle": "video", "play.rectangle.on.rectangle": "movie", "plus": "plus", "plus.circle": "circle-plus",
    "questionmark.bubble": "message-question", "rectangle.portrait.and.arrow.right": "logout",
    "rectangle.stack": "stack-2", "safari": "compass", "slider.horizontal.3": "adjustments-horizontal",
    "speaker.slash": "volume-off", "speaker.slash.fill": "volume-off", "speaker.wave.2": "volume",
    "speaker.wave.2.fill": "volume", "square.and.arrow.up": "share-2", "square.grid.2x2": "layout-grid",
    "square.stack": "stack", "tablecells": "table", "text.append": "playlist-add", "text.book.closed": "book",
    "trash": "trash", "tv": "device-tv", "wifi.exclamationmark": "wifi-off", "wifi.slash": "wifi-off",
    "xmark": "x", "xmark.circle": "circle-x", "xmark.circle.fill": "circle-x-filled",
}

# The tab bar: (asset name, Tabler icon). Outline at rest, filled when selected — X's rule.
TABS = [
    ("TabHome", "home"), ("TabHomeFill", "home-filled"),
    ("TabToday", "device-tv"), ("TabTodayFill", "device-tv-filled"),
    ("TabSchedule", "calendar"), ("TabScheduleFill", "calendar-filled"),
    ("TabLibrary", "library"), ("TabLibraryFill", "library-filled"),
    ("TabDiscover", "search"), ("TabDiscoverFill", "search-filled"),
    # The directions' Discover (16 Oct, `Experience`): a compass — shows to find, not a search box.
    ("TabCompass", "compass"), ("TabCompassFill", "compass-filled"),
]


def source(pkg: pathlib.Path, name: str) -> pathlib.Path:
    if name.endswith("-filled"):
        path = pkg / "icons" / "filled" / f"{name[: -len('-filled')]}.svg"
    else:
        path = pkg / "icons" / "outline" / f"{name}.svg"
    if not path.exists():
        sys.exit(f"missing Tabler icon: {name} ({path})")
    return path


def vendor(pkg: pathlib.Path, name: str) -> pathlib.Path:
    """The SVG, copied into the repo's vendored subset, currentColor made black (a template's
    alpha is all that is read)."""
    out = HERE / "svg" / f"{name}.svg"
    out.parent.mkdir(parents=True, exist_ok=True)
    svg = source(pkg, name).read_text().replace("currentColor", "#000000")
    out.write_text(svg)
    return out


def pad(svg: str, air: float) -> str:
    """The same drawing with `air` units of extra margin on every side (the tab glyphs)."""
    return re.sub(r'viewBox="0 0 24 24"', f'viewBox="{-air} {-air} {24 + 2 * air} {24 + 2 * air}"', svg, count=1)


def imageset(folder: pathlib.Path, name: str, svg_text: str) -> None:
    if folder.exists():
        shutil.rmtree(folder)
    folder.mkdir(parents=True)
    tmp = folder / f"{name}.svg"
    tmp.write_text(svg_text)
    subprocess.run(["rsvg-convert", "-f", "pdf", "-o", str(folder / f"{name}.pdf"), str(tmp)], check=True)
    tmp.unlink()
    (folder / "Contents.json").write_text(json.dumps({
        "images": [{"idiom": "universal", "filename": f"{name}.pdf"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {"template-rendering-intent": "template", "preserves-vector-representation": True},
    }, indent=2) + "\n")


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    pkg = pathlib.Path(sys.argv[1]).resolve()
    catalog = re.findall(r'"([^"]+)":\s*"(Glyph-[^"]+)"', CATALOG_SWIFT.read_text())
    missing = [key for key, _ in catalog if key not in GLYPHS]
    if missing:
        sys.exit(f"no Tabler icon mapped for: {', '.join(missing)}")
    shutil.rmtree(HERE / "svg", ignore_errors=True)
    done = set()
    for key, asset in catalog:
        if asset in done:
            continue
        svg = vendor(pkg, GLYPHS[key]).read_text()
        imageset(SHARED / f"{asset}.imageset", asset, svg)
        done.add(asset)
    for asset, tabler in TABS:
        imageset(ASSETS / f"{asset}.imageset", asset, pad(vendor(pkg, tabler).read_text(), 1.5))
    shutil.copy(pkg / "LICENSE", HERE / "LICENSE")
    print(f"{len(done)} glyphs + {len(TABS)} tab glyphs redrawn from Tabler")
    return 0


if __name__ == "__main__":
    sys.exit(main())
