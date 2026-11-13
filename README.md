# BookTools

这是给 Intel MacBook Pro 使用的本地图书处理工具项目。项目只保留合并版 App：

`/Users/kbdz/Documents/BookTools/Apps/PDF Book Tools.app`

项目已纳入 git 版本管理；清理前的旧版 App 和源码保留在初始提交 `faf60f3` 中，需要时可从历史恢复。

## 下载

在 GitHub Releases 下载最新的 `PDF-Book-Tools-1.0.0.dmg`，打开后把 App 拖到“应用程序”。App 使用本地 ad-hoc 签名、未经过 Apple 公证，首次打开如果被系统拦截，请在 Finder 里右键 App 选择“打开”。

## 当前 App 功能

合并版 `PDF Book Tools.app` 的目标流程是：

1. PDF 解析，默认使用 MinerU 精准解析 API，也保留本地 OCRmyPDF / Tesseract 备用路线。
2. PDF 转换为 MD / TXT / EPUB。
3. MD / TXT 直接在主窗口内交给 AI 排版。
4. 文件选择行右侧的“一键处理”可把 PDF 解析、转换、AI 排版串起来一次完成；选中 TXT / MD 时按钮变为“一键 AI 排版”，直接开始排版。

AI 排版已集成在主窗口第三步下方，接口设置可展开，默认沿用上次保存的配置，不需要另外打开窗口或重新选择文件。

## 目录结构

- `BookToolsHubApp.swift`：合并版主窗口源码，包含内联 AI 排版区。
- `AIReflowEngine.swift`：AI 排版引擎（分块、请求 API、断点续跑），不依赖窗口。
- `BookToolsUI.swift`：界面组件（卡片、按钮、拖拽区、进度条等）。
- `Localization.swift`：界面语言定义与 `L(中文, English)` 文案函数，语言保存在 UserDefaults（`appLanguage`）。
- `reflow_txt_epub_worker.command`：PDF 解析和转换 worker，包含 MinerU 和本地 OCR 路线。
- `BookToolsHub_Info.plist`：合并版 App 的 plist。
- `Assets/`：App 图标资源。`AppIcon-source.png` 是原始图，`AppIcon.icns` 是打包后的图标，`make_icon.py` 负责裁切圆角、加阴影并生成 iconset。
- `Apps/PDF Book Tools.app`：唯一保留的合并版 App。

## 重要实现说明

- `PDF Book Tools.app` 已经可以移动位置，当前放在 `Apps/` 下。
- 主窗口第三步“交给 AI 排版”下方就是 AI 排版区，不再打开独立窗口。
- “一键处理”只增加串联入口，第 1、2、3 步原有按钮都保留，仍可单独执行解析、转换或 AI 排版。
- 选中 PDF 时，“一键处理”会先检查 AI 接口配置，再自动完成解析、转换和 AI 排版；如果当前输出格式是 EPUB，会自动改用 MD，因为 AI 排版需要可直接读取的文本。
- 选中 TXT / MD 时，“一键 AI 排版”直接对当前文件开始排版，不需要再点第 2 步。
- 主窗口已经生成 MD/TXT 时，“开始 AI 排版”会自动使用该文本；直接选择 TXT / MD 文件时也会自动使用，无需重复选择。
- “解析设置”在第 1 步下方，“AI 排版接口设置”在第 3 步下方，都可折叠，默认收起，并记住上次的展开/收起状态。
- 主窗口内容放在滚动视图里；窗口尺寸保持在 860×820 左右，展开设置时日志区自动压缩，内容超出时出现滚动条，窗口大小不会跟着设置展开而变化。
- 解析设置展开后可调整识别语言、解析方式、输出格式和 MinerU Token；AI 设置展开后按“API 地址 → API Key → 模型”的顺序填写。
- API Key 右侧的眼睛按钮可在明文和掩码之间切换；明文状态下可以直接用键盘复制 Key。
- “模型”行右侧是“拉取模型”和“测试接口”：拉取会从当前 API 地址推导出 `/v1/models` 并弹出菜单供选择；测试会向当前地址发送一次很短的消息，确认 API 地址、API Key 和模型是否可用。结果会显示在设置区并写入运行日志，测试会消耗极少量 token。
- 如果接口不支持 `/models`，仍可手动填写模型名；测试前请先把模型填对。
- 标题右侧的外观下拉框可切换“跟随系统 / 浅色 / 深色”，默认跟随系统；选择会保存到 UserDefaults（`appearanceMode`），重启后继续生效，界面颜色随外观自动适配。
- 外观下拉框左侧是界面语言下拉框，可选“中文 / English”，默认中文；切换后立即生效（无需重启），并记住到 UserDefaults（`appLanguage`）。英文界面下菜单栏、按钮、设置项、状态都会切换为英文；运行日志里固定的 `STATUS=` / `ERROR=` 行会转成英文，其余脚本原始输出和第三方工具日志保持原样。
- App 自带标准的“编辑”菜单，所以输入框里可以用 ⌘C / ⌘V / ⌘A 等快捷键；之前没有菜单时只能通过右键菜单复制粘贴。
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
swiftc -target x86_64-apple-macosx13.0 -O /tmp/main.swift AIReflowEngine.swift BookToolsUI.swift Localization.swift -o /tmp/PDFBookTools.new
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
- API Key 和 MinerU Token 使用 `NoAutoFillSecureTextField`，它覆盖了 AppKit 的 `_isPasswordAutofillEnabled` 私有开关，避免输入框获得焦点或点击“测试接口”“拉取模型”时弹出系统“密码”自动填充面板；如果后续 macOS 版本让这个面板重新出现，先检查这处覆盖是否仍生效。
