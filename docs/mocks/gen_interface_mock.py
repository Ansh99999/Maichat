#!/usr/bin/env python3
"""Draws docs/mocks/chat-interface-reorg.svg — a design mock, not app output.

Palette is the real M3 light scheme the app renders from seed #7C5CFF, matched
against docs/screenshots/04-interface.png so the mock reads as the same app.
"""

FONT = "Roboto, 'Segoe UI', 'DejaVu Sans', sans-serif"

CANVAS = "#E9E3F0"
PHONE = "#F8F4FC"
SURFACE = "#FFFFFF"
PRIMARY = "#5B4E9B"
PRIM_CONT = "#E5DEF7"
SEC_CONT = "#E3DCF2"
ON_SEC_CONT = "#3B3552"
ON_SURF = "#1C1B1F"
ON_SURF_VAR = "#4A4553"
OUTLINE = "#7A757F"
OUTLINE_VAR = "#CBC4D3"
TRACK = "#DDD7E6"
WARN = "#9C4256"

out = []


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def rect(x, y, w, h, rx=0, fill="none", stroke=None, sw=1, op=None):
    a = f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="{fill}"'
    if stroke:
        a += f' stroke="{stroke}" stroke-width="{sw}"'
    if op is not None:
        a += f' opacity="{op}"'
    out.append(a + "/>")


def text(x, y, s, size=13, fill=ON_SURF, weight="400", anchor="start", op=None):
    a = (f'<text x="{x}" y="{y}" font-family="{FONT}" font-size="{size}" '
         f'fill="{fill}" font-weight="{weight}" text-anchor="{anchor}"')
    if op is not None:
        a += f' opacity="{op}"'
    out.append(a + f">{esc(s)}</text>")


def line(x1, y1, x2, y2, stroke=OUTLINE_VAR, sw=1, op=None):
    a = (f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{stroke}" '
         f'stroke-width="{sw}"')
    if op is not None:
        a += f' opacity="{op}"'
    out.append(a + "/>")


def circle(cx, cy, r, fill="none", stroke=None, sw=1):
    a = f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="{fill}"'
    if stroke:
        a += f' stroke="{stroke}" stroke-width="{sw}"'
    out.append(a + "/>")


def path(d, fill="none", stroke=None, sw=1.6, cap="round"):
    a = f'<path d="{d}" fill="{fill}"'
    if stroke:
        a += (f' stroke="{stroke}" stroke-width="{sw}" stroke-linecap="{cap}"'
              f' stroke-linejoin="round"')
    out.append(a + "/>")
def switch(x, y, on=True):
    """M3 switch, 44x26, anchored top-left."""
    rect(x, y, 44, 26, 13, PRIMARY if on else TRACK,
         None if on else OUTLINE, 1)
    circle(x + (30 if on else 14), y + 13, 9 if on else 7,
           SURFACE if on else OUTLINE)


def slider(x, y, w, frac, fill=PRIMARY):
    """Track + active portion + thumb, centred on y."""
    rect(x, y - 2, w, 4, 2, TRACK)
    if frac > 0:
        rect(x, y - 2, max(4, w * frac), 4, 2, fill)
    circle(x + w * frac, y, 9, fill)


def segmented(x, y, w, labels, sel, h=38, size=12.5):
    """Outlined pill of equal segments; the selected one is filled."""
    seg = w / len(labels)
    rect(x, y, w, h, h / 2, "none", OUTLINE, 1)
    for i, lab in enumerate(labels):
        if i == sel:
            if i == 0:
                path(f"M{x + h / 2} {y} h{seg - h / 2} v{h} h{-(seg - h / 2)} "
                     f"a{h / 2} {h / 2} 0 0 1 0 {-h} z", PRIM_CONT)
            elif i == len(labels) - 1:
                path(f"M{x + i * seg} {y} h{seg - h / 2} a{h / 2} {h / 2} 0 0 1 "
                     f"0 {h} h{-(seg - h / 2)} z", PRIM_CONT)
            else:
                rect(x + i * seg, y, seg, h, 0, PRIM_CONT)
        if i:
            line(x + i * seg, y, x + i * seg, y + h, OUTLINE)
        text(x + i * seg + seg / 2, y + h / 2 + 4.5, lab, size,
             PRIMARY if i == sel else ON_SURF,
             "500" if i == sel else "400", "middle")
    rect(x, y, w, h, h / 2, "none", OUTLINE, 1)


def chevron(x, y, c=OUTLINE):
    path(f"M{x} {y - 5} l5 5 l-5 5", None, c, 1.6)


