#!/usr/bin/env python3
"""Generate the Markive app icons from the vector master.

`markive-icon.svg` is the source of truth. This script rasterizes it to
a 1024px straight-alpha PNG and hands that to `tauri icon`, which emits
the full platform set into src-tauri/icons (icns, ico, and the PNG
ladder).

Rasterizing uses QuickLook (qlmanage, WebKit-backed) so the SVG's
gradients render faithfully. QuickLook can't emit an alpha channel — it
composites transparent regions onto an opaque background — so the SVG
is rendered twice, on white and on black, and the true straight alpha
is recovered from the pair. Without this the rounded-corner icon ships
with opaque corners.
"""

import os
import re
import subprocess
import tempfile

from PIL import Image, ImageMath

HERE = os.path.dirname(os.path.abspath(__file__))
SVG_PATH = os.path.join(HERE, "markive-icon.svg")


def full_bleed(svg_text):
    """Squares off the icon for the OS icon set.

    macOS 26 composites app icons onto a system-drawn rounded
    rectangle; art with baked-in rounded corners shows the backing
    plate as white corners. The OS applies its own mask, so the icns
    gets full-bleed art: the canvas rects lose their radius and the
    rounded outline stroke goes away.
    """
    svg_text = svg_text.replace(
        '<rect width="1024" height="1024" rx="224"', '<rect width="1024" height="1024"'
    )
    return re.sub(r'<rect x="4" y="4"[^>]*rx="220"[^>]*></rect>', "", svg_text)


def _render_on(svg_text, bg_hex, size, out_dir, tag):
    """Render the SVG via QuickLook onto an opaque `bg_hex` background."""
    variant = re.sub(
        r"(<svg\b[^>]*>)",
        r'\1<rect width="1024" height="1024" fill="%s"/>' % bg_hex,
        svg_text,
        count=1,
    )
    svg_file = os.path.join(out_dir, f"variant_{tag}.svg")
    with open(svg_file, "w") as f:
        f.write(variant)
    subprocess.run(
        ["qlmanage", "-t", "-s", str(size), "-o", out_dir, svg_file],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    png = svg_file + ".png"
    if not os.path.exists(png):
        raise RuntimeError(f"qlmanage did not produce {png}")
    return Image.open(png).convert("RGB")


def rasterize_rgba(svg_text, size, out_dir):
    """Rasterize the SVG to a straight-alpha RGBA image at `size`x`size`.

    From two opaque renders (per channel, 0..255):
        white = a*color + (1 - a)*255
        black = a*color
    so  a = 1 - (white - black)/255  and  color = black / a.
    """
    white = _render_on(svg_text, "#ffffff", size, out_dir, "w")
    black = _render_on(svg_text, "#000000", size, out_dir, "b")
    _, wg, _ = white.split()
    br, bg, bb = black.split()
    alpha = ImageMath.unsafe_eval("255 - (w - b)", w=wg, b=bg).convert("L")

    def unpremult(channel):
        return ImageMath.unsafe_eval(
            "convert(min(c * 255 / max(a, 1), 255), 'L')", c=channel, a=alpha
        ).convert("L")

    return Image.merge("RGBA", (unpremult(br), unpremult(bg), unpremult(bb), alpha))


def main():
    if not os.path.exists(SVG_PATH):
        raise SystemExit(f"Missing vector master: {SVG_PATH}")

    svg_text = full_bleed(open(SVG_PATH).read())
    with tempfile.TemporaryDirectory() as tmp:
        master = rasterize_rgba(svg_text, 1024, tmp)
        if master.size != (1024, 1024):
            master = master.resize((1024, 1024), Image.LANCZOS)

        source = os.path.join(tmp, "markive-icon-1024.png")
        master.save(source)
        subprocess.run(
            ["npm", "run", "tauri", "icon", source], check=True, cwd=HERE
        )

    print("Regenerated src-tauri/icons from markive-icon.svg")


if __name__ == "__main__":
    main()
