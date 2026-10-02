"""生成 FileView 预览的飞牛应用图标（64 / 256 两档）。

用的是 **BaseMetas FileView 官方 logo**（`assets/fileview-logo.png`，
取自官网 fileview.basemetas.cn 的 favicon：320x320、透明底 + 圆形主体），
外面套一层飞牛风格的圆角方形磁贴。

⚠️ 官方 logo 是 BaseMetas 的商标 / 素材。本仓库是第三方打包工程，自用没问题；
   若要公开发布，建议先确认对方对 logo 的使用态度。
   不想用官方 logo 时，把本脚本换成自绘几何图形、再重跑一次即可。

依赖 Pillow：pip install pillow
用法：python gen_icons.py
"""

import os

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
LOGO = os.path.join(HERE, "assets", "fileview-logo.png")

SIZE = 256
SS = 4                       # 超采样倍数：先画 4 倍再缩，边缘更干净
RADIUS_RATIO = 0.225         # 圆角半径 / 边长，贴近飞牛系统图标的观感

# 磁贴底色 = 与官方 logo 圆边同向的斜向渐变（取自 logo 自身的采样值）。
# 为什么必须是「同向渐变」而不是纯色：logo 的圆边有一圈颜色随角度变化的柔光
# （左上偏白蓝、右下偏青蓝），纯色铺底会在圆边露出一圈可见的接缝。
TILE_TL = (186, 231, 255)
TILE_BR = (134, 211, 255)


def rounded_mask(size, radius):
    m = Image.new("L", (size * SS, size * SS), 0)
    ImageDraw.Draw(m).rounded_rectangle(
        [0, 0, size * SS - 1, size * SS - 1], radius=radius * SS, fill=255
    )
    return m.resize((size, size), Image.LANCZOS)


def build(size):
    S = size * SS

    grad = Image.new("RGBA", (S, S))
    gd = ImageDraw.Draw(grad)
    for i in range(2 * S):
        t = i / max(1, 2 * S - 1)
        gd.line(
            [(i, 0), (0, i)],
            fill=tuple(
                round(TILE_TL[c] + (TILE_BR[c] - TILE_TL[c]) * t) for c in range(3)
            ) + (255,),
            width=2,
        )

    mask = rounded_mask(size, round(size * RADIUS_RATIO)).resize((S, S), Image.NEAREST)
    tile = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    tile.paste(grad, (0, 0), mask)

    # 官方 logo 用 alpha 合成叠上去 —— 它自己那圈柔光得以保留，边界最轻
    logo = Image.open(LOGO).convert("RGBA").resize((S, S), Image.LANCZOS)
    tile = Image.alpha_composite(tile, logo)

    tile.putalpha(mask)
    return tile.resize((size, size), Image.LANCZOS)


def main():
    if not os.path.isfile(LOGO):
        raise SystemExit(f"缺少素材：{LOGO}")

    root = os.path.dirname(HERE)                       # fpk/
    app = os.path.join(root, "basemetas-fileview")

    icon256 = build(256)
    icon64 = build(64)
    targets = [
        (os.path.join(app, "ICON.PNG"), icon64),                            # 应用中心 / 安装包识别
        (os.path.join(app, "ICON_256.PNG"), icon256),
        (os.path.join(app, "app", "ui", "images", "icon_64.png"), icon64),  # 桌面 / 打开方式
        (os.path.join(app, "app", "ui", "images", "icon_256.png"), icon256),
    ]

    for path, img in targets:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        img.save(path, "PNG")
        print(f"生成 {os.path.relpath(path, root)}  ({img.width}x{img.height})")


if __name__ == "__main__":
    main()