def pill(x, y, label, fg=PRIMARY, bg=PRIM_CONT, size=10.5):
    w = len(label) * size * 0.56 + 16
    rect(x, y - 9, w, 18, 9, bg)
    text(x + w / 2, y + 4, label, size, fg, "500", "middle")
    return w
def icon(name, cx, cy, c=ON_SURF_VAR, s=1.0):
    """A small set of hand-drawn stand-ins for the Material icons the app uses."""
    u = 11 * s  # half-extent

    def p(d, fill="none", sw=1.6):
        path(d, fill, None if fill != "none" else c, sw * s)

    if name == "eye":
        p(f"M{cx - u} {cy} q{u} {-u * 0.9} {2 * u} 0 q{-u} {u * 0.9} {-2 * u} 0 z")
        circle(cx, cy, 3.2 * s, c)
    elif name == "back":
        p(f"M{cx + u * 0.8} {cy} h{-1.6 * u} m0 0 l{u * 0.7} {-u * 0.7} "
          f"m{-u * 0.7} {u * 0.7} l{u * 0.7} {u * 0.7}")
    elif name == "layout":
        rect(cx - u, cy - u * 0.8, 2 * u, u * 0.62, 2, c)
        rect(cx - u, cy + u * 0.18, 2 * u, u * 0.62, 2, c)
    elif name == "person":
        circle(cx, cy - u * 0.35, 3.6 * s, c)
        p(f"M{cx - u * 0.72} {cy + u * 0.85} q{u * 0.72} {-u * 0.95} "
          f"{u * 1.44} 0", c, 0)
        path(f"M{cx - u * 0.72} {cy + u * 0.85} q{u * 0.72} {-u * 0.95} "
             f"{u * 1.44} 0", "none", c, 2.0 * s)
    elif name == "badge":
        rect(cx - u, cy - u * 0.62, 2 * u, u * 1.24, 3, "none", c, 1.6 * s)
        line(cx - u * 0.55, cy, cx + u * 0.55, cy, c, 1.6 * s)
    elif name == "palette":
        circle(cx, cy, u * 0.9, "none", c, 1.6 * s)
        circle(cx - u * 0.34, cy - u * 0.28, 1.9 * s, c)
        circle(cx + u * 0.34, cy - u * 0.28, 1.9 * s, c)
        circle(cx, cy + u * 0.36, 1.9 * s, c)
    elif name == "textA":
        text(cx, cy + u * 0.62, "A", 17 * s, c, "600", "middle")
    elif name == "dots":
        for d in (-u * 0.55, 0, u * 0.55):
            circle(cx + d, cy, 1.9 * s, c)
    elif name == "group":
        circle(cx - u * 0.4, cy, u * 0.56, "none", c, 1.6 * s)
        circle(cx + u * 0.4, cy, u * 0.56, "none", c, 1.6 * s)
    elif name == "bubble":
        rect(cx - u, cy - u * 0.8, 2 * u, u * 1.35, 3, "none", c, 1.6 * s)
        path(f"M{cx - u * 0.5} {cy + u * 0.55} l0 {u * 0.5} l{u * 0.5} "
             f"{-u * 0.5}", "none", c, 1.6 * s)
    elif name == "move":
        p(f"M{cx} {cy - u * 0.85} v{u * 1.7} M{cx - u * 0.85} {cy} h{u * 1.7} "
          f"M{cx - u * 0.35} {cy - u * 0.5} l{u * 0.35} {-u * 0.35} l{u * 0.35} "
          f"{u * 0.35} M{cx - u * 0.35} {cy + u * 0.5} l{u * 0.35} {u * 0.35} "
          f"l{u * 0.35} {-u * 0.35}", "none", 1.4)
    elif name == "corner":
        p(f"M{cx - u * 0.75} {cy + u * 0.75} v{-u * 0.75} q0 {-u * 0.75} "
          f"{u * 0.75} {-u * 0.75} h{u * 0.75}")
    elif name == "cols":
        for d in (-u * 0.62, 0, u * 0.62):
            rect(cx + d - u * 0.18, cy - u * 0.7, u * 0.36, u * 1.4, 1.5, c)
    elif name == "vspace":
        p(f"M{cx} {cy - u * 0.85} v{u * 1.7} M{cx - u * 0.4} {cy + u * 0.45} "
          f"l{u * 0.4} {u * 0.4} l{u * 0.4} {-u * 0.4} M{cx - u * 0.4} "
          f"{cy - u * 0.45} l{u * 0.4} {-u * 0.4} l{u * 0.4} {u * 0.4}")
    elif name == "hspace":
        p(f"M{cx - u * 0.85} {cy} h{u * 1.7} M{cx + u * 0.45} {cy - u * 0.4} "
          f"l{u * 0.4} {u * 0.4} l{-u * 0.4} {u * 0.4} M{cx - u * 0.45} "
          f"{cy - u * 0.4} l{-u * 0.4} {u * 0.4} l{u * 0.4} {u * 0.4}")
    elif name == "drop":
        p(f"M{cx} {cy - u * 0.85} q{u * 0.8} {u * 0.9} {u * 0.3} {u * 1.25} "
          f"q{-u * 0.55} {u * 0.4} {-u * 0.6} 0 q{-u * 0.5} {-u * 0.35} "
          f"{u * 0.3} {-u * 1.25} z", c)
    elif name == "square":
        rect(cx - u * 0.75, cy - u * 0.75, u * 1.5, u * 1.5, 4,
             "none", c, 1.6 * s)
    elif name == "crop":
        p(f"M{cx - u * 0.8} {cy - u * 0.45} h{u * 1.25} v{u * 1.25} "
          f"M{cx - u * 0.45} {cy - u * 0.8} v{u * 1.25} h{u * 1.25}")
