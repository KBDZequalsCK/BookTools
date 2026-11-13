import AppKit
import Foundation
import Darwin

private let appTitle = "PDF Book Tools"
private let mineruTokenDefaultsKey = "mineruToken"

private struct LanguageOption {
    let title: String
    let code: String
}

private struct FormatOption {
    let title: String
    let code: String
    let suffix: String
}

private enum AppearanceMode: String, CaseIterable {
    case system
    case light
    case dark

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
}

private let formatOptions = [
    FormatOption(title: "MD（推荐，便于 AI 排版）", code: "md", suffix: "_reflow.md"),
    FormatOption(title: "TXT（纯文字）", code: "txt", suffix: "_ocr.txt"),
    FormatOption(title: "EPUB（可调字体）", code: "epub", suffix: "_reflow.epub")
]

private let parserOptions = [
    "MinerU 精准解析 API（推荐）",
    "本地 OCRmyPDF / Tesseract（备用）"
]

private final class MainWindowController: NSWindowController, NSWindowDelegate, FileDropZoneDelegate {
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
    private let parseSettingsToggle = BTButton(title: "解析设置", symbol: "chevron.right", style: .ghost, height: 22)
    private let parseSummaryLabel = BTUI.label("识别语言、解析方式与输出格式", size: 11, color: .tertiaryLabelColor)
    private let appearancePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let appearanceDefaultsKey = "appearanceMode"

