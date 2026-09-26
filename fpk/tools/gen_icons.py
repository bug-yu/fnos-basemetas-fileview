"""生成 FileView 预览的飞牛应用图标（64 / 256 两档）。

纯几何绘制 + 4 倍超采样，避免依赖任何字体文件。
用法：python gen_icons.py
"""

import os

from PIL import Image, ImageDraw

BLUE = (24, 95, 165, 255)
BLUE_LIGHT = (133, 183, 235, 255)
WHITE = (255, 255, 255, 255)

SCALE = 4
SIZE = 256


def s(value):
    return int(round(value * SCALE))


def draw_icon():
    canvas = s(SIZE)
    img = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    d.rounded_rectangle([0, 0, canvas - 1, canvas - 1], radius=s(56), fill=BLUE)

    d.rounded_rectangle([s(46), s(38), s(146), s(176)], radius=s(12), fill=WHITE)

    fold = 32
    d.polygon(
        [(s(146 - fold), s(38)), (s(146), s(38)), (s(146), s(38 + fold))],
        fill=BLUE,
    )
    d.polygon(
        [(s(146 - fold), s(38)), (s(146 - fold), s(38 + fold)), (s(146), s(38 + fold))],
        fill=BLUE_LIGHT,
    )

    for y in (78, 104, 130):
        d.rounded_rectangle([s(64), s(y), s(128), s(y + 10)], radius=s(5), fill=BLUE_LIGHT)

    d.ellipse([s(130), s(130), s(222), s(222)], fill=WHITE)
    d.ellipse([s(156), s(156), s(196), s(196)], fill=BLUE)
    d.line([s(208), s(208), s(232), s(232)], fill=WHITE, width=s(22))

    return img


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    app = os.path.join(root, "basemetas-fileview")

    icon = draw_icon()
    targets = [
        (os.path.join(app, "ICON.PNG"), 64),
        (os.path.join(app, "ICON_256.PNG"), 256),
        (os.path.join(app, "app", "ui", "images", "icon_64.png"), 64),
        (os.path.join(app, "app", "ui", "images", "icon_256.png"), 256),
    ]

    for path, size in targets:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        icon.resize((size, size), Image.LANCZOS).save(path, "PNG")
        print(f"生成 {path}  ({size}x{size})")


if __name__ == "__main__":
    main()