PW, PH = 384, 812  # phone body


def phone(x, y, caption, sub=None):
    """Device shell + caption above it. Returns the content-origin (x, y)."""
    text(x, y - 34, caption, 17, "#241F33", "600")
    if sub:
        text(x, y - 14, sub, 12.5, "#5C566B")
    rect(x + 3, y + 5, PW, PH, 26, "#00000018")
    rect(x, y, PW, PH, 24, PHONE, "#B9B1C6", 1.5)
    return x, y


def appbar(x, y, title, back=False, eye=True):
    """The app bar as the app draws it: large-ish title, optional back + eye."""
    tx = x + (52 if back else 22)
    if back:
        icon("back", x + 30, y + 40, ON_SURF)
    text(tx, y + 47, title, 21, ON_SURF, "400")
    if eye:
        icon("eye", x + PW - 32, y + 40, ON_SURF)
    return y + 74


def switch_row(x, y, ic, title, sub, on=True, h=58):
    icon(ic, x + 34, y + h / 2)
    text(x + 62, y + h / 2 + (-2 if sub else 5), title, 14.5, ON_SURF)
    if sub:
        text(x + 62, y + h / 2 + 15, sub, 11.5, ON_SURF_VAR)
    switch(x + PW - 66, y + h / 2 - 13, on)
    return y + h


def slider_row(x, y, ic, label, value, frac, h=64):
    icon(ic, x + 34, y + 20)
    text(x + 62, y + 25, label, 14.5, ON_SURF)
    text(x + PW - 22, y + 25, value, 11.5, ON_SURF_VAR, "500", "end")
    slider(x + 30, y + 46, PW - 60, frac)
    return y + h


def seg_row(x, y, ic, label, labels, sel, h=68):
    icon(ic, x + 34, y + 16)
    text(x + 62, y + 21, label, 14.5, ON_SURF)
    segmented(x + 26, y + 32, PW - 52, labels, sel)
    return y + h


def subhead(x, y, s, h=30):
    text(x + 26, y + 16, s, 13, PRIMARY, "600")
    return y + h
def panel_before(x, y):
    """Today: one flat page. Drawn as a scroll map — blocks in proportion to
    the rows each section really has, with a bracket for one screenful."""
    px, py = phone(x, y, "Now", "One page · 9 sections · ~66 rows")
    cy = appbar(px, py, "Chat Interface")
    sections = [
        ("Chat style", 7, False), ("Floating buttons", 2, False),
        ("Names", 18, False), ("Message actions", 10, False),
        ("Avatars", 15, False), ("Colours", 7, False),
        ("Group chat", 4, True), ("Response hint", 2, True),
        ("Text wrapping", 2, False),
    ]
    sx, sw = px + 26, PW - 52
    top = cy + 8
    yy = top
    for name, rows, odd in sections:
        h = max(24, rows * 8.0)
        rect(sx, yy, sw, h, 6, "#EFE4E9" if odd else PRIM_CONT,
             WARN if odd else "#C9BFE4", 1)
        text(sx + 12, yy + h / 2 + 4.5, name, 12.5,
             WARN if odd else "#3F3663", "500")
        text(sx + sw - 12, yy + h / 2 + 4.5, f"{rows} rows", 11,
             WARN if odd else "#6A619B", "400", "end")
        yy += h + 2
    # What one screen actually shows — measured off docs/screenshots/04-interface.png.
    seen = top + 56 + 2 + 24 + 1
    out.append(f'<line x1="{sx - 8}" y1="{seen}" x2="{sx + sw + 8}" '
               f'y2="{seen}" stroke="{WARN}" stroke-width="2" '
               f'stroke-dasharray="6 4"/>')
    text(sx + 12, seen + 18, "one screenful ends here", 10.5, WARN, "600")
    line(sx, yy + 10, sx + sw, yy + 10, OUTLINE_VAR)
    text(sx, yy + 34, "Reaching the bottom is eight flings.", 12, ON_SURF_VAR)
    text(sx, yy + 52, "Two of these nine sections are inert", 12, WARN)
    text(sx, yy + 68, "when opened from a chat.", 12, WARN)

