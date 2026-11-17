"""SVG builder for the platform diagrams (visual system v3, docs/diagrams/README.md "Visual system").

GitHub-safe: README images are rendered through <img>, so no scripts, no foreignObject, no external fonts, images or
CSS. Animation is one inline <style> with CSS @keyframes (allowed by GitHub's image CSP `style-src 'unsafe-inline'`),
switched off by `@media (prefers-reduced-motion: reduce)`. Only the numbered flow moves: every animated element is an
overlay whose static opacity is 0, so renderers without CSS animation (rsvg-convert, PDF export, reduced motion) show
the complete diagram.

Every element registers its geometry, so `check()` reports layout defects (overlaps, overflow, arrows through text or
boxes, cramped bends, arrows hugging a border, badges or chips closer than 6 px to text and borders), reading defects
(step numbers out of reading order, boxes neither on the numbered flow nor marked context, duplicate boxes, arrows
whose source is not the actor of the step text, "dials out" arrows pointing inward, jargon and placeholders in box
text) and output defects (contrast below 4.5:1, missing animation rules, unsafe SVG) before anyone looks at a PNG.
"""
from __future__ import annotations

import html
import re
import xml.etree.ElementTree as ET

W = 960                       # canvas width: GitHub's README column is 1012 px, so text renders at >= 1:1
MAX_BOXES = 12                # components per diagram (zones, notes, legend and key do not count)
MIN_TEXT = 13                 # px, every text except status chips
MIN_CHIP = 11                 # px, uppercase status chips
MIN_CONTRAST = 4.5            # WCAG AA, every text including box detail lines, chips and badge numbers
CLEAR = 6                     # px, badges and chips keep this far from text, boxes and borders
ARROW_TEXT_CLEAR = 6          # px, arrows keep this far from any text that is not their own label
HUG = 10                      # px, an arrow running parallel to a zone border keeps at least this far from it
MIN_BEND = 24                 # px, shortest inner segment of an arrow (no cramped Z-bends)
CORNER = 14                   # px, an arrow meets a box edge at least this far from its corners
ROW_TOL = 30                  # px, badges within this distance across the reading direction share a row (column)
MAX_BYTES = 80 * 1024
PLANNED_OPACITY = 0.55

SANS = "'Segoe UI','Helvetica Neue',Helvetica,Arial,'Liberation Sans',sans-serif"
MONO = "'JetBrains Mono',SFMono-Regular,Menlo,Consolas,'Liberation Mono',monospace"

BG = "#0b1120"       # opaque card, same on GitHub light and dark
BASE = "#111827"     # opaque under-fill of every box (tint goes on top)
INK = "#f8fafc"      # titles
INK2 = "#dde5ef"     # box detail lines, key text
MUTED = "#aab6c8"    # lede, legend, arrow labels, context detail
LINE = "#8b9ab0"     # structural arrows
HAIR = "#64748b"     # context box outline, dividers
ACCENT = "#fbbf24"   # the ONE accent: numbered flow (arrows, badges, motion)
CONTEXT_FILL = "#151d2c"

# plane -> (colour, legend label). Box colour = where it runs (one dimension per diagram); the accent is the flow.
PLANES = {
    "mgmt":     ("#2dd4bf", "mgmt cluster"),
    "workload": ("#38bdf8", "workload cluster"),
    "security": ("#fb7185", "security & trust"),
    "data":     ("#a78bfa", "holds state"),
    "external": ("#94a3b8", "outside the clusters"),
}
TINT = 0.16        # box fill = plane colour at this opacity over BASE
ZONE_TINT = 0.08

STATUSES = ("built", "optin", "planned")
TAGS = {"optin": "OPT-IN", "planned": "PLANNED"}

# Never in a README image (no effect in <img>, or blocked by GitHub's sanitiser/CSP).
FORBIDDEN = (r"<script", r"<foreignObject", r"\son[a-z]+=", r"@import", r"url\(\s*['\"]?https?:", r"href=\"https?:",
             r"<image\b")

# Box detail lines are for a manager: plain words. Identifiers, abbreviations and resource kinds go to the step text.
JARGON = (r"\bdp-\*", r"\bCRS\b", r"\bJWT\b", r"\bESO\b", r"\bOTel\b", r"\bOTLP\b", r"\bVAP\b", r"ApplicationSets?\b",
          r"\bAppSets?\b", r"ClusterDataPlane", r"ClusterClass", r"\bpush mode\b", r"\bSA token\b", r"\bHBONE\b",
          r"\bSPIFFE\b", r"\bCN=", r"\bPVCs?\b", r"\bCAPI\b", r"\bk8s\b", r"\bcAdvisor\b", r"\bRCA\b", r"\braft\b",
          r"\bSBOM\b", r"\bSLSA\b", r"\bFulcio\b", r"\bGHCR\b", r"\bOIDC\b", r"\bWAL\b", r"\bkube-", r"\beBPF\b")
# Anywhere on the canvas except the step key: placeholders and issue references.
PLACEHOLDER = (r"<[^>]*>", r"\(#\d+\)", r"#\d+\b")
# Titles start with a capital unless the product spells itself in lower case.
LOWER_OK = ("cert-manager", "cosign", "kgateway", "istio-csr", "k3s", "falco-response", "cluster-agent",
            "cluster-gateway")

# Advance widths (1/1000 em) of Arial/Helvetica/Liberation Sans for ASCII 32..126: what rsvg-convert uses here
# (fontconfig maps Helvetica/Arial to Liberation Sans) and close to Segoe UI / Helvetica Neue. SAFETY covers the
# wider fallbacks (Helvetica Neue +3 %, DejaVu Sans) and bold.
_ARIAL = [278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278,   # space .. /
          556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556,   # 0 .. ?
          1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778,  # @ .. O
          667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556,   # P .. _
          333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556,   # ` .. o
          556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584]        # p .. ~
_WIDE = {"→": 1000, "←": 1000, "↔": 1000, "≥": 584, "≤": 584, "·": 278, "…": 1000, "✓": 800, "½": 834, "×": 584}
SAFETY = 1.06
BOLD = 1.07


def tw(s: str, size: float, mono: bool = False, bold: bool = False, spacing: float = 0.0) -> float:
    """Estimated rendered width of s in px."""
    if mono:
        w = len(s) * 0.60 * 1.03
    else:
        w = sum(_ARIAL[ord(c) - 32] if 32 <= ord(c) <= 126 else _WIDE.get(c, 600) for c in s) / 1000 * SAFETY
        if bold:
            w *= BOLD
    return w * size + spacing * max(len(s) - 1, 0)


def _rgb(c):
    c = c.lstrip("#")
    return tuple(int(c[i:i + 2], 16) for i in (0, 2, 4))


