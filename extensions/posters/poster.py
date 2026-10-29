#!/usr/bin/env python3
"""A poster: a halftone background in one colour, a small eyebrow line over a big title (the look of the Matrix cards).

  poster.py --eyebrow TEXT --title TEXT [--color NAME|#RRGGBB] [--seed N] [--size WxH] [--case upper|keep]
            [--out FILE|FOLDER] [--force]
  poster.py --list-colors

Eyebrow and title are required. Colour and seed are made up when left out: the seed first (random), the colour from
the seed, so the same seed always gives the same poster. The file is named poster-<title>-<seed>.png in the current
folder unless --out is given (a file, or a folder that already exists: the poster goes in with that name); an existing file is only replaced with --force.

Output (plain key<TAB>value lines, what `hs sys ext posters generate` prints):
  status ok|refused        reason <text> (refused)    needs pillow (exit 2, Pillow is not installed)
  file <path>   color <name or #hex>   seed <n>   size <WxH>
Exit 0 = drawn, 1 = refused (bad input), 2 = something missing.

Needs Pillow (python3Packages.pillow, in configuration.nix). Fonts: Inter from the Matrix cards (HS_POSTER_FONTS overrides).
"""
import colorsys
import math
import os
import random
import re
import sys
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
FONTS = os.environ.get("HS_POSTER_FONTS") or os.path.join(HERE, "fonts")

# name -> hue in degrees
COLORS = {"red": 355, "orange": 24, "yellow": 44, "green": 148, "teal": 175, "blue": 222, "indigo": 245, "purple": 280, "pink": 325}
BG = (0x12, 0x14, 0x20)
DESIGN_W, DESIGN_H = 768, 432        # the layout is drawn for this size and scaled


def out(key, value):
    print("%s\t%s" % (key, value))


def refuse(reason, code=1):
    out("status", "refused")
    out("reason", reason)
    sys.exit(code)


def parse_args(argv):
    opts = {"case": "upper"}
    flags = {"--force": "force", "--list-colors": "list"}
    values = {"--eyebrow", "--title", "--color", "--seed", "--size", "--case", "--out"}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in flags:
            opts[flags[a]] = True
        elif a in values and i + 1 < len(argv):
            opts[a[2:]] = argv[i + 1]
            i += 1
        else:
            refuse("unknown or incomplete option: %s" % a)
        i += 1
    return opts


def parse_color(value):
    """(label, hue, saturation hint or None) from a colour name or #rrggbb."""
    v = value.strip().lower()
    if v in COLORS:
        return v, COLORS[v], None
    m = re.fullmatch(r"#?([0-9a-f]{6})", v)
    if not m:
        refuse("colour '%s' is not a name (%s) or a #rrggbb value" % (value, ", ".join(COLORS)))
    r, g, b = (int(m.group(1)[k:k + 2], 16) / 255 for k in (0, 2, 4))
    h, l, s = colorsys.rgb_to_hls(r, g, b)
    return "#" + m.group(1), h * 360, s


def hls(h, l, s):
    return tuple(int(round(c * 255)) for c in colorsys.hls_to_rgb((h % 360) / 360, l, s))


def palette(hue, sat_hint):
    """Dots, glow and the pale tint of the eyebrow for a hue. The lightness is fixed, so every colour reads like the others."""
    s_dots = 0.7 if sat_hint is None else min(0.85, max(0.45, sat_hint))
    s_glow = 0.8 if sat_hint is None else min(0.9, max(0.5, sat_hint + 0.1))
    glow = hls(hue, 0.55, s_glow)
    return {"dots": hls(hue, 0.37, s_dots), "glow": glow, "tint": tuple(min(255, int(c * 0.35 + 255 * 0.65)) for c in glow)}


def slug(text):
    t = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", "-", t.lower()).strip("-")[:40] or "poster"