    private let headerIconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: appTitle)
    private let subtitleLabel = BTUI.label(
        "把扫描版 PDF 变成干净、可编辑的电子书",
        size: 12,
        color: .secondaryLabelColor
    )
    private let dropZone = FileDropZoneView(
        acceptedExtensions: ["pdf", "txt", "md", "markdown"],
        title: "把 PDF / TXT / MD 文件拖到这里",
        subtitle: "也可以双击此区域选择文件"
    )
    private let fileLabel = BTUI.label("尚未选择文件", size: 11, color: .tertiaryLabelColor)
    private let statusLabel = BTUI.label("请选择 PDF、TXT 或 MD，开始三步处理", size: 13, weight: .medium)
    private let progressLabel = BTUI.label("", size: 11, color: .secondaryLabelColor, alignment: .right)
    private let outputLabel = BTUI.label("完成后会显示产物位置", size: 11, color: .secondaryLabelColor)
    private let progressBar = BTProgressBar()
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let parserPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let mineruTokenField = NSSecureTextField(string: "")
    private let chooseButton = BTButton(title: "选择文件", symbol: "folder", style: .ghost, height: 28)
    private let ocrButton = BTButton(title: "本地 OCR 备用", symbol: "text.viewfinder", style: .secondary, height: 30)
    private let parseButton = BTButton(title: "开始转换", symbol: "wand.and.stars", style: .primary, height: 30)
    private let aiButton = BTButton(title: "开始 AI 排版", symbol: "wand.and.stars", style: .accent, height: 30)
    private let oneClickButton = BTButton(title: "一键处理", symbol: "bolt.fill", style: .primary, height: 30)
    private let cancelButton = BTButton(title: "终止并清理", symbol: "stop.circle", style: .destructive, height: 28)
    private let openOutputButton = BTButton(title: "打开产物目录", symbol: "folder", style: .secondary, height: 28)
    private let aiInputLabel = BTUI.label("暂无文本：完成第 2 步后自动可用", size: 11, color: .tertiaryLabelColor)
    private let aiSettingsToggle = BTButton(title: "AI 排版接口设置", symbol: "chevron.right", style: .ghost, height: 22)
    private let aiSettingsStack = NSStackView()
    private let aiAPIURLField = NSTextField(string: "")
    private let aiModelField = NSTextField(string: "")
    private let aiAPIKeyField = NSSecureTextField(string: "")
    private let aiChunkSizeField = NSTextField(string: "")
    private let aiFormatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let aiResumeRow = NSView()
    private let aiResumeLabel = BTUI.label("", size: 11, color: .systemOrange)
    private let aiResumeButton = BTButton(title: "继续未完成", symbol: "play.circle", style: .secondary, height: 24)
    private let aiSkipButton = BTButton(title: "跳过当前块", symbol: "forward.end", style: .ghost, height: 24)
    private let aiCleanupButton = BTButton(title: "清理断点", symbol: "trash", style: .ghost, height: 24)
    private let aiCancelButton = BTButton(title: "终止 AI 排版", symbol: "stop.circle", style: .destructive, height: 24)
    private let logView = NSTextView(frame: .zero)
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
        panel.title = "选择 PDF、TXT 或 MD"
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
            showFailure("没有可用的 OCR 语言")
            return
        }
        let output = nextOCROutputURL(for: input)
        outputURL = output
        runWorker(
            scriptName: "ocr_worker.command",
            arguments: [input.path, language.code, output.path],
            initialStatus: "正在 OCR PDF..."
        )
    }

    @objc private func runPDFParse() {
        guard let input = selectedURL, input.pathExtension.lowercased() == "pdf", process == nil else { return }
        guard let language = selectedLanguage(), let format = selectedFormat() else {
            showFailure("请选择识别语言和输出格式")
            return
        }
        let parser = selectedParserCode()
        var environment: [String: String] = [:]
        if parser == "mineru" {
            let token = mineruTokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                showFailure("请填写 MinerU Token")
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
                ? "正在用 MinerU 直接解析 PDF..."
                : "正在检查 PDF 是否已有文字层..."
        )
    }

    @objc private func startAIReflow() {
        beginAIReflow(clearLog: true)
    }

    private func beginAIReflow(clearLog: Bool) {
        guard process == nil, !aiEngine.isRunning else {
            showFailure("当前还有任务在运行，请先等待完成或终止")
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
            showFailure("没有可排版的文本：请先完成第 2 步，或选择 TXT / MD 文件")
            return
        }
        if aiEngine.apiURLString.isEmpty || aiEngine.apiKeyString.isEmpty {
            setAISettingsExpanded(true)
            showFailure("第一次使用请先在「AI 排版接口设置」里填写 API 地址和 API Key")
            window?.makeFirstResponder(aiEngine.apiURLString.isEmpty ? aiAPIURLField : aiAPIKeyField)
            return
        }
        if clearLog {
            logView.string = "AI 排版日志：\n"
        }
        outputURL = nil
        if let error = aiEngine.start(input: input) {
            showFailure(error)
        }
    }

    @objc private func runOneClick() {
        guard process == nil, !aiEngine.isRunning else {
            showFailure("当前还有任务在运行，请先等待完成或终止")
            return
        }
        guard let selected = selectedURL else {
            showFailure("请先选择 PDF、TXT 或 MD 文件")
            return
        }
        let ext = selected.pathExtension.lowercased()
        if ["txt", "md", "markdown"].contains(ext) {
            beginAIReflow(clearLog: true)
            return
        }
        guard ext == "pdf" else {
            showFailure("一键处理只支持 PDF、TXT 或 MD")
            return
        }
        guard selectedLanguage() != nil else {
            showFailure("没有可用的 OCR 语言")
            return
        }
        // 先检查 AI 接口，避免解析转换完成后才发现没有配置
        syncAISettingsToEngine()
        if aiEngine.apiURLString.isEmpty || aiEngine.apiKeyString.isEmpty {
            setAISettingsExpanded(true)
            showFailure("一键处理需要先填写 AI 排版接口（API 地址和 API Key）")
            window?.makeFirstResponder(aiEngine.apiURLString.isEmpty ? aiAPIURLField : aiAPIKeyField)
            return
        }
        // EPUB 不含可直接排版文本，一键处理改用 MD
        if selectedFormat()?.code == "epub" {
            formatPopup.selectItem(at: 0)
            refreshModeUI()
            appendLog("一键处理改用 MD 输出，便于紧接着进行 AI 排版。\n")
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
        logView.string = "AI 排版日志：\n"
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
        statusLabel.stringValue = "正在终止并清理..."
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
        appearancePopup.toolTip = "外观：跟随系统、浅色或深色"
        header.addSubview(appearancePopup)

        NSLayoutConstraint.activate([
            headerIconView.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headerIconView.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            headerIconView.widthAnchor.constraint(equalToConstant: 38),
            headerIconView.heightAnchor.constraint(equalToConstant: 38),

            appearancePopup.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -2),
            appearancePopup.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            appearancePopup.widthAnchor.constraint(equalToConstant: 104),
            appearancePopup.heightAnchor.constraint(equalToConstant: 26),

            titleLabel.leadingAnchor.constraint(equalTo: headerIconView.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: header.topAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: appearancePopup.leadingAnchor, constant: -12),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: appearancePopup.leadingAnchor, constant: -12),

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
            chooseButton.widthAnchor.constraint(equalToConstant: 104),

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
            parseSettingsToggle.widthAnchor.constraint(equalToConstant: 116)
        ])

        let languageLabel = BTUI.formLabel("识别语言")
        let parserLabel = BTUI.formLabel("解析方式")
        let formatLabel = BTUI.formLabel("输出格式")
        let tokenLabel = BTUI.formLabel("MinerU Token")

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

        parserPopup.addItems(withTitles: parserOptions)
        parserPopup.selectItem(at: 0)
        parserPopup.target = self
        parserPopup.action = #selector(parserSelectionChanged)

        formatPopup.addItems(withTitles: formatOptions.map(\.title))
        formatPopup.selectItem(at: 0)
        formatPopup.target = self
        formatPopup.action = #selector(parserSelectionChanged)

        languagePopup.target = self
        languagePopup.action = #selector(parserSelectionChanged)

        mineruTokenField.placeholderString = "填写一次即可，自动记住"
        mineruTokenField.isBezeled = true
        mineruTokenField.bezelStyle = .roundedBezel

        for label in [languageLabel, parserLabel, formatLabel, tokenLabel] {
            label.widthAnchor.constraint(equalToConstant: 86).isActive = true
        }

        let rowOne = NSStackView(views: [languageLabel, languagePopup, parserLabel, parserPopup])
        rowOne.orientation = .horizontal
        rowOne.alignment = .centerY
        rowOne.spacing = 10

        let rowTwo = NSStackView(views: [formatLabel, formatPopup, tokenLabel, mineruTokenField])
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

        let header = BTUI.sectionHeader(title: "三步流程", symbol: "list.number")
        card.stack.addArrangedSubview(header)

        let stepOne = makeStepRow(
            number: 1,
            title: "PDF 解析",
            subtitle: "默认 MinerU 云端解析，OCR 备用",
            button: ocrButton,
            detailAssign: { [weak self] label in self?.stepOneDetailLabel = label }
        )
        let parseSection = makeParseSection()
        let stepTwo = makeStepRow(
            number: 2,
            title: "转换为 MD / TXT / EPUB",
            subtitle: "自动完成解析并提取文字，输出所选格式",
            button: parseButton
        )
        let stepThree = makeStepRow(
            number: 3,
            title: "交给 AI 排版",
            subtitle: "自动使用第 2 步的文本，无需重新选择文件",
            button: aiButton,
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

        for field in [aiAPIURLField, aiModelField, aiAPIKeyField, aiChunkSizeField] {
            field.font = NSFont.systemFont(ofSize: 12)
            field.isBezeled = true
            field.bezelStyle = .roundedBezel
            field.heightAnchor.constraint(equalToConstant: 24).isActive = true
            field.cell?.usesSingleLineMode = true
        }
        aiAPIURLField.placeholderString = "https://api.openai.com/v1/chat/completions"
        aiModelField.placeholderString = "gpt-4o-mini"
        aiAPIKeyField.placeholderString = "sk-… 只保存在本机偏好设置里"
        aiChunkSizeField.placeholderString = "8000"
        aiFormatPopup.controlSize = .regular
        aiFormatPopup.addItems(withTitles: aiFormatOptions.map(\.title))

        let urlLabel = BTUI.formLabel("API 地址")
        let modelLabel = BTUI.formLabel("模型")
        let keyLabel = BTUI.formLabel("API Key")
        let chunkLabel = BTUI.formLabel("分块字符数")
        let formatLabel = BTUI.formLabel("AI 输出格式")
        for label in [urlLabel, modelLabel, keyLabel, chunkLabel, formatLabel] {
            label.widthAnchor.constraint(equalToConstant: 86).isActive = true
        }

        let urlRow = makeAIFormRow([urlLabel, aiAPIURLField])
        let keyRow = makeAIFormRow([modelLabel, aiModelField, keyLabel, aiAPIKeyField])
        aiModelField.widthAnchor.constraint(equalToConstant: 170).isActive = true
        keyLabel.widthAnchor.constraint(equalToConstant: 76).isActive = true

        let rowSpacer = NSView()
        rowSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let formatRow = makeAIFormRow([chunkLabel, aiChunkSizeField, formatLabel, aiFormatPopup, rowSpacer])
        aiChunkSizeField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        aiFormatPopup.widthAnchor.constraint(equalToConstant: 210).isActive = true
        aiFormatPopup.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        aiAPIURLField.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        aiAPIKeyField.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        for row in [urlRow, keyRow, formatRow] {
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
        aiSkipButton.widthAnchor.constraint(equalToConstant: 104).isActive = true
        aiCleanupButton.widthAnchor.constraint(equalToConstant: 92).isActive = true
        aiCancelButton.widthAnchor.constraint(equalToConstant: 108).isActive = true

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

    private func makeStepRow(number: Int, title: String, subtitle: String, button: BTButton, detailAssign: ((NSTextField) -> Void)? = nil) -> NSView {
        let row = NSView()

        let badge = BTNumberBadge(number: number)
        row.addSubview(badge)

        let titleLabel = BTUI.label(title, size: 13, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(titleLabel)

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
        let header = BTUI.sectionHeader(title: "运行日志", symbol: "terminal")
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
        logView.string = "日志会显示在这里。\n"
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
            cancelButton.widthAnchor.constraint(equalToConstant: 118),

            openOutputButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -2),
            openOutputButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            openOutputButton.widthAnchor.constraint(equalToConstant: 128)
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
            showFailure("请选择 PDF、TXT 或 MD 文件")
            return
        }
        selectedURL = url.standardizedFileURL
        if ext == "txt" || ext == "md" || ext == "markdown" {
            lastTextURL = url.standardizedFileURL
        }
        outputURL = nil
        dropZone.iconName = ext == "pdf" ? "doc.richtext" : "doc.text"
        dropZone.titleText = url.lastPathComponent
        dropZone.subtitleText = ext == "pdf" ? "默认直接用 MinerU 解析，OCR 是备用路线" : "可直接发送到 AI 排版"
        dropZone.needsDisplay = true
        fileLabel.stringValue = "已选择：\(url.path)"
        fileLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = ext == "pdf" ? "PDF 已就绪，默认可直接 MinerU 解析" : "文本文件已就绪，可以发送到 AI 排版"
        statusLabel.textColor = .labelColor
        outputLabel.stringValue = "完成后会显示产物位置"
        logView.string = "日志会显示在这里。\n"
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
            oneClickButton.setTitleText("AI 排版中…")
            oneClickButton.setSymbol("hourglass")
        } else if busy {
            oneClickButton.setTitleText("一键处理中…")
            oneClickButton.setSymbol("hourglass")
        } else if isPDF {
            oneClickButton.setTitleText("一键处理")
            oneClickButton.setSymbol("bolt.fill")
        } else if isText {
            oneClickButton.setTitleText("一键 AI 排版")
            oneClickButton.setSymbol("bolt.fill")
        } else {
            oneClickButton.setTitleText("一键处理")
            oneClickButton.setSymbol("bolt.fill")
        }

        oneClickButton.isEnabled = !busy && (isPDF ? !languageOptions.isEmpty : isText)
        oneClickButton.toolTip = isText
            ? "直接对当前文本开始 AI 排版"
            : "自动完成 PDF 解析、文本转换，然后开始 AI 排版"
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
        aiChunkSizeField.stringValue = String(aiEngine.chunkSize)
        if let index = aiFormatOptions.firstIndex(where: { $0.code == aiEngine.formatCode }) {
            aiFormatPopup.selectItem(at: index)
        }
    }

    private func syncAISettingsToEngine() {
        aiEngine.apiURLString = aiAPIURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        aiEngine.modelString = aiModelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        aiEngine.apiKeyString = aiAPIKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let size = Int(aiChunkSizeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
            aiEngine.chunkSize = size
        }
        let index = aiFormatPopup.indexOfSelectedItem
        if index >= 0, index < aiFormatOptions.count {
            aiEngine.formatCode = aiFormatOptions[index].code
        }
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
            aiInputLabel.stringValue = "自动使用：\(input.lastPathComponent)"
            aiInputLabel.textColor = .secondaryLabelColor
            aiInputLabel.toolTip = input.path
        } else {
            aiInputLabel.stringValue = "暂无文本：完成第 2 步后自动可用"
            aiInputLabel.textColor = .tertiaryLabelColor
            aiInputLabel.toolTip = nil
        }

        aiButton.isEnabled = !pdfBusy && !aiRunning && (input != nil || aiEngine.resumeAvailable)
        if aiRunning {
            aiButton.setTitleText("AI 排版中…")
            aiButton.setSymbol("hourglass")
        } else if aiEngine.resumeAvailable {
            aiButton.setTitleText("继续 AI 排版")
            aiButton.setSymbol("play.circle")
        } else {
            aiButton.setTitleText("开始 AI 排版")
            aiButton.setSymbol("wand.and.stars")
        }

        if aiRunning {
            stepThreeDetailLabel?.stringValue = "正在整理：\(progressLabel.stringValue)，日志和断点会实时更新"
        } else if aiEngine.resumeAvailable {
            stepThreeDetailLabel?.stringValue = "检测到未完成：已完成 \(aiEngine.resumeCompletedChunks) / \(aiEngine.resumeTotalChunks) 块"
        } else if input != nil {
            stepThreeDetailLabel?.stringValue = "自动使用第 2 步的文本，无需重新选择文件"
        } else {
            stepThreeDetailLabel?.stringValue = "完成第 2 步后，可直接开始 AI 排版"
        }

        if aiRunning {
            aiResumeRow.isHidden = false
            aiResumeLabel.stringValue = "AI 正在排版，终止会清理未完成产物"
            aiResumeLabel.textColor = .systemOrange
            aiResumeButton.isHidden = true
            aiSkipButton.isHidden = true
            aiCleanupButton.isHidden = true
            aiCancelButton.isHidden = false
        } else if aiEngine.resumeAvailable {
            aiResumeRow.isHidden = false
            let format = aiEngine.resumeFormatCode?.uppercased() ?? "TXT"
            aiResumeLabel.stringValue = "未完成：\(format)，已完成 \(aiEngine.resumeCompletedChunks) / \(aiEngine.resumeTotalChunks) 块"
            aiResumeLabel.textColor = .systemOrange
            aiResumeButton.isHidden = false
            aiSkipButton.isHidden = false
            aiCleanupButton.isHidden = false
            aiCancelButton.isHidden = true
        } else {
            aiResumeRow.isHidden = true
        }

        updateAISettingsToggle()
        for field in [aiAPIURLField, aiModelField, aiAPIKeyField, aiChunkSizeField] {
            field.isEnabled = !pdfBusy && !aiRunning
        }
        aiFormatPopup.isEnabled = !pdfBusy && !aiRunning
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
        if let index = AppearanceMode.allCases.firstIndex(where: { $0.rawValue == mode.rawValue }) {
            appearancePopup.selectItem(at: index)
        }
        if persist {
            UserDefaults.standard.set(mode.rawValue, forKey: appearanceDefaultsKey)
        }
    }

    @objc private func appearanceSelectionChanged() {
        let index = appearancePopup.indexOfSelectedItem
        guard index >= 0, index < AppearanceMode.allCases.count else { return }
        applyAppearance(AppearanceMode.allCases[index], persist: true)
    }

    private func updateParseSettingsToggle() {
        parseSettingsToggle.setTitleText(parseSettingsExpanded ? "收起设置" : "解析设置")
        parseSettingsToggle.setSymbol(parseSettingsExpanded ? "chevron.up" : "chevron.right")
    }

    private func updateAISettingsToggle() {
        aiSettingsToggle.setTitleText(aiSettingsExpanded ? "收起接口设置" : "AI 排版接口设置")
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
            showFailure("找不到内置处理脚本")
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
        outputLabel.stringValue = "完成后会显示产物位置"
        logView.string = "日志开始...\n"
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
            showFailure("无法启动处理程序：\(error.localizedDescription)")
        }
    }

    private func consumeWorkerOutput(_ text: String) {
        appendLog(text)
        let combined = partialWorkerLine + text
        let lines = combined.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        partialWorkerLine = combined.hasSuffix("\n") ? "" : (lines.last ?? "")
        let completeLines = lines.dropLast()
        for line in completeLines {
            if line.hasPrefix("PHASE=") {
                currentPhase = String(line.dropFirst(6))
            } else if line.hasPrefix("STATUS=") {
                if lastWorkerError == nil { statusLabel.stringValue = String(line.dropFirst(7)) }
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
                let message = String(line.dropFirst(6))
                lastWorkerError = message
                statusLabel.stringValue = message
                statusLabel.textColor = .systemRed
                outputLabel.stringValue = "失败原因：\(message)"
            } else {
                updatePageProgress(from: line)
            }
        }
    }

    private func updatePageProgress(from line: String) {
        guard let totalPages, totalPages > 0 else { return }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.split(separator: " ", maxSplits: 1).first,
              let page = Int(first), page > 0, page <= totalPages else { return }
        let value = min(88, max(1, Double(page) / Double(totalPages) * 88))
        setProgress(max(progressBar.progress * 100, value))
        if currentPhase == "OCR" {
            statusLabel.stringValue = "正在 OCR：第 \(page) / \(totalPages) 页"
        } else {
            statusLabel.stringValue = "正在处理：第 \(page) / \(totalPages) 页"
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
        outputPipe = nil
        process = nil
        childPID = nil

        let shouldAutoStartAI = autoStartAIAfterWorker
        autoStartAIAfterWorker = false
        var conversionSucceeded = false

        if isCancelling {
            cleanupKnownTemporaryFiles()
            setProgress(0)
            statusLabel.stringValue = "已终止，临时产物已清理"
            statusLabel.textColor = .systemOrange
            outputLabel.stringValue = "本次处理未生成产物"
            updateControls(isRunning: false)
            aiEngine.loadResumeState(for: currentTextURL())
            return
        }

        if worker.terminationStatus == 0, let outputURL, fileManager.fileExists(atPath: outputURL.path) {
            conversionSucceeded = true
            cleanupKnownTemporaryFiles()
            setProgress(100)
            statusLabel.stringValue = "处理完成"
            statusLabel.textColor = .systemGreen
            outputLabel.stringValue = "产物位置：\(outputURL.path)"
            if ["txt", "md", "markdown"].contains(outputURL.pathExtension.lowercased()) {
                lastTextURL = outputURL
                selectedURL = outputURL
                dropZone.iconName = "doc.text"
                dropZone.titleText = outputURL.lastPathComponent
                dropZone.subtitleText = "可直接发送到 AI 排版"
                dropZone.needsDisplay = true
                fileLabel.stringValue = "当前文本产物：\(outputURL.path)"
                fileLabel.textColor = .secondaryLabelColor
            }
        } else {
            cleanupKnownTemporaryFiles()
            setProgress(0)
            if let lastWorkerError {
                statusLabel.stringValue = lastWorkerError
                outputLabel.stringValue = "失败原因：\(lastWorkerError)"
            } else {
                statusLabel.stringValue = "处理失败，但后台没有返回具体原因"
                outputLabel.stringValue = "请查看日志"
            }
            statusLabel.textColor = .systemRed
        }
        updateControls(isRunning: false)
        aiEngine.loadResumeState(for: currentTextURL())

        if shouldAutoStartAI, conversionSucceeded {
            if let textURL = currentTextURL(),
               ["txt", "md", "markdown"].contains(textURL.pathExtension.lowercased()) {
                appendLog("\n=== 转换完成，自动开始 AI 排版 ===\n")
                beginAIReflow(clearLog: false)
            } else {
                showFailure("转换完成，但没有生成可交给 AI 排版的文本")
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
            statusLabel.stringValue = "找不到 Tesseract"
            return
        }
        let result = runSynchronously(executable: tesseract, arguments: ["--list-langs"])
        let installed = Set(result.output.split(whereSeparator: \.isNewline).map(String.init))
        var options: [LanguageOption] = []
        if installed.contains("chi_sim") { options.append(LanguageOption(title: "仅简体中文", code: "chi_sim")) }
        if installed.contains("chi_sim") && installed.contains("eng") { options.append(LanguageOption(title: "简体中文 + 英文", code: "chi_sim+eng")) }
        if installed.contains("chi_tra") { options.append(LanguageOption(title: "仅繁体中文", code: "chi_tra")) }
        if installed.contains("chi_tra") && installed.contains("eng") { options.append(LanguageOption(title: "繁体中文 + 英文", code: "chi_tra+eng")) }
        if installed.contains("eng") { options.append(LanguageOption(title: "仅英文", code: "eng")) }
        languageOptions = options
        languagePopup.removeAllItems()
        languagePopup.addItems(withTitles: options.map(\.title))
        if let index = options.firstIndex(where: { $0.code == "chi_sim+eng" }) ?? options.firstIndex(where: { $0.code == "chi_sim" }) {
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
        let language = selectedLanguage()?.title ?? "识别语言"
        let parser = selectedParserCode() == "mineru" ? "MinerU" : "本地 OCR"
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
        ocrButton.setTitleText(parserIsMineru ? "本地 OCR 备用" : "执行本地 OCR")
        stepOneDetailLabel?.stringValue = parserIsMineru
            ? "默认 MinerU 云端解析，OCR 备用"
            : "本地 OCR 会在原文件旁生成可搜索 PDF"
        if let ext = selectedURL?.pathExtension.lowercased(), ext == "pdf" {
            dropZone.subtitleText = parserIsMineru
                ? "默认直接用 MinerU 解析，OCR 只是备用路线"
                : "当前切换为本地 OCR 模式"
            dropZone.needsDisplay = true
            fileLabel.stringValue = selectedURL.map { "已选择：\($0.path)" } ?? fileLabel.stringValue
            if process == nil, statusLabel.stringValue.hasPrefix("PDF 已就绪") {
                statusLabel.stringValue = parserIsMineru
                    ? "PDF 已就绪，默认可直接 MinerU 解析"
                    : "PDF 已就绪，可执行本地 OCR 或直接转换"
                statusLabel.textColor = .labelColor
            }
        }
        subtitleLabel.stringValue = parserIsMineru
            ? "把扫描版 PDF 变成干净、可编辑的电子书 · MinerU 云端解析"
            : "把扫描版 PDF 变成干净、可编辑的电子书 · 本地 OCR 模式"
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
        windowController = MainWindowController()
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        windowController.window?.makeFirstResponder(nil)
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
