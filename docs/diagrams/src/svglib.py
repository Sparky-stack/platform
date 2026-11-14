"""Tiny SVG builder for the platform diagrams (GitHub-safe: no scripts, no <style>, no external fonts).

Design system: architecture-diagram skill (dark slate-950 background, 40px grid, semantic colours,
double-rect boxes, arrows behind boxes, legend outside every boundary).

Every element registers its bounding box so `check()` can flag overlapping boxes, overlapping text,
text overflowing its box and arrows crossing text or unrelated boxes before anyone looks at a PNG.
"""
from __future__ import annotations

import html

FONT = "JetBrains Mono, ui-monospace, SFMono-Regular, Menlo, monospace"
CHAR = 0.62  # advance width of a monospace glyph in em (JetBrains Mono = 0.60; margin for fallbacks)

BG = "#020617"
CARD = "#0f172a"
TEXT = "#f1f5f9"
SUB = "#94a3b8"
SUB2 = "#cbd5e1"  # sublabels inside boxes (higher contrast on tinted fills)
DIM = "#64748b"

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


def tw(s: str, size: float) -> float:
    return len(s) * size * CHAR


class Diagram:
    def __init__(self, w: int, h: int, title: str, subtitle: str = ""):
        self.w, self.h = w, h
        self.title, self.subtitle = title, subtitle
        self.groups: list[str] = []
        self.arrows: list[str] = []
        self.boxes: list[str] = []
        self.top: list[str] = []
        self.colors: set[str] = set()
        # bookkeeping for check()
        self.r_boxes: list[tuple[str, tuple]] = []   # (name, rect) solid components
        self.r_groups: list[tuple[str, tuple]] = []  # boundaries (may contain boxes)
        self.r_text: list[tuple[str, tuple, tuple | None]] = []  # (text, rect, container rect)
        self.segs: list[tuple[str, tuple, tuple]] = []  # (arrow id, p1, p2)
        self.arrow_labels: dict[str, list[tuple]] = {}
        self.warnings: list[str] = []
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

    def box(self, x, y, w, h, kind, title, lines=(), planned=False, title_size=13, sub_size=11.5,
            sub_color=SUB2, name=None, align="middle"):
        """Component box. Text is centred; `lines` are sublabels (str or (str, colour))."""
        fill, op, stroke = KINDS[kind]
        dash = ' stroke-dasharray="6,4"' if planned else ""
        self.boxes.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="6" fill="{CARD}"/>')
        self.boxes.append(
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
        self._text(tx, ty, title, title_size, TEXT, weight=600, container=rect, anchor=align)
        yy = ty + 4
        for ln in lines:
            s, c = (ln, sub_color) if isinstance(ln, str) else ln
            yy += sub_size + 4
            self._text(tx, yy, s, sub_size, c, container=rect, anchor=align)
        self.r_boxes.append((name or title, rect))
        return rect

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

    def arrow(self, pts, color, planned=False, label=None, label_pos=None, label_anchor="middle",
              both=False, badge=None, badge_pos=None, aid=None, width=1.6, head=True):
        aid = aid or f"a{len(self.segs)}"
        d = "M " + " L ".join(f"{px:.1f} {py:.1f}" for px, py in pts)
        dash = ' stroke-dasharray="6,4"' if planned else ""
        me = f' marker-end="{self._marker(color)}"' if head else ""
        ms = f' marker-start="{self._marker(color)}"' if both else ""
        self.arrows.append(
            f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{width}" '
            f'stroke-linejoin="round"{dash}{me}{ms}/>'
        )
        for p1, p2 in zip(pts, pts[1:]):
            self.segs.append((aid, p1, p2))
        if label:
            lx, ly = label_pos
            self.label(lx, ly, label, color, anchor=label_anchor, owner=aid)
        if badge is not None:
            bx, by = badge_pos
            self.badge(bx, by, badge, color, owner=aid, planned=planned)
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
               labels=None):
        """Colour swatches, then (own row) built/planned box + line styles. Returns bottom y."""
        y0 = y
        self._text(x, y, title, 12, TEXT, weight=700, anchor="start", layer=self.top)
        y += 12
        rows = [[("k", k) for k in kinds[i:i + cols]] for i in range(0, len(kinds), cols)]
        status = []
        if planned:
            status = [("solid", "built (on main)"), ("dashed", "planned"),
                      ("f", ("flow", "#e2e8f0", False)), ("f", ("planned flow", "#e2e8f0", True))]
        if zone:
            status.append(("zone", "cluster / zone"))
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
                elif t in ("solid", "dashed"):
                    dash = ' stroke-dasharray="4,3"' if t == "dashed" else ""
                    self.top.append(
                        f'<rect x="{cx}" y="{cy + 4}" width="22" height="13" rx="3" fill="none" '
                        f'stroke="#f8fafc" stroke-width="1.4"{dash}/>'
                    )
                    lab = v
                else:  # flow line: (label, colour, dashed)
                    lab, color, dashed = v
                    dash = ' stroke-dasharray="4,3"' if dashed else ""
                    self.top.append(
                        f'<line x1="{cx - 4}" y1="{cy + 11}" x2="{cx + 22}" y2="{cy + 11}" stroke="{color}" '
                        f'stroke-width="1.8"{dash} marker-end="{self._marker(color)}"/>'
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
        issues = []
        # boxes must not overlap each other (nesting is not allowed for components)
        for i, (na, a) in enumerate(self.r_boxes):
            for nb, b in self.r_boxes[i + 1:]:
                if self._ov(a, b):
                    issues.append(f"box overlap: {na!r} x {nb!r}")
            if a[0] < 0 or a[1] < 0 or a[0] + a[2] > self.w or a[1] + a[3] > self.h:
                issues.append(f"box outside canvas: {na!r} {a}")
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
        # arrows vs text and unrelated boxes
        for aid, p1, p2 in self.segs:
            own = self.arrow_labels.get(aid, [])
            for s, r, c in self.r_text:
                if r in own:
                    continue
                if self._seg_hits(p1, p2, (r[0] - 2, r[1] - 2, r[2] + 4, r[3] + 4), shrink=0):
                    issues.append(f"arrow {aid} crosses text {s!r}")
            for nb, b in self.r_boxes:
                if self._seg_hits(p1, p2, b, shrink=2.5):
                    issues.append(f"arrow {aid} passes through box {nb!r}")
        return issues

    # ------------------------------------------------------------------ output
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
            f'<defs><pattern id="grid" width="40" height="40" patternUnits="userSpaceOnUse">'
            f'<path d="M 40 0 L 0 0 0 40" fill="none" stroke="#1e293b" stroke-width="0.5"/></pattern>'
            f"{markers}</defs>"
            f'<rect width="{self.w}" height="{self.h}" fill="{BG}"/>'
            f'<rect width="{self.w}" height="{self.h}" fill="url(#grid)"/>'
            f'<rect x="8" y="8" width="{self.w - 16}" height="{self.h - 16}" rx="14" fill="none" '
            f'stroke="#1e293b" stroke-width="1"/>'
        )
        body = "\n".join(self.groups + self.arrows + self.boxes + self.top)
        return head + "\n" + body + "\n</svg>\n"

    def save(self, path):
        with open(path, "w") as f:
            f.write(self.svg())
