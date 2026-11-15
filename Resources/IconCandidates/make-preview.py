#!/usr/bin/env python3
"""生成自包含的「化形」图标候选预览页（第二版）。

图片全部以 data URI 内嵌，单文件可直接用浏览器打开，不依赖相对路径。
尺寸条使用 .iconset 里的真实位图，而不是 CSS 缩放，便于判断小尺寸表现。
本页只呈现候选，不标记推荐、不预设采用方案。
"""

import base64
import pathlib
import subprocess
import tempfile
from string import Template

HERE = pathlib.Path(__file__).resolve().parent
TMP = pathlib.Path(tempfile.gettempdir()) / "huaxing-icon-preview"
TMP.mkdir(exist_ok=True)

CANDIDATES = [
    dict(
        key="1", slug="1-墨印", name="墨印", style="东方 · 字形",
        tagline="朱砂印章 + 浮雕「化」字",
        desc="朱红渐变底、双层印框、带暗红浮雕偏移的白色「化」字。中文识别度最高，气质偏传统。",
        colors=("#761E1C", "#C65238"),
    ),
    dict(
        key="2", slug="2-折光", name="折光", style="拟物 · 玻璃",
        tagline="棱镜分光，白光进、三色出",
        desc="深靛底上的玻璃棱镜，左侧入射白光、右侧射出渐隐光谱。有体积与材质，叙事性最强。",
        colors=("#0A1026", "#202C5C"),
    ),
    dict(
        key="3", slug="3-线环", name="线环", style="极简 · 线性",
        tagline="浅底开口弧 + 圆心",
        desc="浅灰蓝底、蓝青渐变粗弧与中心圆点。留白最大、最克制，是六款里唯一的浅色图标。",
        colors=("#F7F9FD", "#E0E7F3"),
    ),
    dict(
        key="4", slug="4-叠片", name="叠片", style="材质 · 层叠",
        tagline="磨砂后卡 + 渐变前卡 + 箭头",
        desc="后方半透明线框卡片、前方青蓝渐变实卡，带投影与顶部高光，用前后景深表达输入到输出。",
        colors=("#1A2438", "#3C4E70"),
    ),
    dict(
        key="5", slug="5-融形", name="融形", style="抽象 · 液态",
        tagline="两滴融合的液态轮廓",
        desc="青到紫渐变的 metaball 轮廓配玻璃高光，字面演绎「化形」。没有具体物件，最抽象。",
        colors=("#180E34", "#46207E"),
    ),
    dict(
        key="6", slug="6-化圆", name="化圆", style="符号 · 几何",
        tagline="左方右圆，形态本身在变化",
        desc="近黑底上一个由方形过渡到圆形的单体，横向渐变区分两侧。纯符号、无装饰，概念最直译。",
        colors=("#12151C", "#282E3E"),
    ),
]

SIZE_FILES = [
    (128, "icon_128x128.png"),
    (64, "icon_32x32@2x.png"),
    (32, "icon_32x32.png"),
    (16, "icon_16x16.png"),
]


def thumb(src: pathlib.Path, size: int) -> pathlib.Path:
    out = TMP / f"{src.stem}-{size}.png"
    if not out.exists():
        subprocess.run(
            ["sips", "-z", str(size), str(size), str(src), "--out", str(out)],
            check=True, stdout=subprocess.DEVNULL,
        )
    return out


def uri(path: pathlib.Path) -> str:
    return "data:image/png;base64," + base64.b64encode(path.read_bytes()).decode("ascii")


def swatches(colors) -> str:
    return "".join(
        f'<span class="sw" style="background:{c}"></span><code>{c}</code>'
        for c in colors
    )


def size_row(slug: str) -> str:
    parts = []
    iconset = HERE / f"{slug}.iconset"
    for px, filename in SIZE_FILES:
        parts.append(
            f'<div class="sz"><img src="{uri(iconset / filename)}" '
            f'style="width:{px}px;height:{px}px" alt="{px}px">'
            f'<span>{px}px</span></div>'
        )
    return "".join(parts)


def card(c: dict) -> str:
    big = uri(thumb(HERE / f'{c["slug"]}.png', 320))
    return f"""<article class="card">
  <div class="iconbox"><img src="{big}" alt="{c['name']}"></div>
  <div class="meta">
    <div class="head"><span class="badge">{c['key']}</span><h2>{c['name']}</h2>
      <span class="style">{c['style']}</span></div>
    <p class="tagline">{c['tagline']}</p>
    <p class="desc">{c['desc']}</p>
    <div class="palette">{swatches(c['colors'])}</div>
    <div class="sizes">{size_row(c['slug'])}</div>
  </div>
</article>"""


