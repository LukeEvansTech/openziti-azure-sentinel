#!/usr/bin/env python3
"""Rasterise the Azure service SVGs this repo's figure needs into icons.json.

build_diagram.py embeds the icons directly into the draw.io XML as
`data:image/png,<b64>` (a COMMA, never `;base64` - draw.io splits style strings
on ';' and would truncate the property). draw.io does not render SVG data URIs
in shape=image cells, hence the PNG rasterise step.

Setup: download "Azure Public Service Icons" from Microsoft
(https://learn.microsoft.com/en-us/azure/architecture/icons/), unzip it, and
either place it at diagrams/Azure_Public_Service_Icons/ (gitignored) or set
AZURE_ICONS_DIR to the unzipped Icons/ directory. The icon set itself is not
committed to this repository; only the finished figure is.

Rasteriser: auto-detected, first available wins - rsvg-convert
(`brew install librsvg` / `apt install librsvg2-bin`), inkscape, or
`pip install cairosvg`. Do not use qlmanage (file-preview thumbnails only).

Run: `python3 diagrams/make_icons.py` -> writes diagrams/icons.json.
"""

import base64
import glob
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import urllib.request

BASE = pathlib.Path(__file__).parent
ICONS_DIR = os.environ.get(
    "AZURE_ICONS_DIR", str(BASE / "Azure_Public_Service_Icons" / "Icons")
)
OUT = BASE / "icons.json"
PX = 256  # rasterise size; displayed small but the 2x export stays crisp

# friendly name -> ordered candidate filename substrings; first existing match
# wins. Filenames differ between Azure icon-set releases - if a name reports
# MISSING, find the current filename in your set and update the substring.
WANT = {
    "servicebus": ["10836-icon-service-Azure-Service-Bus.svg", "Service-Bus"],
    "function": ["10029-icon-service-Function-Apps.svg", "Function-Apps"],
    "dcr": [
        "01857-icon-service-Data-Collection-Rules.svg",
        "00001-icon-service-Monitor.svg",
    ],
    "loganalytics": ["00009-icon-service-Log-Analytics-Workspaces.svg"],
    "sentinel": ["10248-icon-service-Azure-Sentinel.svg", "Sentinel"],
}

# Brand marks not in the Azure set, fetched as ready-made PNGs from a stable
# URL (GitHub serves an org's avatar at github.com/<org>.png). The OpenZiti
# mark identifies the OpenZiti controller card in the figure; the logo remains
# the OpenZiti project's - it is embedded in the built figure, not
# redistributed as an asset.
BRAND_MARKS = {
    "openziti": f"https://github.com/openziti.png?size={PX}",
}


def _rsvg(svg, png):
    subprocess.run(
        ["rsvg-convert", "-w", str(PX), "-h", str(PX), svg, "-o", png], check=True
    )


def _inkscape(svg, png):
    subprocess.run(
        [
            "inkscape",
            svg,
            "--export-type=png",
            f"--export-filename={png}",
            f"--export-width={PX}",
            f"--export-height={PX}",
        ],
        check=True,
    )


RASTERISERS = [("rsvg-convert", _rsvg), ("inkscape", _inkscape)]


def _pick_rasteriser():
    for exe, fn in RASTERISERS:
        if shutil.which(exe):
            return exe, fn
    try:
        import cairosvg  # noqa: F401  pylint: disable=unused-import,import-outside-toplevel

        return "cairosvg", None
    except ImportError:
        return None, None


RAST_NAME, RAST_FN = _pick_rasteriser()
TMP = tempfile.gettempdir()


def rasterise(svg_path, name):
    png = os.path.join(TMP, f"icon_{name}.png")
    if RAST_FN is None:  # cairosvg python path
        import cairosvg  # pylint: disable=import-outside-toplevel

        cairosvg.svg2png(url=svg_path, write_to=png, output_width=PX, output_height=PX)
    else:
        RAST_FN(svg_path, png)
    with open(png, "rb") as f:
        return base64.b64encode(f.read()).decode()


def find(cands, allsvg):
    for c in cands:
        hits = [p for p in allsvg if c in p]
        if hits:
            hits.sort(key=len)
            return hits[0]
    return None


def main():
    if not os.path.isdir(ICONS_DIR):
        raise SystemExit(
            f"Icon set not found at {ICONS_DIR} - download Azure Public Service "
            "Icons from Microsoft and set AZURE_ICONS_DIR (see the module docstring)."
        )
    if RAST_NAME is None:
        raise SystemExit(
            "No rasteriser found. Install one of: rsvg-convert (librsvg), "
            "inkscape, or `pip install cairosvg`."
        )
    allsvg = glob.glob(os.path.join(ICONS_DIR, "**", "*.svg"), recursive=True)
    cat = json.loads(OUT.read_text()) if OUT.exists() else {}
    report = []
    for name, cands in WANT.items():
        svg = find(cands, allsvg)
        if not svg:
            report.append(f"  MISSING: {name} (tried {cands})")
            continue
        cat[name] = rasterise(svg, name)
        report.append(f"  {name:14s} <- {os.path.relpath(svg, ICONS_DIR)}")
    for name, url in BRAND_MARKS.items():
        try:
            with urllib.request.urlopen(url, timeout=30) as resp:  # noqa: S310
                cat[name] = base64.b64encode(resp.read()).decode()
            report.append(f"  {name:14s} <- {url}")
        except OSError as exc:
            report.append(f"  MISSING: {name} ({url}: {exc})")
    OUT.write_text(json.dumps(cat))
    print(f"Rasteriser: {RAST_NAME}")
    print(f"Wrote {OUT} with {len(cat)} icons total:")
    print("\n".join(report))


if __name__ == "__main__":
    main()
