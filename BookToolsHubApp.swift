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
    private var aiReflowWindowController: AIReflowWindowController?

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
    private let aiButton = BTButton(title: "打开 AI 排版", symbol: "text.alignleft", style: .accent, height: 30)
    private let cancelButton = BTButton(title: "终止并清理", symbol: "stop.circle", style: .destructive, height: 28)
    private let openOutputButton = BTButton(title: "打开产物目录", symbol: "folder", style: .secondary, height: 28)
    private let logView = NSTextView(frame: .zero)
    private var stepOneDetailLabel: NSTextField?

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
        window.center()
        discoverLanguages()
        loadSavedMinerUToken()
        updateControls(isRunning: false)
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
        if process?.isRunning == true {
            isCancelling = true
            if let childPID { kill(childPID, SIGTERM) }
            process?.terminate()
        }
    }

    @objc private func chooseFile() {
        guard process == nil else { return }
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

    @objc private func sendToAIReflow() {
        let target = currentTextURL()
        if let aiReflowWindowController {
            if let target {
                aiReflowWindowController.loadInput(target)
            } else {
                aiReflowWindowController.showWindow(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        } else {
            aiReflowWindowController = AIReflowWindowController(initialInput: target)
            aiReflowWindowController?.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        if let target {
            statusLabel.stringValue = "已打开 AI 排版窗口：\(target.lastPathComponent)"
        } else {
            statusLabel.stringValue = "已打开 AI 排版窗口，请选择 MD / TXT 文件"
        }
        statusLabel.textColor = .labelColor
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
        guard let targetURL = outputURL ?? lastTextURL ?? selectedURL else { return }
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

        let mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 10
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            mainStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            mainStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            mainStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18)
        ])

        addFullWidth(makeHeader(), to: mainStack, spacingAfter: 4)
        addFullWidth(makeDropCard(), to: mainStack)
        addFullWidth(makeSettingsCard(), to: mainStack)
        addFullWidth(makeStepsCard(), to: mainStack)
        addFullWidth(makeStatusStack(), to: mainStack, spacingAfter: 2)

        let logCard = makeLogCard()
        logCard.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        addFullWidth(logCard, to: mainStack)

        addFullWidth(makeBottomBar(), to: mainStack, spacingAfter: 0)
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

        NSLayoutConstraint.activate([
            headerIconView.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headerIconView.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            headerIconView.widthAnchor.constraint(equalToConstant: 38),
            headerIconView.heightAnchor.constraint(equalToConstant: 38),

            titleLabel.leadingAnchor.constraint(equalTo: headerIconView.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: header.topAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor),

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
        fileLabel.translatesAutoresizingMaskIntoConstraints = false
        chooseButton.translatesAutoresizingMaskIntoConstraints = false
        chooseRow.addSubview(fileLabel)
        chooseRow.addSubview(chooseButton)

        NSLayoutConstraint.activate([
            fileLabel.leadingAnchor.constraint(equalTo: chooseRow.leadingAnchor, constant: 4),
            fileLabel.centerYAnchor.constraint(equalTo: chooseRow.centerYAnchor),
            fileLabel.trailingAnchor.constraint(lessThanOrEqualTo: chooseButton.leadingAnchor, constant: -10),

            chooseButton.trailingAnchor.constraint(equalTo: chooseRow.trailingAnchor, constant: -2),
            chooseButton.centerYAnchor.constraint(equalTo: chooseRow.centerYAnchor),
            chooseButton.widthAnchor.constraint(equalToConstant: 104),

            chooseRow.heightAnchor.constraint(equalToConstant: 30)
        ])
        chooseButton.target = self
        chooseButton.action = #selector(chooseFile)

        card.stack.addArrangedSubview(dropZone)
        card.stack.addArrangedSubview(chooseRow)
        dropZone.widthAnchor.constraint(equalTo: card.stack.widthAnchor).isActive = true
        chooseRow.widthAnchor.constraint(equalTo: card.stack.widthAnchor).isActive = true
        card.stack.spacing = 6
        return card
    }

    private func makeSettingsCard() -> NSView {
        let card = BTCardView(insets: NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16))

        let header = BTUI.sectionHeader(title: "解析设置", symbol: "slider.horizontal.3")
        card.stack.addArrangedSubview(header)

        let languageLabel = BTUI.formLabel("识别语言")
        let parserLabel = BTUI.formLabel("PDF 解析")
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

        card.stack.addArrangedSubview(rowOne)
        card.stack.addArrangedSubview(rowTwo)
        rowOne.widthAnchor.constraint(equalTo: card.stack.widthAnchor).isActive = true
        rowTwo.widthAnchor.constraint(equalTo: card.stack.widthAnchor).isActive = true
        card.stack.spacing = 8
        return card
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
        let stepTwo = makeStepRow(
            number: 2,
            title: "转换为 MD / TXT / EPUB",
            subtitle: "自动完成解析并提取文字，输出所选格式",
            button: parseButton
        )
        let stepThree = makeStepRow(
            number: 3,
            title: "交给 AI 排版",
            subtitle: "进一步整理章节与段落",
            button: aiButton
        )

        for view in [stepOne, BTUI.separator(), stepTwo, BTUI.separator(), stepThree] {
            view.translatesAutoresizingMaskIntoConstraints = false
            card.stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: card.stack.widthAnchor).isActive = true
        }
        card.stack.spacing = 4
        return card
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
        aiButton.action = #selector(sendToAIReflow)

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
        guard process == nil else { return }
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
    }

    private func updateControls(isRunning: Bool) {
        let ext = selectedURL?.pathExtension.lowercased() ?? ""
        let isPDF = ext == "pdf"
        let parserIsLocal = selectedParserCode() == "local"
        chooseButton.isEnabled = !isRunning
        dropZone.isInteractionEnabled = !isRunning
        languagePopup.isEnabled = !isRunning
        parserPopup.isEnabled = !isRunning
        formatPopup.isEnabled = !isRunning
        mineruTokenField.isEnabled = !isRunning
        ocrButton.isEnabled = !isRunning && isPDF && !languageOptions.isEmpty && parserIsLocal
        parseButton.isEnabled = !isRunning && isPDF && !languageOptions.isEmpty
        aiButton.isEnabled = !isRunning
        cancelButton.isEnabled = isRunning
        openOutputButton.isEnabled = !isRunning && (outputURL != nil || lastTextURL != nil || selectedURL != nil)
        refreshModeUI()
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

        if isCancelling {
            cleanupKnownTemporaryFiles()
            setProgress(0)
            statusLabel.stringValue = "已终止，临时产物已清理"
            statusLabel.textColor = .systemOrange
            outputLabel.stringValue = "本次处理未生成产物"
            updateControls(isRunning: false)
            return
        }

        if worker.terminationStatus == 0, let outputURL, fileManager.fileExists(atPath: outputURL.path) {
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

    private func refreshModeUI() {
        let parserIsMineru = selectedParserCode() == "mineru"
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
        if let selectedURL, ["txt", "md", "markdown"].contains(selectedURL.pathExtension.lowercased()) {
            return selectedURL
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
