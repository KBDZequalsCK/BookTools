# BookTools

这是给 Intel MacBook Pro 使用的本地图书处理工具项目。项目只保留合并版 App：

`/Users/kbdz/Documents/BookTools/Apps/PDF Book Tools.app`

项目已纳入 git 版本管理；清理前的旧版 App 和源码保留在初始提交 `faf60f3` 中，需要时可从历史恢复。

## 当前 App 功能

合并版 `PDF Book Tools.app` 的目标流程是：

1. PDF 解析，默认使用 MinerU 精准解析 API，也保留本地 OCRmyPDF / Tesseract 备用路线。
2. PDF 转换为 MD / TXT / EPUB。
3. MD / TXT 直接在主窗口内交给 AI 排版。

AI 排版已集成在主窗口第三步下方，接口设置可展开，默认沿用上次保存的配置，不需要另外打开窗口或重新选择文件。

## 目录结构

- `BookToolsHubApp.swift`：合并版主窗口源码，包含内联 AI 排版区。
- `AIReflowEngine.swift`：AI 排版引擎（分块、请求 API、断点续跑），不依赖窗口。
- `BookToolsUI.swift`：界面组件（卡片、按钮、拖拽区、进度条等）。
- `reflow_txt_epub_worker.command`：PDF 解析和转换 worker，包含 MinerU 和本地 OCR 路线。
- `BookToolsHub_Info.plist`：合并版 App 的 plist。
- `Assets/`：App 图标资源。`AppIcon-source.png` 是原始图，`AppIcon.icns` 是打包后的图标，`make_icon.py` 负责裁切圆角、加阴影并生成 iconset。
- `Apps/PDF Book Tools.app`：唯一保留的合并版 App。

## 重要实现说明

- `PDF Book Tools.app` 已经可以移动位置，当前放在 `Apps/` 下。
- 主窗口第三步“交给 AI 排版”下方就是 AI 排版区，不再打开独立窗口。
- 主窗口已经生成 MD/TXT 时，“开始 AI 排版”会自动使用该文本；直接选择 TXT / MD 文件时也会自动使用，无需重复选择。
- “解析设置”在第 1 步下方，“AI 排版接口设置”在第 3 步下方，都可折叠，默认收起，并记住上次的展开/收起状态。
- 主窗口内容放在滚动视图里；窗口尺寸保持在 860×820 左右，展开设置时日志区自动压缩，内容超出时出现滚动条，窗口大小不会跟着设置展开而变化。
- 解析设置展开后可调整识别语言、解析方式、输出格式和 MinerU Token；AI 设置展开后可修改 API 地址、模型、API Key、分块字符数和 AI 输出格式。
- 配置会保存到 UserDefaults；不修改配置时直接点“开始 AI 排版”即可。
- 合并版会兼容读取旧 AI 排版 App 的已保存配置域：`local.codex.ai-txt-reflow`。
- 不要把 API Key、MinerU Token 写进源码或 README。

## AI 排版逻辑

Markdown 输入会使用更适合书籍的分块方式：

- 新任务优先按目录、前言、章节、结语、译后记等大边界分块。
- 如果某章太长，再在章内按小标题/段落继续拆。
- 每块发送给 AI 前，会附带当前块编号、当前章/大节、当前块内标题。
- 这样可以帮助 AI 判断哪些是页眉污染，哪些是真正标题。
- 为了保护旧任务，继续未完成断点时会兼容旧分块算法，避免因为分块变化导致无法续跑。

AI 排版断点规则：

- 失败、退出、网络中断时，保留 `.part` 和 `.resume.json`。
- 输入文本旁存在断点时，主窗口会显示“继续未完成 / 跳过当前块 / 清理断点”，主按钮也会变为“继续 AI 排版”。
- 只有用户点击“终止 AI 排版”或“清理断点”才删除断点。
- 成功完成后自动清理临时文件和断点。

## 本地 OCR 逻辑

本地 OCR 解析时会先检测 PDF 是否已有可用文字层：

- 如果已有可用文字层，跳过 OCR，直接提取文字。
- 如果没有文字层或文字太少，才调用 OCRmyPDF / Tesseract。
- 日志会显示 `检测到已有可用文字层，跳过 OCR` 或 `准备进行本地 OCR`。

## 构建合并版 App

在 `/Users/kbdz/Documents/BookTools` 下执行：

```zsh
cd /Users/kbdz/Documents/BookTools
cp BookToolsHubApp.swift /tmp/main.swift
swiftc -target x86_64-apple-macosx13.0 -O /tmp/main.swift AIReflowEngine.swift BookToolsUI.swift -o /tmp/PDFBookTools.new
cp /tmp/PDFBookTools.new "/Users/kbdz/Documents/BookTools/Apps/PDF Book Tools.app/Contents/MacOS/PDFBookTools"
cp reflow_txt_epub_worker.command "/Users/kbdz/Documents/BookTools/Apps/PDF Book Tools.app/Contents/Resources/reflow_txt_epub_worker.command"
cp Assets/AppIcon.icns "/Users/kbdz/Documents/BookTools/Apps/PDF Book Tools.app/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "/Users/kbdz/Documents/BookTools/Apps/PDF Book Tools.app"
codesign --verify --deep --strict --verbose=2 "/Users/kbdz/Documents/BookTools/Apps/PDF Book Tools.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Users/kbdz/Documents/BookTools/Apps/PDF Book Tools.app"
open "/Users/kbdz/Documents/BookTools/Apps/PDF Book Tools.app"
```

说明：

- Intel Mac 编译目标使用 `x86_64-apple-macosx13.0`。
- 需要把 `BookToolsHubApp.swift` 临时复制成 `/tmp/main.swift`，因为 Swift 多文件编译时只有 `main.swift` 适合放顶层启动代码。
- 编译后必须重新签名，否则 App 可能打不开或行为异常。
- 图标由 `Assets/make_icon.py` 生成：先处理 `AppIcon-source.png`，再执行 `iconutil -c icns` 得到 `AppIcon.icns`；App 的 `CFBundleIconFile` 指向 `AppIcon`。
- 换图标后如果 Finder/Dock 仍显示旧图标，通常是 LaunchServices / Dock 缓存：先对 App 执行 `lsregister -f`，必要时再 `killall Dock`（Dock 会自动重启）并重新打开 App。

## 维护注意事项

- 默认只维护合并版 `PDF Book Tools.app`；旧版独立 App 和源码已清理，需要时从 git 历史 `faf60f3` 恢复。
- 手动改文件时优先改源码，再重新编译和签名，不要直接改二进制。
- 不要删除用户正在使用的 `.part` 和 `.resume.json` 断点文件，除非用户明确要求清理。
- 如果要优化界面，优先保持三步流程清晰：PDF 解析，转换为 MD/TXT/EPUB，MD/TXT 交给 AI 排版。
