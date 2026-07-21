#!/usr/bin/env python3
"""Programmatic draw.io architecture figure for openziti-azure-sentinel.

The data-flow figure is built as code: this script emits deterministic draw.io
XML with embedded Azure service icons (white cards, dashed tinted zones,
channel-coloured edges, semantic legend). Never hand-edit the .drawio or the
exported PNG - edit this script and rebuild:

    python3 diagrams/make_icons.py     # once, needs the Azure icon set
    python3 diagrams/build_diagram.py  # -> diagrams/data-flow.drawio
    # export (draw.io desktop CLI):
    #   drawio -x -f png --scale 2 -b 10 \\
    #     -o docs/assets/data-flow.png diagrams/data-flow.drawio

Colour system: the accent (indigo, matching the docs site) is chrome only -
the title rule and zone tints. Edge colours are semantic channels and mean the
same thing in every figure: grey = shared-secret (SAS), green = identity
(managed identity), Azure blue = Azure Monitor data path.
"""

import html
import json
import pathlib

BASE = pathlib.Path(__file__).parent
ICONS = (
    json.loads((BASE / "icons.json").read_text())
    if (BASE / "icons.json").exists()
    else {}
)

# ---------------------------- design tokens ----------------------------
# Chrome (identity only, never meaning): indigo, matching the docs site theme.
ACCENT = "#3F51B5"
ACCENT_DK = "#283593"

FONT = "Open Sans"
INK = "#37424A"
GREY = "#8A949B"
CARD = "#FFFFFF"
CARD_BORD = "#D8DEE3"
ZONE_FILL = "#F4F5FB"  # indigo wash (primary zones)
ZONE_BORD = "#AEB6E8"
EGRESS_FILL = "#F4F5F6"  # neutral zone (the OpenZiti estate - not ours)
EGRESS_BORD = "#C7CDD2"

# Channels (fixed, semantic - these are what the legend explains)
AZURE = "#0078D4"  # Azure Monitor data path
GREEN = "#107C10"  # identity-based auth (managed identity)
NEUTRAL = GREY  # shared-secret auth (SAS connection strings)


def esc(s):
    return html.escape(s, quote=True)


def tint(hexcolor, frac=0.86):
    h = hexcolor.lstrip("#")
    rgb = [int(h[i : i + 2], 16) for i in (0, 2, 4)]
    return "#" + "".join(f"{int(round(c + (255 - c) * frac)):02X}" for c in rgb)


def shade(hexcolor, frac=0.30):
    h = hexcolor.lstrip("#")
    rgb = [int(h[i : i + 2], 16) for i in (0, 2, 4)]
    return "#" + "".join(f"{int(round(c * (1 - frac))):02X}" for c in rgb)


