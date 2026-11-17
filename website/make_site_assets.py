"""Builds the Aperta website image assets into website/aperta/assets/.

Geometry matches ApertureMark in Sources/Theme/Components.swift and tools/make_icon.py:
a ring and six blades, openness 0.28.

Writes: favicon.svg, aperta-mark.svg, favicon-32.png, apple-touch-icon.png, icon-512.png, og-image.png
Usage: python website/make_site_assets.py     (needs Pillow)
"""
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "website" / "aperta" / "assets"
ICON = ROOT / "Sources" / "Resources" / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon-1024.png"
OUT.mkdir(parents=True, exist_ok=True)

OPEN = 0.28


def blade_lines(cx, cy, R):
    """Return the six blade segments as (x1, y1, x2, y2)."""
    beta = math.acos(OPEN)
    vr = R * OPEN / math.cos(math.pi / 6)
    segs = []
    for i in range(6):
        a = i / 6 * 2 * math.pi
        segs.append((cx + math.cos(a + beta) * R, cy + math.sin(a + beta) * R,
                     cx + math.cos(a - math.pi / 6) * vr, cy + math.sin(a - math.pi / 6) * vr))
    return segs


def mark_svg(bg, size=100, ring=0.335 * 100, lw=1.8):
    c = size / 2
    lines = "".join(f'<line x1="{x1:.2f}" y1="{y1:.2f}" x2="{x2:.2f}" y2="{y2:.2f}"/>'
                    for x1, y1, x2, y2 in blade_lines(c, c, ring))
    bgrect = f'<rect width="{size}" height="{size}" rx="22.4" fill="#0C0D0F"/>' if bg else ""
    inner = (f'<defs><linearGradient id="b" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="0" y2="{size}"><stop offset="0" stop-color="#E6C78C"/>'
             f'<stop offset="1" stop-color="#B89252"/></linearGradient></defs>')
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {size} {size}" role="img" aria-label="Aperta">'
            f'<title>Aperta</title>{inner}{bgrect}'
            f'<g fill="none" stroke="url(#b)" stroke-width="{lw}" stroke-linecap="round">'
            f'<circle cx="{c}" cy="{c}" r="{ring}"/>{lines}</g></svg>\n')


def fonts(size, serif=True):
    cands = (["C:/Windows/Fonts/georgia.ttf"] if serif else ["C:/Windows/Fonts/segoeui.ttf"]) + [
        "/usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf" if serif else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"]
    for p in cands:
        if Path(p).exists():
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()


def rounded_icon(px):
    icon = Image.open(ICON).convert("RGB").resize((px, px), Image.LANCZOS)
    mask = Image.new("L", (px * 4, px * 4), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, px * 4 - 1, px * 4 - 1], radius=int(px * 4 * 0.2237), fill=255)
    mask = mask.resize((px, px), Image.LANCZOS)
    out = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    out.paste(icon, (0, 0), mask)
    return out


def main():
    (OUT / "favicon.svg").write_text(mark_svg(True), encoding="utf-8")
    (OUT / "aperta-mark.svg").write_text(mark_svg(False), encoding="utf-8")
    icon = Image.open(ICON).convert("RGB")
    icon.resize((180, 180), Image.LANCZOS).save(OUT / "apple-touch-icon.png", optimize=True)
    rounded_icon(512).save(OUT / "icon-512.png", optimize=True)
    rounded_icon(32).save(OUT / "favicon-32.png", optimize=True)

    W, H = 1200, 630
    img = Image.new("RGB", (W, H), "#0C0D0F")
    d = ImageDraw.Draw(img)
    d.rectangle([0, H - 10, W, H], fill="#D2AE6E")
    d.rectangle([80, 96, 80 + 64, 99], fill="#D2AE6E")
    d.text((80, 128), "Photo Editor & Collage:", font=fonts(62), fill="#EDEAE3")
    d.text((80, 204), "Aperta", font=fonts(96), fill="#D2AE6E")
    d.text((80, 344), "A free photo editor for iPhone.", font=fonts(36, False), fill="#A3A5AB")
    d.text((80, 392), "Photos are edited on your device.", font=fonts(36, False), fill="#A3A5AB")
    d.text((80, 520), "Collage   Resize   Compress   Convert   ID photo", font=fonts(28, False), fill="#EDEAE3")
    ic = rounded_icon(340)
    img.paste(ic, (W - 340 - 100, (H - 340) // 2 - 5), ic)
    img.save(OUT / "og-image.png", optimize=True)
    print("assets written to", OUT)


if __name__ == "__main__":
    main()