def mix(fg: str, bg: str, a: float) -> str:
    f, b = _rgb(fg), _rgb(bg)
    return "#" + "".join(f"{int(round(b[i] + (f[i] - b[i]) * a)):02x}" for i in range(3))


def contrast(a: str, b: str) -> float:
    def lum(c):
        out = []
        for v in _rgb(c):
            v /= 255
            out.append(v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4)
        return 0.2126 * out[0] + 0.7152 * out[1] + 0.0722 * out[2]
    la, lb = sorted((lum(a), lum(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


def lighten(color: str, f: float = 0.6) -> str:
    return mix("#ffffff", color, f)


def wrap(s: str, size: float, width: float) -> list[str]:
    words, lines, cur = s.split(" "), [], ""
    for w in words:
        t = (cur + " " + w).strip()
        if cur and tw(t, size) > width:
            lines.append(cur)
            cur = w
        else:
            cur = t
    return lines + [cur] if cur else lines


class Diagram:
    def __init__(self, title: str, lede: str = "", slot: float = 1.1, reading: str = "rows"):
        """reading: "rows" (left to right, then the next row down) or "columns" (top to bottom, then the next
        column right): the order in which the step numbers must increase."""
        assert reading in ("rows", "columns"), reading
        self.w = W
        self.h = 0
        self.title, self.lede = title, lede
        self.slot = slot                      # seconds between consecutive steps lighting up
        self.reading = reading
        self.l_zones: list[str] = []
        self.l_arrows: list[str] = []
        self.l_fx: list[str] = []
        self.l_boxes: list[str] = []
        self.l_top: list[str] = []
        self.colors: set[str] = set()
        self.steps: dict[int, str] = {}       # step -> key text
        self.badges: set[int] = set()         # step numbers drawn in the diagram
        self.badge_count: dict[int, int] = {}
        self.badge_pos: dict[int, tuple] = {}
        self.fx_steps: set[int] = set()
        self.planes_used: set[str] = set()
        self.status_used: set[str] = set()
        self.legend_labels: dict[str, str] = {}
        self.has_line = False
        self.has_context = False
        self.has_both = False
        self.node_badges = False
        self.ring_steps: set[int] = set()
        self.ring_owner: dict[int, tuple] = {}
        self.line_label = "other relation"
        self.notes: list[str] = []
        self._final = False
        # bookkeeping for check()
        self.r_boxes: list[tuple[str, tuple]] = []   # (name, rect) components
        self.box_info: dict[tuple, dict] = {}        # rect -> {name, title, aka, context, lines}
        self.r_panels: list[tuple[str, tuple]] = []  # key / legend areas
        self.r_groups: list[tuple[str, tuple]] = []  # zones
        self.zone_plane: dict[tuple, str] = {}
        self.r_text: list[tuple] = []                # (text, rect, container, size, fill, bg, alpha, kind)
        self.r_ink: list[tuple] = []                 # (text, fg, bg) for text not in r_text (badge digits, chips)
        self.r_tags: list[tuple[str, tuple, tuple]] = []
        self.r_badges: list[tuple[int, tuple, tuple | None]] = []  # (n, rect, owner box)
        self.segs: list[tuple[str, tuple, tuple]] = []
        self.ends: list[tuple[str, tuple, tuple]] = []
        self.arrow_pts: dict[str, list[tuple]] = {}
        self.arrow_labels: dict[str, list[tuple]] = {}
        self.flow_arrows: dict[str, list[tuple]] = {}      # numbered-flow arrows: id -> points
        self.flow_step: dict[str, int] = {}
        self.flow_head: dict[str, bool] = {}
        self.flow_both: dict[str, bool] = {}
        self.arrow_badges: dict[str, list[tuple]] = {}     # arrow id -> [(x, y, r)] of its badges
        self.titles: list[str] = []
        self.required: list[str] = []
        self.statuses: dict[str, str] = {}
        self.layout: list[dict] = []         # exported layout data (tests read it)
        self.bottom = 0.0
        self._text(28, 46, title, 24, INK, weight=700, layer=self.l_top, kind="title")
        if lede:
            for i, ln in enumerate(wrap(lede, 14, W - 56)):
                self._text(28, 72 + i * 19, ln, 14, MUTED, layer=self.l_top, kind="lede")

    # ------------------------------------------------------------------ primitives
    def _text(self, x, y, s, size, color, weight=400, anchor="start", layer=None, container=None, mono=False,
              spacing=0.0, bg=BG, record=True, alpha=1.0, kind="text"):
        layer = self.l_boxes if layer is None else layer
        w = tw(s, size, mono=mono, bold=weight >= 600, spacing=spacing)
        x0 = x - w / 2 if anchor == "middle" else (x - w if anchor == "end" else x)
        if record:
            self.r_text.append((s, (x0, y - size * 0.78, w, size * 1.0), container, size, color, bg, alpha, kind))
        cls = "m" if mono else "s"
        attrs = f' font-weight="{weight}"' if weight != 400 else ""
        if anchor != "start":
            attrs += f' text-anchor="{anchor}"'
        if spacing:
            attrs += f' letter-spacing="{spacing}"'
        if "  " in s:
            attrs += ' xml:space="preserve"'
        layer.append(f'<text class="{cls}" x="{x:.1f}" y="{y:.1f}" font-size="{size}" fill="{color}"{attrs}>'
                     f'{html.escape(s)}</text>')

    def text(self, x, y, s, size=13, color=MUTED, weight=400, anchor="start", mono=False, spacing=0.0):
        """Free text (lane labels, notes) on the card."""
        self._text(x, y, s, size, color, weight, anchor, layer=self.l_top, mono=mono, spacing=spacing, kind="free")

    def lane(self, x, y, label, sub=(), color=INK2):
        """Lane heading: tracked caps, optionally plain lines under it."""
        self.text(x, y, label.upper(), 13, color, weight=700, spacing=1.0)
        for i, s in enumerate([sub] if isinstance(sub, str) else sub):
            self.text(x, y + 20 + i * 18, s, 13, MUTED)

    def divider(self, x1, x2, y):
        """Dashed hairline separating two lanes."""
        self.l_zones.append(f'<path d="M {x1} {y} L {x2} {y}" stroke="{HAIR}" stroke-width="1.2" '
                            f'stroke-dasharray="3 5"/>')

    def note(self, s):
        """Unnumbered sentence printed under the key (e.g. the other operations of a lifecycle)."""
        self.notes.append(s)

    def require(self, *names):
        """Component names this diagram must contain (box titles or `name=`); check() fails otherwise."""
        self.required += names

    def box(self, x, y, w, h, plane, title, lines=(), status="built", name=None, tag=None, step=None,
            title_size=15, line_size=13, context=False, aka=()):
        """Component. lines: detail lines in plain words; a line wrapped in backticks is set in the mono face.

        status: built (solid) | optin (dashed + OPT-IN chip) | planned (dimmed, dashed, PLANNED chip).
        context: not on the numbered flow; drawn neutral and quiet, listed in the legend as context.
        step: ring badge left of the text = a step that happens at this component.
        aka: other names the step texts use for this component (for the actor check).
        """
        assert status in STATUSES, status
        if context:
            color, fill, stroke, sw = HAIR, CONTEXT_FILL, HAIR, 1.2
            tcol, lcol = INK2, MUTED
            self.has_context = True
        else:
            color = PLANES[plane][0]
            fill, stroke, sw = mix(color, BASE, TINT), color, 1.5
            tcol, lcol = INK, INK2
            self.planes_used.add(plane)
        if status != "built":
            self.status_used.add(status)
        alpha = PLANNED_OPACITY if status == "planned" else 1.0
        dash = ' stroke-dasharray="6 4"' if status != "built" else ""
        out = [f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8" fill="{fill}" stroke="{stroke}" '
               f'stroke-width="{sw}"{dash}/>']
        rect = (x, y, w, h)
        lh = line_size + 5
        span = 0.72 * title_size + (len(lines) * lh + 2 if lines else 0)
        ty = y + h / 2 - span / 2 + 0.72 * title_size
        cx = x + w / 2
        widths = [tw(title, title_size, bold=True)] + [
            tw(ln.strip("`"), line_size, mono=ln.startswith("`")) for ln in lines]
        block = max(widths)
        if step is not None:            # a ring badge sits left of the text block: shift the block right
            cx += max(0, (x + 48) - (cx - block / 2))
        self._text(cx, ty, title, title_size, tcol, weight=600, anchor="middle", container=rect, layer=out, bg=fill,
                   alpha=alpha, kind="title")
        yy = ty + 2
        for ln in lines:
            mono = ln.startswith("`") and ln.endswith("`")
            s = ln.strip("`") if mono else ln
            yy += lh
            self._text(cx, yy, s, line_size, lcol, anchor="middle", container=rect, layer=out, mono=mono, bg=fill,
                       alpha=alpha, kind="line")
        chip = tag or TAGS.get(status)
        if chip:
            cs, sp = MIN_CHIP, 0.6
            cw = tw(chip, cs, bold=True, spacing=sp) + 14
            chx, chy = x + w - cw - 12, y - 17 - CLEAR
            out.append(f'<rect x="{chx:.1f}" y="{chy}" width="{cw:.1f}" height="17" rx="8.5" fill="{BG}" '
                       f'stroke="{color}" stroke-width="1"/>')
            out.append(f'<text class="s" x="{chx + cw / 2:.1f}" y="{chy + 12.5}" font-size="{cs}" font-weight="700" '
                       f'fill="{color}" text-anchor="middle" letter-spacing="{sp}">{html.escape(chip)}</text>')
            self.r_tags.append((chip, (chx, chy, cw, 17), rect))
            self.r_ink.append((chip, color, BG, alpha))
        if status == "planned":
            out = [f'<g opacity="{PLANNED_OPACITY}">'] + out + ["</g>"]
        self.l_boxes += out
        if step is not None:            # step at a component: ring badge left of the text block, vertically centred
            self.badge(cx - block / 2 - 24, y + h / 2, step, owner=rect, ring=True)
        self.r_boxes.append((name or title, rect))
        self.box_info[rect] = {"name": name or title, "title": title, "aka": tuple(aka), "context": context,
                               "lines": list(lines)}
        self.titles.append(title)
        self.statuses[name or title] = status
        self.layout.append({"kind": "box", "name": name or title, "title": title, "lines": list(lines),
                            "rect": rect, "plane": plane, "status": status, "context": context})
        self.bottom = max(self.bottom, y + h)
        return rect

    def zone(self, x, y, w, h, label, plane="external", dash=None, label_at="tl"):
        """Boundary: a cluster, a trust zone or a column. Label: tracked caps inside the top-left (tl) or top-right
        (tr) corner; put it where no arrow crosses the border."""
        color = PLANES[plane][0]
        dd = f' stroke-dasharray="{dash}"' if dash else ""
        zfill = mix(color, BG, ZONE_TINT)
        self.l_zones.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="14" fill="{zfill}" '
                            f'stroke="{color}" stroke-opacity=".8" stroke-width="1.3"{dd}/>')
        if label:
            if label_at == "tr":
                self._text(x + w - 16, y + 24, label.upper(), 13, color, weight=700, anchor="end",
                           layer=self.l_zones, container=(x, y, w, h), spacing=1.0, bg=zfill, kind="zone")
            else:
                self._text(x + 16, y + 24, label.upper(), 13, color, weight=700,
                           layer=self.l_zones, container=(x, y, w, h), spacing=1.0, bg=zfill, kind="zone")
        self.r_groups.append((label, (x, y, w, h)))
        self.zone_plane[(x, y, w, h)] = plane
        self.layout.append({"kind": "zone", "name": label, "rect": (x, y, w, h)})
        self.bottom = max(self.bottom, y + h)

    def junction(self, x, y, flow=True):
        """Dot where an arrow forks or joins (accent on the numbered flow, grey otherwise)."""
        self.l_top.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="3.6" fill="{ACCENT if flow else LINE}"/>')

    def _marker(self, color):
        self.colors.add(color)
        return f"url(#ah{color.lstrip('#')})"

    def arrow(self, pts, step=None, status="built", label=None, label_pos=None, label_anchor="middle", aid=None,
              both=False, badge=True, badge_at=None, loose=False, head=True):
        """Arrow pts[0] -> pts[-1] (orthogonal polyline), from the component that acts (opens the connection,
        writes, sends) to the one it acts on. With `step` it is part of the numbered flow: accent colour, animated
        overlay, badge (on the longest segment at `badge_at`, or at `badge=(x, y)`). Without, a neutral line.
        status: built (solid) | optin (dashed) | planned (dimmed dashed). loose=True: endpoints need not be on a box.
        both=True: a request with a reply (heads on both ends).
        """
        assert status in STATUSES, status
        if status != "built":
            self.status_used.add(status)
        aid = aid or f"a{len(self.segs)}"
        pts = [tuple(p) for p in pts]
        color = ACCENT if step is not None else LINE
        self.has_line = self.has_line or step is None
        self.has_both = self.has_both or (both and step is not None)
        width = 2.4 if step is not None else 1.6
        d = "M " + " L ".join(f"{px:.1f} {py:.1f}" for px, py in pts)
        dash = ' stroke-dasharray="7 5"' if status != "built" else ""
        dim = f' opacity="{PLANNED_OPACITY}"' if status == "planned" else ""
        ms = f' marker-start="{self._marker(color).replace("#ah", "#as")}"' if both else ""
        me = f' marker-end="{self._marker(color)}"' if head else ""
        self.l_arrows.append(f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{width}" '
                             f'stroke-linejoin="round"{dash}{dim}{me}{ms}/>')
        if step is not None and status != "planned":
            self._fx(d, step)
        for p1, p2 in zip(pts, pts[1:]):
            self.segs.append((aid, p1, p2))
        self.arrow_pts[aid] = pts
        self.bottom = max([self.bottom] + [py for _, py in pts])
        if step is not None:
            self.flow_arrows[aid] = pts
            self.flow_step[aid] = step
            self.flow_head[aid] = head
            self.flow_both[aid] = both
        if not loose:
            self.ends.append((aid, pts[0], pts[-1]))
        if label:
            lx, ly = label_pos
            self.label(lx, ly, label, anchor=label_anchor, owner=aid)
        if step is not None and isinstance(badge, tuple):
            self.badge(badge[0], badge[1], step, owner=None, arrow=aid)
        elif step is not None and badge:
            segs = list(zip(pts, pts[1:]))
            i = max(range(len(segs)), key=lambda k: abs(segs[k][1][0] - segs[k][0][0]) + abs(segs[k][1][1] - segs[k][0][1]))
            (ax, ay), (bx, by) = segs[i]
            f = badge_at if badge_at is not None else 0.5
            self.badge(ax + (bx - ax) * f, ay + (by - ay) * f, step, owner=None, arrow=aid)
        self.layout.append({"kind": "arrow", "id": aid, "points": [tuple(p) for p in pts], "step": step})
        return aid

    def _fx(self, d, step, layer=None):
        self.fx_steps.add(step)
        delay = (step - 1) * self.slot
        (self.l_fx if layer is None else layer).append(
            f'<path class="fx" d="{d}" stroke="{lighten(ACCENT)}" style="animation-delay:0s,{delay:.2f}s"/>')

    def label(self, x, y, s, size=13, anchor="middle", owner=None):
        """Arrow label on an opaque backing so crossing lines never hide it."""
        w = tw(s, size)
        x0 = x - w / 2 if anchor == "middle" else (x - w if anchor == "end" else x)
        self.l_top.append(f'<rect x="{x0 - 4:.1f}" y="{y - size - 1:.1f}" width="{w + 8:.1f}" height="{size + 7:.1f}" '
                          f'rx="3" fill="{BG}"/>')
        self._text(x, y, s, size, MUTED, anchor=anchor, layer=self.l_top, kind="label")
        if owner:
            self.arrow_labels.setdefault(owner, []).append(self.r_text[-1][1])

    def badge(self, x, y, n, owner=None, arrow=None, r=12, ring=False):
        """Numbered step marker: accent disc on a flow arrow; accent ring = a step that happens at a component."""
        self.badges.add(n)
        self.badge_count[n] = self.badge_count.get(n, 0) + 1
        self.badge_pos[n] = (x, y)
        fs = 12 if n > 9 else 13
        if ring:
            self.node_badges = True
            self.ring_steps.add(n)
            self.ring_owner[n] = owner
            self.l_top.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{r - 1}" fill="{BG}" stroke="{ACCENT}" '
                              f'stroke-width="2.4"/>')
            self.l_top.append(f'<text class="s" x="{x:.1f}" y="{y + 4.6:.1f}" font-size="{fs}" '
                              f'font-weight="700" fill="{ACCENT}" text-anchor="middle">{n}</text>')
            self.r_ink.append((str(n), ACCENT, BG, 1.0))
        else:
            self.l_top.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{r}" fill="{ACCENT}" stroke="{BG}" '
                              f'stroke-width="2"/>')
            self.l_top.append(f'<text class="s" x="{x:.1f}" y="{y + 4.6:.1f}" font-size="{fs}" font-weight="700" '
                              f'fill="{BG}" text-anchor="middle">{n}</text>')
            self.r_ink.append((str(n), BG, ACCENT, 1.0))
        rect = (x - r, y - r, 2 * r, 2 * r)
        self.r_badges.append((n, rect, owner))
        self.bottom = max(self.bottom, y + r)
        if arrow:
            self.arrow_labels.setdefault(arrow, []).append(rect)
            self.arrow_badges.setdefault(arrow, []).append((x, y, r))

    def key(self, *steps: str):
        """Numbered step texts (1..n). They must match the diagram's section in docs/diagrams/README.md."""
        for i, s in enumerate(steps, 1):
            self.steps[i] = s

    def legend_label(self, plane: str, label: str):
        self.legend_labels[plane] = label

    # ------------------------------------------------------------------ key + legend (below the content)
    def _finalize(self):
        if self._final:
            return
        self._final = True
        y = self.bottom + 36
        self.l_top.append(f'<line x1="28" y1="{y - 14}" x2="{W - 28}" y2="{y - 14}" stroke="{HAIR}" stroke-width="1.2"/>')
        y0 = y
        # numbered key: one column, in step order (reads like the diagram: top to bottom)
        cy = y + 14
        tx = 28 + 34
        for n, st in sorted(self.steps.items()):
            lines = wrap(st, 13.5, W - 28 - tx)
            if n in self.ring_steps:
                self.l_top.append(f'<circle cx="40" cy="{cy - 4.5}" r="10" fill="{BG}" stroke="{ACCENT}" '
                                  f'stroke-width="2.2"/>')
            else:
                self.l_top.append(f'<circle cx="40" cy="{cy - 4.5}" r="11" fill="{ACCENT}"/>')
            self.l_top.append(f'<text class="s" x="40" y="{cy}" font-size="{12 if n > 9 else 13}" '
                              f'font-weight="700" fill="{ACCENT if n in self.ring_steps else BG}" '
                              f'text-anchor="middle">{n}</text>')
            for k, ln in enumerate(lines):
                self._text(tx, cy + k * 19, ln, 13.5, INK2, layer=self.l_top, kind="key")
            cy += len(lines) * 19 + 9
        for s in self.notes:
            for k, ln in enumerate(wrap(s, 13.5, W - 56)):
                self._text(28, cy + 4 + k * 19, ln, 13.5, MUTED, layer=self.l_top, kind="key")
            cy += len(wrap(s, 13.5, W - 56)) * 19 + 9
        y = cy + 4 if (self.steps or self.notes) else y
        if self.steps:
            self.r_panels.append(("key", (24, y0 - 10, W - 48, y - y0)))
        # legend: only what this diagram uses
        entries: list[tuple[str, str]] = []
        for p in PLANES:
            if p in self.planes_used:
                entries.append((p, self.legend_labels.get(p, PLANES[p][1])))
        if self.fx_steps or self.badges:
            entries.append(("flow", "numbered step"))
        if self.node_badges:
            entries.append(("node", "step inside a component"))
        if self.has_both:
            entries.append(("both", "request and reply"))
        if self.has_line:
            entries.append(("line", self.line_label))
        if self.has_context:
            entries.append(("context", "context, not a step"))
        for s in ("optin", "planned"):
            if s in self.status_used:
                entries.append((s, {"optin": "opt-in (off by default)", "planned": "planned (not on main)"}[s]))
        x, ly = 28, y + 18
        for t, lab in entries:
            sw = 36 if t in ("flow", "both", "optin") else 22
            wlab = tw(lab, 13)
            if x + sw + 8 + wlab > W - 28:
                x, ly = 28, ly + 26
            if t in PLANES:
                c = PLANES[t][0]
                self.l_top.append(f'<rect x="{x}" y="{ly - 10}" width="20" height="13" rx="3" '
                                  f'fill="{mix(c, BASE, TINT)}" stroke="{c}" stroke-width="1.4"/>')
            elif t == "flow":
                dd = f"M {x - 2} {ly - 4} L {x + 34} {ly - 4}"
                self.l_top.append(f'<path d="{dd}" stroke="{ACCENT}" stroke-width="2.4" '
                                  f'marker-end="{self._marker(ACCENT)}"/>')
                self.l_top.append(f'<circle cx="{x + 12}" cy="{ly - 4}" r="7" fill="{ACCENT}" stroke="{BG}" '
                                  f'stroke-width="1.5"/>')
            elif t == "both":
                dd = f"M {x + 2} {ly - 4} L {x + 34} {ly - 4}"
                self.l_top.append(f'<path d="{dd}" stroke="{ACCENT}" stroke-width="2.4" '
                                  f'marker-end="{self._marker(ACCENT)}" '
                                  f'marker-start="{self._marker(ACCENT).replace("#ah", "#as")}"/>')
            elif t == "line":
                self.l_top.append(f'<path d="M {x - 2} {ly - 4} L {x + 20} {ly - 4}" stroke="{LINE}" '
                                  f'stroke-width="1.6" marker-end="{self._marker(LINE)}"/>')
            elif t == "context":
                self.l_top.append(f'<rect x="{x}" y="{ly - 10}" width="20" height="13" rx="3" fill="{CONTEXT_FILL}" '
                                  f'stroke="{HAIR}" stroke-width="1.2"/>')
            elif t in ("optin", "planned"):
                op = f' opacity="{PLANNED_OPACITY}"' if t == "planned" else ""
                self.l_top.append(f'<rect x="{x}" y="{ly - 10}" width="34" height="13" rx="3" fill="none" '
                                  f'stroke="{INK2}" stroke-width="1.3" stroke-dasharray="5 3"{op}/>')
            elif t == "node":
                self.l_top.append(f'<circle cx="{x + 10}" cy="{ly - 4}" r="8" fill="{BG}" stroke="{ACCENT}" '
                                  f'stroke-width="2.2"/>')
            self._text(x + sw + 8, ly, lab, 13, MUTED, layer=self.l_top, kind="legend")
            x += sw + 8 + wlab + 26
        self.r_panels.append(("legend", (24, y, W - 48, ly + 10 - y)))
        self.h = int(ly + 26)

    # ------------------------------------------------------------------ checks
    @staticmethod
    def _ov(a, b, pad=0.0):
        ax, ay, aw, ah = a
        bx, by, bw, bh = b
        return ax < bx + bw - pad and bx < ax + aw - pad and ay < by + bh - pad and by < ay + ah - pad

    @staticmethod
    def _inside(a, b, tol=0.5):
        ax, ay, aw, ah = a
        bx, by, bw, bh = b
        return ax >= bx - tol and ay >= by - tol and ax + aw <= bx + bw + tol and ay + ah <= by + bh + tol

    @staticmethod
    def _grow(r, d):
        return (r[0] - d, r[1] - d, r[2] + 2 * d, r[3] + 2 * d)

    @staticmethod
    def _on_edge(p, r, tol=3.0):
        x, y = p
        rx, ry, rw, rh = r
        if not (rx - tol <= x <= rx + rw + tol and ry - tol <= y <= ry + rh + tol):
            return False
        return min(abs(x - rx), abs(x - rx - rw), abs(y - ry), abs(y - ry - rh)) <= tol

    @staticmethod
    def _contains(r, p):
        return r[0] < p[0] < r[0] + r[2] and r[1] < p[1] < r[1] + r[3]

    @staticmethod
    def _seg_hits(p1, p2, r, shrink=1.0):
        (x1, y1), (x2, y2) = p1, p2
        rx, ry, rw, rh = r[0] + shrink, r[1] + shrink, r[2] - 2 * shrink, r[3] - 2 * shrink
        if rw <= 0 or rh <= 0:
            return False
        dx, dy = x2 - x1, y2 - y1
        t0, t1 = 0.0, 1.0
        for p, q in ((-dx, x1 - rx), (dx, rx + rw - x1), (-dy, y1 - ry), (dy, ry + rh - y1)):
            if p == 0:
                if q < 0:
                    return False
            else:
                t = q / p
                if p < 0:
                    t0 = max(t0, t)
                else:
                    t1 = min(t1, t)
                if t0 > t1:
                    return False
        return t1 - t0 > 1e-6

    def _box_at(self, p):
        for _, b in self.r_boxes:
            if self._on_edge(p, b):
                return b
        return None

    def _first_box(self, text):
        """The component a step text names first (its grammatical actor): title, name= or aka, whole words."""
        t, best = text.lower(), None
        for rect, i in self.box_info.items():
            for nm in {i["title"], i["name"], *i["aka"]}:
                m = re.search(r"(?<![a-z0-9])" + re.escape(nm.lower()) + r"(?![a-z0-9])", t)
                if m and (best is None or (m.start(), -len(nm)) < best[0]):
                    best = ((m.start(), -len(nm)), rect)
        return best[1] if best else None

    def _border_clear(self, r, g, d):
        """True when rect r keeps d px from the border of zone g (fully inside with margin, or fully outside)."""
        inner = (g[0] + d, g[1] + d, g[2] - 2 * d, g[3] - 2 * d)
        return self._inside(r, inner, tol=0) or not self._ov(r, self._grow(g, d))

    def check(self):
        """Layout checks on the registered geometry + output checks on the rendered SVG string."""
        self._finalize()
        issues = []

        def touches(p, other):
            pts = self.flow_arrows[other]
            return any(self._seg_hits(p, p, (min(a[0], b[0]) - .6, min(a[1], b[1]) - .6,
                                              abs(b[0] - a[0]) + 1.2, abs(b[1] - a[1]) + 1.2), shrink=0)
                       for a, b in zip(pts, pts[1:]))
        n_boxes = len(self.r_boxes)
        if n_boxes > MAX_BOXES:
            issues.append(f"{n_boxes} boxes > {MAX_BOXES}: split the diagram")
        seen = {}
        for t in self.titles:
            k = t.lower()
            if k in seen:
                issues.append(f"duplicate component box: {t!r} (one box per component; show the other role in text)")
            seen[k] = True
            if t[:1].islower() and not any(t.lower().startswith(p) for p in LOWER_OK):
                issues.append(f"box title not capitalised: {t!r}")
        for i, (na, a) in enumerate(self.r_boxes):
            for nb, b in self.r_boxes[i + 1:]:
                if self._ov(a, b, pad=-6):   # boxes keep >= 6 px apart
                    issues.append(f"boxes overlap or touch (< 6 px): {na!r} x {nb!r}")
            if a[0] < 16 or a[1] < 0 or a[0] + a[2] > self.w - 16 or a[1] + a[3] > self.h:
                issues.append(f"box outside the card: {na!r} {a}")
        for ng, g in self.r_groups:
            if g[0] < 16 or g[1] < 0 or g[0] + g[2] > self.w - 16 or g[1] + g[3] > self.h - 8:
                issues.append(f"zone outside the card: {ng!r} {g}")
            for nb, b in self.r_boxes:     # a box is inside a zone or clear of it, never across its border
                if self._ov(b, g) and not self._inside(b, g):
                    issues.append(f"box {nb!r} crosses the border of zone {ng!r}")
        # --- text
        for s, r, c, size, fill, bg, alpha, kind in self.r_text:
            if c and not self._inside(r, (c[0] + 8, c[1] + 3, c[2] - 16, c[3] - 6)):
                issues.append(f"text overflows its box (8 px padding): {s!r}")
            if r[0] < 20 or r[0] + r[2] > self.w - 20:
                issues.append(f"text outside the card: {s!r}")
            if size < MIN_TEXT:
                issues.append(f"text below {MIN_TEXT} px: {s!r} ({size})")
            fg_e, bg_e = (mix(fill, BG, alpha), mix(bg, BG, alpha)) if alpha < 1 else (fill, bg)
            ratio = contrast(fg_e, bg_e)
            if ratio < MIN_CONTRAST:
                issues.append(f"text contrast {ratio:.2f} < {MIN_CONTRAST}: {s!r}")
            if kind != "key":
                for pat in PLACEHOLDER:
                    if re.search(pat, s):
                        issues.append(f"placeholder or issue reference on the canvas: {s!r} (put it in the docs)")
            if kind == "line":
                for pat in JARGON:
                    if re.search(pat, s):
                        issues.append(f"jargon in a box detail line: {s!r} ({pat}); say it plainly, "
                                      f"name it in the step text")
        for s, fg, bg, alpha in self.r_ink:
            fg_e, bg_e = (mix(fg, BG, alpha), mix(bg, BG, alpha)) if alpha < 1 else (fg, bg)
            ratio = contrast(fg_e, bg_e)
            if ratio < MIN_CONTRAST:
                issues.append(f"text contrast {ratio:.2f} < {MIN_CONTRAST}: chip or badge {s!r}")
        for n, st in self.steps.items():
            if re.search(r"\(#\d+\)", st):
                issues.append(f"step {n} cites an issue number: link issues in the docs, not in the diagram")
        for i, (sa, a, *_r) in enumerate(self.r_text):
            for sb, b, *_q in self.r_text[i + 1:]:
                if self._ov(a, b, pad=0.5):
                    issues.append(f"text overlap: {sa!r} x {sb!r}")
        for s, r, c, *_r in self.r_text:
            for nb, b in self.r_boxes:
                if c != b and self._ov(r, b):
                    issues.append(f"text {s!r} overlaps box {nb!r}")
        # --- badges: >= CLEAR px from text, boxes (or inside their own box with CLEAR margin), chips, zone borders
        for n, r, owner in self.r_badges:
            for s, tr, *_r in self.r_text:
                if self._ov(r, tr, pad=-CLEAR):
                    issues.append(f"badge {n} is closer than {CLEAR} px to text {s!r}")
            for nb, b in self.r_boxes:
                if b == owner:
                    if not self._inside(r, self._grow(b, -CLEAR), tol=0):
                        issues.append(f"ring badge {n} is closer than {CLEAR} px to the border of {nb!r}")
                elif self._ov(r, b, pad=-CLEAR):
                    issues.append(f"badge {n} is closer than {CLEAR} px to box {nb!r}")
            for t, tr, _ in self.r_tags:
                if self._ov(r, tr, pad=-CLEAR):
                    issues.append(f"badge {n} is closer than {CLEAR} px to chip {t!r}")
            for ng, g in self.r_groups:
                if not self._border_clear(r, g, CLEAR):
                    issues.append(f"badge {n} is closer than {CLEAR} px to the border of zone {ng!r}")
        for i, (na, a, _o) in enumerate(self.r_badges):
            for nb, b, _p in self.r_badges[i + 1:]:
                if self._ov(a, b, pad=-CLEAR):
                    issues.append(f"badges {na} and {nb} closer than {CLEAR} px")
        # --- chips: >= CLEAR px from text, other boxes, zone borders
        for t, r, owner in self.r_tags:
            for s, tr, *_r in self.r_text:
                if self._ov(r, tr, pad=-CLEAR):
                    issues.append(f"chip {t!r} is closer than {CLEAR} px to text {s!r}")
            for nb, b in self.r_boxes:
                if b != owner and self._ov(r, b, pad=-CLEAR):
                    issues.append(f"chip {t!r} is closer than {CLEAR} px to box {nb!r}")
                if b == owner and self._ov(r, b, pad=-CLEAR + 0.5):
                    issues.append(f"chip {t!r} touches its box {nb!r}")
            for ng, g in self.r_groups:
                if not self._border_clear(r, g, CLEAR):
                    issues.append(f"chip {t!r} is closer than {CLEAR} px to the border of zone {ng!r}")
        # --- arrows
        for aid, p1, p2 in self.segs:
            own = self.arrow_labels.get(aid, [])
            for s, r, *_r in self.r_text:
                if r in own:
                    continue
                if self._seg_hits(p1, p2, self._grow(r, ARROW_TEXT_CLEAR), shrink=0):
                    issues.append(f"arrow {aid} passes within {ARROW_TEXT_CLEAR} px of text {s!r}")
            for t, r, _ in self.r_tags:
                if self._seg_hits(p1, p2, self._grow(r, 2), shrink=0):
                    issues.append(f"arrow {aid} crosses chip {t!r}")
            for n, r, _o in self.r_badges:
                if r not in own and self._seg_hits(p1, p2, r, shrink=1):
                    issues.append(f"arrow {aid} crosses badge {n}")
            for nb, b in self.r_boxes:
                if self._seg_hits(p1, p2, b, shrink=2.5):
                    issues.append(f"arrow {aid} passes through box {nb!r}")
            for ng, (gx, gy, gw, gh) in self.r_groups:   # no arrow runs along a zone border
                (x1, y1), (x2, y2) = p1, p2
                if y1 == y2 and max(x1, x2) > gx and min(x1, x2) < gx + gw:
                    if min(abs(y1 - gy), abs(y1 - gy - gh)) < HUG:
                        issues.append(f"arrow {aid} runs along the border of zone {ng!r} (< {HUG} px)")
                if x1 == x2 and max(y1, y2) > gy and min(y1, y2) < gy + gh:
                    if min(abs(x1 - gx), abs(x1 - gx - gw)) < HUG:
                        issues.append(f"arrow {aid} runs along the border of zone {ng!r} (< {HUG} px)")
        for aid, pts in self.arrow_pts.items():
            segs = list(zip(pts, pts[1:]))
            for i, ((x1, y1), (x2, y2)) in enumerate(segs[1:-1], 1):
                if abs(x2 - x1) + abs(y2 - y1) < MIN_BEND:
                    issues.append(f"arrow {aid} has a cramped bend (segment {i} is "
                                  f"{abs(x2 - x1) + abs(y2 - y1):.0f} px < {MIN_BEND})")
        rects = [b for _, b in self.r_boxes] + [g for _, g in self.r_groups]
        for aid, p0, p1 in self.ends:
            for which, p in (("start", p0), ("end", p1)):
                if aid in self.flow_arrows and any(o != aid and self.flow_step[o] == self.flow_step[aid]
                                                   and touches(p, o) for o in self.flow_arrows):
                    continue
                if not any(self._on_edge(p, r) for r in rects):
                    issues.append(f"arrow {aid} {which} {p} is not on a box or zone edge")
                b = self._box_at(p)
                if b:
                    x, y = p
                    on_h = abs(y - b[1]) <= 3 or abs(y - b[1] - b[3]) <= 3
                    d = min(x - b[0], b[0] + b[2] - x) if on_h else min(y - b[1], b[1] + b[3] - y)
                    if d < CORNER:
                        issues.append(f"arrow {aid} {which} meets {self.box_info[b]['name']!r} "
                                      f"{d:.0f} px from a corner (< {CORNER})")
        for pn, pr in self.r_panels:
            for ng, g in self.r_groups:
                if self._ov(pr, g):
                    issues.append(f"{pn} overlaps zone {ng!r}")
            for nb, b in self.r_boxes:
                if self._ov(pr, b):
                    issues.append(f"{pn} overlaps box {nb!r}")
        # --- numbered steps: consecutive from 1, every badge has a key entry and every entry a badge
        if self.steps and sorted(self.steps) != list(range(1, len(self.steps) + 1)):
            issues.append(f"key steps are not 1..n: {sorted(self.steps)}")
        for n, k in sorted(self.badge_count.items()):
            if k > 1:
                issues.append(f"step {n} has {k} badges (one per step: fork or join the arrows instead)")
        for n in sorted(self.badges - set(self.steps)):
            issues.append(f"badge {n} has no key entry")
        for n in sorted(set(self.steps) - self.badges):
            issues.append(f"key step {n} has no badge in the diagram")
        # --- reading order: each step's badge comes after the previous one (same row: further right; else lower)
        order = sorted(n for n in self.badge_pos if n in self.steps)
        for a, b in zip(order, order[1:]):
            (ax, ay), (bx, by) = self.badge_pos[a], self.badge_pos[b]
            if self.reading == "columns":
                ax, ay, bx, by = ay, ax, by, bx
            across, along = by - ay, bx - ax
            if across < -ROW_TOL or (abs(across) <= ROW_TOL and along <= 0):
                issues.append(f"step {b} reads before step {a} ({self.reading}: left to right, top to bottom)")
        # --- every box is on the numbered flow or marked context
        on_flow = set()
        for aid, pts in self.flow_arrows.items():
            for p in (pts[0], pts[-1]):
                b = self._box_at(p)
                if b:
                    on_flow.add(b)
        on_flow |= {o for o in self.ring_owner.values() if o}
        for rect, info in self.box_info.items():
            if info["context"] and rect in on_flow:
                issues.append(f"box {info['name']!r} is marked context but is on the numbered flow")
            if not info["context"] and rect not in on_flow:
                issues.append(f"box {info['name']!r} is not on the numbered flow: connect it or mark it context")
        # --- the arrow starts at the actor of its step text (the first component the text names); "dials out"
        # arrows start inside a cluster and point out of it
        for n, st in sorted(self.steps.items()):
            arrows = [a for a in self.flow_arrows if self.flow_step[a] == n]
            srcs = {self._box_at(self.flow_arrows[a][0]) for a in arrows} - {None}
            if any(self.flow_both[a] for a in arrows):
                srcs |= {self._box_at(self.flow_arrows[a][-1]) for a in arrows} - {None}
            if self.ring_owner.get(n):
                srcs.add(self.ring_owner[n])
            if not srcs:
                continue
            actor = self._first_box(st)
            if actor is None:
                issues.append(f"step {n}: the text names no component; start it with the actor "
                              f"({', '.join(self.box_info[b]['title'] for b in srcs)})")
            elif actor not in srcs:
                issues.append(f"step {n}: the text's actor is {self.box_info[actor]['title']!r} but the arrow starts "
                              f"at {', '.join(self.box_info[b]['title'] for b in srcs)}: arrows point from the actor")
            if re.search(r"\bdials? out\b", st, re.I):
                for a in arrows:
                    p0, p1 = self.flow_arrows[a][0], self.flow_arrows[a][-1]
                    zs = [g for _, g in self.r_groups if self._contains(g, p0)]
                    if not zs or any(self._contains(g, p1) for g in zs):
                        issues.append(f"step {n} dials out, but arrow {a} does not start inside a cluster and "
                                      f"point out of it")
        # --- numbered flow: every accent arrow carries its badge, with visible shaft on both sides of it
        def linked(aid):    # arrows of the same step sharing a junction with this one
            st, pts = self.flow_step[aid], self.flow_arrows[aid]
            return [o for o in self.flow_arrows if o != aid and self.flow_step[o] == st
                    and (touches(pts[0], o) or touches(pts[-1], o)
                         or any(touches(q, aid) for q in (self.flow_arrows[o][0], self.flow_arrows[o][-1])))]

        for aid, pts in self.flow_arrows.items():
            bs = self.arrow_badges.get(aid, [])
            group, todo = {aid}, [aid]
            while todo:
                for o in linked(todo.pop()):
                    if o not in group:
                        group.add(o)
                        todo.append(o)
            if not any(self.arrow_badges.get(o) for o in group):
                issues.append(f"flow arrow {aid} has no badge (every numbered flow shows its number)")
            for bx, by, r in bs:
                segs = list(zip(pts, pts[1:]))
                for i, ((x1, y1), (x2, y2)) in enumerate(segs):
                    on = (min(x1, x2) - .5 <= bx <= max(x1, x2) + .5) and (min(y1, y2) - .5 <= by <= max(y1, y2) + .5)
                    if not on:
                        continue
                    d_start = abs(bx - x1) + abs(by - y1)
                    d_end = abs(x2 - bx) + abs(y2 - by)
                    need_end = r + (26 if i == len(segs) - 1 and self.flow_head.get(aid, True) else 8)
                    need_start = r + (26 if i == 0 and self.flow_both.get(aid) else (18 if i == 0 else 8))
                    if d_start < need_start or d_end < need_end:
                        issues.append(f"badge on flow arrow {aid} hides the shaft or arrowhead "
                                      f"(segment {i}: {d_start:.0f}/{d_end:.0f} px either side)")
                    break
                else:
                    issues.append(f"badge of flow arrow {aid} is not on the arrow")
        # flow arrows never cross each other
        flow_segs = [(a, p1, p2) for a, pts in self.flow_arrows.items() for p1, p2 in zip(pts, pts[1:])]
        for i, (a, (ax1, ay1), (ax2, ay2)) in enumerate(flow_segs):
            for b, (bx1, by1), (bx2, by2) in flow_segs[i + 1:]:
                if a == b:
                    continue
                if ay1 == ay2 and bx1 == bx2:      # a horizontal, b vertical
                    hx1, hx2, hy, vx, vy1, vy2 = min(ax1, ax2), max(ax1, ax2), ay1, bx1, min(by1, by2), max(by1, by2)
                elif ax1 == ax2 and by1 == by2:
                    hx1, hx2, hy, vx, vy1, vy2 = min(bx1, bx2), max(bx1, bx2), by1, ax1, min(ay1, ay2), max(ay1, ay2)
                else:
                    continue
                if hx1 + 1 < vx < hx2 - 1 and vy1 + 1 < hy < vy2 - 1:
                    issues.append(f"flow arrows {a} and {b} cross at ({vx:.0f}, {hy:.0f})")
        names_all = {n for n, _ in self.r_boxes} | set(self.titles)
        for n in self.required:
            if n not in names_all:
                issues.append(f"required component missing: {n!r}")
        issues += self.check_svg(self.svg())
        return issues

    def check_svg(self, svg: str):
        issues = []
        size = len(svg.encode())
        if size > MAX_BYTES:
            issues.append(f"svg is {size / 1024:.1f} KB > {MAX_BYTES // 1024} KB")
        try:
            root = ET.fromstring(svg)
        except ET.ParseError as e:  # pragma: no cover - would be a generator bug
            return issues + [f"svg is not well-formed XML: {e}"]
        for pat in FORBIDDEN:
            if re.search(pat, svg, re.I):
                issues.append(f"forbidden in a README image: {pat}")
        ns = "{http://www.w3.org/2000/svg}"
        texts = {html.unescape("".join(t.itertext())) for t in root.iter(f"{ns}text")}
        for t in self.titles:
            if t not in texts:
                issues.append(f"box label not rendered: {t!r}")
        style = "".join("".join(s.itertext()) for s in root.iter(f"{ns}style"))
        used = {n.strip().split()[0] for m in re.findall(r"animation\s*:\s*([^;}]+)", style) for n in m.split(",")}
        defined = set(re.findall(r"@keyframes\s+([\w-]+)", style))
        if not defined:
            issues.append("no @keyframes")
        for n in sorted(used - defined - {"none"}):
            issues.append(f"animation {n!r} has no @keyframes")
        if not re.search(r"@media\s*\(\s*prefers-reduced-motion\s*:\s*reduce\s*\)\s*\{[^}]*animation\s*:\s*none",
                         style):
            issues.append("no prefers-reduced-motion rule disabling animation")
        if self.fx_steps and 'class="fx"' not in svg:
            issues.append("numbered flow but no animated overlay")
        return issues

    # ------------------------------------------------------------------ output
    def css(self):
        n = max(self.fx_steps) if self.fx_steps else 1
        period = n * self.slot + 2.5          # one pass over every step, then a short rest
        on = min(2.4 * self.slot / period * 100, 60)
        return (
            f".s{{font-family:{SANS}}}.m{{font-family:{MONO}}}"
            ".fx{fill:none;stroke-width:3.4;stroke-linecap:round;stroke-dasharray:4 10;opacity:0;"
            f"animation:fxdash .9s linear infinite,fxseq {period:.2f}s linear infinite both}}"
            "@keyframes fxdash{to{stroke-dashoffset:-14}}"
            f"@keyframes fxseq{{0%{{opacity:0}}3%{{opacity:1}}{on:.1f}%{{opacity:1}}{on + 5:.1f}%{{opacity:0}}"
            "100%{opacity:0}}"
            "@media (prefers-reduced-motion:reduce){.fx{animation:none;opacity:0}}"
        )

    def svg(self):
        self._finalize()
        markers = "".join(
            f'<marker id="ah{c.lstrip("#")}" markerWidth="13" markerHeight="10" refX="12" refY="5" '
            f'orient="auto" markerUnits="userSpaceOnUse"><path d="M0,0 L13,5 L0,10 z" fill="{c}"/></marker>'
            f'<marker id="as{c.lstrip("#")}" markerWidth="13" markerHeight="10" refX="1" refY="5" '
            f'orient="auto" markerUnits="userSpaceOnUse"><path d="M13,0 L0,5 L13,10 z" fill="{c}"/></marker>'
            for c in sorted(self.colors)
        )
        head = (
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{self.w}" height="{self.h}" '
            f'viewBox="0 0 {self.w} {self.h}" role="img" aria-label="{html.escape(self.title)}">'
            f"<title>{html.escape(self.title)}</title>"
            f"<style>{self.css()}</style>"
            f"<defs>{markers}</defs>"
            f'<rect width="{self.w}" height="{self.h}" rx="16" fill="{BG}"/>'
            f'<rect x="8" y="8" width="{self.w - 16}" height="{self.h - 16}" rx="12" fill="none" stroke="{LINE}" stroke-opacity=".8"/>'
        )
        body = "\n".join(self.l_zones + self.l_arrows + self.l_fx + self.l_boxes + self.l_top)
        return head + "\n" + body + "\n</svg>\n"