class Doc:
    """One figure: build cells with the helpers, then render() to draw.io XML."""

    # geometry helpers take x/y/w/h plus content, so the arg/local-count
    # ceilings are noise here
    # pylint: disable=too-many-arguments,too-many-positional-arguments
    # pylint: disable=too-many-locals

    def __init__(self, name, w, h):
        self.name, self.w, self.h = name, w, h
        self.cells = []
        self.n = 0

    def _id(self, p=""):
        self.n += 1
        return f"{p}{self.n}"

    def zone(self, x, y, w, h, label, fill, border):
        self.cells.append(
            f'<mxCell id="{self._id("z")}" value="{esc(label)}" style="rounded=1;arcSize=2;'
            f"whiteSpace=wrap;html=1;fillColor={fill};"
            f"strokeColor={border};strokeWidth=1.5;dashed=1;"
            f"dashPattern=6 4;verticalAlign=top;align=left;"
            f"fontFamily={FONT};fontColor={border};"
            f'fontSize=12;fontStyle=1;spacingLeft=16;spacingTop=10;letterSpacing=2;" vertex="1" '
            f'parent="1"><mxGeometry x="{x}" y="{y}" width="{w}" height="{h}" '
            f'as="geometry"/></mxCell>'
        )

    def title(self, x, y, w, text, sub=""):
        self.cells.append(
            f'<mxCell id="ttl" value="{esc(text)}" '
            f'style="text;html=1;fontFamily={FONT};fontSize=20;'
            f'fontStyle=1;fontColor={INK};align=left;verticalAlign=top;" vertex="1" parent="1">'
            f'<mxGeometry x="{x}" y="{y}" width="{w}" height="28" as="geometry"/></mxCell>'
        )
        self.cells.append(
            f'<mxCell id="rule" value="" style="line;strokeColor={ACCENT};strokeWidth=3;html=1;" '
            f'vertex="1" parent="1">'
            f'<mxGeometry x="{x}" y="{y + 30}" width="64" height="8" as="geometry"/></mxCell>'
        )
        if sub:
            self.cells.append(
                f'<mxCell id="sub" value="{esc(sub)}" style="text;html=1;fontFamily={FONT};'
                f'fontSize=12;fontColor={GREY};align=left;" vertex="1" parent="1">'
                f'<mxGeometry x="{x + 76}" y="{y + 30}" width="{w - 80}" '
                f'height="18" as="geometry"/>'
                f"</mxCell>"
            )

    def card(
        self,
        x,
        y,
        w,
        h,
        card_title,
        icon=None,
        sub=None,
        font_color=INK,
        shadow=True,
        dashed=False,
    ):
        cid = self._id("c")
        isz = min(h - 20, 42)
        spacing = (isz + 26) if icon else 14
        iy = y + (h - isz) // 2
        lab = f"<b>{card_title}</b>"
        if sub:
            lab += f'<br><font color="{GREY}" style="font-size:10px">{sub}</font>'
        label = (
            lab.replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
            .replace('"', "&quot;")
        )
        sh = "shadow=1;" if shadow else ""
        da = "dashed=1;dashPattern=4 4;" if dashed else ""
        self.cells.append(
            f'<mxCell id="{cid}" value="{label}" style="rounded=1;arcSize=8;whiteSpace=wrap;html=1;'
            f"fillColor={CARD};strokeColor={CARD_BORD};strokeWidth=1.5;{sh}{da}fontFamily={FONT};"
            f"fontSize=13;fontColor={font_color};align=left;verticalAlign=middle;"
            f'spacingLeft={spacing};spacingRight=10;" vertex="1" parent="1">'
            f'<mxGeometry x="{x}" y="{y}" width="{w}" height="{h}" as="geometry"/></mxCell>'
        )
        if icon and icon in ICONS:
            # data:image/png,<b64> with a comma - draw.io splits styles on ';'
            self.cells.append(
                f'<mxCell id="{cid}i" value="" style="shape=image;html=1;imageAspect=1;'
                f'image=data:image/png,{ICONS[icon]};" vertex="1" parent="1">'
                f'<mxGeometry x="{x + 14}" y="{iy}" width="{isz}" height="{isz}" as="geometry"/>'
                f"</mxCell>"
            )
        return cid

    def edge(
        self,
        src,
        tgt,
        color,
        label="",
        exit_xy=None,
        entry_xy=None,
        tag=False,
        label_pos=None,
    ):
        if tag and label:
            box = f"labelBackgroundColor={tint(color)};labelBorderColor={color};fontStyle=1;"
            fcol = shade(color)
            fsize = 11
        else:
            box = "labelBackgroundColor=none;"
            fcol = color
            fsize = 10
        st = (
            f"edgeStyle=orthogonalEdgeStyle;rounded=1;html=1;strokeColor={color};strokeWidth=2.5;"
            f"fontFamily={FONT};fontSize={fsize};fontColor={fcol};{box}"
            f"endArrow=block;endFill=1;jettySize=auto;"
        )
        if exit_xy:
            st += f"exitX={exit_xy[0]};exitY={exit_xy[1]};exitDx=0;exitDy=0;"
        if entry_xy:
            st += f"entryX={entry_xy[0]};entryY={entry_xy[1]};entryDx=0;entryDy=0;"
        lp = f' x="{label_pos}"' if label_pos is not None else ""
        self.cells.append(
            f'<mxCell id="{self._id("e")}" value="{esc(label)}" style="{st}" edge="1" parent="1" '
            f'source="{src}" target="{tgt}"><mxGeometry relative="1"{lp} as="geometry"/></mxCell>'
        )

    def legend(self, x, y, items):
        self.cells.append(
            f'<mxCell id="lt" value="Channels" style="text;html=1;fontFamily={FONT};fontSize=11;'
            f'fontStyle=1;fontColor={INK};align=left;" vertex="1" parent="1">'
            f'<mxGeometry x="{x}" y="{y - 2}" width="70" height="18" as="geometry"/></mxCell>'
        )
        cx = x + 78
        for color, text in items:
            self.cells.append(
                f'<mxCell id="{self._id("ll")}" value="" style="endArrow=none;html=1;'
                f'strokeColor={color};strokeWidth=3;" edge="1" parent="1">'
                f'<mxGeometry relative="1" as="geometry">'
                f'<mxPoint x="{cx}" y="{y + 8}" as="sourcePoint"/>'
                f'<mxPoint x="{cx + 34}" y="{y + 8}" as="targetPoint"/>'
                f"</mxGeometry></mxCell>"
            )
            self.cells.append(
                f'<mxCell id="{self._id("lx")}" value="{esc(text)}" style="text;html=1;'
                f'fontFamily={FONT};fontSize=10;fontColor={INK};align=left;verticalAlign=middle;" '
                f'vertex="1" parent="1"><mxGeometry x="{cx + 40}" y="{y}" '
                f'width="{14 + len(text) * 6}" height="16" as="geometry"/></mxCell>'
            )
            cx += 40 + 14 + len(text) * 6 + 22

    def render(self):
        body = "\n".join(self.cells)
        return (
            f'<mxfile host="Electron" agent="build_diagram.py">\n'
            f'<diagram id="{self.name}" name="{self.name}">\n'
            f'<mxGraphModel dx="1400" dy="900" grid="0" gridSize="10" guides="1" tooltips="1" '
            f'connect="1" arrows="1" fold="1" page="1" pageScale="1" pageWidth="{self.w}" '
            f'pageHeight="{self.h}" math="0" shadow="0">\n<root>\n<mxCell id="0"/>\n'
            f'<mxCell id="1" parent="0"/>\n{body}\n</root>\n'
            f"</mxGraphModel>\n</diagram>\n</mxfile>\n"
        )