def hub_row(x, y, ic, title, sub, badge=None, dim=False, h=74):
    fg = "#8F8A99" if dim else ON_SURF
    sfg = "#A29DAC" if dim else ON_SURF_VAR
    circle(x + 42, y + h / 2, 20, "#EFEBF6" if dim else SEC_CONT)
    icon(ic, x + 42, y + h / 2, "#A29DAC" if dim else ON_SEC_CONT)
    text(x + 76, y + h / 2 - 3, title, 15, fg, "500")
    text(x + 76, y + h / 2 + 16, sub, 11.5, sfg)
    if badge:
        pill(x + PW - 106, y + h / 2 - 3, badge)
    if not dim:
        chevron(x + PW - 34, y + h / 2)
    return y + h


def panel_hub(x, y):
    """The proposal: a hub of six rows, each with a live summary."""
    px, py = phone(x, y, "Proposed hub", "Six rows · every one a live summary")
    cy = appbar(px, py, "Chat Interface")
    # Named looks, so ~66 knobs have a way back.
    text(px + 26, cy + 16, "STYLE", 10.5, ON_SURF_VAR, "600")
    chips = [("Bubbles", True), ("Document", False), ("Compact", False),
             ("Roleplay", False)]
    cx = px + 26
    for label, on in chips:
        w = len(label) * 6.6 + 26
        rect(cx, cy + 26, w, 30, 15, PRIM_CONT if on else "none",
             PRIMARY if on else OUTLINE, 1)
        text(cx + w / 2, cy + 46, label, 12, PRIMARY if on else ON_SURF,
             "500" if on else "400", "middle")
        cx += w + 8
    yy = cy + 68
    yy = hub_row(px, yy, "layout", "Layout & spacing",
                 "Bubbles · Beside · Medium · 14 px", "2 changed")
    yy = hub_row(px, yy, "person", "Avatars", "Both shown · 56 px · Circle")
    yy = hub_row(px, yy, "badge", "Names",
                 "Shown · synced · above the message", "1 changed")
    yy = hub_row(px, yy, "palette", "Colours", "Theme, with 2 overridden")
    yy = hub_row(px, yy, "textA", "Text",
                 "16 px · Markdown on · 1 wrapping rule")
    yy = hub_row(px, yy, "dots", "Message actions", "3 inline · 5 in the menu")
    line(px + 26, yy + 10, px + PW - 26, yy + 10, OUTLINE_VAR)
    yy = hub_row(px, yy + 18, "group", "Group chat bar",
                 "Hidden — group chats are off", None, True)
    text(px + 26, yy + 26, "Response hint and the group-chats switch",
         11.5, WARN)
    text(px + 26, yy + 42, "move out — neither is an interface setting.",
         11.5, WARN)
def tonal_button(x, y, label, w=None):
    w = w or len(label) * 7.0 + 40
    rect(x, y, w, 38, 19, SEC_CONT)
    text(x + w / 2, y + 24, label, 12.5, ON_SEC_CONT, "500", "middle")
    return y + 38


