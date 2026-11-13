import AppKit
import Foundation
import Darwin

private let appTitle = "PDF Book Tools"
private let mineruTokenDefaultsKey = "mineruToken"

/// 普通 NSSecureTextField 一旦获得焦点，macOS 就会弹出系统的“密码”自动填充面板。
/// 本应用没有登录表单，这个面板只会挡住接口设置，因此在这里覆盖 AppKit 的开关
/// （NSSecureTextField 自身实现了 `_isPasswordAutofillEnabled`，默认返回 YES）。
private final class NoAutoFillSecureTextField: NSSecureTextField {
    @objc(_isPasswordAutofillEnabled)
    private func isPasswordAutofillDisabled() -> Bool { false }
}

private struct LanguageOption {
    let title: String
    let titleEN: String
    let code: String

    var localizedTitle: String { L(title, titleEN) }
}

private struct FormatOption {
    let title: String
    let titleEN: String
    let code: String
    let suffix: String

    var localizedTitle: String { L(title, titleEN) }
}

private enum AppearanceMode: String, CaseIterable {
    case system
    case light
    case dark

    var title: String {
        switch self {
        case .system: return L("跟随系统", "System")
        case .light: return L("浅色", "Light")
        case .dark: return L("深色", "Dark")
        }
    }
}

private let formatOptions = [
    FormatOption(title: "MD（推荐，便于 AI 排版）", titleEN: "MD (recommended for AI layout)", code: "md", suffix: "_reflow.md"),
    FormatOption(title: "TXT（纯文字）", titleEN: "TXT (plain text)", code: "txt", suffix: "_ocr.txt"),
    FormatOption(title: "EPUB（可调字体）", titleEN: "EPUB (adjustable font)", code: "epub", suffix: "_reflow.epub")
]

private var parserOptionTitles: [String] {
    [
        L("MinerU 精准解析 API（推荐）", "MinerU Cloud Parsing API (recommended)"),
        L("本地 OCRmyPDF / Tesseract（备用）", "Local OCRmyPDF / Tesseract (fallback)")
    ]
}

private final class MainWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, FileDropZoneDelegate {
    private let fileManager = FileManager.default
    private var selectedURL: URL?
    private var lastTextURL: URL?
    private var outputURL: URL?
    private var tempURL: URL?
    private var partURL: URL?
    private var process: Process?
    private var outputPipe: Pipe?
    private var childPID: pid_t?
    private var totalPages: Int?
    private var currentPhase = ""
    private var partialWorkerLine = ""
    private var lastWorkerError: String?
    private var isCancelling = false
    private var languageOptions: [LanguageOption] = []
    private let aiEngine = AIReflowEngine()
    private var aiSettingsExpanded = false
    private var parseSettingsExpanded = false
    private var autoStartAIAfterWorker = false
    private let parseSettingsExpandedKey = "parseSettingsExpanded"
    private let aiSettingsExpandedKey = "aiSettingsExpanded"
    private weak var mainScrollView: NSScrollView?
    private let parseSettingsRows = NSStackView()
    private let parseSettingsToggle = BTButton(title: L("解析设置", "Parse settings"), symbol: "chevron.right", style: .ghost, height: 22)
    private let parseSummaryLabel = BTUI.label(L("识别语言、解析方式与输出格式", "Language, parser, and output format"), size: 11, color: .tertiaryLabelColor)
    private let appearancePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let interfaceLanguagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let appearanceDefaultsKey = "appearanceMode"