CSS = """
* { box-sizing: border-box; }
body { margin: 0; padding: 36px 32px 48px; background: #f5f6f8; color: #1c2028;
       font: 14px/1.6 -apple-system, BlinkMacSystemFont, "PingFang SC", "Helvetica Neue", sans-serif; }
.wrap { max-width: 1080px; margin: 0 auto; }
header { margin-bottom: 26px; }
h1 { margin: 0 0 6px; font-size: 26px; letter-spacing: .5px; }
.sub { margin: 0; color: #6b7280; font-size: 13px; }
.notice { margin: 16px 0 0; padding: 10px 14px; border-left: 3px solid #d98b2b;
          background: #fff8ec; border-radius: 0 8px 8px 0; font-size: 12px; color: #7a5320; }
.grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 18px; }
@media (max-width: 900px) { .grid { grid-template-columns: 1fr; } }
.card { display: flex; gap: 18px; padding: 20px; background: #fff;
        border: 1px solid #e3e6eb; border-radius: 14px;
        box-shadow: 0 1px 2px rgba(20,28,45,.04); }
.iconbox { flex: 0 0 164px; display: flex; align-items: flex-start; justify-content: center; }
.iconbox img { width: 156px; height: 156px; border-radius: 22.5%;
               box-shadow: 0 8px 20px rgba(20,28,45,.18), 0 1px 3px rgba(20,28,45,.12); }
.meta { flex: 1; min-width: 0; }
.head { display: flex; align-items: center; gap: 9px; }
.badge { display: inline-flex; align-items: center; justify-content: center;
         width: 24px; height: 24px; border-radius: 7px; background: #1c2028; color: #fff;
         font-size: 12px; font-weight: 700; }
h2 { margin: 0; font-size: 18px; }
.style { margin-left: auto; padding: 2px 8px; border-radius: 5px; background: #eef1f6;
         color: #5b6577; font-size: 11px; white-space: nowrap; }
.tagline { margin: 8px 0 4px; font-size: 12px; color: #4b5563; font-weight: 600; }
.desc { margin: 0 0 12px; font-size: 12px; color: #6b7280; }
.palette { display: flex; align-items: center; gap: 6px; margin-bottom: 14px; }
.sw { width: 14px; height: 14px; border-radius: 4px; border: 1px solid rgba(0,0,0,.08); }
code { font-size: 10px; color: #8a919e; margin-right: 8px; }
.sizes { display: flex; align-items: flex-end; gap: 14px; padding-top: 12px;
         border-top: 1px solid #eef0f3; }
.sz { display: flex; flex-direction: column; align-items: center; gap: 5px; }
.sz img { border-radius: 22.5%; }
.sz span { font-size: 10px; color: #9aa1ad; }
footer { margin-top: 26px; padding: 18px 20px; background: #fff; border: 1px solid #e3e6eb;
         border-radius: 12px; font-size: 12px; color: #4b5563; }
footer h3 { margin: 0 0 8px; font-size: 13px; color: #1c2028; }
footer ul { margin: 0 0 12px; padding-left: 18px; }
footer li { margin: 3px 0; }
"""

HTML = Template("""<!DOCTYPE html>
<html lang="zh-CN">
<head><meta charset="utf-8"><title>化形 · 图标候选（第二版）</title><style>$css</style></head>
<body><div class="wrap">
<header>
  <h1>化形 · 图标候选（第二版）</h1>
  <p class="sub">6 个刻意拉开差异的风格方向 · 1024×1024 设计稿 · 完整 10 尺寸 .icns · 尺寸条为真实位图</p>
  <p class="notice"><strong>已按你的选择采用 2 折光（七色修正版）。</strong>红橙黄绿青蓝紫自棱镜右边缘外侧按顺序发散，棱镜内部只有白光与玻璃。正式图标已写入 Resources/化形.icns 与 Info.plist，本地 App 已构建；是否替换 /Applications 中的旧 App 仍待你确认。</p>
</header>
<div class="grid">$cards</div>
<footer>
  <h3>macOS 图标规范符合性</h3>
  <ul>
    <li>1024×1024 全幅不透明画布，未自行加圆角 —— 圆角超椭圆由系统统一套用（本页用 22.5% 圆角模拟）。</li>
    <li>主体居中、四周留约 10% 安全边距，单一焦点，无小字与复杂纹理。</li>
    <li>每个 .icns 含 16 / 32 / 64 / 128 / 256 / 512 / 1024 px 共 10 个尺寸（@1x / @2x 成对），由 iconutil 生成。</li>
    <li>六款并列呈现，不预设默认；选择权在你。</li>
  </ul>
</footer>
</div></body></html>
""")

out = HERE / "图标预览.html"
out.write_text(
    HTML.substitute(css=CSS, cards="\n".join(card(c) for c in CANDIDATES)),
    encoding="utf-8",
)
print(f"预览页已生成：{out}  ({out.stat().st_size / 1024:.0f} KB，自包含)")
