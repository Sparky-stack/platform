"""Tiny SVG builder for the platform diagrams.

GitHub-safe: README images are rendered through <img>, so no scripts, no foreignObject, no external fonts, images or
CSS. Animation is a single inline <style> with CSS @keyframes (allowed by GitHub's image CSP `style-src
'unsafe-inline'`), switched off by `@media (prefers-reduced-motion: reduce)`. Every animated element is an extra
overlay whose static (unanimated) opacity is 0, so renderers without CSS animation (rsvg-convert, PDF export, the
reduced-motion case) show a complete, clean static frame.

Theme: an opaque dark card (BG) is painted inside every SVG, so the same file reads the same on GitHub's light and
dark themes (see docs/diagrams/README.md "Light and dark themes").

Design system: architecture-diagram skill (dark slate-950 background, 40px grid, semantic colours, double-rect boxes,
arrows behind boxes, legend outside every boundary).

Every element registers its geometry so `check()` can flag overlapping boxes or text, text overflowing its box,
arrows crossing text or unrelated boxes, arrows that do not start and end on a box or boundary, missing required
components and missing animation rules before anyone looks at a PNG.
"""
from __future__ import annotations

import html
import re
import xml.etree.ElementTree as ET

FONT = "JetBrains Mono, ui-monospace, SFMono-Regular, Menlo, monospace"
CHAR = 0.62  # advance width of a monospace glyph in em (JetBrains Mono = 0.60; margin for fallbacks)

BG = "#020617"
CARD = "#0f172a"
TEXT = "#f1f5f9"
SUB = "#94a3b8"
SUB2 = "#cbd5e1"  # sublabels inside boxes (higher contrast on tinted fills)
DIM = "#64748b"

MAX_BYTES = 150 * 1024
PLANNED_OPACITY = 0.55

# kind: (fill, fill-opacity, stroke)
KINDS = {
    "gitops":   ("#064e3b", 0.40, "#34d399"),  # emerald: GitOps & cluster lifecycle
    "platform": ("#083344", 0.40, "#22d3ee"),  # cyan: OpenChoreo
    "network":  ("#1e3a8a", 0.40, "#60a5fa"),  # blue: networking / mesh / ingress
    "security": ("#881337", 0.40, "#fb7185"),  # rose: security, secrets, identity
    "data":     ("#4c1d95", 0.40, "#a78bfa"),  # violet: registries, artifacts, telemetry stores
    "bus":      ("#fb923c", 0.18, "#fb923c"),  # orange: telemetry & event pipelines
    "external": ("#1e293b", 0.50, "#94a3b8"),  # slate: GitHub, SaaS, people
    "cloud":    ("#78350f", 0.30, "#fbbf24"),  # amber: cloud providers
    "zone":     ("#0f172a", 0.60, "#7b8cab"),  # neutral blue-grey: cluster / trust-zone boundaries
    "note":     ("#0f172a", 0.90, "#334155"),  # reference panels (value layering, contracts)
}

LEGEND_LABELS = {
    "gitops": "GitOps & lifecycle",
    "platform": "OpenChoreo",
    "network": "networking",
    "security": "security & secrets",
    "data": "registry & data",
    "bus": "telemetry & events",
    "external": "external / git",
    "cloud": "cloud / infra",
}

STATUSES = ("built", "optin", "planned")
TAGS = {"optin": "opt-in", "planned": "planned"}

# Elements that must never appear in a README image (no effect in <img>, or blocked by GitHub's sanitiser/CSP).
FORBIDDEN = (r"<script", r"<foreignObject", r"\son[a-z]+=", r"@import", r"url\(\s*['\"]?https?:", r"href=\"https?:",
             r"<image\b")


def tw(s: str, size: float) -> float:
    return len(s) * size * CHAR


def lighten(color: str, f: float = 0.55) -> str:
    """Mix a #rrggbb colour with white (for the animated flow particles)."""
    c = color.lstrip("#")
    r, g, b = (int(c[i:i + 2], 16) for i in (0, 2, 4))
    return "#" + "".join(f"{int(v + (255 - v) * f):02x}" for v in (r, g, b))


