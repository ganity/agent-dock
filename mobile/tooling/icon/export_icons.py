from __future__ import annotations

import subprocess
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[2]
MASTER_SVG = ROOT / "assets/app_icon/app_icon_master.svg"
MASTER_PNG = ROOT / "assets/app_icon/app_icon_master.png"

IOS_DIR = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
ANDROID_DIR = ROOT / "android/app/src/main/res"

IOS_SIZES = {
    "Icon-App-20x20@1x.png": 20,
    "Icon-App-20x20@2x.png": 40,
    "Icon-App-20x20@3x.png": 60,
    "Icon-App-29x29@1x.png": 29,
    "Icon-App-29x29@2x.png": 58,
    "Icon-App-29x29@3x.png": 87,
    "Icon-App-40x40@1x.png": 40,
    "Icon-App-40x40@2x.png": 80,
    "Icon-App-40x40@3x.png": 120,
    "Icon-App-60x60@2x.png": 120,
    "Icon-App-60x60@3x.png": 180,
    "Icon-App-76x76@1x.png": 76,
    "Icon-App-76x76@2x.png": 152,
    "Icon-App-83.5x83.5@2x.png": 167,
    "Icon-App-1024x1024@1x.png": 1024,
}

ANDROID_SIZES = {
    "mipmap-mdpi/ic_launcher.png": 48,
    "mipmap-hdpi/ic_launcher.png": 72,
    "mipmap-xhdpi/ic_launcher.png": 96,
    "mipmap-xxhdpi/ic_launcher.png": 144,
    "mipmap-xxxhdpi/ic_launcher.png": 192,
}


def render_master_png() -> None:
    subprocess.run(
        [
            "rsvg-convert",
            "-w",
            "1024",
            "-h",
            "1024",
            str(MASTER_SVG),
            "-o",
            str(MASTER_PNG),
        ],
        check=True,
    )


def save_resized(source: Image.Image, output: Path, size: int) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    icon = source.resize((size, size), Image.Resampling.LANCZOS)
    icon.save(output, format="PNG")


def main() -> None:
    render_master_png()
    with Image.open(MASTER_PNG) as master:
        master = master.convert("RGBA")
        for name, size in IOS_SIZES.items():
            save_resized(master, IOS_DIR / name, size)
        for relative_path, size in ANDROID_SIZES.items():
            save_resized(master, ANDROID_DIR / relative_path, size)


if __name__ == "__main__":
    main()