    private let headerIconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: appTitle)
    private let subtitleLabel = BTUI.label(
        L("把扫描版 PDF 变成干净、可编辑的电子书", "Turn scanned PDFs into clean, editable ebooks"),
        size: 12,
        color: .secondaryLabelColor
    )
    private let dropZone = FileDropZoneView(
        acceptedExtensions: ["pdf", "txt", "md", "markdown"],
        title: L("把 PDF / TXT / MD 文件拖到这里", "Drop a PDF / TXT / MD file here"),
        subtitle: L("也可以双击此区域选择文件", "Or double-click this area to choose a file")
    )
    private let fileLabel = BTUI.label(L("尚未选择文件", "No file selected"), size: 11, color: .tertiaryLabelColor)
    private let statusLabel = BTUI.label(L("请选择 PDF、TXT 或 MD，开始三步处理", "Choose a PDF, TXT, or MD file to start"), size: 13, weight: .medium)
    private let progressLabel = BTUI.label("", size: 11, color: .secondaryLabelColor, alignment: .right)
    private let outputLabel = BTUI.label(L("完成后会显示产物位置", "Output location will appear here"), size: 11, color: .secondaryLabelColor)
    private let progressBar = BTProgressBar()
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let parserPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let mineruTokenField = NoAutoFillSecureTextField(string: "")
    private let chooseButton = BTButton(title: L("选择文件", "Choose File"), symbol: "folder", style: .ghost, height: 28)
    private let ocrButton = BTButton(title: L("本地 OCR 备用", "Local OCR"), symbol: "text.viewfinder", style: .secondary, height: 30)
    private let parseButton = BTButton(title: L("开始转换", "Convert"), symbol: "wand.and.stars", style: .primary, height: 30)
    private let aiButton = BTButton(title: L("开始 AI 排版", "AI Layout"), symbol: "wand.and.stars", style: .accent, height: 30)
    private let oneClickButton = BTButton(title: L("一键处理", "One-Click"), symbol: "bolt.fill", style: .primary, height: 30)
    private let cancelButton = BTButton(title: L("终止并清理", "Stop & Clean"), symbol: "stop.circle", style: .destructive, height: 28)
    private let openOutputButton = BTButton(title: L("打开产物目录", "Open Output"), symbol: "folder", style: .secondary, height: 28)
    private let aiInputLabel = BTUI.label(L("暂无文本：完成第 2 步后自动可用", "No text yet — available after step 2"), size: 11, color: .tertiaryLabelColor)
    private let aiSettingsToggle = BTButton(title: L("AI 排版接口设置", "AI API Settings"), symbol: "chevron.right", style: .ghost, height: 22)
    private let aiSettingsStack = NSStackView()
    private let aiAPIURLField = NSTextField(string: "")
    private let aiModelField = NSComboBox(frame: .zero)
    private let aiModelFetchButton = BTButton(title: L("拉取模型", "Fetch Models"), symbol: "arrow.down.circle", style: .secondary, height: 24)
    private let aiAPITestButton = BTButton(title: L("测试接口", "Test API"), symbol: "network", style: .secondary, height: 24)
    private let aiTestResultLabel = BTUI.label("", size: 11, color: .tertiaryLabelColor)
    private var isTestingAIAPI = false
    private var isFetchingAIModels = false
    private let aiAPIKeyField = NoAutoFillSecureTextField(string: "")
    private let aiAPIKeyPlainField = NSTextField(string: "")
    private let aiAPIKeyRevealButton = BTButton(title: L("显示", "Show"), symbol: "eye", style: .ghost, height: 24)
    private var isShowingAPIKey = false
    private var activeAPIKeyField: NSTextField {
        isShowingAPIKey ? aiAPIKeyPlainField : aiAPIKeyField
    }
    private let aiChunkSizeField = NSTextField(string: "")
    private let aiFormatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let aiResumeRow = NSView()
    private let aiResumeLabel = BTUI.label("", size: 11, color: .systemOrange)
    private let aiResumeButton = BTButton(title: L("继续未完成", "Resume"), symbol: "play.circle", style: .secondary, height: 24)
    private let aiSkipButton = BTButton(title: L("跳过当前块", "Skip Chunk"), symbol: "forward.end", style: .ghost, height: 24)
    private let aiCleanupButton = BTButton(title: L("清理断点", "Clear Resume"), symbol: "trash", style: .ghost, height: 24)
    private let aiCancelButton = BTButton(title: L("终止 AI 排版", "Stop AI Layout"), symbol: "stop.circle", style: .destructive, height: 24)
    private let logView = NSTextView(frame: .zero)
    private let stepsHeaderLabel = BTUI.label(L("三步流程", "Three Steps"), size: 11, weight: .semibold, color: .secondaryLabelColor)
    private let logHeaderLabel = BTUI.label(L("运行日志", "Run Log"), size: 11, weight: .semibold, color: .secondaryLabelColor)
    private let parseLanguageLabel = BTUI.formLabel(L("识别语言", "Language"))
    private let parseParserLabel = BTUI.formLabel(L("解析方式", "Parser"))
    private let parseFormatLabel = BTUI.formLabel(L("输出格式", "Output"))
    private let parseTokenLabel = BTUI.formLabel("MinerU Token")
    private let aiURLLabel = BTUI.formLabel(L("API 地址", "API URL"))
    private let aiModelLabel = BTUI.formLabel(L("模型", "Model"))
    private let aiKeyLabel = BTUI.formLabel("API Key")
    private let aiChunkLabel = BTUI.formLabel(L("分块字符数", "Chunk Size"))
    private let aiOutputFormatLabel = BTUI.formLabel(L("AI 输出格式", "AI Output"))
    private var stepOneTitleLabel: NSTextField?
    private var stepTwoTitleLabel: NSTextField?
    private var stepTwoDetailLabel: NSTextField?
    private var stepThreeTitleLabel: NSTextField?
    private var stepOneDetailLabel: NSTextField?
    private var stepThreeDetailLabel: NSTextField?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 820, height: 780)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildInterface()
        loadSavedAppearance()
        window.center()
        discoverLanguages()
        loadSavedMinerUToken()
        applyExpansionStates()
        wireAIEngine()
        loadSavedAISettings()
        updateControls(isRunning: false)
        aiEngine.loadResumeState(for: currentTextURL())
    }

    required init?(coder: NSCoder) {
        fatalError("This app does not use storyboards")
    }

    deinit {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
    }

    func windowWillClose(_ notification: Notification) {
        shutdownForTermination()
    }

    func dropZoneWasDoubleClicked(_ view: FileDropZoneView) {
        chooseFile()
    }

    func dropZone(_ view: FileDropZoneView, received url: URL) {
        setSelectedFile(url)
    }

    func handleOpenURLs(_ urls: [URL]) {
        if let url = urls.first(where: { ["pdf", "txt", "md", "markdown"].contains($0.pathExtension.lowercased()) }) {
            setSelectedFile(url)
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func shutdownForTermination() {
        aiEngine.shutdownForTermination()
        if process?.isRunning == true {
            isCancelling = true
            if let childPID { kill(childPID, SIGTERM) }
            process?.terminate()
        }
    }

    @objc private func chooseFile() {
        guard process == nil, !aiEngine.isRunning else { return }
        let panel = NSOpenPanel()
        panel.title = L("选择 PDF、TXT 或 MD", "Choose a PDF, TXT, or MD file")
        panel.allowedFileTypes = ["pdf", "txt", "md", "markdown"]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.setSelectedFile(url)
        }
    }

    @objc private func runOCRPDF() {
        guard let input = selectedURL, input.pathExtension.lowercased() == "pdf", process == nil else { return }
        guard let language = selectedLanguage() else {
            showFailure(L("没有可用的 OCR 语言", "No OCR language is available"))
            return
        }
        let output = nextOCROutputURL(for: input)
        outputURL = output
        runWorker(
            scriptName: "ocr_worker.command",
            arguments: [input.path, language.code, output.path],
            initialStatus: L("正在 OCR PDF...", "Running OCR on the PDF…")
        )
    }

    @objc private func runPDFParse() {
        guard let input = selectedURL, input.pathExtension.lowercased() == "pdf", process == nil else { return }
        guard let language = selectedLanguage(), let format = selectedFormat() else {
            showFailure(L("请选择识别语言和输出格式", "Choose a language and an output format"))
            return
        }
        let parser = selectedParserCode()
        var environment: [String: String] = [:]
        if parser == "mineru" {
            let token = mineruTokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                showFailure(L("请填写 MinerU Token", "Enter your MinerU Token"))
                return
            }
            saveMinerUToken(token)
            environment["MINERU_TOKEN"] = token
        }
        let output = nextParseOutputURL(for: input, format: format)
        outputURL = output
        runWorker(
            scriptName: "reflow_txt_epub_worker.command",
            arguments: [input.path, language.code, format.code, output.path, parser],
            extraEnvironment: environment,
            initialStatus: parser == "mineru"
                ? L("正在用 MinerU 直接解析 PDF...", "Parsing the PDF with MinerU…")
                : L("正在检查 PDF 是否已有文字层...", "Checking the PDF for an existing text layer…")
        )
    }

    @objc private func startAIReflow() {
        beginAIReflow(clearLog: true)
    }

    private func beginAIReflow(clearLog: Bool) {
        guard process == nil, !aiEngine.isRunning else {
            showFailure(L("当前还有任务在运行，请先等待完成或终止", "Another task is still running — wait for it to finish or stop it"))
            return
        }
        syncAISettingsToEngine()
        if aiEngine.resumeAvailable {
            if let error = aiEngine.resume() {
                showFailure(error)
            }
            return
        }
        guard let input = currentTextURL() else {
            showFailure(L("没有可排版的文本：请先完成第 2 步，或选择 TXT / MD 文件", "No text to lay out — finish step 2 first, or choose a TXT / MD file"))
            return
        }
        if aiEngine.apiURLString.isEmpty || aiEngine.apiKeyString.isEmpty {
            setAISettingsExpanded(true)
            showFailure(L("第一次使用请先在「AI 排版接口设置」里填写 API 地址和 API Key", "First use: fill in the API URL and API Key under \"AI API Settings\""))
            window?.makeFirstResponder(aiEngine.apiURLString.isEmpty ? aiAPIURLField : activeAPIKeyField)
            return
        }
        if clearLog {
            logView.string = L("AI 排版日志：\n", "AI layout log:\n")
        }
        outputURL = nil
        if let error = aiEngine.start(input: input) {
            showFailure(error)
        }
    }

    @objc private func runOneClick() {
        guard process == nil, !aiEngine.isRunning else {
            showFailure(L("当前还有任务在运行，请先等待完成或终止", "Another task is still running — wait for it to finish or stop it"))
            return
        }
        guard let selected = selectedURL else {
            showFailure(L("请先选择 PDF、TXT 或 MD 文件", "Choose a PDF, TXT, or MD file first"))
            return
        }
        let ext = selected.pathExtension.lowercased()
        if ["txt", "md", "markdown"].contains(ext) {
            beginAIReflow(clearLog: true)
            return
        }
        guard ext == "pdf" else {
            showFailure(L("一键处理只支持 PDF、TXT 或 MD", "One-click processing supports only PDF, TXT, or MD"))
            return
        }
        guard selectedLanguage() != nil else {
            showFailure(L("没有可用的 OCR 语言", "No OCR language is available"))
            return
        }
        // 先检查 AI 接口，避免解析转换完成后才发现没有配置
        syncAISettingsToEngine()
        if aiEngine.apiURLString.isEmpty || aiEngine.apiKeyString.isEmpty {
            setAISettingsExpanded(true)
            showFailure(L("一键处理需要先填写 AI 排版接口（API 地址和 API Key）", "One-click processing needs the AI API settings (API URL and API Key) first"))
            window?.makeFirstResponder(aiEngine.apiURLString.isEmpty ? aiAPIURLField : activeAPIKeyField)
            return
        }
        // EPUB 不含可直接排版文本，一键处理改用 MD
        if selectedFormat()?.code == "epub" {
            formatPopup.selectItem(at: 0)
            refreshModeUI()
            appendLog(L("一键处理改用 MD 输出，便于紧接着进行 AI 排版。\n", "One-click switched the output to MD so AI layout can follow immediately.\n"))
        }
        autoStartAIAfterWorker = true
        runPDFParse()
        if process == nil {
            autoStartAIAfterWorker = false
        }
    }

    @objc private func resumeAIReflow() {
        guard process == nil, !aiEngine.isRunning else { return }
        syncAISettingsToEngine()
        if let error = aiEngine.resume() {
            showFailure(error)
        }
    }

    @objc private func skipAIChunk() {
        guard process == nil, !aiEngine.isRunning else { return }
        syncAISettingsToEngine()
        logView.string = L("AI 排版日志：\n", "AI layout log:\n")
        if let error = aiEngine.skipChunkAndContinue() {
            showFailure(error)
        }
    }

    @objc private func cleanupAIReflow() {
        aiEngine.cancelOrCleanup()
    }

    @objc private func cancelAIReflow() {
        aiEngine.cancelOrCleanup()
    }

    @objc private func toggleAISettings() {
        setAISettingsExpanded(!aiSettingsExpanded)
    }

    @objc private func cancelProcessing() {
        guard let worker = process, worker.isRunning else { return }
        isCancelling = true
        statusLabel.stringValue = L("正在终止并清理...", "Stopping and cleaning up…")
        statusLabel.textColor = .systemOrange
        cancelButton.isEnabled = false
        if let childPID { kill(childPID, SIGTERM) }
        worker.terminate()
    }

    @objc private func openOutputDirectory() {
        guard let targetURL = outputURL ?? aiEngine.outputURL ?? lastTextURL ?? selectedURL else { return }
        let target = fileManager.fileExists(atPath: targetURL.path) ? targetURL : targetURL.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    @objc private func parserSelectionChanged() {
        refreshModeUI()
        updateControls(isRunning: process?.isRunning == true)
    }

    // MARK: - Interface

    private func buildInterface() {
        guard let content = window?.contentView else { return }

        let root = NSView(frame: content.bounds)
        root.autoresizingMask = [.width, .height]
        window?.contentView = root

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        root.addSubview(scrollView)
        mainScrollView = scrollView

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        let mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 10
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(mainStack)

        let bottomBar = makeBottomBar()
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bottomBar)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -10),

            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),

            mainStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 24),
            mainStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -24),
            mainStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 20),
            mainStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -18),

            bottomBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            bottomBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            bottomBar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            bottomBar.heightAnchor.constraint(equalToConstant: 30)
        ])

        addFullWidth(makeHeader(), to: mainStack, spacingAfter: 4)
        addFullWidth(makeDropCard(), to: mainStack)
        addFullWidth(makeStepsCard(), to: mainStack)
        addFullWidth(makeStatusStack(), to: mainStack, spacingAfter: 2)

        let logCard = makeLogCard()
        logCard.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        addFullWidth(logCard, to: mainStack)
    }

    private func makeHeader() -> NSView {
        let header = NSView()

        headerIconView.translatesAutoresizingMaskIntoConstraints = false
        headerIconView.imageScaling = .scaleProportionallyDown
        headerIconView.image = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage
        header.addSubview(headerIconView)

        titleLabel.font = NSFont.systemFont(ofSize: 22, weight: .bold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titleLabel)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(subtitleLabel)

        appearancePopup.translatesAutoresizingMaskIntoConstraints = false
        appearancePopup.controlSize = .regular
        appearancePopup.font = NSFont.systemFont(ofSize: 12)
        appearancePopup.addItems(withTitles: AppearanceMode.allCases.map(\.title))
        appearancePopup.target = self
        appearancePopup.action = #selector(appearanceSelectionChanged)
        appearancePopup.toolTip = L("外观：跟随系统、浅色或深色", "Appearance: System, Light, or Dark")
        header.addSubview(appearancePopup)

        interfaceLanguagePopup.translatesAutoresizingMaskIntoConstraints = false
        interfaceLanguagePopup.controlSize = .regular
        interfaceLanguagePopup.font = NSFont.systemFont(ofSize: 12)
        interfaceLanguagePopup.addItems(withTitles: AppLanguage.allCases.map(\.displayName))
        syncLanguagePopupSelection()
        interfaceLanguagePopup.target = self
        interfaceLanguagePopup.action = #selector(interfaceLanguageChanged)
        interfaceLanguagePopup.toolTip = L("界面语言", "Interface language")
        header.addSubview(interfaceLanguagePopup)

        NSLayoutConstraint.activate([
            headerIconView.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headerIconView.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            headerIconView.widthAnchor.constraint(equalToConstant: 38),
            headerIconView.heightAnchor.constraint(equalToConstant: 38),

            appearancePopup.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -2),
            appearancePopup.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            appearancePopup.widthAnchor.constraint(equalToConstant: 104),
            appearancePopup.heightAnchor.constraint(equalToConstant: 26),

            interfaceLanguagePopup.trailingAnchor.constraint(equalTo: appearancePopup.leadingAnchor, constant: -8),
            interfaceLanguagePopup.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            interfaceLanguagePopup.widthAnchor.constraint(equalToConstant: 92),
            interfaceLanguagePopup.heightAnchor.constraint(equalToConstant: 26),

            titleLabel.leadingAnchor.constraint(equalTo: headerIconView.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: header.topAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: interfaceLanguagePopup.leadingAnchor, constant: -12),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: interfaceLanguagePopup.leadingAnchor, constant: -12),

            header.heightAnchor.constraint(equalToConstant: 46)
        ])
        return header
    }

    private func makeDropCard() -> NSView {
        let card = BTCardView(insets: NSEdgeInsets(top: 12, left: 12, bottom: 10, right: 12))

        dropZone.delegate = self
        dropZone.translatesAutoresizingMaskIntoConstraints = false
        dropZone.heightAnchor.constraint(equalToConstant: 78).isActive = true

        let chooseRow = NSView()
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fileLabel.translatesAutoresizingMaskIntoConstraints = false
        chooseButton.translatesAutoresizingMaskIntoConstraints = false
        oneClickButton.translatesAutoresizingMaskIntoConstraints = false
        chooseRow.addSubview(fileLabel)
        chooseRow.addSubview(chooseButton)
        chooseRow.addSubview(oneClickButton)

        NSLayoutConstraint.activate([
            fileLabel.leadingAnchor.constraint(equalTo: chooseRow.leadingAnchor, constant: 4),
            fileLabel.centerYAnchor.constraint(equalTo: chooseRow.centerYAnchor),
            fileLabel.trailingAnchor.constraint(lessThanOrEqualTo: chooseButton.leadingAnchor, constant: -10),

            oneClickButton.trailingAnchor.constraint(equalTo: chooseRow.trailingAnchor, constant: -2),
            oneClickButton.centerYAnchor.constraint(equalTo: chooseRow.centerYAnchor),
            oneClickButton.widthAnchor.constraint(equalToConstant: 158),

            chooseButton.trailingAnchor.constraint(equalTo: oneClickButton.leadingAnchor, constant: -8),
            chooseButton.centerYAnchor.constraint(equalTo: chooseRow.centerYAnchor),
            chooseButton.widthAnchor.constraint(equalToConstant: 132),

            chooseRow.heightAnchor.constraint(equalToConstant: 30)
        ])
        chooseButton.target = self
        chooseButton.action = #selector(chooseFile)
        oneClickButton.target = self
        oneClickButton.action = #selector(runOneClick)

        card.stack.addArrangedSubview(dropZone)
        card.stack.addArrangedSubview(chooseRow)
        dropZone.widthAnchor.constraint(equalTo: card.stack.widthAnchor).isActive = true
        chooseRow.widthAnchor.constraint(equalTo: card.stack.widthAnchor).isActive = true
        card.stack.spacing = 6
        return card
    }

    private func makeParseSection() -> NSView {
        let section = NSView()

        let sectionStack = NSStackView()
        sectionStack.orientation = .vertical
        sectionStack.alignment = .leading
        sectionStack.spacing = 6
        sectionStack.translatesAutoresizingMaskIntoConstraints = false
        section.addSubview(sectionStack)
        NSLayoutConstraint.activate([
            sectionStack.leadingAnchor.constraint(equalTo: section.leadingAnchor, constant: 32),
            sectionStack.trailingAnchor.constraint(equalTo: section.trailingAnchor, constant: -2),
            sectionStack.topAnchor.constraint(equalTo: section.topAnchor),
            sectionStack.bottomAnchor.constraint(equalTo: section.bottomAnchor)
        ])

        // 当前解析摘要 + 可展开设置开关
        let toggleRow = NSView()
        parseSummaryLabel.lineBreakMode = .byTruncatingTail
        parseSummaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        parseSummaryLabel.translatesAutoresizingMaskIntoConstraints = false
        toggleRow.addSubview(parseSummaryLabel)

        parseSettingsToggle.target = self
        parseSettingsToggle.action = #selector(toggleParseSettings)
        parseSettingsToggle.translatesAutoresizingMaskIntoConstraints = false
        toggleRow.addSubview(parseSettingsToggle)

        NSLayoutConstraint.activate([
            toggleRow.heightAnchor.constraint(equalToConstant: 24),
            parseSummaryLabel.leadingAnchor.constraint(equalTo: toggleRow.leadingAnchor),
            parseSummaryLabel.centerYAnchor.constraint(equalTo: toggleRow.centerYAnchor),
            parseSummaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: parseSettingsToggle.leadingAnchor, constant: -10),
            parseSettingsToggle.trailingAnchor.constraint(equalTo: toggleRow.trailingAnchor),
            parseSettingsToggle.centerYAnchor.constraint(equalTo: toggleRow.centerYAnchor),
            parseSettingsToggle.widthAnchor.constraint(equalToConstant: 148)
        ])

        parseLanguageLabel.stringValue = L("识别语言", "Language")
        parseParserLabel.stringValue = L("解析方式", "Parser")
        parseFormatLabel.stringValue = L("输出格式", "Output")
        parseTokenLabel.stringValue = "MinerU Token"

        languagePopup.translatesAutoresizingMaskIntoConstraints = false
        parserPopup.translatesAutoresizingMaskIntoConstraints = false
        formatPopup.translatesAutoresizingMaskIntoConstraints = false
        mineruTokenField.translatesAutoresizingMaskIntoConstraints = false

        for control in [languagePopup, parserPopup, formatPopup] {
            control.controlSize = .regular
        }
        mineruTokenField.font = NSFont.systemFont(ofSize: 12)

        languagePopup.widthAnchor.constraint(equalToConstant: 230).isActive = true
        formatPopup.widthAnchor.constraint(equalToConstant: 230).isActive = true
        languagePopup.heightAnchor.constraint(equalToConstant: 26).isActive = true
        formatPopup.heightAnchor.constraint(equalToConstant: 26).isActive = true
        parserPopup.heightAnchor.constraint(equalToConstant: 26).isActive = true
        mineruTokenField.heightAnchor.constraint(equalToConstant: 26).isActive = true

        parserPopup.addItems(withTitles: parserOptionTitles)
        parserPopup.selectItem(at: 0)
        parserPopup.target = self
        parserPopup.action = #selector(parserSelectionChanged)

        formatPopup.addItems(withTitles: formatOptions.map(\.localizedTitle))
        formatPopup.selectItem(at: 0)
        formatPopup.target = self
        formatPopup.action = #selector(parserSelectionChanged)

        languagePopup.target = self
        languagePopup.action = #selector(parserSelectionChanged)

        mineruTokenField.placeholderString = L("填写一次即可，自动记住", "Enter once, remembered automatically")
        mineruTokenField.isBezeled = true
        mineruTokenField.bezelStyle = .roundedBezel

        for label in [parseLanguageLabel, parseParserLabel, parseFormatLabel, parseTokenLabel] {
            label.widthAnchor.constraint(equalToConstant: 86).isActive = true
        }

        let rowOne = NSStackView(views: [parseLanguageLabel, languagePopup, parseParserLabel, parserPopup])
        rowOne.orientation = .horizontal
        rowOne.alignment = .centerY
        rowOne.spacing = 10

        let rowTwo = NSStackView(views: [parseFormatLabel, formatPopup, parseTokenLabel, mineruTokenField])
        rowTwo.orientation = .horizontal
        rowTwo.alignment = .centerY
        rowTwo.spacing = 10
        rowTwo.distribution = .fill

        parserPopup.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        mineruTokenField.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        parseSettingsRows.orientation = .vertical
        parseSettingsRows.alignment = .leading
        parseSettingsRows.spacing = 8
        parseSettingsRows.addArrangedSubview(rowOne)
        parseSettingsRows.addArrangedSubview(rowTwo)
        rowOne.widthAnchor.constraint(equalTo: parseSettingsRows.widthAnchor).isActive = true
        rowTwo.widthAnchor.constraint(equalTo: parseSettingsRows.widthAnchor).isActive = true
        parseSettingsRows.isHidden = true

        sectionStack.addArrangedSubview(toggleRow)
        toggleRow.widthAnchor.constraint(equalTo: sectionStack.widthAnchor).isActive = true
        sectionStack.addArrangedSubview(parseSettingsRows)
        parseSettingsRows.widthAnchor.constraint(equalTo: sectionStack.widthAnchor).isActive = true
        return section
    }

    private func makeStepsCard() -> NSView {
        let card = BTCardView(insets: NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16))

        let header = makeSectionHeader(symbol: "list.number", label: stepsHeaderLabel)
        stepsHeaderLabel.stringValue = L("三步流程", "Three Steps")
        card.stack.addArrangedSubview(header)

        let stepOne = makeStepRow(
            number: 1,
            title: L("PDF 解析", "PDF Parsing"),
            subtitle: L("默认 MinerU 云端解析，OCR 备用", "MinerU cloud parsing by default, local OCR as fallback"),
            button: ocrButton,
            titleAssign: { [weak self] label in self?.stepOneTitleLabel = label },
            detailAssign: { [weak self] label in self?.stepOneDetailLabel = label }
        )
        let parseSection = makeParseSection()
        let stepTwo = makeStepRow(
            number: 2,
            title: L("转换为 MD / TXT / EPUB", "Convert to MD / TXT / EPUB"),
            subtitle: L("自动完成解析并提取文字，输出所选格式", "Parses and extracts text, then writes the chosen format"),
            button: parseButton,
            titleAssign: { [weak self] label in self?.stepTwoTitleLabel = label },
            detailAssign: { [weak self] label in self?.stepTwoDetailLabel = label }
        )
        let stepThree = makeStepRow(
            number: 3,
            title: L("交给 AI 排版", "AI Layout"),
            subtitle: L("自动使用第 2 步的文本，无需重新选择文件", "Uses the text from step 2 automatically — no need to pick a file again"),
            button: aiButton,
            titleAssign: { [weak self] label in self?.stepThreeTitleLabel = label },
            detailAssign: { [weak self] label in self?.stepThreeDetailLabel = label }
        )

        for view in [stepOne, parseSection, BTUI.separator(), stepTwo, BTUI.separator(), stepThree] {
            view.translatesAutoresizingMaskIntoConstraints = false
            card.stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: card.stack.widthAnchor).isActive = true
        }

        let aiSection = makeAISection()
        aiSection.translatesAutoresizingMaskIntoConstraints = false
        card.stack.addArrangedSubview(aiSection)
        aiSection.widthAnchor.constraint(equalTo: card.stack.widthAnchor).isActive = true
        card.stack.setCustomSpacing(2, after: stepOne)
        card.stack.setCustomSpacing(2, after: stepThree)

        card.stack.spacing = 4
        return card
    }

    private func makeAISection() -> NSView {
        let section = NSView()

        let sectionStack = NSStackView()
        sectionStack.orientation = .vertical
        sectionStack.alignment = .leading
        sectionStack.spacing = 6
        sectionStack.translatesAutoresizingMaskIntoConstraints = false
        section.addSubview(sectionStack)
        NSLayoutConstraint.activate([
            sectionStack.leadingAnchor.constraint(equalTo: section.leadingAnchor, constant: 32),
            sectionStack.trailingAnchor.constraint(equalTo: section.trailingAnchor, constant: -2),
            sectionStack.topAnchor.constraint(equalTo: section.topAnchor),
            sectionStack.bottomAnchor.constraint(equalTo: section.bottomAnchor)
        ])

        // 自动输入提示 + 可展开接口设置开关
        let inputRow = NSView()
        aiInputLabel.lineBreakMode = .byTruncatingMiddle
        aiInputLabel.translatesAutoresizingMaskIntoConstraints = false
        aiInputLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        inputRow.addSubview(aiInputLabel)

        aiSettingsToggle.target = self
        aiSettingsToggle.action = #selector(toggleAISettings)
        aiSettingsToggle.translatesAutoresizingMaskIntoConstraints = false
        inputRow.addSubview(aiSettingsToggle)

        NSLayoutConstraint.activate([
            inputRow.heightAnchor.constraint(equalToConstant: 24),
            aiInputLabel.leadingAnchor.constraint(equalTo: inputRow.leadingAnchor),
            aiInputLabel.centerYAnchor.constraint(equalTo: inputRow.centerYAnchor),
            aiInputLabel.trailingAnchor.constraint(lessThanOrEqualTo: aiSettingsToggle.leadingAnchor, constant: -10),
            aiSettingsToggle.trailingAnchor.constraint(equalTo: inputRow.trailingAnchor),
            aiSettingsToggle.centerYAnchor.constraint(equalTo: inputRow.centerYAnchor),
            aiSettingsToggle.widthAnchor.constraint(equalToConstant: 148)
        ])

        // 可展开的接口设置
        aiSettingsStack.orientation = .vertical
        aiSettingsStack.alignment = .leading
        aiSettingsStack.spacing = 6
        aiSettingsStack.isHidden = true

        for field in [aiAPIURLField, aiModelField, aiAPIKeyField, aiAPIKeyPlainField, aiChunkSizeField] {
            field.font = NSFont.systemFont(ofSize: 12)
            field.isBezeled = true
            field.bezelStyle = .roundedBezel
            field.heightAnchor.constraint(equalToConstant: 24).isActive = true
            field.cell?.usesSingleLineMode = true
        }
        aiAPIURLField.placeholderString = "https://api.openai.com/v1/chat/completions"
        aiModelField.placeholderString = "gpt-4o-mini"
        aiModelField.controlSize = .regular
        aiModelField.completes = true
        aiModelField.numberOfVisibleItems = 12
        aiModelField.hasVerticalScroller = true
        aiAPIKeyField.placeholderString = L("sk-… 只保存在本机偏好设置里", "sk-… stored only in local preferences")
        aiAPIKeyPlainField.placeholderString = aiAPIKeyField.placeholderString
        aiAPIKeyPlainField.isHidden = true
        aiAPIKeyField.delegate = self
        aiAPIKeyPlainField.delegate = self
        aiChunkSizeField.placeholderString = "8000"
        aiFormatPopup.controlSize = .regular
        aiFormatPopup.addItems(withTitles: aiFormatOptions.map(\.localizedTitle))

        aiModelFetchButton.target = self
        aiModelFetchButton.action = #selector(fetchAIModels)
        aiModelFetchButton.toolTip = L("从当前 API 拉取可用模型，然后从列表中选择", "Fetch available models from the current API and pick one from the list")
        aiAPITestButton.target = self
        aiAPITestButton.action = #selector(testAIAPIInterface)
        aiAPITestButton.toolTip = L("向当前接口发送一次很小的测试请求，确认 API 地址、API Key 和模型是否可用", "Send a tiny test request to verify the API URL, API Key, and model")
        aiAPIKeyRevealButton.target = self
        aiAPIKeyRevealButton.action = #selector(toggleAPIKeyVisibility)
        aiAPIKeyRevealButton.toolTip = L("显示 API Key", "Show API Key")

        aiURLLabel.stringValue = L("API 地址", "API URL")
        aiModelLabel.stringValue = L("模型", "Model")
        aiKeyLabel.stringValue = "API Key"
        aiChunkLabel.stringValue = L("分块字符数", "Chunk Size")
        aiOutputFormatLabel.stringValue = L("AI 输出格式", "AI Output")
        for label in [aiURLLabel, aiModelLabel, aiKeyLabel, aiChunkLabel, aiOutputFormatLabel] {
            label.widthAnchor.constraint(equalToConstant: 86).isActive = true
        }

        aiTestResultLabel.lineBreakMode = .byTruncatingTail
        aiTestResultLabel.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        aiTestResultLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        aiTestResultLabel.isHidden = true

        let keyFieldContainer = NSView()
        keyFieldContainer.translatesAutoresizingMaskIntoConstraints = false
        keyFieldContainer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        keyFieldContainer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for field in [aiAPIKeyField, aiAPIKeyPlainField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            keyFieldContainer.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: keyFieldContainer.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: keyFieldContainer.trailingAnchor),
                field.topAnchor.constraint(equalTo: keyFieldContainer.topAnchor),
                field.bottomAnchor.constraint(equalTo: keyFieldContainer.bottomAnchor)
            ])
        }

        let urlRow = makeAIFormRow([aiURLLabel, aiAPIURLField])
        let keyRow = makeAIFormRow([aiKeyLabel, keyFieldContainer, aiAPIKeyRevealButton])
        let modelSpacer = NSView()
        modelSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let modelRow = makeAIFormRow([aiModelLabel, aiModelField, aiModelFetchButton, aiAPITestButton, modelSpacer])
        aiModelField.widthAnchor.constraint(equalToConstant: 240).isActive = true
        aiModelFetchButton.widthAnchor.constraint(equalToConstant: 138).isActive = true
        aiAPITestButton.widthAnchor.constraint(equalToConstant: 110).isActive = true

        let rowSpacer = NSView()
        rowSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let formatRow = makeAIFormRow([aiChunkLabel, aiChunkSizeField, aiOutputFormatLabel, aiFormatPopup, rowSpacer])
        aiChunkSizeField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        aiFormatPopup.widthAnchor.constraint(equalToConstant: 210).isActive = true
        aiFormatPopup.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let resultRow = makeAIFormRow([aiTestResultLabel])

        aiAPIURLField.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        for row in [urlRow, keyRow, modelRow, resultRow, formatRow] {
            aiSettingsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: aiSettingsStack.widthAnchor).isActive = true
        }

        // 断点 / 运行状态行
        aiResumeLabel.lineBreakMode = .byTruncatingTail
        aiResumeLabel.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        aiResumeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        aiResumeButton.target = self
        aiResumeButton.action = #selector(resumeAIReflow)
        aiSkipButton.target = self
        aiSkipButton.action = #selector(skipAIChunk)
        aiCleanupButton.target = self
        aiCleanupButton.action = #selector(cleanupAIReflow)
        aiCancelButton.target = self
        aiCancelButton.action = #selector(cancelAIReflow)

        let resumeStack = NSStackView(views: [aiResumeLabel, aiResumeButton, aiSkipButton, aiCleanupButton, aiCancelButton])
        resumeStack.orientation = .horizontal
        resumeStack.alignment = .centerY
        resumeStack.spacing = 8
        resumeStack.translatesAutoresizingMaskIntoConstraints = false

        aiResumeRow.addSubview(resumeStack)
        NSLayoutConstraint.activate([
            aiResumeRow.heightAnchor.constraint(equalToConstant: 24),
            resumeStack.leadingAnchor.constraint(equalTo: aiResumeRow.leadingAnchor),
            resumeStack.trailingAnchor.constraint(equalTo: aiResumeRow.trailingAnchor),
            resumeStack.topAnchor.constraint(equalTo: aiResumeRow.topAnchor),
            resumeStack.bottomAnchor.constraint(equalTo: aiResumeRow.bottomAnchor)
        ])
        aiResumeRow.isHidden = true
        aiResumeButton.widthAnchor.constraint(equalToConstant: 108).isActive = true
        aiSkipButton.widthAnchor.constraint(equalToConstant: 126).isActive = true
        aiCleanupButton.widthAnchor.constraint(equalToConstant: 136).isActive = true
        aiCancelButton.widthAnchor.constraint(equalToConstant: 146).isActive = true

        sectionStack.addArrangedSubview(inputRow)
        inputRow.widthAnchor.constraint(equalTo: sectionStack.widthAnchor).isActive = true
        sectionStack.addArrangedSubview(aiSettingsStack)
        aiSettingsStack.widthAnchor.constraint(equalTo: sectionStack.widthAnchor).isActive = true
        sectionStack.addArrangedSubview(aiResumeRow)
        aiResumeRow.widthAnchor.constraint(equalTo: sectionStack.widthAnchor).isActive = true
        return section
    }

    private func makeAIFormRow(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.distribution = .fill
        return row
    }

    private func makeSectionHeader(symbol: String, label: NSTextField) -> NSView {
        let imageView = NSImageView()
        let configuration = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold)
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        imageView.contentTintColor = .secondaryLabelColor
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [imageView, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 13),
            imageView.heightAnchor.constraint(equalToConstant: 13)
        ])
        return stack
    }

    private func makeStepRow(
        number: Int,
        title: String,
        subtitle: String,
        button: BTButton,
        titleAssign: ((NSTextField) -> Void)? = nil,
        detailAssign: ((NSTextField) -> Void)? = nil
    ) -> NSView {
        let row = NSView()

        let badge = BTNumberBadge(number: number)
        row.addSubview(badge)

        let titleLabel = BTUI.label(title, size: 13, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(titleLabel)
        titleAssign?(titleLabel)

        let detailLabel = BTUI.label(subtitle, size: 11, color: .secondaryLabelColor)
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(detailLabel)
        detailAssign?(detailLabel)

        button.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(button)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 36),

            badge.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            badge.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
            titleLabel.topAnchor.constraint(equalTo: row.topAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -10),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -10),

            button.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -2),
            button.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 132)
        ])
        return row
    }

    private func makeStatusStack() -> NSView {
        let container = NSView()

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        outputLabel.translatesAutoresizingMaskIntoConstraints = false
        outputLabel.lineBreakMode = .byTruncatingMiddle

        container.addSubview(statusLabel)
        container.addSubview(progressLabel)
        container.addSubview(progressBar)
        container.addSubview(outputLabel)

        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            statusLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: progressLabel.leadingAnchor, constant: -10),

            progressLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            progressLabel.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),

            progressBar.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
            progressBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            progressBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),

            outputLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 5),
            outputLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            outputLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            outputLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    private func makeLogCard() -> BTCardView {
        let card = BTCardView(insets: NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12))
        card.stack.spacing = 6

        let headerRow = NSView()
        logHeaderLabel.stringValue = L("运行日志", "Run Log")
        let header = makeSectionHeader(symbol: "terminal", label: logHeaderLabel)
        header.translatesAutoresizingMaskIntoConstraints = false
        headerRow.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: headerRow.leadingAnchor),
            header.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            headerRow.heightAnchor.constraint(equalToConstant: 16)
        ])
        card.stack.addArrangedSubview(headerRow)
        headerRow.widthAnchor.constraint(equalTo: card.stack.widthAnchor).isActive = true

        configureLogView()

        let well = BTWellView()
        well.translatesAutoresizingMaskIntoConstraints = false
        well.cornerRadius = 8

        let logScroll = NSScrollView()
        logScroll.translatesAutoresizingMaskIntoConstraints = false
        logScroll.hasVerticalScroller = true
        logScroll.autohidesScrollers = true
        logScroll.borderType = .noBorder
        logScroll.drawsBackground = false
        logScroll.documentView = logView
        well.addSubview(logScroll)
        NSLayoutConstraint.activate([
            logScroll.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: 2),
            logScroll.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -2),
            logScroll.topAnchor.constraint(equalTo: well.topAnchor, constant: 2),
            logScroll.bottomAnchor.constraint(equalTo: well.bottomAnchor, constant: -2)
        ])

        well.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        well.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        card.stack.addArrangedSubview(well)
        well.widthAnchor.constraint(equalTo: card.stack.widthAnchor).isActive = true
        return card
    }

    private func configureLogView() {
        logView.isEditable = false
        logView.isSelectable = true
        logView.drawsBackground = false
        logView.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        logView.textColor = .secondaryLabelColor
        logView.textContainerInset = NSSize(width: 6, height: 6)
        logView.frame = NSRect(x: 0, y: 0, width: 700, height: 60)
        logView.minSize = NSSize(width: 0, height: 0)
        logView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        logView.isVerticallyResizable = true
        logView.isHorizontallyResizable = false
        logView.autoresizingMask = [.width]
        logView.textContainer?.widthTracksTextView = true
        logView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        logView.string = L("日志会显示在这里。\n", "Logs will appear here.\n")
    }

    private func makeBottomBar() -> NSView {
        let bar = NSView()

        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        openOutputButton.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(cancelButton)
        bar.addSubview(openOutputButton)

        cancelButton.target = self
        cancelButton.action = #selector(cancelProcessing)
        openOutputButton.target = self
        openOutputButton.action = #selector(openOutputDirectory)
        ocrButton.target = self
        ocrButton.action = #selector(runOCRPDF)
        parseButton.target = self
        parseButton.action = #selector(runPDFParse)
        parseButton.keyEquivalent = "\r"
        aiButton.target = self
        aiButton.action = #selector(startAIReflow)

        NSLayoutConstraint.activate([
            bar.heightAnchor.constraint(equalToConstant: 30),

            cancelButton.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 2),
            cancelButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: 132),

            openOutputButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -2),
            openOutputButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            openOutputButton.widthAnchor.constraint(equalToConstant: 132)
        ])
        return bar
    }

    private func addFullWidth(_ view: NSView, to stack: NSStackView, spacingAfter: CGFloat? = nil) {
        view.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        if let spacingAfter {
            stack.setCustomSpacing(spacingAfter, after: view)
        }
    }

    private func setProgress(_ value: Double) {
        let clamped = min(100, max(0, value))
        progressBar.progress = clamped / 100
        progressLabel.stringValue = clamped > 0.5 ? "\(Int(clamped))%" : ""
    }

    // MARK: - Selection

    private func setSelectedFile(_ url: URL) {
        guard process == nil, !aiEngine.isRunning else { return }
        let ext = url.pathExtension.lowercased()
        guard ["pdf", "txt", "md", "markdown"].contains(ext) else {
            showFailure(L("请选择 PDF、TXT 或 MD 文件", "Choose a PDF, TXT, or MD file"))
            return
        }
        selectedURL = url.standardizedFileURL
        if ext == "txt" || ext == "md" || ext == "markdown" {
            lastTextURL = url.standardizedFileURL
        }
        outputURL = nil
        dropZone.iconName = ext == "pdf" ? "doc.richtext" : "doc.text"
        dropZone.titleText = url.lastPathComponent
        dropZone.subtitleText = ext == "pdf"
            ? L("默认直接用 MinerU 解析，OCR 是备用路线", "MinerU parses it directly; local OCR is the fallback")
            : L("可直接发送到 AI 排版", "Ready to send to AI layout")
        dropZone.needsDisplay = true
        fileLabel.stringValue = L("已选择：\(url.path)", "Selected: \(url.path)")
        fileLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = ext == "pdf"
            ? L("PDF 已就绪，默认可直接 MinerU 解析", "PDF ready — MinerU parsing is the default")
            : L("文本文件已就绪，可以发送到 AI 排版", "Text file ready — send it to AI layout")
        statusLabel.textColor = .labelColor
        outputLabel.stringValue = L("完成后会显示产物位置", "Output location will appear here")
        logView.string = L("日志会显示在这里。\n", "Logs will appear here.\n")
        setProgress(0)
        updateControls(isRunning: false)
        aiEngine.loadResumeState(for: currentTextURL())
    }

    private func updateControls(isRunning: Bool) {
        let ext = selectedURL?.pathExtension.lowercased() ?? ""
        let isPDF = ext == "pdf"
        let parserIsLocal = selectedParserCode() == "local"
        let busy = isRunning || aiEngine.isRunning
        chooseButton.isEnabled = !busy
        dropZone.isInteractionEnabled = !busy
        languagePopup.isEnabled = !busy
        parserPopup.isEnabled = !busy
        formatPopup.isEnabled = !busy
        mineruTokenField.isEnabled = !busy
        interfaceLanguagePopup.isEnabled = !busy
        ocrButton.isEnabled = !busy && isPDF && !languageOptions.isEmpty && parserIsLocal
        parseButton.isEnabled = !busy && isPDF && !languageOptions.isEmpty
        cancelButton.isEnabled = isRunning
        openOutputButton.isEnabled = !busy && (outputURL != nil || aiEngine.outputURL != nil || lastTextURL != nil || selectedURL != nil)
        refreshModeUI()
        refreshAISection()
        updateOneClickButton(isRunning: isRunning)
    }

    private func updateOneClickButton(isRunning: Bool) {
        let ext = selectedURL?.pathExtension.lowercased() ?? ""
        let isPDF = ext == "pdf"
        let isText = ["txt", "md", "markdown"].contains(ext)
        let busy = isRunning || aiEngine.isRunning

        if aiEngine.isRunning {
            oneClickButton.setTitleText(L("AI 排版中…", "AI Layout…"))
            oneClickButton.setSymbol("hourglass")
        } else if busy {
            oneClickButton.setTitleText(L("一键处理中…", "Processing…"))
            oneClickButton.setSymbol("hourglass")
        } else if isPDF {
            oneClickButton.setTitleText(L("一键处理", "One-Click"))
            oneClickButton.setSymbol("bolt.fill")
        } else if isText {
            oneClickButton.setTitleText(L("一键 AI 排版", "AI Layout"))
            oneClickButton.setSymbol("bolt.fill")
        } else {
            oneClickButton.setTitleText(L("一键处理", "One-Click"))
            oneClickButton.setSymbol("bolt.fill")
        }

        oneClickButton.isEnabled = !busy && (isPDF ? !languageOptions.isEmpty : isText)
        oneClickButton.toolTip = isText
            ? L("直接对当前文本开始 AI 排版", "Start AI layout on the current text")
            : L("自动完成 PDF 解析、文本转换，然后开始 AI 排版", "Automatically parse the PDF, convert the text, then start AI layout")
    }

    // MARK: - AI 排版

    private func wireAIEngine() {
        aiEngine.onStatus = { [weak self] text, color in
            self?.statusLabel.stringValue = text
            self?.statusLabel.textColor = color
        }
        aiEngine.onProgress = { [weak self] value in
            self?.setProgress(value)
        }
        aiEngine.onProgressLabel = { [weak self] text in
            self?.progressLabel.stringValue = text
        }
        aiEngine.onOutput = { [weak self] text in
            self?.outputLabel.stringValue = text
        }
        aiEngine.onLog = { [weak self] text in
            self?.appendLog(text + "\n")
        }
        aiEngine.onStateChange = { [weak self] in
            guard let self else { return }
            self.updateControls(isRunning: self.process?.isRunning == true)
        }
        aiEngine.onResumeStateChanged = { [weak self] in
            self?.refreshAIResumeState()
        }
    }

    private func loadSavedAISettings() {
        aiAPIURLField.stringValue = aiEngine.apiURLString
        aiModelField.stringValue = aiEngine.modelString
        aiAPIKeyField.stringValue = aiEngine.apiKeyString
        aiAPIKeyPlainField.stringValue = aiEngine.apiKeyString
        aiChunkSizeField.stringValue = String(aiEngine.chunkSize)
        if let index = aiFormatOptions.firstIndex(where: { $0.code == aiEngine.formatCode }) {
            aiFormatPopup.selectItem(at: index)
        }
    }

    private func syncAISettingsToEngine() {
        aiEngine.apiURLString = aiAPIURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        aiEngine.modelString = aiModelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        aiEngine.apiKeyString = activeAPIKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let size = Int(aiChunkSizeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
            aiEngine.chunkSize = size
        }
        let index = aiFormatPopup.indexOfSelectedItem
        if index >= 0, index < aiFormatOptions.count {
            aiEngine.formatCode = aiFormatOptions[index].code
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === aiAPIKeyField {
            aiAPIKeyPlainField.stringValue = aiAPIKeyField.stringValue
        } else if field === aiAPIKeyPlainField {
            aiAPIKeyField.stringValue = aiAPIKeyPlainField.stringValue
        }
    }

    @objc private func toggleAPIKeyVisibility() {
        window?.makeFirstResponder(nil)
        let value = activeAPIKeyField.stringValue
        aiAPIKeyField.stringValue = value
        aiAPIKeyPlainField.stringValue = value
        isShowingAPIKey.toggle()
        aiAPIKeyField.isHidden = isShowingAPIKey
        aiAPIKeyPlainField.isHidden = !isShowingAPIKey
        updateRevealButton()
        window?.makeFirstResponder(activeAPIKeyField)
    }

    private func updateRevealButton() {
        aiAPIKeyRevealButton.setTitleText(isShowingAPIKey ? L("隐藏", "Hide") : L("显示", "Show"))
        aiAPIKeyRevealButton.setSymbol(isShowingAPIKey ? "eye.slash" : "eye")
        aiAPIKeyRevealButton.toolTip = isShowingAPIKey
            ? L("隐藏 API Key", "Hide API Key")
            : L("显示 API Key", "Show API Key")
    }

    @objc private func testAIAPIInterface() {
        guard !isTestingAIAPI, !isFetchingAIModels else { return }
        guard process?.isRunning != true, !aiEngine.isRunning else { return }
        window?.makeFirstResponder(nil)
        syncAISettingsToEngine()
        isTestingAIAPI = true
        setAITestResult(L("正在测试接口，会发送一次很小的请求…", "Testing the API with one tiny request…"), color: .secondaryLabelColor, toolTip: nil)
        refreshAISection()

        aiEngine.testConnection { [weak self] result in
            guard let self else { return }
            self.isTestingAIAPI = false
            switch result {
            case .success(let outcome):
                let seconds = String(format: "%.1f", outcome.latency)
                self.setAITestResult(
                    L("接口正常 · \(outcome.model) · \(seconds) 秒", "API OK · \(outcome.model) · \(seconds) s"),
                    color: .systemGreen,
                    toolTip: L("模型返回：\(outcome.replyPreview)", "Model replied: \(outcome.replyPreview)")
                )
                self.appendLog(L("接口测试成功：\(outcome.model)，用时 \(seconds) 秒", "API test passed: \(outcome.model), \(seconds) s"))
                self.syncAISettingsToEngine()
                self.aiEngine.saveCurrentSettings()
            case .failure(let error):
                self.setAITestResult(L("接口测试失败：\(error.message)", "API test failed: \(error.message)"), color: .systemRed, toolTip: error.message)
                self.appendLog(L("接口测试失败：\(error.message)", "API test failed: \(error.message)"))
            }
            self.refreshAISection()
        }
    }

    @objc private func fetchAIModels() {
        guard !isTestingAIAPI, !isFetchingAIModels else { return }
        guard process?.isRunning != true, !aiEngine.isRunning else { return }
        window?.makeFirstResponder(nil)
        syncAISettingsToEngine()
        isFetchingAIModels = true
        setAITestResult(L("正在从接口拉取模型列表…", "Fetching the model list from the API…"), color: .secondaryLabelColor, toolTip: nil)
        refreshAISection()

        aiEngine.fetchAvailableModels { [weak self] result in
            guard let self else { return }
            self.isFetchingAIModels = false
            switch result {
            case .success(let models):
                self.aiModelField.removeAllItems()
                self.aiModelField.addItems(withObjectValues: models)
                self.setAITestResult(
                    L("已获取 \(models.count) 个模型，请在列表中选择", "Fetched \(models.count) models — pick one from the list"),
                    color: .systemGreen,
                    toolTip: models.prefix(60).joined(separator: "\n")
                )
                self.appendLog(L("已拉取 \(models.count) 个可用模型", "Fetched \(models.count) available models"))
                self.syncAISettingsToEngine()
                self.aiEngine.saveCurrentSettings()
                self.refreshAISection()
                self.presentFetchedModelMenu(models)
            case .failure(let error):
                self.setAITestResult(
                    L("拉取模型失败：\(error.message)；也可以手动填写模型名", "Failed to fetch models: \(error.message); you can also type a model name"),
                    color: .systemRed,
                    toolTip: error.message
                )
                self.appendLog(L("拉取模型失败：\(error.message)", "Failed to fetch models: \(error.message)"))
                self.refreshAISection()
            }
        }
    }

    private func presentFetchedModelMenu(_ models: [String]) {
        let menu = NSMenu()
        let header = NSMenuItem(title: L("选择模型（共 \(models.count) 个）", "Choose a model (\(models.count) total)"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let current = aiModelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        for model in models {
            let item = NSMenuItem(title: model, action: #selector(selectFetchedModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = model
            item.state = model == current ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: aiModelFetchButton)
    }

    @objc private func selectFetchedModel(_ sender: NSMenuItem) {
        guard let model = sender.representedObject as? String else { return }
        aiModelField.stringValue = model
        syncAISettingsToEngine()
        aiEngine.saveCurrentSettings()
        setAITestResult(L("已选择模型：\(model)", "Model selected: \(model)"), color: .secondaryLabelColor, toolTip: model)
        appendLog(L("已选择模型：\(model)", "Model selected: \(model)"))
    }

    private func setAITestResult(_ text: String, color: NSColor, toolTip: String?) {
        aiTestResultLabel.isHidden = false
        aiTestResultLabel.stringValue = text
        aiTestResultLabel.textColor = color
        aiTestResultLabel.toolTip = toolTip
    }

    private func refreshAIResumeState() {
        if let size = aiEngine.resumeChunkSize {
            aiChunkSizeField.stringValue = String(size)
        }
        if let code = aiEngine.resumeFormatCode,
           let index = aiFormatOptions.firstIndex(where: { $0.code == code }) {
            aiFormatPopup.selectItem(at: index)
        }
        refreshAISection()
    }

    private func refreshAISection() {
        let pdfBusy = process?.isRunning == true
        let aiRunning = aiEngine.isRunning
        let input = currentTextURL()

        if let input {
            aiInputLabel.stringValue = L("自动使用：\(input.lastPathComponent)", "Auto input: \(input.lastPathComponent)")
            aiInputLabel.textColor = .secondaryLabelColor
            aiInputLabel.toolTip = input.path
        } else {
            aiInputLabel.stringValue = L("暂无文本：完成第 2 步后自动可用", "No text yet — available after step 2")
            aiInputLabel.textColor = .tertiaryLabelColor
            aiInputLabel.toolTip = nil
        }

        aiButton.isEnabled = !pdfBusy && !aiRunning && (input != nil || aiEngine.resumeAvailable)
        if aiRunning {
            aiButton.setTitleText(L("AI 排版中…", "AI Layout…"))
            aiButton.setSymbol("hourglass")
        } else if aiEngine.resumeAvailable {
            aiButton.setTitleText(L("继续 AI 排版", "Resume"))
            aiButton.setSymbol("play.circle")
        } else {
            aiButton.setTitleText(L("开始 AI 排版", "AI Layout"))
            aiButton.setSymbol("wand.and.stars")
        }

        if aiRunning {
            stepThreeDetailLabel?.stringValue = L(
                "正在整理：\(progressLabel.stringValue)，日志和断点会实时更新",
                "Working on \(progressLabel.stringValue) — log and checkpoint update live"
            )
        } else if aiEngine.resumeAvailable {
            stepThreeDetailLabel?.stringValue = L(
                "检测到未完成：已完成 \(aiEngine.resumeCompletedChunks) / \(aiEngine.resumeTotalChunks) 块",
                "Unfinished run found: \(aiEngine.resumeCompletedChunks) / \(aiEngine.resumeTotalChunks) chunks done"
            )
        } else if input != nil {
            stepThreeDetailLabel?.stringValue = L("自动使用第 2 步的文本，无需重新选择文件", "Uses the text from step 2 automatically — no need to pick a file again")
        } else {
            stepThreeDetailLabel?.stringValue = L("完成第 2 步后，可直接开始 AI 排版", "Finish step 2, then start AI layout right away")
        }

        if aiRunning {
            aiResumeRow.isHidden = false
            aiResumeLabel.stringValue = L("AI 正在排版，终止会清理未完成产物", "AI layout is running — stopping cleans up unfinished output")
            aiResumeLabel.textColor = .systemOrange
            aiResumeButton.isHidden = true
            aiSkipButton.isHidden = true
            aiCleanupButton.isHidden = true
            aiCancelButton.isHidden = false
        } else if aiEngine.resumeAvailable {
            aiResumeRow.isHidden = false
            let format = aiEngine.resumeFormatCode?.uppercased() ?? "TXT"
            aiResumeLabel.stringValue = L(
                "未完成：\(format)，已完成 \(aiEngine.resumeCompletedChunks) / \(aiEngine.resumeTotalChunks) 块",
                "Unfinished: \(format), \(aiEngine.resumeCompletedChunks) / \(aiEngine.resumeTotalChunks) chunks done"
            )
            aiResumeLabel.textColor = .systemOrange
            aiResumeButton.isHidden = false
            aiSkipButton.isHidden = false
            aiCleanupButton.isHidden = false
            aiCancelButton.isHidden = true
        } else {
            aiResumeRow.isHidden = true
        }

        updateAISettingsToggle()
        let utilityBusy = isTestingAIAPI || isFetchingAIModels
        for field in [aiAPIURLField, aiModelField, aiAPIKeyField, aiAPIKeyPlainField, aiChunkSizeField] {
            field.isEnabled = !pdfBusy && !aiRunning && !utilityBusy
        }
        aiFormatPopup.isEnabled = !pdfBusy && !aiRunning && !utilityBusy

        let utilityEnabled = !pdfBusy && !aiRunning && !utilityBusy
        aiModelFetchButton.isEnabled = utilityEnabled
        aiAPITestButton.isEnabled = utilityEnabled
        aiAPIKeyRevealButton.isEnabled = utilityEnabled
        aiModelFetchButton.setTitleText(isFetchingAIModels ? L("拉取中…", "Fetching…") : L("拉取模型", "Fetch Models"))
        aiModelFetchButton.setSymbol(isFetchingAIModels ? "hourglass" : "arrow.down.circle")
        aiAPITestButton.setTitleText(isTestingAIAPI ? L("测试中…", "Testing…") : L("测试接口", "Test API"))
        aiAPITestButton.setSymbol(isTestingAIAPI ? "hourglass" : "network")
        updateRevealButton()
    }

    private func applyExpansionStates() {
        let defaults = UserDefaults.standard
        parseSettingsExpanded = defaults.bool(forKey: parseSettingsExpandedKey)
        aiSettingsExpanded = defaults.bool(forKey: aiSettingsExpandedKey)
        parseSettingsRows.isHidden = !parseSettingsExpanded
        aiSettingsStack.isHidden = !aiSettingsExpanded
        updateParseSettingsToggle()
        updateAISettingsToggle()
    }

    private func loadSavedAppearance() {
        let raw = UserDefaults.standard.string(forKey: appearanceDefaultsKey) ?? AppearanceMode.system.rawValue
        let mode = AppearanceMode(rawValue: raw) ?? .system
        applyAppearance(mode, persist: false)
    }

    private func applyAppearance(_ mode: AppearanceMode, persist: Bool) {
        switch mode {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        rebuildAppearancePopup(selecting: mode)
        if persist {
            UserDefaults.standard.set(mode.rawValue, forKey: appearanceDefaultsKey)
        }
    }

    private func rebuildAppearancePopup(selecting mode: AppearanceMode? = nil) {
        let fallbackIndex = appearancePopup.indexOfSelectedItem
        let target = mode ?? (fallbackIndex >= 0 && fallbackIndex < AppearanceMode.allCases.count
            ? AppearanceMode.allCases[fallbackIndex]
            : .system)
        appearancePopup.removeAllItems()
        appearancePopup.addItems(withTitles: AppearanceMode.allCases.map(\.title))
        if let index = AppearanceMode.allCases.firstIndex(where: { $0.rawValue == target.rawValue }) {
            appearancePopup.selectItem(at: index)
        }
    }

    @objc private func appearanceSelectionChanged() {
        let index = appearancePopup.indexOfSelectedItem
        guard index >= 0, index < AppearanceMode.allCases.count else { return }
        applyAppearance(AppearanceMode.allCases[index], persist: true)
    }

    private func syncLanguagePopupSelection() {
        let index = AppLanguage.allCases.firstIndex(of: AppLocalization.language) ?? 0
        interfaceLanguagePopup.selectItem(at: index)
    }

    @objc private func interfaceLanguageChanged() {
        let index = interfaceLanguagePopup.indexOfSelectedItem
        guard index >= 0, index < AppLanguage.allCases.count else { return }
        let language = AppLanguage.allCases[index]
        guard language != AppLocalization.language else { return }
        AppLocalization.setLanguage(language)
        applyLanguage()
        (NSApp.delegate as? AppDelegate)?.rebuildMainMenu()
    }

    /// 切换界面语言后刷新所有已有控件，保留当前文件、设置与日志。
    private func applyLanguage() {
        syncLanguagePopupSelection()
        interfaceLanguagePopup.toolTip = L("界面语言", "Interface language")
        appearancePopup.toolTip = L("外观：跟随系统、浅色或深色", "Appearance: System, Light, or Dark")

        stepsHeaderLabel.stringValue = L("三步流程", "Three Steps")
        logHeaderLabel.stringValue = L("运行日志", "Run Log")

        stepOneTitleLabel?.stringValue = L("PDF 解析", "PDF Parsing")
        stepTwoTitleLabel?.stringValue = L("转换为 MD / TXT / EPUB", "Convert to MD / TXT / EPUB")
        stepTwoDetailLabel?.stringValue = L("自动完成解析并提取文字，输出所选格式", "Parses and extracts text, then writes the chosen format")
        stepThreeTitleLabel?.stringValue = L("交给 AI 排版", "AI Layout")

        chooseButton.setTitleText(L("选择文件", "Choose File"))
        parseButton.setTitleText(L("开始转换", "Convert"))
        cancelButton.setTitleText(L("终止并清理", "Stop & Clean"))
        openOutputButton.setTitleText(L("打开产物目录", "Open Output"))
        aiResumeButton.setTitleText(L("继续未完成", "Resume"))
        aiSkipButton.setTitleText(L("跳过当前块", "Skip Chunk"))
        aiCleanupButton.setTitleText(L("清理断点", "Clear Resume"))
        aiCancelButton.setTitleText(L("终止 AI 排版", "Stop AI Layout"))

        parseLanguageLabel.stringValue = L("识别语言", "Language")
        parseParserLabel.stringValue = L("解析方式", "Parser")
        parseFormatLabel.stringValue = L("输出格式", "Output")
        parseTokenLabel.stringValue = "MinerU Token"
        mineruTokenField.placeholderString = L("填写一次即可，自动记住", "Enter once, remembered automatically")
        rebuildParserPopup()
        rebuildFormatPopup()
        rebuildLanguagePopup()

        aiURLLabel.stringValue = L("API 地址", "API URL")
        aiModelLabel.stringValue = L("模型", "Model")
        aiKeyLabel.stringValue = "API Key"
        aiChunkLabel.stringValue = L("分块字符数", "Chunk Size")
        aiOutputFormatLabel.stringValue = L("AI 输出格式", "AI Output")
        aiAPIKeyField.placeholderString = L("sk-… 只保存在本机偏好设置里", "sk-… stored only in local preferences")
        aiAPIKeyPlainField.placeholderString = aiAPIKeyField.placeholderString
        aiModelFetchButton.toolTip = L("从当前 API 拉取可用模型，然后从列表中选择", "Fetch available models from the current API and pick one from the list")
        aiAPITestButton.toolTip = L("向当前接口发送一次很小的测试请求，确认 API 地址、API Key 和模型是否可用", "Send a tiny test request to verify the API URL, API Key, and model")
        rebuildAIFormatPopup()

        let defaultLogs = ["日志会显示在这里。\n", "Logs will appear here.\n"]
        if defaultLogs.contains(logView.string) {
            logView.string = L("日志会显示在这里。\n", "Logs will appear here.\n")
        }

        refreshSelectedFileTexts()
        updateParseSettingsToggle()
        updateAISettingsToggle()
        refreshModeUI()
        refreshIdleStatus()
        refreshAISection()
        updateOneClickButton(isRunning: process?.isRunning == true)
    }

    private func rebuildParserPopup() {
        let index = max(0, parserPopup.indexOfSelectedItem)
        parserPopup.removeAllItems()
        parserPopup.addItems(withTitles: parserOptionTitles)
        parserPopup.selectItem(at: min(index, parserOptionTitles.count - 1))
    }

    private func rebuildFormatPopup() {
        let index = max(0, formatPopup.indexOfSelectedItem)
        formatPopup.removeAllItems()
        formatPopup.addItems(withTitles: formatOptions.map(\.localizedTitle))
        formatPopup.selectItem(at: min(index, formatOptions.count - 1))
    }

    private func rebuildAIFormatPopup() {
        let index = max(0, aiFormatPopup.indexOfSelectedItem)
        aiFormatPopup.removeAllItems()
        aiFormatPopup.addItems(withTitles: aiFormatOptions.map(\.localizedTitle))
        aiFormatPopup.selectItem(at: min(index, aiFormatOptions.count - 1))
    }

    private func rebuildLanguagePopup() {
        let selectedCode = selectedLanguage()?.code
        languagePopup.removeAllItems()
        languagePopup.addItems(withTitles: languageOptions.map(\.localizedTitle))
        if let selectedCode,
           let index = languageOptions.firstIndex(where: { $0.code == selectedCode }) {
            languagePopup.selectItem(at: index)
        }
    }

    /// 只重建当前文件相关的静态文案，不清空日志或产物状态。
    private func refreshSelectedFileTexts() {
        guard let url = selectedURL else {
            dropZone.iconName = "arrow.down.doc"
            dropZone.titleText = L("把 PDF / TXT / MD 文件拖到这里", "Drop a PDF / TXT / MD file here")
            dropZone.subtitleText = L("也可以双击此区域选择文件", "Or double-click this area to choose a file")
            dropZone.needsDisplay = true
            fileLabel.stringValue = L("尚未选择文件", "No file selected")
            fileLabel.textColor = .tertiaryLabelColor
            return
        }
        let ext = url.pathExtension.lowercased()
        dropZone.iconName = ext == "pdf" ? "doc.richtext" : "doc.text"
        dropZone.titleText = url.lastPathComponent
        if ext != "pdf" {
            dropZone.subtitleText = L("可直接发送到 AI 排版", "Ready to send to AI layout")
        }
        dropZone.needsDisplay = true
        fileLabel.stringValue = L("已选择：\(url.path)", "Selected: \(url.path)")
        fileLabel.textColor = .secondaryLabelColor
    }

    /// 空闲时按当前文件重新给出状态与产物文案（切换语言后不会留下旧语言的句子）。
    private func refreshIdleStatus() {
        guard process == nil, !aiEngine.isRunning else { return }
        if let out = outputURL, fileManager.fileExists(atPath: out.path) {
            statusLabel.stringValue = L("处理完成", "Done")
            statusLabel.textColor = .systemGreen
            outputLabel.stringValue = L("产物位置：\(out.path)", "Output: \(out.path)")
            return
        }
        if let aiOut = aiEngine.outputURL {
            statusLabel.stringValue = L("AI 排版完成", "AI layout complete")
            statusLabel.textColor = .systemGreen
            outputLabel.stringValue = L("产物位置：\(aiOut.path)", "Output: \(aiOut.path)")
            return
        }
        if let url = selectedURL {
            if url.pathExtension.lowercased() == "pdf" {
                statusLabel.stringValue = selectedParserCode() == "mineru"
                    ? L("PDF 已就绪，默认可直接 MinerU 解析", "PDF ready — MinerU parsing is the default")
                    : L("PDF 已就绪，可执行本地 OCR 或直接转换", "PDF ready — run local OCR or convert directly")
            } else {
                statusLabel.stringValue = L("文本文件已就绪，可以发送到 AI 排版", "Text file ready — send it to AI layout")
            }
        } else {
            statusLabel.stringValue = L("请选择 PDF、TXT 或 MD，开始三步处理", "Choose a PDF, TXT, or MD file to start")
        }
        statusLabel.textColor = .labelColor
        outputLabel.stringValue = L("完成后会显示产物位置", "Output location will appear here")
    }

    private func updateParseSettingsToggle() {
        parseSettingsToggle.setTitleText(parseSettingsExpanded ? L("收起设置", "Hide settings") : L("解析设置", "Parse settings"))
        parseSettingsToggle.setSymbol(parseSettingsExpanded ? "chevron.up" : "chevron.right")
    }

    private func updateAISettingsToggle() {
        aiSettingsToggle.setTitleText(aiSettingsExpanded ? L("收起接口设置", "Hide settings") : L("AI 排版接口设置", "AI API Settings"))
        aiSettingsToggle.setSymbol(aiSettingsExpanded ? "chevron.up" : "chevron.right")
    }

    @objc private func toggleParseSettings() {
        parseSettingsExpanded.toggle()
        parseSettingsRows.isHidden = !parseSettingsExpanded
        UserDefaults.standard.set(parseSettingsExpanded, forKey: parseSettingsExpandedKey)
        updateParseSettingsToggle()
        if parseSettingsExpanded {
            revealSettings(parseSettingsRows)
        }
    }

    private func setAISettingsExpanded(_ expanded: Bool) {
        guard expanded != aiSettingsExpanded else { return }
        aiSettingsExpanded = expanded
        aiSettingsStack.isHidden = !expanded
        UserDefaults.standard.set(expanded, forKey: aiSettingsExpandedKey)
        updateAISettingsToggle()
        refreshAISection()
        if expanded {
            revealSettings(aiSettingsStack)
        }
    }

    private func revealSettings(_ view: NSView) {
        DispatchQueue.main.async {
            view.scrollToVisible(view.bounds)
        }
    }

    // MARK: - Worker

    private func runWorker(scriptName: String, arguments: [String], extraEnvironment: [String: String] = [:], initialStatus: String) {
        guard let scriptURL = Bundle.main.resourceURL?.appendingPathComponent(scriptName) else {
            showFailure(L("找不到内置处理脚本", "The built-in processing script is missing"))
            return
        }
        tempURL = nil
        partURL = outputURL?.appendingPathExtension("part")
        childPID = nil
        totalPages = nil
        currentPhase = ""
        partialWorkerLine = ""
        lastWorkerError = nil
        isCancelling = false
        setProgress(0)
        statusLabel.stringValue = initialStatus
        statusLabel.textColor = .labelColor
        outputLabel.stringValue = L("完成后会显示产物位置", "Output location will appear here")
        logView.string = L("日志开始...\n", "Log started…\n")
        updateControls(isRunning: true)

        let worker = Process()
        worker.executableURL = URL(fileURLWithPath: "/bin/zsh")
        worker.arguments = [scriptURL.path] + arguments
        var environment = [
            "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "TMPDIR": NSTemporaryDirectory(),
            "LANG": "en_US.UTF-8"
        ]
        for (key, value) in extraEnvironment {
            environment[key] = value
        }
        worker.environment = environment

        let pipe = Pipe()
        outputPipe = pipe
        worker.standardOutput = pipe
        worker.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { self?.consumeWorkerOutput(text) }
        }
        worker.terminationHandler = { [weak self] process in
            DispatchQueue.main.async { self?.workerFinished(process) }
        }

        process = worker
        do {
            try worker.run()
        } catch {
            process = nil
            outputPipe = nil
            updateControls(isRunning: false)
            showFailure(L("无法启动处理程序：\(error.localizedDescription)", "Could not start the processing script: \(error.localizedDescription)"))
        }
    }

    private func consumeWorkerOutput(_ text: String) {
        let combined = partialWorkerLine + text
        let lines = combined.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        partialWorkerLine = combined.hasSuffix("\n") ? "" : (lines.last ?? "")
        for line in lines.dropLast() {
            handleWorkerLine(line)
        }
    }

    private func handleWorkerLine(_ line: String) {
        appendLog(workerLogLine(line) + "\n")
        if line.hasPrefix("PHASE=") {
            currentPhase = String(line.dropFirst(6))
        } else if line.hasPrefix("STATUS=") {
            if lastWorkerError == nil { statusLabel.stringValue = localizedWorkerStatus(String(line.dropFirst(7))) }
        } else if line.hasPrefix("TEMP_DIR=") {
            tempURL = URL(fileURLWithPath: String(line.dropFirst(9)))
        } else if line.hasPrefix("PART_PATH=") {
            partURL = URL(fileURLWithPath: String(line.dropFirst(10)))
        } else if line.hasPrefix("CHILD_PID=") {
            childPID = pid_t(String(line.dropFirst(10))) ?? nil
        } else if line.hasPrefix("TOTAL_PAGES=") {
            totalPages = Int(line.dropFirst(12))
        } else if line.hasPrefix("PROGRESS="), let value = Double(line.dropFirst(9)) {
            setProgress(value)
        } else if line.hasPrefix("OUTPUT_PATH=") {
            let url = URL(fileURLWithPath: String(line.dropFirst(12)))
            outputURL = url
            if ["txt", "md", "markdown"].contains(url.pathExtension.lowercased()) {
                lastTextURL = url
            }
        } else if line.hasPrefix("ERROR=") {
            let message = localizedWorkerError(String(line.dropFirst(6)))
            lastWorkerError = message
            statusLabel.stringValue = message
            statusLabel.textColor = .systemRed
            outputLabel.stringValue = L("失败原因：\(message)", "Failure reason: \(message)")
        } else {
            updatePageProgress(from: line)
        }
    }

    private func flushPartialWorkerLine() {
        guard !partialWorkerLine.isEmpty else { return }
        handleWorkerLine(partialWorkerLine)
        partialWorkerLine = ""
    }

    /// 英文界面下，日志里固定的 STATUS / ERROR 行也换成英文；其他原始输出保持原样。
    private func workerLogLine(_ line: String) -> String {
        guard AppLocalization.isEnglish else { return line }
        if line.hasPrefix("STATUS=") {
            return localizedWorkerStatus(String(line.dropFirst(7)))
        }
        if line.hasPrefix("ERROR=") {
            return "Error: " + localizedWorkerError(String(line.dropFirst(6)))
        }
        return line
    }

    /// 处理脚本输出的 STATUS 行是固定中文；英文界面下做一次轻量映射，日志原文不变。
    private func localizedWorkerStatus(_ text: String) -> String {
        guard AppLocalization.isEnglish else { return text }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let exact: [String: String] = [
            "正在用 MinerU 精准解析 PDF": "Parsing the PDF with MinerU…",
            "正在合并 MinerU Markdown": "Merging MinerU Markdown…",
            "MinerU 精准解析失败，详情见下方日志": "MinerU parsing failed — see the log below",
            "MinerU TXT 生成完成": "MinerU TXT is ready",
            "MinerU Markdown 生成完成": "MinerU Markdown is ready",
            "MinerU EPUB 生成完成": "MinerU EPUB is ready",
            "正在检查 PDF 是否已有可用文字层": "Checking the PDF for an existing text layer…",
            "检测到已有可用文字层，跳过 OCR，直接使用现有文字": "Text layer found — skipping OCR and using the existing text",
            "未检测到足够文字层，准备进行本地 OCR": "Not enough text layer — preparing local OCR",
            "文字层检测失败，准备进行本地 OCR": "Text-layer check failed — preparing local OCR",
            "未找到 Ghostscript，无法检测文字层，准备进行本地 OCR": "Ghostscript not found — preparing local OCR",
            "正在使用 OCRmyPDF / Tesseract 识别 PDF 文字": "Recognizing PDF text with OCRmyPDF / Tesseract…",
            "正在整理 OCR 文字为 TXT": "Building TXT from the OCR text…",
            "正在整理 OCR 文字为 Markdown": "Building Markdown from the OCR text…",
            "正在生成可调字体 EPUB": "Generating the adjustable-font EPUB…",
            "TXT 生成完成": "TXT is ready",
            "Markdown 生成完成": "Markdown is ready",
            "EPUB 生成完成": "EPUB is ready",
            "正在识别 PDF 文字": "Recognizing PDF text…",
            "OCR 完成": "OCR finished",
            "正在 OCR 文字并生成可搜索 PDF": "Running OCR to create a searchable PDF…",
            "可搜索 PDF 生成完成": "Searchable PDF is ready"
        ]
        if let mapped = exact[trimmed] { return mapped }

        func pattern(_ prefix: String, _ suffix: String, _ englishPrefix: String, _ englishSuffix: String = "") -> String? {
            guard trimmed.hasPrefix(prefix), trimmed.hasSuffix(suffix) else { return nil }
            let start = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
            let end = trimmed.index(trimmed.endIndex, offsetBy: -suffix.count)
            guard start <= end else { return nil }
            return englishPrefix + String(trimmed[start..<end]) + englishSuffix
        }

        if let value = pattern("MinerU 解析中：约第 ", " 页", "MinerU parsing: page ") { return value }
        if let value = pattern("已拆分第 ", " 页", "Split pages ") { return value }
        if let value = pattern("PDF 已拆成 ", " 个 MinerU 分段", "PDF split into ", " MinerU parts") { return value }
        if let value = pattern("正在申请 MinerU 上传链接：第 ", " 段", "Requesting MinerU upload URLs: parts ") { return value }
        if let value = pattern("正在上传 MinerU 分段：第 ", " 页", "Uploading MinerU part: pages ") { return value }
        if let value = pattern("正在下载 MinerU 结果：第 ", " 页", "Downloading MinerU result: pages ") { return value }
        return trimmed
    }

    /// ERROR 行会直接显示在状态栏和“失败原因”中；英文界面下做同样的轻量映射，日志原文不变。
    private func localizedWorkerError(_ text: String) -> String {
        guard AppLocalization.isEnglish else { return text }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let exact: [String: String] = [
            "参数不足": "Missing arguments",
            "不支持的输出格式": "Unsupported output format",
            "不支持的解析方式": "Unsupported parser",
            "找不到 Python 3": "Python 3 was not found",
            "找不到 OCRmyPDF 或 Tesseract": "OCRmyPDF or Tesseract was not found",
            "找不到 qpdf，无法为 MinerU 拆分页数较多的 PDF": "qpdf was not found — cannot split large PDFs for MinerU",
            "输入 PDF 不存在": "The input PDF does not exist",
            "没有找到 MinerU Token，请在 App 界面填写后再开始": "MinerU Token not found — enter it in the app first",
            "无法读取 PDF 页数": "Could not read the PDF page count",
            "无法解析 PDF 页数": "Could not parse the PDF page count",
            "MinerU 没有返回有效的上传链接": "MinerU did not return a valid upload URL",
            "MinerU 结果中没有找到 Markdown 文件": "No Markdown file was found in the MinerU results",
            "没有可写入 EPUB 的文本": "No text available for the EPUB",
            "MinerU 没有解析出可用 Markdown": "MinerU produced no usable Markdown",
            "MinerU 没有解析出可用文本": "MinerU produced no usable text",
            "没有提取到文字": "No text was extracted",
            "输出生成失败": "Output generation failed"
        ]
        if let mapped = exact[trimmed] { return mapped }

        var message = trimmed
        let replacements = [
            ("qpdf 没有生成分段文件", "qpdf produced no split files"),
            ("curl 返回错误", "curl returned an error")
        ]
        for (chinese, english) in replacements {
            message = message.replacingOccurrences(of: chinese, with: english)
        }

        let prefixes = [
            ("PDF 拆分失败：", "PDF split failed: "),
            ("MinerU API 请求失败：", "MinerU API request failed: "),
            ("MinerU API 返回不是 JSON：", "MinerU API returned non-JSON data: "),
            ("MinerU API 返回错误：", "MinerU API returned an error: "),
            ("上传到 MinerU 失败：", "Upload to MinerU failed: "),
            ("MinerU 解析失败：", "MinerU parsing failed: "),
            ("下载 MinerU 结果失败：", "Failed to download MinerU results: "),
            ("解压 MinerU 结果失败：", "Failed to extract MinerU results: "),
            ("OCRmyPDF 返回错误代码 ", "OCRmyPDF returned error code ")
        ]
        for (chinese, english) in prefixes where message.hasPrefix(chinese) {
            return english + message.dropFirst(chinese.count)
        }
        return message
    }

    private func updatePageProgress(from line: String) {
        guard let totalPages, totalPages > 0 else { return }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.split(separator: " ", maxSplits: 1).first,
              let page = Int(first), page > 0, page <= totalPages else { return }
        let value = min(88, max(1, Double(page) / Double(totalPages) * 88))
        setProgress(max(progressBar.progress * 100, value))
        if currentPhase == "OCR" {
            statusLabel.stringValue = L("正在 OCR：第 \(page) / \(totalPages) 页", "OCR: page \(page) / \(totalPages)")
        } else {
            statusLabel.stringValue = L("正在处理：第 \(page) / \(totalPages) 页", "Processing page \(page) / \(totalPages)")
        }
    }

    private func workerFinished(_ worker: Process) {
        if let handle = outputPipe?.fileHandleForReading {
            handle.readabilityHandler = nil
            let remaining = handle.readDataToEndOfFile()
            if !remaining.isEmpty {
                consumeWorkerOutput(String(decoding: remaining, as: UTF8.self))
            }
        }
        flushPartialWorkerLine()
        outputPipe = nil
        process = nil
        childPID = nil

        let shouldAutoStartAI = autoStartAIAfterWorker
        autoStartAIAfterWorker = false
        var conversionSucceeded = false

        if isCancelling {
            cleanupKnownTemporaryFiles()
            setProgress(0)
            statusLabel.stringValue = L("已终止，临时产物已清理", "Stopped — temporary files cleaned up")
            statusLabel.textColor = .systemOrange
            outputLabel.stringValue = L("本次处理未生成产物", "No output was produced")
            updateControls(isRunning: false)
            aiEngine.loadResumeState(for: currentTextURL())
            return
        }

        if worker.terminationStatus == 0, let outputURL, fileManager.fileExists(atPath: outputURL.path) {
            conversionSucceeded = true
            cleanupKnownTemporaryFiles()
            setProgress(100)
            statusLabel.stringValue = L("处理完成", "Done")
            statusLabel.textColor = .systemGreen
            outputLabel.stringValue = L("产物位置：\(outputURL.path)", "Output: \(outputURL.path)")
            if ["txt", "md", "markdown"].contains(outputURL.pathExtension.lowercased()) {
                lastTextURL = outputURL
                selectedURL = outputURL
                dropZone.iconName = "doc.text"
                dropZone.titleText = outputURL.lastPathComponent
                dropZone.subtitleText = L("可直接发送到 AI 排版", "Ready to send to AI layout")
                dropZone.needsDisplay = true
                fileLabel.stringValue = L("当前文本产物：\(outputURL.path)", "Current text output: \(outputURL.path)")
                fileLabel.textColor = .secondaryLabelColor
            }
        } else {
            cleanupKnownTemporaryFiles()
            setProgress(0)
            if let lastWorkerError {
                statusLabel.stringValue = lastWorkerError
                outputLabel.stringValue = L("失败原因：\(lastWorkerError)", "Failure reason: \(lastWorkerError)")
            } else {
                statusLabel.stringValue = L("处理失败，但后台没有返回具体原因", "Processing failed without a specific reason")
                outputLabel.stringValue = L("请查看日志", "See the log for details")
            }
            statusLabel.textColor = .systemRed
        }
        updateControls(isRunning: false)
        aiEngine.loadResumeState(for: currentTextURL())

        if shouldAutoStartAI, conversionSucceeded {
            if let textURL = currentTextURL(),
               ["txt", "md", "markdown"].contains(textURL.pathExtension.lowercased()) {
                appendLog(L("\n=== 转换完成，自动开始 AI 排版 ===\n", "\n=== Conversion finished — starting AI layout ===\n"))
                beginAIReflow(clearLog: false)
            } else {
                showFailure(L("转换完成，但没有生成可交给 AI 排版的文本", "Conversion finished, but no text was produced for AI layout"))
            }
        }
    }

    private func cleanupKnownTemporaryFiles(removePartOnly: Bool = false) {
        if let partURL, fileManager.fileExists(atPath: partURL.path) { try? fileManager.removeItem(at: partURL) }
        if !removePartOnly, let tempURL, fileManager.fileExists(atPath: tempURL.path) { try? fileManager.removeItem(at: tempURL) }
        partURL = nil
        if !removePartOnly { tempURL = nil }
    }

    private func appendLog(_ text: String) {
        logView.string = String((logView.string + text).suffix(30000))
        logView.scrollToEndOfDocument(nil)
    }

    private func showFailure(_ message: String) {
        statusLabel.stringValue = message
        statusLabel.textColor = .systemRed
        appendLog(message + "\n")
    }

    private func discoverLanguages() {
        let tesseract = ["/usr/local/bin/tesseract", "/opt/homebrew/bin/tesseract"].first(where: { fileManager.isExecutableFile(atPath: $0) })
        guard let tesseract else {
            statusLabel.stringValue = L("找不到 Tesseract", "Tesseract was not found")
            return
        }
        let result = runSynchronously(executable: tesseract, arguments: ["--list-langs"])
        let installed = Set(result.output.split(whereSeparator: \.isNewline).map(String.init))
        var options: [LanguageOption] = []
        if installed.contains("chi_sim") {
            options.append(LanguageOption(title: "仅简体中文", titleEN: "Simplified Chinese only", code: "chi_sim"))
        }
        if installed.contains("chi_sim") && installed.contains("eng") {
            options.append(LanguageOption(title: "简体中文 + 英文", titleEN: "Simplified Chinese + English", code: "chi_sim+eng"))
        }
        if installed.contains("chi_tra") {
            options.append(LanguageOption(title: "仅繁体中文", titleEN: "Traditional Chinese only", code: "chi_tra"))
        }
        if installed.contains("chi_tra") && installed.contains("eng") {
            options.append(LanguageOption(title: "繁体中文 + 英文", titleEN: "Traditional Chinese + English", code: "chi_tra+eng"))
        }
        if installed.contains("eng") {
            options.append(LanguageOption(title: "仅英文", titleEN: "English only", code: "eng"))
        }
        languageOptions = options
        let selectedCode = selectedLanguage()?.code
        languagePopup.removeAllItems()
        languagePopup.addItems(withTitles: options.map(\.localizedTitle))
        if let selectedCode,
           let index = options.firstIndex(where: { $0.code == selectedCode }) {
            languagePopup.selectItem(at: index)
        } else if let index = options.firstIndex(where: { $0.code == "chi_sim+eng" }) ?? options.firstIndex(where: { $0.code == "chi_sim" }) {
            languagePopup.selectItem(at: index)
        }
    }

    private func selectedLanguage() -> LanguageOption? {
        guard languagePopup.indexOfSelectedItem >= 0, languagePopup.indexOfSelectedItem < languageOptions.count else { return nil }
        return languageOptions[languagePopup.indexOfSelectedItem]
    }

    private func selectedFormat() -> FormatOption? {
        guard formatPopup.indexOfSelectedItem >= 0, formatPopup.indexOfSelectedItem < formatOptions.count else { return nil }
        return formatOptions[formatPopup.indexOfSelectedItem]
    }

    private func selectedParserCode() -> String {
        parserPopup.indexOfSelectedItem == 0 ? "mineru" : "local"
    }

    private func updateParseSummary() {
        let language = selectedLanguage()?.localizedTitle ?? L("识别语言", "Language")
        let parser = selectedParserCode() == "mineru" ? "MinerU" : L("本地 OCR", "Local OCR")
        let format: String
        switch selectedFormat()?.code {
        case "txt": format = "TXT"
        case "epub": format = "EPUB"
        default: format = "MD"
        }
        parseSummaryLabel.stringValue = "\(language) · \(parser) · \(format)"
    }

    private func refreshModeUI() {
        let parserIsMineru = selectedParserCode() == "mineru"
        updateParseSummary()
        ocrButton.setTitleText(parserIsMineru ? L("本地 OCR 备用", "Local OCR") : L("执行本地 OCR", "Run Local OCR"))
        stepOneDetailLabel?.stringValue = parserIsMineru
            ? L("默认 MinerU 云端解析，OCR 备用", "MinerU cloud parsing by default, local OCR as fallback")
            : L("本地 OCR 会在原文件旁生成可搜索 PDF", "Local OCR creates a searchable PDF next to the original")
        if let ext = selectedURL?.pathExtension.lowercased(), ext == "pdf" {
            dropZone.subtitleText = parserIsMineru
                ? L("默认直接用 MinerU 解析，OCR 只是备用路线", "MinerU parses it directly; local OCR is only a fallback")
                : L("当前切换为本地 OCR 模式", "Local OCR mode is selected")
            dropZone.needsDisplay = true
            fileLabel.stringValue = selectedURL.map { L("已选择：\($0.path)", "Selected: \($0.path)") } ?? fileLabel.stringValue
            if process == nil, statusLabel.stringValue.hasPrefix("PDF 已就绪") || statusLabel.stringValue.hasPrefix("PDF ready") {
                statusLabel.stringValue = parserIsMineru
                    ? L("PDF 已就绪，默认可直接 MinerU 解析", "PDF ready — MinerU parsing is the default")
                    : L("PDF 已就绪，可执行本地 OCR 或直接转换", "PDF ready — run local OCR or convert directly")
                statusLabel.textColor = .labelColor
            }
        }
        subtitleLabel.stringValue = parserIsMineru
            ? L("把扫描版 PDF 变成干净、可编辑的电子书 · MinerU 云端解析", "Turn scanned PDFs into clean, editable ebooks · MinerU cloud parsing")
            : L("把扫描版 PDF 变成干净、可编辑的电子书 · 本地 OCR 模式", "Turn scanned PDFs into clean, editable ebooks · Local OCR mode")
    }

    private func currentTextURL() -> URL? {
        if let selectedURL {
            let ext = selectedURL.pathExtension.lowercased()
            if ["txt", "md", "markdown"].contains(ext) {
                return selectedURL
            }
            if ext == "pdf", let lastTextURL {
                let pdfStem = selectedURL.deletingPathExtension().lastPathComponent
                let textStem = lastTextURL.deletingPathExtension().lastPathComponent
                return textStem.hasPrefix(pdfStem) ? lastTextURL : nil
            }
        }
        return lastTextURL
    }

    private func nextOCROutputURL(for input: URL) -> URL {
        nextAvailableURL(directory: input.deletingLastPathComponent(), stem: input.deletingPathExtension().lastPathComponent, suffix: "_ocr.pdf")
    }

    private func nextParseOutputURL(for input: URL, format: FormatOption) -> URL {
        nextAvailableURL(directory: input.deletingLastPathComponent(), stem: input.deletingPathExtension().lastPathComponent, suffix: format.suffix)
    }

    private func nextAvailableURL(directory: URL, stem: String, suffix: String) -> URL {
        var candidate = directory.appendingPathComponent(stem + suffix)
        let ext = candidate.pathExtension
        let base = candidate.deletingPathExtension().lastPathComponent
        var index = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)_\(index).\(ext)")
            index += 1
        }
        return candidate
    }

    private func runSynchronously(executable: String, arguments: [String]) -> (output: String, status: Int32) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.environment = ["PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return (String(decoding: data, as: UTF8.self), task.terminationStatus)
        } catch {
            return ("", -1)
        }
    }

    private func loadSavedMinerUToken() {
        if let value = UserDefaults.standard.string(forKey: mineruTokenDefaultsKey) {
            mineruTokenField.stringValue = value
        }
    }

    private func saveMinerUToken(_ value: String) {
        UserDefaults.standard.set(value, forKey: mineruTokenDefaultsKey)
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        windowController = MainWindowController()
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        windowController.window?.makeFirstResponder(nil)
    }

    func rebuildMainMenu() {
        installMainMenu()
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: L("关于 \(appTitle)", "About \(appTitle)"),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: L("隐藏 \(appTitle)", "Hide \(appTitle)"),
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        let hideOthersItem = appMenu.addItem(
            withTitle: L("隐藏其他", "Hide Others"),
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(
            withTitle: L("显示全部", "Show All"),
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: L("退出 \(appTitle)", "Quit \(appTitle)"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: L("编辑", "Edit"))
        editMenu.addItem(withTitle: L("撤销", "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: L("重做", "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L("剪切", "Cut"), action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("复制", "Copy"), action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("粘贴", "Paste"), action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("全选", "Select All"), action: Selector(("selectAll:")), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: L("窗口", "Window"))
        windowMenu.addItem(
            withTitle: L("最小化", "Minimize"),
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenu.addItem(
            withTitle: L("关闭", "Close"),
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        windowController?.handleOpenURLs(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        windowController?.shutdownForTermination()
        return .terminateNow
    }
}

private let application = NSApplication.shared
private let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
