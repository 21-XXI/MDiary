#!/usr/bin/env python3
"""生成星图概念稿（PNG + 动画 GIF），供选型用。

输出到 docs/star-map/：
  concept-a.png / concept-a.gif  星座连线
  concept-b.png / concept-b.gif  星云粒子
  concept-c.png / concept-c.gif  轨道仪
  concept-d.png                  银河卷轴（静态）
"""
import math
import os
import random

from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 1280, 800
OUT = os.path.join(os.path.dirname(__file__), "..", "docs", "star-map")
FONT = "C:/Windows/Fonts/msyh.ttc"


def font(size, bold=False):
    try:
        return ImageFont.truetype(FONT, size)
    except OSError:
        return ImageFont.load_default()


def background(seed=7):
    rnd = random.Random(seed)
    img = Image.new("RGB", (W, H), (5, 9, 20))
    px = img.load()
    for y in range(H):
        t = y / H
        r, g, b = int(5 + 6 * t), int(9 + 10 * t), int(20 + 22 * t)
        for x in range(W):
            px[x, y] = (r, g, b)
    draw = ImageDraw.Draw(img)
    for _ in range(420):
        x, y = rnd.randrange(W), rnd.randrange(H)
        v = rnd.randint(40, 110)
        draw.point((x, y), fill=(v, v + 8, min(255, v + 30)))
    return img


def glow_layer(size):
    return Image.new("RGBA", size, (0, 0, 0, 0))


def star(draw, x, y, r, color, alpha=255):
    draw.ellipse((x - r, y - r, x + r, y + r), fill=color + (alpha,))


def add_glow(img, layer, radius=8):
    glow = layer.filter(ImageFilter.GaussianBlur(radius))
    img.alpha_composite(glow)
    img.alpha_composite(layer)


def label(draw, xy, text, size=18, color=(180, 210, 255), anchor="la"):
    draw.text(xy, text, font=font(size), fill=color + (255,), anchor=anchor)


def header(draw, title, subtitle):
    label(draw, (44, 34), title, 30, (225, 238, 255))
    label(draw, (44, 76), subtitle, 15, (130, 160, 200))


# ───────────────────────── A 星座连线 ─────────────────────────

def concept_a_frame(phase):
    base = background(11).convert("RGBA")
    layer = glow_layer((W, H))
    d = ImageDraw.Draw(layer)
    rnd = random.Random(3)

    # 一周 7 个主星，沿星座路径
    pts = []
    for i in range(7):
        x = 180 + i * 145
        y = 400 + math.sin(i * 1.05) * 130
        pts.append((x, y))

    # 邻近日的暗星，制造"同一星座"的延伸
    for i in range(6):
        x = 250 + i * 145
        y = 400 + math.sin((i + 0.5) * 1.05) * 130
        r = 1.6
        star(d, x, y, r, (120, 170, 230), 120)

    # 连线
    for i in range(len(pts) - 1):
        a, b = pts[i], pts[i + 1]
        d.line((a[0], a[1], b[0], b[1]), fill=(70, 120, 190, 120), width=2)

    # 附件轨道（绕周五与周日）
    for center_index, orbit_r in ((4, 46), (6, 38)):
        cx, cy = pts[center_index]
        d.ellipse(
            (cx - orbit_r, cy - orbit_r * 0.45, cx + orbit_r, cy + orbit_r * 0.45),
            outline=(90, 140, 200, 70),
            width=1,
        )
        angle = phase * 2 * math.pi + center_index
        ox = cx + orbit_r * math.cos(angle)
        oy = cy + orbit_r * 0.45 * math.sin(angle)
        star(d, ox, oy, 3, (150, 210, 255), 230)

    # 主星 + 呼吸
    for i, (x, y) in enumerate(pts):
        pulse = 0.75 + 0.25 * math.sin(phase * 2 * math.pi + i * 0.9)
        r = 4.5 + 1.5 * pulse
        star(d, x, y, r, (200, 230, 255), 255)
        d.ellipse((x - 14, y - 14, x + 14, y + 14), outline=(120, 170, 240, 60), width=1)
        label(d, (x, y + 22), ["周一", "周二", "周三", "周四", "周五", "周六", "周日"][i], 13, (150, 185, 225), "ma")

    add_glow(base, layer, 6)
    draw = ImageDraw.Draw(base)
    header(draw, "本周 · 星座连线", "7 天 = 7 颗主星，附件绕所属日记旋转")
    label(draw, (W - 44, 40), "2026-11-02 ~ 11-08", 16, (120, 155, 200), "ra")
    label(draw, (44, H - 46), "拖拽旋转 · 滚轮缩放 · 点星打开当天", 14, (110, 140, 180))
    return base.convert("RGB")


# ───────────────────────── B 星云粒子 ─────────────────────────

def nebula_cluster(rnd, cx, cy, rx, ry, count, color, alpha):
    layer = glow_layer((W, H))
    d = ImageDraw.Draw(layer)
    for _ in range(count):
        a = rnd.uniform(0, 2 * math.pi)
        r = rnd.uniform(0, 1) ** 0.6
        x = cx + math.cos(a) * rx * r
        y = cy + math.sin(a) * ry * r
        s = rnd.randint(1, 3)
        d.ellipse(
            (x - s, y - s, x + s, y + s),
            fill=color + (int(alpha * (0.25 + 0.75 * rnd.random())),),
        )
    return layer