def render(eyebrow, title, hue, sat_hint, seed, width, height):
    from PIL import Image, ImageDraw, ImageFilter, ImageFont
    z = min(width / DESIGN_W, height / DESIGN_H)
    pal = palette(hue, sat_hint)
    rnd = random.Random(seed)
    img = Image.new("RGB", (width, height), BG)

    def radial(cx, cy, rx, ry, peak):
        w4, h4 = max(1, width // 4), max(1, height // 4)
        m = Image.new("L", (w4, h4))
        m.putdata([int(255 * peak * max(0.0, 1 - math.hypot((x * 4 - cx) / rx, (y * 4 - cy) / ry)) ** 1.6) for y in range(h4) for x in range(w4)])
        return m.resize((width, height), Image.BICUBIC)

    # the glow sits in two opposite corners (which pair depends on the seed), the middle stays dark for the text
    flip = rnd.random() < 0.5
    corners = [(60 * z, 30 * z), (width - 40 * z, height - 20 * z)]
    if flip:
        corners = [(width - 60 * z, 30 * z), (40 * z, height - 20 * z)]
    for (cx, cy), peak in zip(corners, (0.22, 0.18)):
        img.paste(Image.new("RGB", (width, height), pal["glow"]), (0, 0), radial(cx, cy, 520 * z, 300 * z, peak))

    jx, jy = lambda: (rnd.random() - 0.5) * 0.08, lambda: (rnd.random() - 0.5) * 0.06
    (a, b) = ((0.92 + jx(), 0.12 + jy()), (0.07 + jx(), 0.9 + jy())) if flip else ((0.08 + jx(), 0.12 + jy()), (0.93 + jx(), 0.9 + jy()))
    blobs = [(width * a[0], height * a[1], 95 * z, 0.9, 1.5), (width * b[0], height * b[1], 105 * z, 0.9, 1.4),
             (width * (0.45 + rnd.random() * 0.5), height * 0.05, 70 * z, 0.55, 1.7),
             (width * (0.05 + rnd.random() * 0.4), height * 0.95, 70 * z, 0.55, 1.6)]
    pitch, k = 7 * z, 3 if z <= 1.2 else 2
    mask = Image.new("L", (int(width * k), int(height * k)), 0)
    d = ImageDraw.Draw(mask)
    half, row, y = pitch / 2, 0, 0.0
    while y < height + pitch:
        x = (row % 2) * half
        while x < width + pitch:
            f = 0.0
            for bx, by, sg, amp, kk in blobs:
                dx, dy = (x - bx) / kk, y - by
                f += amp * math.exp(-(dx * dx + dy * dy) / (2 * sg * sg))
            c = math.hypot((x - width / 2) / (width * 0.34), (y - height / 2) / (height * 0.30))     # fade out behind the text
            t = min(1.0, max(0.0, (c - 0.35) / 1.0))
            f *= t * t * (3 - 2 * t)
            f = 0.36 * (1 - math.exp(-f * 1.8))
            if f >= 0.012:
                r = pitch * 0.53 * math.sqrt(f) * k
                d.ellipse((x * k - r, y * k - r, x * k + r, y * k + r), fill=255)
            x += pitch
        y += half
        row += 1
    img.paste(Image.new("RGB", (width, height), pal["dots"]), (0, 0), mask.resize((width, height), Image.LANCZOS))

    def font(name, size):
        return ImageFont.truetype(os.path.join(FONTS, name), max(1, int(round(size))))

    def span(text, f, ls):
        return sum(f.getlength(ch) for ch in text) + ls * (len(text) - 1)

    def text(txt, cy, f, ls, fill):
        x = width / 2 - span(txt, f, ls) / 2
        shadow = Image.new("RGBA", (width, height), (0, 0, 0, 0))
        sd = ImageDraw.Draw(shadow)
        xx = x
        for ch in txt:
            sd.text((xx, cy + 4 * z), ch, font=f, fill=(0, 0, 0, 200), anchor="lm")
            xx += f.getlength(ch) + ls
        shadow = shadow.filter(ImageFilter.GaussianBlur(7 * z))
        img.paste(shadow, (0, 0), shadow)
        dd = ImageDraw.Draw(img)
        xx = x
        for ch in txt:
            dd.text((xx, cy), ch, font=f, fill=fill, anchor="lm")
            xx += f.getlength(ch) + ls

    room = width * 0.82
    size, ls = 116 * z, 6 * z
    while span(title, font("Inter-SemiBold.ttf", size), ls) > room and size > 116 * z * 0.22:
        size, ls = size * 0.94, ls * 0.94
    if span(title, font("Inter-SemiBold.ttf", size), ls) > room:
        refuse("the title is too long for the poster (%d characters)" % len(title))
    esize, els = 32 * z, 9 * z
    while span(eyebrow, font("Inter-Medium.ttf", esize), els) > room and esize > 32 * z * 0.4:
        esize, els = esize * 0.94, els * 0.94
    text(eyebrow, height / 2 - 82 * z * (size / (116 * z)) ** 0.5, font("Inter-Medium.ttf", esize), els, pal["tint"])
    text(title, height / 2 + 18 * z, font("Inter-SemiBold.ttf", size), ls, (255, 255, 255))
    return img


def main(argv):
    o = parse_args(argv)
    if o.get("list"):
        print("\n".join(COLORS))
        return 0
    eyebrow, title = (o.get("eyebrow") or "").strip(), (o.get("title") or "").strip()
    if not eyebrow:
        refuse("the eyebrow (the small line above the title) is required")
    if not title:
        refuse("the title is required")
    if o["case"] not in ("upper", "keep"):
        refuse("--case is upper or keep")
    if o["case"] == "upper":
        eyebrow, title = eyebrow.upper(), title.upper()

    seed = o.get("seed")
    if seed is None:
        seed = random.SystemRandom().randrange(1, 10 ** 6)
    else:
        if not re.fullmatch(r"\d{1,9}", str(seed)):
            refuse("the seed is a whole number (up to 9 digits)")
        seed = int(seed)
    if o.get("color"):
        label, hue, sat_hint = parse_color(o["color"])
    else:                                    # from the seed: the same seed, the same colour
        hue = random.Random(seed * 7919 + 13).uniform(0, 360)
        label, sat_hint = "random #%03d" % int(hue), None

    m = re.fullmatch(r"(\d{3,4})x(\d{3,4})", o.get("size", "1920x1080"))
    if not m or not (256 <= int(m.group(1)) <= 7680 and 144 <= int(m.group(2)) <= 4320):
        refuse("the size is WIDTHxHEIGHT, for example 1920x1080 (256x144 up to 7680x4320)")
    width, height = int(m.group(1)), int(m.group(2))

    default = "poster-%s-%d.png" % (slug(title), seed)
    path = o.get("out") or default
    if os.path.isdir(path):                       # a folder: the poster goes in with its default name
        path = os.path.join(path, default)
    if not path.lower().endswith(".png"):
        path += ".png"
    path = os.path.abspath(path)
    if not os.path.isdir(os.path.dirname(path)):
        refuse("the folder %s does not exist" % os.path.dirname(path))
    if os.path.exists(path) and not o.get("force"):
        refuse("%s exists already (--force replaces it)" % path)

    try:
        import PIL  # noqa: F401
    except ImportError:
        out("status", "refused")
        out("needs", "pillow")
        out("reason", "Pillow is not installed (python3Packages.pillow); hs rebuild installs it")
        return 2
    try:
        img = render(eyebrow, title, hue, sat_hint, seed, width, height)
        img.save(path, optimize=True)
    except OSError as e:
        refuse("cannot draw or write the poster: %s" % e, 2)
    out("status", "ok")
    out("file", path)
    out("color", label)
    out("seed", seed)
    out("size", "%dx%d" % (width, height))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
