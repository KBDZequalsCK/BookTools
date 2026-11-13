# BookTools

这是给 Intel MacBook Pro 使用的本地图书处理工具项目。主要 App 是合并版：

`/Users/kbdz/Documents/BookTools/Apps/PDF Book Tools.app`

## 当前 App 功能

合并版 `PDF Book Tools.app` 的目标流程是：

1. PDF 解析，默认使用 MinerU 精准解析 API，也保留本地 OCRmyPDF / Tesseract 备用路线。
2. PDF 转换为 MD / TXT / EPUB。
3. MD / TXT 交给内置 AI 排版窗口处理。

AI 排版窗口已经集成到合并版 App 中，不再依赖单独打开旧的 `AI TXT-MD 排版.app`。

## 目录结构

- `BookToolsHubApp.swift`：合并版主窗口源码。
- `AIReflowApp.swift`：内置 AI 排版窗口源码。
- `reflow_txt_epub_worker.command`：PDF 解析和转换 worker，包含 MinerU 和本地 OCR 路线。
- `BookToolsHub_Info.plist`：合并版 App 的 plist。
- `Apps/PDF Book Tools.app`：当前建议使用的合并版 App。
- `Apps/AI TXT-MD 排版.app`：旧独立 AI 排版 App，备用。
- `Apps/OCR PDF.app`：旧独立 OCR App，备用。
- `Apps/PDF to TXT-EPUB-MD.app`：旧独立 PDF 转换 App，备用。
- `outputs/`：早期开发/测试输出目录，正式 App 不依赖它。
- `work/`：早期开发辅助目录。

## 重要实现说明

- `PDF Book Tools.app` 已经可以移动位置，当前放在 `Apps/` 下。
- 合并版主窗口的第三步“打开 AI 排版”会打开内置 AI 排版窗口。
- 如果主窗口已经生成 MD/TXT，AI 排版窗口会自动带入该文件。
- 如果还没生成 MD/TXT，可以在 AI 排版窗口里拖入或双击选择 MD/TXT 文件。
- AI 排版的 API 地址、模型、API Key、分块字符数和输出格式会保存到 UserDefaults。
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
- 只有用户点击“终止并清理”或“清理未完成”才删除断点。
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
swiftc -target x86_64-apple-macosx13.0 -O /tmp/main.swift AIReflowApp.swift -o /tmp/PDFBookTools.new
cp /tmp/PDFBookTools.new "/Users/kbdz/Documents/BookTools/Apps/PDF Book Tools.app/Contents/MacOS/PDFBookTools"
cp reflow_txt_epub_worker.command "/Users/kbdz/Documents/BookTools/Apps/PDF Book Tools.app/Contents/Resources/reflow_txt_epub_worker.command"
codesign --force --deep --sign - "/Users/kbdz/Documents/BookTools/Apps/PDF Book Tools.app"
codesign --verify --deep --strict --verbose=2 "/Users/kbdz/Documents/BookTools/Apps/PDF Book Tools.app"
open "/Users/kbdz/Documents/BookTools/Apps/PDF Book Tools.app"
```

说明：

- Intel Mac 编译目标使用 `x86_64-apple-macosx13.0`。
- 需要把 `BookToolsHubApp.swift` 临时复制成 `/tmp/main.swift`，因为 Swift 多文件编译时只有 `main.swift` 适合放顶层启动代码。
- 编译后必须重新签名，否则 App 可能打不开或行为异常。

## 维护注意事项

- 默认只维护合并版 `PDF Book Tools.app`，旧的三个独立 App 先保留作备用。
- 手动改文件时优先改源码，再重新编译和签名，不要直接改二进制。
- 不要删除用户正在使用的 `.part` 和 `.resume.json` 断点文件，除非用户明确要求清理。
- 如果要优化界面，优先保持三步流程清晰：PDF 解析，转换为 MD/TXT/EPUB，MD/TXT 交给 AI 排版。