class Diagram:
    def __init__(self, w: int, h: int, title: str, subtitle: str = "", slot: float = 0.9):
        self.w, self.h = w, h
        self.title, self.subtitle = title, subtitle
        self.slot = slot  # seconds between consecutive flow steps lighting up
        self.groups: list[str] = []
        self.rings: list[str] = []   # focus pulse rings (between boundaries and arrows)
        self.arrows: list[str] = []
        self.fx: list[str] = []      # animated flow overlays (above arrows, below boxes)
        self.boxes: list[str] = []
        self.top: list[str] = []
        self.colors: set[str] = set()
        self.steps: set[int] = set()
        self._auto_step = 0
        # bookkeeping for check()
        self.r_boxes: list[tuple[str, tuple]] = []   # (name, rect) solid components
        self.r_groups: list[tuple[str, tuple]] = []  # boundaries (may contain boxes)
        self.r_text: list[tuple[str, tuple, tuple | None]] = []  # (text, rect, container rect)
        self.r_tags: list[tuple[str, tuple, tuple]] = []  # (tag, rect, owner box rect): status chips on box borders
        self.segs: list[tuple[str, tuple, tuple]] = []  # (arrow id, p1, p2)
        self.ends: list[tuple[str, tuple, tuple]] = []  # (arrow id, first point, last point)
        self.arrow_labels: dict[str, list[tuple]] = {}
        self.titles: list[str] = []  # box titles, must all appear as <text> in the output
        self.required: list[str] = []
        self.statuses: dict[str, str] = {}  # box name -> status
        self.has_legend = False
        self._text(28, 40, title, 22, TEXT, weight=700, anchor="start", layer=self.top)
        if subtitle:
            self._text(28, 62, subtitle, 12.5, SUB, anchor="start", layer=self.top)

    # ------------------------------------------------------------------ primitives
    def _text(self, x, y, s, size, color, weight=400, anchor="middle", layer=None, container=None,
              italic=False, record=True):
        layer = self.boxes if layer is None else layer
        w = tw(s, size)
        x0 = x - w / 2 if anchor == "middle" else (x - w if anchor == "end" else x)
        if record:
            self.r_text.append((s, (x0, y - size * 0.80, w, size * 1.0), container))
        st = ' font-style="italic"' if italic else ""
        if "  " in s:
            st += ' xml:space="preserve"'
        layer.append(
            f'<text x="{x:.1f}" y="{y:.1f}" font-family="{FONT}" font-size="{size}" '
            f'font-weight="{weight}" fill="{color}" text-anchor="{anchor}"{st}>{html.escape(s)}</text>'
        )

    def text(self, x, y, s, size=11, color=SUB, weight=400, anchor="start", italic=False):
        self._text(x, y, s, size, color, weight, anchor, layer=self.top, italic=italic)

    def require(self, *names):
        """Component names (box titles or `name=`) this diagram must contain; check() fails otherwise."""
        self.required += names

    def box(self, x, y, w, h, kind, title, lines=(), planned=False, title_size=13, sub_size=11.5,
            sub_color=SUB2, name=None, align="middle", status=None, focus=False, tag=None):
        """Component box. Text is centred; `lines` are sublabels (str or (str, colour)).

        status: built (solid outline) | optin (dashed outline + "opt-in" chip) | planned (dimmed, dashed, "planned"
        chip). `planned=True` is shorthand for status="planned". focus=True adds the pulsing ring of the component a
        view is about. `tag` overrides the chip text.
        """
        status = status or ("planned" if planned else "built")
        assert status in STATUSES, status
        fill, op, stroke = KINDS[kind]
        dash = ' stroke-dasharray="6,4"' if status != "built" else ""
        out = []
        out.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="6" fill="{CARD}"/>')
        out.append(
            f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="6" fill="{fill}" fill-opacity="{op}" '
            f'stroke="{stroke}" stroke-width="1.5"{dash}/>'
        )
        # centre the visual extent (cap height of the title .. descender of the last line)
        span = 0.75 * title_size + (4 + len(lines) * (sub_size + 4) + 0.22 * sub_size if lines else 0)
        ty = y + h / 2 + 0.75 * title_size - span / 2
        if align != "middle":  # reference panels: top-aligned
            ty = y + 24
        rect = (x, y, w, h)
        tx = x + w / 2 if align == "middle" else x + 12
        self._text(tx, ty, title, title_size, TEXT, weight=600, container=rect, anchor=align, layer=out)
        yy = ty + 4
        for ln in lines:
            s, c = (ln, sub_color) if isinstance(ln, str) else ln
            yy += sub_size + 4
            self._text(tx, yy, s, sub_size, c, container=rect, anchor=align, layer=out)
        chip = tag or TAGS.get(status)
        if chip:
            cs = 9.5
            cw = tw(chip, cs) + 10
            cx, cy = x + w - cw - 8, y - 10
            out.append(f'<rect x="{cx:.1f}" y="{cy}" width="{cw:.1f}" height="14" rx="7" fill="{BG}" '
                       f'stroke="{stroke}" stroke-width="1"/>')
            out.append(f'<text x="{cx + cw / 2:.1f}" y="{cy + 10.5}" font-family="{FONT}" font-size="{cs}" '
                       f'font-weight="700" fill="{stroke}" text-anchor="middle">{html.escape(chip)}</text>')
            self.r_tags.append((chip, (cx, cy, cw, 14), rect))
        if status == "planned":
            out = [f'<g opacity="{PLANNED_OPACITY}">'] + out + ["</g>"]
        self.boxes += out
        if focus:
            self.focus(rect, stroke)
        self.r_boxes.append((name or title, rect))
        self.titles.append(title)
        self.statuses[name or title] = status
        return rect

    def focus(self, rect, color):
        """Pulsing ring around the component a view is about (static frame: faint ring)."""
        x, y, w, h = rect
        self.rings.append(f'<rect class="pulse" x="{x - 5}" y="{y - 5}" width="{w + 10}" height="{h + 10}" rx="10" '
                          f'fill="none" stroke="{color}" stroke-width="2.5"/>')

    def group(self, x, y, w, h, label, kind="external", dash=None, sub=None, stacked=0, label_size=12.5):
        """Boundary (cluster, region, trust zone). Label sits inside the top-left corner."""
        fill, op, stroke = KINDS[kind]
        dd = f' stroke-dasharray="{dash}"' if dash else ""
        for i in range(stacked, 0, -1):  # offset outlines behind = "one per fleet file"
            d = 7 * i
            self.groups.append(
                f'<rect x="{x + d}" y="{y + d}" width="{w}" height="{h}" rx="12" fill="{BG}" '
                f'stroke="{stroke}" stroke-opacity="0.45" stroke-width="1"{dd}/>'
            )
        self.groups.append(
            f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="12" fill="{BG}" stroke="none"/>'
        )
        self.groups.append(
            f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="12" fill="{fill}" fill-opacity="0.10" '
            f'stroke="{stroke}" stroke-opacity="0.75" stroke-width="1.2"{dd}/>'
        )
        lc = "#e2e8f0" if kind == "zone" else stroke
        if label:
            self._text(x + 14, y + 22, label, label_size, lc, weight=700, anchor="start", layer=self.groups,
                       container=(x, y, w, h))
        if sub:
            subs = [sub] if isinstance(sub, str) else sub
            for i, s in enumerate(subs):
                self._text(x + 14, y + 40 + i * 16, s, 11.5, SUB2, anchor="start", layer=self.groups,
                           container=(x, y, w, h))
        self.r_groups.append((label, (x, y, w + 7 * stacked, h + 7 * stacked)))

    def _marker(self, color):
        self.colors.add(color)
        return f"url(#ah{color.lstrip('#')})"

    def _fx_path(self, d, color, step, layer=None):
        self.steps.add(step)
        delay = step * self.slot
        (self.fx if layer is None else layer).append(
            f'<path class="fx" d="{d}" stroke="{lighten(color)}" style="animation-delay:0s,{delay:.2f}s"/>')

    def arrow(self, pts, color, planned=False, label=None, label_pos=None, label_anchor="middle",
              both=False, badge=None, badge_pos=None, aid=None, width=1.6, head=True, status=None, step=None,
              loose=False):
        """Arrow from pts[0] to pts[-1]. status: built (solid + animated flow) | optin (dashed) | planned (dimmed,
        dashed). Built flows light up in `step` order (default: creation order); equal steps light up together.
        loose=True skips the endpoints-on-a-box check (free annotations)."""
        status = status or ("planned" if planned else "built")
        assert status in STATUSES, status
        aid = aid or f"a{len(self.segs)}"
        d = "M " + " L ".join(f"{px:.1f} {py:.1f}" for px, py in pts)
        dash = ' stroke-dasharray="6,4"' if status != "built" else ""
        dim = f' opacity="{PLANNED_OPACITY}"' if status == "planned" else ""
        me = f' marker-end="{self._marker(color)}"' if head else ""
        ms = f' marker-start="{self._marker(color)}"' if both else ""
        self.arrows.append(
            f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{width}" '
            f'stroke-linejoin="round"{dash}{dim}{me}{ms}/>'
        )
        if status == "built":
            if step is None:
                step = self._auto_step
                self._auto_step += 1
            else:
                self._auto_step = max(self._auto_step, step + 1)
            self._fx_path(d, color, step)
        for p1, p2 in zip(pts, pts[1:]):
            self.segs.append((aid, p1, p2))
        if not loose:
            self.ends.append((aid, pts[0], pts[-1]))
        if label:
            lx, ly = label_pos
            self.label(lx, ly, label, color, anchor=label_anchor, owner=aid)
        if badge is not None:
            bx, by = badge_pos
            self.badge(bx, by, badge, color, owner=aid, planned=status != "built")
        return aid

    def label(self, x, y, s, color=SUB, size=11.5, anchor="middle", owner=None):
        """Arrow label with an opaque backing so crossing lines never hide it."""
        w = tw(s, size)
        x0 = x - w / 2 if anchor == "middle" else (x - w if anchor == "end" else x)
        self.top.append(
            f'<rect x="{x0 - 4:.1f}" y="{y - size - 1:.1f}" width="{w + 8:.1f}" height="{size + 6:.1f}" '
            f'rx="3" fill="{BG}" fill-opacity="0.92"/>'
        )
        self._text(x, y, s, size, color, anchor=anchor, layer=self.top)
        if owner:
            self.arrow_labels.setdefault(owner, []).append(self.r_text[-1][1])

    def badge(self, x, y, n, color, owner=None, r=9, planned=False):
        dash = ' stroke-dasharray="3,2"' if planned else ""
        self.top.append(f'<circle cx="{x}" cy="{y}" r="{r}" fill="{BG}" stroke="{color}" stroke-width="1.5"{dash}/>')
        self._text(x, y + 4, str(n), 11, color, weight=700, layer=self.top)
        if owner:
            self.arrow_labels.setdefault(owner, []).append(self.r_text[-1][1])

    def legend(self, x, y, kinds=(), planned=True, flows=(), cols=4, col_w=210, title="Legend", zone=True,
               labels=None, optin=True, focus=False):
        """Colour swatches, then status rows: box styles (built / opt-in / planned) and flow styles. Returns bottom y."""
        y0 = y
        self.has_legend = True
        self._text(x, y, title, 12, TEXT, weight=700, anchor="start", layer=self.top)
        y += 12
        rows = [[("k", k) for k in kinds[i:i + cols]] for i in range(0, len(kinds), cols)]
        status: list[tuple] = [("built", "built (on main)")]
        if optin:
            status.append(("optin", "opt-in (off by default)"))
        if planned:
            status.append(("planned", "planned (not on main)"))
        if zone:
            status.append(("zone", "cluster / zone"))
        status.append(("live", "flow (animated)"))
        if optin:
            status.append(("f", ("opt-in flow", "#e2e8f0", "optin")))
        if planned:
            status.append(("f", ("planned flow", "#e2e8f0", "planned")))
        if focus:
            status.append(("focus", "focus of this view"))
        status += [("f", f) for f in flows]
        rows += [status[i:i + cols] for i in range(0, len(status), cols)]
        for r, row in enumerate(rows):
            for c, (t, v) in enumerate(row):
                cx = x + c * col_w
                cy = y + r * 22
                if t == "k":
                    fill, op, stroke = KINDS[v]
                    self.top.append(f'<rect x="{cx}" y="{cy + 4}" width="22" height="13" rx="3" fill="{CARD}"/>')
                    self.top.append(
                        f'<rect x="{cx}" y="{cy + 4}" width="22" height="13" rx="3" fill="{fill}" '
                        f'fill-opacity="{op}" stroke="{stroke}" stroke-width="1.2"/>'
                    )
                    lab = (labels or {}).get(v, LEGEND_LABELS[v])
                elif t == "zone":
                    self.top.append(
                        f'<rect x="{cx - 2}" y="{cy + 1}" width="26" height="19" rx="6" fill="none" '
                        f'stroke="{KINDS["zone"][2]}" stroke-width="1.4"/>'
                    )
                    lab = v
                elif t == "focus":
                    self.top.append(
                        f'<rect x="{cx}" y="{cy + 4}" width="22" height="13" rx="3" fill="none" '
                        f'stroke="#f8fafc" stroke-width="1.2"/>')
                    self.top.append(
                        f'<rect class="pulse" x="{cx - 3}" y="{cy + 1}" width="28" height="19" rx="5" fill="none" '
                        f'stroke="#f8fafc" stroke-width="2"/>')
                    lab = v
                elif t in STATUSES:
                    dash = ' stroke-dasharray="4,3"' if t != "built" else ""
                    op = f' opacity="{PLANNED_OPACITY}"' if t == "planned" else ""
                    self.top.append(
                        f'<rect x="{cx}" y="{cy + 4}" width="22" height="13" rx="3" fill="none" '
                        f'stroke="#f8fafc" stroke-width="1.4"{dash}{op}/>'
                    )
                    lab = v
                elif t == "live":
                    d = f"M {cx - 4} {cy + 11} L {cx + 22} {cy + 11}"
                    self.top.append(f'<path d="{d}" stroke="#e2e8f0" stroke-width="1.8" '
                                    f'marker-end="{self._marker("#e2e8f0")}"/>')
                    self._fx_path(d, "#94a3b8", 0, layer=self.top)
                    lab = v
                else:  # flow line: (label, colour, status or bool dashed)
                    lab, color, st = v
                    st = {True: "planned", False: "built"}.get(st, st)
                    dash = ' stroke-dasharray="4,3"' if st != "built" else ""
                    op = f' opacity="{PLANNED_OPACITY}"' if st == "planned" else ""
                    self.top.append(
                        f'<line x1="{cx - 4}" y1="{cy + 11}" x2="{cx + 22}" y2="{cy + 11}" stroke="{color}" '
                        f'stroke-width="1.8"{dash}{op} marker-end="{self._marker(color)}"/>'
                    )
                self._text(cx + 30, cy + 15, lab, 11.5, SUB2, anchor="start", layer=self.top)
        bottom = y + len(rows) * 22
        self.r_boxes.append(("legend", (x - 4, y0 - 14, cols * col_w, bottom - y0 + 14)))
        return bottom

    def flowkey(self, x, y, entries, colors, title="Flows", width=None, planned=()):
        """Numbered flow list (badge + text)."""
        y0 = y
        if title:
            self._text(x, y, title, 12, TEXT, weight=700, anchor="start", layer=self.top)
        y += 22
        maxw = 0
        for (n, s), c in zip(entries, colors):
            self.badge(x + 9, y - 4, n, c, planned=n in planned)
            self._text(x + 26, y, s, 12, SUB2, anchor="start", layer=self.top)
            maxw = max(maxw, 26 + tw(s, 12))
            y += 22
        self.r_boxes.append(("flowkey", (x - 4, y0 - 14, width or maxw + 8, y - y0)))
        return y

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
    def _on_edge(p, r, tol=3.0):
        """Point lies on the perimeter band of rect r."""
        x, y = p
        rx, ry, rw, rh = r
        if not (rx - tol <= x <= rx + rw + tol and ry - tol <= y <= ry + rh + tol):
            return False
        return min(abs(x - rx), abs(x - rx - rw), abs(y - ry), abs(y - ry - rh)) <= tol

    @staticmethod
    def _seg_hits(p1, p2, r, shrink=1.0):
        (x1, y1), (x2, y2) = p1, p2
        rx, ry, rw, rh = r[0] + shrink, r[1] + shrink, r[2] - 2 * shrink, r[3] - 2 * shrink
        if rw <= 0 or rh <= 0:
            return False
        # Liang-Barsky clip
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

    def check(self):
        """Layout checks on the registered geometry + output checks on the rendered SVG string."""
        issues = []
        # boxes must not overlap each other (nesting is not allowed for components)
        for i, (na, a) in enumerate(self.r_boxes):
            for nb, b in self.r_boxes[i + 1:]:
                if self._ov(a, b):
                    issues.append(f"box overlap: {na!r} x {nb!r}")
            if a[0] < 0 or a[1] < 0 or a[0] + a[2] > self.w or a[1] + a[3] > self.h:
                issues.append(f"box outside canvas: {na!r} {a}")
        for ng, g in self.r_groups:
            if g[0] < 0 or g[1] < 0 or g[0] + g[2] > self.w - 8 or g[1] + g[3] > self.h - 8:
                issues.append(f"boundary outside the card: {ng!r} {g}")
        # legend / flowkey outside every boundary
        for nb, b in self.r_boxes:
            if nb in ("legend", "flowkey"):
                for ng, g in self.r_groups:
                    if self._ov(b, g):
                        issues.append(f"{nb} overlaps boundary {ng!r}")
        # text inside its container, text vs text
        for s, r, c in self.r_text:
            if c and not self._inside(r, (c[0] + 4, c[1] + 2, c[2] - 8, c[3] - 4)):
                issues.append(f"text overflows container: {s!r}")
            if r[0] + r[2] > self.w or r[0] < 0:
                issues.append(f"text outside canvas: {s!r}")
        for i, (sa, a, _) in enumerate(self.r_text):
            for sb, b, _ in self.r_text[i + 1:]:
                if self._ov(a, b, pad=0.5):
                    issues.append(f"text overlap: {sa!r} x {sb!r}")
        # text vs boxes it does not belong to
        for s, r, c in self.r_text:
            for nb, b in self.r_boxes:
                if nb in ("legend", "flowkey"):
                    continue
                if c == b:
                    continue
                if self._ov(r, b):
                    issues.append(f"text {s!r} overlaps box {nb!r}")
        # status chips: never on other text or other boxes
        for t, r, owner in self.r_tags:
            for s, tr, _ in self.r_text:
                if self._ov(r, tr):
                    issues.append(f"status chip {t!r} of box {owner} overlaps text {s!r}")
            for nb, b in self.r_boxes:
                if b != owner and self._ov(r, b):
                    issues.append(f"status chip {t!r} of box {owner} overlaps box {nb!r}")
        # arrows vs text and unrelated boxes
        for aid, p1, p2 in self.segs:
            own = self.arrow_labels.get(aid, [])
            for s, r, c in self.r_text:
                if r in own:
                    continue
                if self._seg_hits(p1, p2, (r[0] - 2, r[1] - 2, r[2] + 4, r[3] + 4), shrink=0):
                    issues.append(f"arrow {aid} crosses text {s!r}")
            for t, r, _ in self.r_tags:
                if self._seg_hits(p1, p2, r, shrink=0):
                    issues.append(f"arrow {aid} crosses status chip {t!r}")
            for nb, b in self.r_boxes:
                if self._seg_hits(p1, p2, b, shrink=2.5):
                    issues.append(f"arrow {aid} passes through box {nb!r}")
        # arrows start and end on a component box or a boundary
        rects = [b for nb, b in self.r_boxes if nb not in ("legend", "flowkey")] + [g for _, g in self.r_groups]
        for aid, p0, p1 in self.ends:
            for which, p in (("start", p0), ("end", p1)):
                if not any(self._on_edge(p, r) for r in rects):
                    issues.append(f"arrow {aid} {which} {p} is not on a box or boundary edge")
        # required components are first-class boxes
        names = {n for n, _ in self.r_boxes} | set(self.titles)
        for n in self.required:
            if n not in names:
                issues.append(f"required component missing: {n!r}")
        if not self.has_legend:
            issues.append("no legend")
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
        used = set(re.findall(r"animation(?:-name)?\s*:\s*([a-z][\w-]*)", style))
        used |= {n.strip().split()[0] for m in re.findall(r"animation\s*:\s*([^;}]+)", style) for n in m.split(",")}
        defined = set(re.findall(r"@keyframes\s+([\w-]+)", style))
        if not defined:
            issues.append("no @keyframes")
        for n in sorted(used - defined - {"none"}):
            issues.append(f"animation {n!r} has no @keyframes")
        if not re.search(r"@media\s*\(\s*prefers-reduced-motion\s*:\s*reduce\s*\)\s*\{[^}]*animation\s*:\s*none",
                         style):
            issues.append("no prefers-reduced-motion rule disabling animation")
        if self.steps and 'class="fx"' not in svg:
            issues.append("built flows but no animated overlay")
        return issues

    # ------------------------------------------------------------------ output
    def css(self):
        n = (max(self.steps) + 1) if self.steps else 1
        period = n * self.slot + 2.4  # one pass over every step, then a short rest
        on = min(2.2 * self.slot / period * 100, 60)  # each step stays bright for ~2 slots
        return (
            ".fx{fill:none;stroke-width:3;stroke-linecap:round;stroke-dasharray:5 9;opacity:0;"
            f"animation:fxdash .8s linear infinite,fxseq {period:.2f}s linear infinite both}}"
            "@keyframes fxdash{to{stroke-dashoffset:-14}}"
            f"@keyframes fxseq{{0%{{opacity:.3}}4%{{opacity:1}}{on:.1f}%{{opacity:1}}{on + 6:.1f}%{{opacity:.3}}"
            "100%{opacity:.3}}"
            ".pulse{opacity:.35;animation:pulse 2.6s ease-in-out infinite}"
            "@keyframes pulse{0%,100%{opacity:.15}50%{opacity:.9}}"
            "@media (prefers-reduced-motion:reduce){.fx,.pulse{animation:none}.fx{opacity:0}.pulse{opacity:.35}}"
        )

    def svg(self):
        markers = "".join(
            f'<marker id="ah{c.lstrip("#")}" markerWidth="10" markerHeight="8" refX="9" refY="4" '
            f'orient="auto" markerUnits="userSpaceOnUse"><path d="M0,0 L10,4 L0,8 z" fill="{c}"/></marker>'
            for c in sorted(self.colors)
        )
        head = (
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{self.w}" height="{self.h}" '
            f'viewBox="0 0 {self.w} {self.h}" role="img" aria-label="{html.escape(self.title)}">'
            f"<title>{html.escape(self.title)}</title>"
            f"<style>{self.css()}</style>"
            f'<defs><pattern id="grid" width="40" height="40" patternUnits="userSpaceOnUse">'
            f'<path d="M 40 0 L 0 0 0 40" fill="none" stroke="#1e293b" stroke-width="0.5"/></pattern>'
            f"{markers}</defs>"
            f'<rect width="{self.w}" height="{self.h}" rx="16" fill="{BG}"/>'
            f'<rect width="{self.w}" height="{self.h}" rx="16" fill="url(#grid)"/>'
            f'<rect x="8" y="8" width="{self.w - 16}" height="{self.h - 16}" rx="14" fill="none" '
            f'stroke="#1e293b" stroke-width="1"/>'
        )
        body = "\n".join(self.groups + self.rings + self.arrows + self.fx + self.boxes + self.top)
        return head + "\n" + body + "\n</svg>\n"

    def save(self, path):
        with open(path, "w") as f:
            f.write(self.svg())
