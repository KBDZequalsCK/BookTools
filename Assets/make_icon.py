#!/usr/bin/env python3
"""Build AppIcon.icns from the generated 1024x1024 master artwork."""
import os
import sys
from PIL import Image, ImageDraw, ImageFilter

SRC = sys.argv[1] if len(sys.argv) > 1 else "vibe_images/booktools-icon-v1_1794550385664_15a46dfa.png"
OUT_DIR = os.path.dirname(os.path.abspath(__file__))
MASTER = os.path.join(OUT_DIR, "AppIcon-1024.png")
ICONSET = os.path.join(OUT_DIR, "AppIcon.iconset")


def fill_gradient_corner(im: Image.Image, x0: int, y0: int) -> Image.Image:
    """Repaint the bottom-right corner with a smooth bilinear gradient so the
    platform watermark disappears without a visible seam."""
    im = im.convert("RGB")
    px = im.load()
    w, h = im.size
    top = [px[x, y0 - 1] for x in range(x0, w)]
    left = [px[x0 - 1, y] for y in range(y0, h)]

    patch = Image.new("RGB", (w - x0, h - y0))
    pp = patch.load()
    for y in range(h - y0):
        ty = y / max(1, h - y0 - 1)
        for x in range(w - x0):
            t = top[x]
            l = left[y]
            pp[x, y] = (
                int(t[0] * (1 - ty) + l[0] * ty),
                int(t[1] * (1 - ty) + l[1] * ty),
                int(t[2] * (1 - ty) + l[2] * ty),
            )
    # feather the top and left seams slightly
    mask = Image.new("L", patch.size, 255)
    md = ImageDraw.Draw(mask)
    for i in range(10):
        v = int(255 * i / 10)
        md.line([(0, i), (patch.width, i)], fill=v)
        md.line([(i, 0), (i, patch.height)], fill=v)
    im.paste(patch, (x0, y0), mask)
    return im


def rounded_mask(size: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    # soften the silhouette edge a hair so it scales cleanly
    return mask.filter(ImageFilter.GaussianBlur(0.6))


def main() -> None:
    src = Image.open(SRC).convert("RGBA")
    src = fill_gradient_corner(src, 850, 910).convert("RGBA")

    canvas = 1024
    content = 824
    margin = (canvas - content) // 2
    radius = 186

    icon = src.resize((content, content), Image.LANCZOS)
    mask = rounded_mask(content, radius)
    icon.putalpha(mask)

    shadow = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle(
        (margin, margin + 8, margin + content - 1, margin + content + 7),
        radius=radius,
        fill=(0, 0, 0, 110),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(16))

    out = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    out.alpha_composite(shadow)
    out.alpha_composite(icon, (margin, margin))
    out.save(MASTER, "PNG")

    os.makedirs(ICONSET, exist_ok=True)
    for logical in (16, 32, 128, 256, 512):
        for scale, suffix in ((1, ""), (2, "@2x")):
            size = logical * scale
            out.resize((size, size), Image.LANCZOS).save(
                os.path.join(ICONSET, f"icon_{logical}x{logical}{suffix}.png"), "PNG"
            )
    print("master:", MASTER)
    print("iconset:", ICONSET)


if __name__ == "__main__":
    main()
