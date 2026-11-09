#!/usr/bin/env python3
import os
import shutil
import subprocess
import tempfile

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICON_DIR = os.path.join(ROOT, "assets", "icon")
ASSETS = os.path.join(ROOT, "assets")
# The finished app icon: 1024 px, already rounded, with the standard margin around it.
APP_ICON = os.path.join(ICON_DIR, "app-icon-1024.png")

def svg_to_png(svg, size, out):
    subprocess.run(["rsvg-convert", "-w", str(size), "-h", str(size), "-a", "-o", out, svg], check=True)
    return Image.open(out).convert("RGBA")

def build_icns(icon, tmp):
    iconset = os.path.join(tmp, "AppIcon.iconset")
    os.makedirs(iconset)
    for base in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = base * scale
            name = f"icon_{base}x{base}{'@2x' if scale == 2 else ''}.png"
            icon.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, name))
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(ASSETS, "AppIcon.icns")], check=True)

def menubar(tmp):
    for state in ("off", "on"):
        svg = os.path.join(ICON_DIR, f"menubar-{state}.svg")
        for scale, suffix in ((1, ""), (2, "@2x"), (3, "@3x")):
            px = 18 * scale
            img = svg_to_png(svg, px, os.path.join(tmp, f"mb-{state}{suffix}.png"))
            black = Image.new("RGBA", img.size, (0, 0, 0, 255))
            black.putalpha(img.getchannel("A"))
            black.save(os.path.join(ASSETS, f"menubar_{state}{suffix}.png"))

def main():
    tmp = tempfile.mkdtemp()
    try:
        build_icns(Image.open(APP_ICON).convert("RGBA"), tmp)
        menubar(tmp)
    finally:
        shutil.rmtree(tmp)
    print("wrote assets/AppIcon.icns, assets/menubar_*.png")

if __name__ == "__main__":
    main()