def concept_b_frame(phase):
    base = background(19).convert("RGBA")
    layer = glow_layer((W, H))
    rnd = random.Random(5)
    clusters = [
        (330, 360, 190, 130, 520, (90, 180, 255), 60),
        (640, 430, 220, 150, 620, (150, 120, 255), 55),
        (960, 350, 170, 120, 480, (80, 210, 200), 50),
    ]
    for cx, cy, rx, ry, count, color, alpha in clusters:
        sway = 10 * math.sin(phase * 2 * math.pi + cx)
        layer.alpha_composite(nebula_cluster(rnd, cx + sway, cy, rx, ry, count, color, alpha))

    # 星云内的一些"亮星"
    for cx, cy, *_ in clusters:
        for _ in range(14):
            x = cx + rnd.uniform(-90, 90) * 0.6
            y = cy + rnd.uniform(-60, 60) * 0.6
            star(ImageDraw.Draw(layer), x, y, rnd.uniform(1.5, 3.2), (210, 235, 255), 200)

    add_glow(base, layer, 10)
    draw = ImageDraw.Draw(base)
    header(draw, "十一月 · 星云", "一个月 = 一团星云，亮度按字数累积")
    for (cx, cy, *_), name in zip(clusters, ["九月", "十月", "十一月"]):
        label(draw, (cx, cy + 150), name, 18, (185, 210, 245), "ma")
    label(draw, (44, H - 46), "滚轮从星云缩到年度 → 再缩到全部", 14, (110, 140, 180))
    label(draw, (W - 44, 40), "31 篇 · 4 个附件", 16, (120, 155, 200), "ra")
    return base.convert("RGB")


# ───────────────────────── C 轨道仪 ─────────────────────────

def concept_c_frame(phase):
    base = background(23).convert("RGBA")
    layer = glow_layer((W, H))
    d = ImageDraw.Draw(layer)
    cx, cy = 640, 420
    rings = [(90, "日", 10), (170, "周", 7), (265, "月", 12), (360, "年", 9)]
    for idx, (r, name, count) in enumerate(rings):
        d.ellipse((cx - r, cy - r, cx + r, cy + r), outline=(70, 110, 170, 70), width=1)
        rot = phase * 2 * math.pi * (0.5 + idx * 0.35)
        for i in range(count):
            a = rot + i * 2 * math.pi / count
            x = cx + r * math.cos(a)
            y = cy + r * math.sin(a)
            star(d, x, y, 3.2, (190, 225, 255), 210)
            d.ellipse((x - 9, y - 9, x + 9, y + 9), outline=(110, 160, 230, 60), width=1)
        label(d, (cx, cy - r - 6), name, 14, (160, 195, 240), "ma")

    star(d, cx, cy, 6, (235, 245, 255), 255)
    d.ellipse((cx - 26, cy - 26, cx + 26, cy + 26), outline=(140, 190, 255, 90), width=2)

    add_glow(base, layer, 6)
    draw = ImageDraw.Draw(base)
    header(draw, "轨道仪 · 由近到远", "日 / 周 / 月 / 年 = 四层轨道，往外一层就是上一个尺度")
    label(draw, (44, H - 46), "切换尺度 = 镜头拉远，轨道保持连续", 14, (110, 140, 180))
    return base.convert("RGB")


# ───────────────────────── D 银河卷轴 ─────────────────────────

def concept_d():
    base = background(29).convert("RGBA")
    layer = glow_layer((W, H))
    d = ImageDraw.Draw(layer)
    rnd = random.Random(31)
    # 横向星河
    for i in range(2600):
        t = rnd.random()
        x = 80 + t * (W - 160)
        band = math.sin(t * math.pi) * 120 + 60
        y = 420 + rnd.gauss(0, band * 0.45)
        if 0 <= y < H:
            s = rnd.randint(1, 2)
            d.ellipse((x - s, y - s, x + s, y + s), fill=(130, 180, 240, rnd.randint(30, 120)))

    # 周的星团
    for w in range(12):
        x = 140 + w * 85
        y = 420 + math.sin(w * 0.9) * 40
        for _ in range(10):
            star(d, x + rnd.uniform(-22, 22), y + rnd.uniform(-16, 16), 1.6, (200, 230, 255), 160)
        label(d, (x, 620), f"{w + 1}月", 13, (130, 165, 205), "ma")

    add_glow(base, layer, 8)
    draw = ImageDraw.Draw(base)
    header(draw, "全年 · 银河卷轴", "一年 = 一条星河，每月是一段星团；横向滚动带视差")
    label(draw, (W - 44, 40), "2026", 22, (150, 185, 230), "ra")
    label(draw, (44, H - 46), "滚轮横向滚动 · 拖拽平移", 14, (110, 140, 180))
    return base.convert("RGB")


def main():
    os.makedirs(OUT, exist_ok=True)

    # A 动画
    frames = [concept_a_frame(i / 24) for i in range(24)]
    frames[0].save(os.path.join(OUT, "concept-a.gif"), save_all=True,
                   append_images=frames[1:], duration=80, loop=0, optimize=True)
    concept_a_frame(0.2).save(os.path.join(OUT, "concept-a.png"))

    # B 动画（轻微呼吸）
    frames = [concept_b_frame(i / 24) for i in range(16)]
    frames[0].save(os.path.join(OUT, "concept-b.gif"), save_all=True,
                   append_images=frames[1:], duration=110, loop=0, optimize=True)
    concept_b_frame(0.15).save(os.path.join(OUT, "concept-b.png"))

    # C 动画（轨道旋转）
    frames = [concept_c_frame(i / 36) for i in range(24)]
    frames[0].save(os.path.join(OUT, "concept-c.gif"), save_all=True,
                   append_images=frames[1:], duration=70, loop=0, optimize=True)
    concept_c_frame(0.1).save(os.path.join(OUT, "concept-c.png"))

    concept_d().save(os.path.join(OUT, "concept-d.png"))
    print("saved to", os.path.abspath(OUT))


if __name__ == "__main__":
    main()