def panel_avatars(x, y):
    """One editor for both sides — the fold that deletes ~30 duplicated rows."""
    px, py = phone(x, y, "Avatars", "One editor, a side selector — not two cards")
    cy = appbar(px, py, "Avatars", back=True)
    segmented(px + 26, cy + 10, PW - 52, ["Character", "You", "Both"], 2, 40, 13)
    text(px + 30, cy + 70, "Synced, so both sides move together.", 11.5,
         ON_SURF_VAR)
    text(px + PW - 30, cy + 70, "Unsync", 11.5, PRIMARY, "500", "end")
    yy = cy + 82
    yy = switch_row(px, yy, "eye", "Show avatar", None, True)
    # Size: slider and a typed value, as the page already does.
    icon("person", px + 34, yy + 20)
    text(px + 62, yy + 25, "Size", 14.5, ON_SURF)
    rect(px + PW - 96, yy + 6, 70, 28, 4, "none", OUTLINE, 1)
    text(px + PW - 34, yy + 25, "56  px", 12, ON_SURF, "400", "end")
    slider(px + 30, yy + 50, PW - 60, 0.18)
    yy += 72
    yy = seg_row(px, yy, "corner", "Corners", ["Circle", "Rounded", "Square"], 1)
    text(px + 62, yy + 26, "Roundness", 14.5, ON_SURF_VAR)
    text(px + PW - 30, yy + 26, "M  ▾", 13, PRIMARY, "500", "end")
    yy += 46
    yy = seg_row(px, yy, "crop", "Image fit", ["Fill", "Fit", "Free"], 0)
    yy = seg_row(px, yy, "hspace", "Side", ["Left", "Right"], 0)
    # Nudge: one pad instead of two sliders plus a reset tile.
    icon("move", px + 34, yy + 34)
    text(px + 62, yy + 22, "Position", 14.5, ON_SURF)
    text(px + 62, yy + 41, "Drag here, or on the preview", 11.5, ON_SURF_VAR)
    rect(px + PW - 96, yy + 6, 66, 66, 8, "#F1ECF8", OUTLINE_VAR, 1)
    line(px + PW - 96, yy + 39, px + PW - 30, yy + 39, OUTLINE_VAR, 1, 0.6)
    line(px + PW - 63, yy + 6, px + PW - 63, yy + 72, OUTLINE_VAR, 1, 0.6)
    circle(px + PW - 74, yy + 47, 7, PRIMARY)
    yy += 84
    tonal_button(px + 26, yy, "Reset avatars to defaults")
    text(px + 26, yy + 68, "Sliders, corners, fit and side collapse from",
         11.5, PRIMARY)
    text(px + 26, yy + 84, "two identical cards into one.", 11.5, PRIMARY)
def panel_layout(x, y):
    """A spoke that gathers everything about the shape of a turn."""
    px, py = phone(x, y, "Layout & spacing",
                   "The floating buttons come home here")
    cy = appbar(px, py, "Layout & spacing", back=True)
    yy = cy + 6
    yy = switch_row(px, yy, "bubble", "Bubbles", "Tinted bubbles per turn", True)
    yy = seg_row(px, yy, "layout", "Text placement",
                 ["Beside", "Below", "Around"], 0)
    yy = seg_row(px, yy, "cols", "Content width",
                 ["Narrow", "Medium", "Wide", "Full"], 1)
    yy = slider_row(px, yy, "drop", "Bubble opacity", "100%", 1.0)
    yy = slider_row(px, yy, "vspace", "Message spacing", "14 px", 0.29)
    line(px + 26, yy + 12, px + PW - 26, yy + 12, OUTLINE_VAR)
    yy = subhead(px, yy + 18, "Floating buttons")
    yy = slider_row(px, yy, "dots", "Menu button", "50%", 0.5)
    yy = slider_row(px, yy, "vspace", "Jump to latest", "50%", 0.5)
    yy = tonal_button(px + 26, yy + 8, "Reset layout to defaults")
    text(px + 26, yy + 34, "Everything that decides the shape of a turn,",
         11.5, PRIMARY)
    text(px + 26, yy + 50, "in one place you can see at once.", 11.5, PRIMARY)


def main():
    xs = [56, 512, 968, 1424]
    top = 176
    w, h = xs[-1] + PW + 56, top + PH + 92
    out.append(f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" '
               f'height="{h}" viewBox="0 0 {w} {h}">')
    rect(0, 0, w, h, 0, CANVAS)
    text(56, 74, "MaiChat · Chat Interface, reorganised", 30, "#241F33", "600")
    text(56, 104, "Hub and spoke (A) + folded avatar/name symmetry (D) + the "
                  "two non-interface sections moved out (F).", 15, "#5C566B")
    text(56, 126, "A mock, not a screenshot — nothing in the app has changed.",
         13, WARN, "500")
    panel_before(xs[0], top)
    panel_hub(xs[1], top)
    panel_avatars(xs[2], top)
    panel_layout(xs[3], top)
    text(56, h - 34, "Drawn by docs/mocks/gen_interface_mock.py · palette is "
                     "the app's own M3 light scheme from seed #7C5CFF.",
         12, "#6E687C")
    out.append("</svg>")
    with open("docs/mocks/chat-interface-reorg.svg", "w") as f:
        f.write("\n".join(out))
    print(f"wrote docs/mocks/chat-interface-reorg.svg ({w}x{h})")


if __name__ == "__main__":
    main()
