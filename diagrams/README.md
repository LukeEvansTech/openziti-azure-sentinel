# Diagrams

The data-flow figure (`docs/assets/data-flow.png`) is built as code - the
`.drawio` XML and the exported PNG are generated, never hand-edited. Every
visual change is an edit to `build_diagram.py` followed by a rebuild, so the
git diff of the `.drawio` shows exactly what changed.

## Rebuild

1. Download "Azure Public Service Icons" from
   [Microsoft](https://learn.microsoft.com/en-us/azure/architecture/icons/) and
   unzip it to `diagrams/Azure_Public_Service_Icons/` (gitignored), or point
   `AZURE_ICONS_DIR` at the unzipped `Icons/` directory. The icon set is not
   redistributed in this repository.
2. Install a rasteriser (`brew install librsvg` for `rsvg-convert`, or
   Inkscape, or `pip install cairosvg`) and
   [draw.io desktop](https://github.com/jgraph/drawio-desktop/releases).
3. Build:

   ```bash
   python3 diagrams/make_icons.py      # -> diagrams/icons.json (gitignored)
   python3 diagrams/build_diagram.py   # -> diagrams/data-flow.drawio
   drawio -x -f png --scale 2 -b 10 \
     -o docs/assets/data-flow.png diagrams/data-flow.drawio
   ```

   On macOS the draw.io CLI lives at
   `/Applications/draw.io.app/Contents/MacOS/draw.io`.

The colour system: the indigo accent is chrome (title rule, zone tints) and
carries no meaning; edge colours are semantic channels - grey for shared-secret
SAS legs, green for the managed-identity leg, Azure blue for the Azure Monitor
data path. The legend explains the channels, never the chrome.