def build(doc):
    out = BASE / f"{doc.name}.drawio"
    out.write_text(doc.render())
    print(f"wrote {out}")


# ------------------------------ the figure ------------------------------
def data_flow():
    d = Doc("data-flow", 1300, 660)
    d.title(
        40,
        28,
        1220,
        "openziti-azure-sentinel  ·  Data flow",
        "OpenZiti events into Microsoft Sentinel  ·  Service Bus sink  ·  Function  ·  "
        "Logs Ingestion API",
    )

    # one row grid: cards sit on rows y=140 / 276 / 412 so every edge is a
    # single straight run and the three zones read as aligned columns
    d.zone(40, 96, 300, 160, "OPENZITI ESTATE", EGRESS_FILL, EGRESS_BORD)
    d.zone(480, 96, 360, 440, "AZURE  ·  INGESTION", ZONE_FILL, ZONE_BORD)
    d.zone(920, 96, 340, 440, "AZURE  ·  SENTINEL WORKSPACE", ZONE_FILL, ZONE_BORD)

    # the demo deployment IS the controller (deploy_demo_controller stands one
    # up on ACI) - a sub-line, not a second component
    ctrl = d.card(
        60,
        140,
        260,
        76,
        "OpenZiti controller",
        icon="openziti",
        sub="v2.0+  ·  servicebus event sink<br>Yours, or the optional ACI demo",
    )

    sb = d.card(
        510,
        140,
        300,
        76,
        "Azure Service Bus",
        icon="servicebus",
        sub="Standard  ·  queue: openziti-events",
    )
    fn = d.card(
        510,
        276,
        300,
        76,
        "Azure Function",
        icon="function",
        sub="Python  ·  Y1 Consumption",
    )
    dcr = d.card(
        510, 412, 300, 76, "DCE + DCR", icon="dcr", sub="Ingestion-time KQL transform"
    )

    rules = d.card(
        950,
        140,
        280,
        76,
        "Sentinel content",
        icon="sentinel",
        sub="2 analytics rules  ·  workbook",
    )
    law = d.card(
        950,
        412,
        280,
        76,
        "Log Analytics workspace",
        icon="loganalytics",
        sub="OpenZitiEvents_CL  ·  Sentinel-onboarded",
    )

    # ctrl and sb share row y=140, so mid-height anchors give a straight run
    d.edge(
        ctrl,
        sb,
        NEUTRAL,
        "Events  ·  SAS Send-only",
        tag=True,
        exit_xy=(1, 0.5),
        entry_xy=(0, 0.5),
    )
    # vertical in-zone hops: tags mask the line under the label (craft rule -
    # a plain label on a vertical run has the line strike through its text)
    d.edge(
        sb,
        fn,
        NEUTRAL,
        "Service Bus trigger  ·  Listen",
        tag=True,
        exit_xy=(0.5, 1),
        entry_xy=(0.5, 0),
    )
    d.edge(
        fn,
        dcr,
        GREEN,
        "Logs Ingestion API  ·  Managed identity",
        tag=True,
        exit_xy=(0.5, 1),
        entry_xy=(0.5, 0),
    )
    # dcr and law share row y=412: straight run at mid-height
    d.edge(
        dcr,
        law,
        AZURE,
        "Projected columns",
        tag=True,
        exit_xy=(1, 0.5),
        entry_xy=(0, 0.5),
    )
    d.edge(law, rules, AZURE, "KQL", tag=True, exit_xy=(0.5, 0), entry_xy=(0.5, 1))

    d.legend(
        70,
        570,
        [
            (NEUTRAL, "SAS connection string"),
            (GREEN, "Managed identity (Entra)"),
            (AZURE, "Azure Monitor data path"),
        ],
    )
    build(d)


if __name__ == "__main__":
    data_flow()
