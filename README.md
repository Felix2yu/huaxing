# 化形

macOS 多媒体转换工具包：用**预设**把视频 / 音频 / 图片转成目标格式，用**规则引擎**按条件批量匹配并自动执行，并提供一套**工具链自检**。

- **HuaXingKit** —— 纯 Swift 引擎（管线、规则、命名、工具链、持久化）
- **huaxingctl** —— 命令行前端
- **化形** —— SwiftUI 图形界面（macOS App）

> 目标平台：macOS 27，Swift 6.4.2。视频/音频转换需要 `ffmpeg` + `ffprobe`；图片转换可走系统 ImageIO / `sips`，仅在使用 JPEG XL / WebP 等格式时才依赖可选工具。

---

## 功能

- **预设转换**：视频（HEVC / H.264 / AV1）、音频（AAC m4a）、图片（JPEG XL / WebP 等），支持质量、位率、缩放。
- **批量与并发**：目录递归展开、可控并发数（`-j`）。
- **规则引擎**：按媒体类型 / 扩展名 / 分辨率 / 文件名 glob / 来源目录 / 时长 / 大小等条件匹配，命中后套用预设并执行动作。
- **命名模板**：`{name}` `{width}` `{height}` `{duration}` `{codec}` `{preset}` `{index}`。
- **冲突策略**：`overwrite` / `rename`(-N) / `skip`。
- **后处理**：在 Finder 中显示、打开结果、移入废纸篓等。
- **工具链自检**：`doctor` 命令与 GUI 诊断页，必需工具缺失报错、可选工具仅警告。
- **JSON 持久化**：预设与规则存于 `~/Library/Application Support/im.yufei.huaxing/` 下的 `presets.json` / `rules.json` / `settings.json`。

---

## 环境要求

| 组件 | 是否必须 | 说明 |
|------|----------|------|
| macOS 27 | 必须 | 目标部署版本（`.v27`） |
| Swift 6.4.2 工具链 | 必须 | Xcode 27 或 Command Line Tools 6.4.2 |
| `ffmpeg` + `ffprobe` | 必须（视频/音频） | 图片转换不依赖 ffmpeg |
| `djxl` / `cwebp` / `dwebp` / `jxlinfo` / `sips` | 可选 | 用于 JPEG XL / WebP 等格式与元数据保留（`sips` 为 macOS 自带） |

---

## 构建

```bash
make build            # 构建 HuaXingKit + huaxingctl
make test             # 运行单元测试（41 个用例）
make app              # 构建根包 + App 子包，组装并 ad-hoc 签名 化形.app
make doctor           # 自检工具链
```

也可直接用 SwiftPM：

```bash
swift build                     # 调试构建
swift build -c release          # 发布构建
swift test -c release           # 发布构建下跑测试
```

> `Makefile` 的 `SANDBOX` 与 `App/build-app.sh` 都加了 `--disable-sandbox`（SwiftPM manifest 层）与 `-Xswiftc -disable-sandbox`（编译器层），受限环境 / CI 下 `make build/test/app/doctor` 才能全部跑通。

`make app` 产物位于 `.build/release/化形.app`，CLI 随包打包在 `Contents/MacOS/huaxingctl`：

```bash
open .build/release/化形.app
# 或系统安装
sudo cp -r .build/release/化形.app /Applications/
```

---

## 命令行（huaxingctl）

```bash
huaxingctl doctor                                  # 工具链自检
huaxingctl convert video.mp4 --hevc                # 快捷预设：HEVC
huaxingctl convert clip.mov --av1                  # AV1（libsvtav1）
huaxingctl convert photo.png --jxl -q 80           # 图片：JPEG XL，质量 0–100
huaxingctl convert "*.mov" --preset <id> -o ~/out -j 4   # 预设 + 输出目录 + 并发
huaxingctl convert in.mp4 --dry-run               # 只预览，不转换
huaxingctl presets list                            # 列出预设
huaxingctl rules list                              # 列出规则
huaxingctl rules run ~/Downloads --dry-run         # 评估并预览规则命中
huaxingctl rules run ~/Downloads --rule <id>       # 仅评估某条规则
huaxingctl probe file.mp4                          # 输出 ffprobe 信息（JSON）
huaxingctl version                                 # 版本号
```

全局选项：`--json`（机器可读输出）、`--help / -h`。

### 退出码

| 码 | 含义 |
|----|------|
| 0 | 成功 |
| 1 | 参数错误 |
| 2 | 工具链缺失（必需工具不可用） |
| 3 | 容器 / 编解码 / 兼容性被拒 |
| 4 | 规则未命中 / 配置缺失 |
| 5 | 至少一个转换失败 |
| 6 | 已取消 |
| 7 | 持久化 I/O 错误 |

---

## 图形界面

`make app` 后打开 `化形.app`，左侧分栏五个标签页：

- **转换**：拖拽文件 / 文件夹，选预设与输出目录，开始转换
- **作业**：任务表格（名称 / 状态 / 进度 / 输入 / 输出 / 耗时 / 预设 / 规则 / 错误），右键取消 / 清空
- **预设**：新增 / 编辑 / 删除转换预设
- **规则**：条件构建与动作配置
- **诊断**：工具链状态与安装建议

---

## 目录结构

```
huaxing/
├── Package.swift              # 根包：HuaXingKit + huaxingctl
├── Makefile                   # build / test / app / doctor / check-*
├── Sources/
│   ├── HuaXingKit/            # 引擎：FFmpeg 管线、规则引擎、命名模板、工具链、持久化
│   └── huaxingctl/            # CLI：参数解析与各子命令
├── Tests/HuaXingKitTests/     # 单元测试
├── App/                       # SwiftUI 子包（macOS App）
│   ├── Package.swift
│   ├── Sources/HuaXingUI/     # 模型层：AppModel / JobModel / QueueManager
│   └── Sources/huaxing/       # SwiftUI 视图层（Views/）
├── Resources/Info.plist       # App bundle 元数据
├── docs/                      # API_AUDIT.md、M10_SWIFTUI_VIEWS.md（开发文档）
└── build-app.sh               # 转发到 App/build-app.sh
```

---

## 许可证

尚未指定。如需发布开源，请添加 `LICENSE` 文件（例如 MIT）。
