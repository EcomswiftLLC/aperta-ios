"""Builds the App Store screenshots (iPhone 6.9 inch, 1320 x 2868) from the CI screenshots.
Usage: python tools/make_store_shots.py <folder-with-CI-pngs> <output-folder>
Each store image is a real in-app screenshot placed under a short headline on the app's dark brand background."""
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageChops

W, H = 1320, 2868
BG, PAPER, MIST, BRASS = (12, 13, 15), (237, 234, 227), (163, 165, 171), (210, 174, 110)
SERIF = r"C:\Windows\Fonts\georgia.ttf"
SERIF_B = r"C:\Windows\Fonts\georgiab.ttf"

# (screenshot name, headline lines, sub line)
SLIDES = [
    ("shot-filters", ["Twenty-five looks.", "One tap."], "Original filters with adjustable strength"),
    ("shot-adjust", ["Dial in light", "and colour."], "Thirteen precise controls plus auto enhance"),
    ("shot-cutout", ["Lift the subject", "off its background."], "Found on your device, nothing is uploaded"),
    ("shot-crop", ["Crop and straighten", "to any shape."], "Ratios for every feed, flip and rotate"),
    ("shot-text", ["Add words,", "stickers and more."], "Text, emoji, shapes and freehand drawing"),
    ("shot-collage", ["Collages in", "seconds."], "Two to nine photos, layouts you can tune"),
    ("shot-passport", ["ID and passport", "photos at home."], "Plain background, right size, ready to print"),
    ("shot-resize", ["Resize for any", "social network."], "Exact sizes and presets, many photos at once"),
    ("shot-watermark", ["Sign your", "photos."], "Text or logo on up to twenty photos"),
    ("shot-metadata", ["See what a photo", "tells others."], "Remove location and camera details before sharing"),
]


def glow():
    img = Image.new("RGB", (W, H), BG)
    layer = Image.new("RGB", (W, H), BRASS)
    mask = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(mask)
    d.ellipse([W * 0.1, -H * 0.12, W * 0.9, H * 0.26], fill=70)
    mask = mask.filter(ImageFilter.GaussianBlur(220))
    return Image.composite(layer, img, mask)


def rounded(im, radius):
    mask = Image.new("L", im.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, im.width, im.height], radius, fill=255)
    out = im.convert("RGBA")
    out.putalpha(mask)
    return out


def main(src, dst):
    src, dst = Path(src), Path(dst)
    dst.mkdir(parents=True, exist_ok=True)
    head = ImageFont.truetype(SERIF_B, 118)
    sub = ImageFont.truetype(SERIF, 52)
    for i, (name, lines, caption) in enumerate(SLIDES, 1):
        shot_path = src / f"{name}.png"
        if not shot_path.exists():
            print("missing", shot_path)
            continue
        canvas = glow()
        d = ImageDraw.Draw(canvas)
        y = 150
        for line in lines:
            d.text((W / 2, y), line, font=head, fill=PAPER, anchor="ma")
            y += 140
        d.text((W / 2, y + 22), caption, font=sub, fill=MIST, anchor="ma")
        shot = Image.open(shot_path).convert("RGB")
        scale = 1120 / shot.width
        shot = shot.resize((1120, round(shot.height * scale)), Image.LANCZOS)
        framed = rounded(shot, 96)
        top = 640
        # soft shadow
        shadow = Image.new("RGBA", (framed.width + 160, framed.height + 160), (0, 0, 0, 0))
        ImageDraw.Draw(shadow).rounded_rectangle([80, 80, 80 + framed.width, 80 + framed.height], 96, fill=(0, 0, 0, 170))
        shadow = shadow.filter(ImageFilter.GaussianBlur(40))
        canvas.paste(shadow, ((W - framed.width) // 2 - 80, top - 80), shadow)
        # thin brass edge
        edge = Image.new("RGBA", (framed.width + 6, framed.height + 6), (0, 0, 0, 0))
        ImageDraw.Draw(edge).rounded_rectangle([0, 0, edge.width - 1, edge.height - 1], 99, outline=(210, 174, 110, 120), width=3)
        canvas.paste(edge, ((W - framed.width) // 2 - 3, top - 3), edge)
        canvas.paste(framed, ((W - framed.width) // 2, top), framed)
        out = dst / f"{i:02d}-{name.replace('shot-', '')}.png"
        canvas.convert("RGB").save(out, optimize=True)
        print("wrote", out)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
