import AppKit
import Foundation
import Darwin

private struct LanguageOption {
    let title: String
    let code: String
}

private struct ParserOption {
    let title: String
    let code: String
}

private struct FormatOption {
    let title: String
    let code: String
    let suffix: String
}

#if OCR_APP
private let appTitle = "OCR PDF"
#else
private let appTitle = "PDF to TXT/EPUB/MD"
#endif

private let mineruTokenDefaultsKey = "mineruToken"

private let parserOptions = [
    ParserOption(title: "本地 OCRmyPDF / Tesseract", code: "local"),
    ParserOption(title: "MinerU 精准解析 API", code: "mineru")
]

private let formatOptions = [
    FormatOption(title: "TXT（纯文字）", code: "txt", suffix: "_ocr.txt"),
    FormatOption(title: "EPUB（可调字体）", code: "epub", suffix: "_reflow.epub"),
    FormatOption(title: "MD（Markdown）", code: "md", suffix: "_reflow.md")
]

private protocol FileDropDelegate: AnyObject {
    func fileDropView(_ view: FileDropView, received url: URL)
    func fileDropViewWasDoubleClicked(_ view: FileDropView)
}

private protocol RootViewDelegate: AnyObject {
    func rootViewWasDoubleClicked(_ view: RootView)
}

private final class RootView: NSView {
    weak var delegate: RootViewDelegate?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            delegate?.rootViewWasDoubleClicked(self)
        }
        super.mouseDown(with: event)
    }
}

private final class FileDropView: NSView {
    weak var delegate: FileDropDelegate?
    var titleText = "把 PDF 拖到这里"
    var subtitleText = "也可以双击此区域选择文件"
    var isHighlighted = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 2, dy: 2)
        let path = NSBezierPath(roundedRect: box, xRadius: 14, yRadius: 14)
        (isHighlighted ? NSColor.controlAccentColor.withAlphaComponent(0.18) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (isHighlighted ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isHighlighted ? 2.5 : 1.2
        path.stroke()

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        let subtitleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let titleSize = titleText.size(withAttributes: titleAttributes)
        let subtitleSize = subtitleText.size(withAttributes: subtitleAttributes)
        titleText.draw(at: NSPoint(x: box.midX - titleSize.width / 2, y: box.midY + 8), withAttributes: titleAttributes)
        subtitleText.draw(at: NSPoint(x: box.midX - subtitleSize.width / 2, y: box.midY - 22), withAttributes: subtitleAttributes)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard firstPDFURL(from: sender.draggingPasteboard) != nil else { return [] }
        isHighlighted = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isHighlighted = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isHighlighted = false
        guard let url = firstPDFURL(from: sender.draggingPasteboard) else { return false }
        delegate?.fileDropView(self, received: url)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            delegate?.fileDropViewWasDoubleClicked(self)
        }
        super.mouseDown(with: event)
    }

    private func firstPDFURL(from pasteboard: NSPasteboard) -> URL? {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else { return nil }
        return urls.first(where: { $0.pathExtension.lowercased() == "pdf" })
    }
}

private final class MainWindowController: NSWindowController, NSWindowDelegate, RootViewDelegate, FileDropDelegate {
    private let fileManager = FileManager.default
    private var inputURL: URL?
    private var outputURL: URL?
    private var tempURL: URL?
    private var partURL: URL?
    private var process: Process?
    private var outputPipe: Pipe?
    private var progressTimer: Timer?
    private var startDate: Date?
    private var isCancelling = false
    private var childPID: pid_t?
    private var totalPages: Int?
    private var currentPhase = ""
    private var partialWorkerLine = ""
    private var lastWorkerError: String?
    private var languageOptions: [LanguageOption] = []

    private let titleLabel = NSTextField(labelWithString: appTitle)
    private let fileLabel = NSTextField(labelWithString: "尚未选择 PDF")
    private let outputLabel = NSTextField(labelWithString: "完成后会显示保存位置")
    private let statusLabel = NSTextField(labelWithString: "请选择一个 PDF 开始")
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let parserPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let mineruTokenField = NSSecureTextField(string: "")
    private let progressIndicator = NSProgressIndicator(frame: .zero)
    private let startButton = NSButton(frame: .zero)
    private let cancelButton = NSButton(frame: .zero)
    private let openOutputButton = NSButton(frame: .zero)
    private let logView = NSTextView(frame: .zero)
    private let dropView = FileDropView(frame: .zero)
    private var rootView: RootView!

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = appTitle
        window.minSize = NSSize(width: 680, height: 620)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildInterface()
        discoverLanguages()
        loadSavedMinerUToken()
    }

    required init?(coder: NSCoder) {
        fatalError("This app does not use storyboards")
    }

    deinit {
        progressTimer?.invalidate()
        outputPipe?.fileHandleForReading.readabilityHandler = nil
    }

    func windowWillClose(_ notification: Notification) {
        shutdownForTermination()
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        window?.center()
    }

    func rootViewWasDoubleClicked(_ view: RootView) {
        chooseFile()
    }

    func fileDropViewWasDoubleClicked(_ view: FileDropView) {
        chooseFile()
    }

    func fileDropView(_ view: FileDropView, received url: URL) {
        setInput(url)
    }

    func handleOpenURLs(_ urls: [URL]) {
        if let pdf = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) {
            setInput(pdf)
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func shutdownForTermination() {
        progressTimer?.invalidate()
        progressTimer = nil
        if let childPID {
            kill(childPID, SIGTERM)
        }
        process?.terminate()
        cleanupKnownTemporaryFiles()
    }

    @objc private func chooseFile() {
        guard process == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "选择要转换的 PDF"
        panel.message = "选择一个扫描版 PDF"
        panel.allowedFileTypes = ["pdf"]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.setInput(url)
        }
    }

    @objc private func startProcessing() {
        guard let inputURL, process == nil else { return }
        guard let language = selectedLanguage() else {
            showFailure("没有可用的 OCR 语言")
            return
        }

#if OCR_APP
        let output = nextOCROutputURL(for: inputURL)
#else
        var mineruToken = ""
        guard let format = selectedFormat() else {
            showFailure("没有可用的输出格式")
            return
        }
        guard let parser = selectedParser() else {
            showFailure("没有可用的解析方式")
            return
        }
        if parser.code == "mineru" {
            let token = mineruTokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                showFailure("请填写 MinerU Token")
                return
            }
            mineruToken = token
            saveMinerUToken(token)
        }
        let output = nextOutputURL(for: inputURL, format: format)
#endif
        outputURL = output
        tempURL = nil
        partURL = nil
        isCancelling = false
        childPID = nil
        totalPages = nil
        currentPhase = ""
        partialWorkerLine = ""
        lastWorkerError = nil
        startDate = Date()
        updateControls(isRunning: true)
        outputLabel.stringValue = "完成后会显示保存位置"
        statusLabel.stringValue = "准备开始..."
        statusLabel.textColor = .labelColor
        elapsedLabel.stringValue = ""
        logView.string = "日志开始...\n"
        progressIndicator.isIndeterminate = false
        progressIndicator.doubleValue = 0

#if OCR_APP
        let workerName = "ocr_worker.command"
        let workerArguments = [inputURL.path, language.code, output.path]
#else
        let workerURL = Bundle.main.resourceURL!.appendingPathComponent("reflow_txt_epub_worker.command")
#endif
        let worker = Process()
        worker.executableURL = URL(fileURLWithPath: "/bin/zsh")
#if OCR_APP
        let workerURL = Bundle.main.resourceURL!.appendingPathComponent(workerName)
        worker.arguments = [workerURL.path] + workerArguments
#else
        worker.arguments = [workerURL.path, inputURL.path, language.code, format.code, output.path, parser.code]
#endif
        var environment = [
            "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "TMPDIR": NSTemporaryDirectory(),
            "LANG": "en_US.UTF-8"
        ]
#if !OCR_APP
        if parser.code == "mineru" {
            environment["MINERU_TOKEN"] = mineruToken
        }
#endif
        worker.environment = environment

        let pipe = Pipe()
        outputPipe = pipe
        worker.standardOutput = pipe
        worker.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                self?.consumeWorkerOutput(text)
            }
        }
        worker.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                self?.workerFinished(process)
            }
        }

        process = worker
        do {
            try worker.run()
            startProgressTimer()
        } catch {
            process = nil
            outputPipe = nil
            updateControls(isRunning: false)
            showFailure("无法启动处理程序：\(error.localizedDescription)")
        }
    }

    @objc private func cancelProcessing() {
        guard let worker = process, worker.isRunning else { return }
        isCancelling = true
        statusLabel.stringValue = "正在终止并清理临时产物..."
        statusLabel.textColor = .systemOrange
        cancelButton.isEnabled = false
        if let childPID {
            kill(childPID, SIGTERM)
        }
        worker.terminate()
    }

    @objc private func openOutputDirectory() {
        guard let outputURL else { return }
        let target = fileManager.fileExists(atPath: outputURL.path) ? outputURL : outputURL.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    private func buildInterface() {
        guard let contentView = window?.contentView else { return }
        rootView = RootView(frame: contentView.bounds)
        rootView.autoresizingMask = [.width, .height]
        rootView.delegate = self
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        window?.contentView = rootView

        titleLabel.font = NSFont.systemFont(ofSize: 24, weight: .bold)
        titleLabel.frame = NSRect(x: 28, y: 595, width: 660, height: 30)
        titleLabel.autoresizingMask = [.minYMargin, .width]
        rootView.addSubview(titleLabel)

        let explanation = NSTextField(labelWithString: {
#if OCR_APP
            return "拖放或双击选择 PDF，处理期间可随时终止并清理"
#else
            return "选择输出格式后处理 PDF，可随时终止并清理"
#endif
        }())
        explanation.font = NSFont.systemFont(ofSize: 13)
        explanation.textColor = .secondaryLabelColor
        explanation.frame = NSRect(x: 30, y: 569, width: 660, height: 20)
        explanation.autoresizingMask = [.minYMargin, .width]
        rootView.addSubview(explanation)

        dropView.frame = NSRect(x: 28, y: 415, width: 664, height: 130)
        dropView.autoresizingMask = [.width, .minYMargin]
        dropView.delegate = self
        rootView.addSubview(dropView)

        fileLabel.font = NSFont.systemFont(ofSize: 13)
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.frame = NSRect(x: 30, y: 386, width: 660, height: 20)
        fileLabel.autoresizingMask = [.width, .minYMargin]
        rootView.addSubview(fileLabel)

        let parserLabel = NSTextField(labelWithString: "解析方式：")
        parserLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        parserLabel.frame = NSRect(x: 30, y: 348, width: 75, height: 24)
        parserLabel.autoresizingMask = [.minYMargin]
        rootView.addSubview(parserLabel)

        parserPopup.frame = NSRect(x: 108, y: 346, width: 260, height: 26)
        parserPopup.addItems(withTitles: parserOptions.map(\.title))
        parserPopup.selectItem(at: 1)
        parserPopup.autoresizingMask = [.minYMargin]
        rootView.addSubview(parserPopup)
#if OCR_APP
        parserLabel.isHidden = true
        parserPopup.isHidden = true
#endif

        let formatLabel = NSTextField(labelWithString: "输出格式：")
        formatLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        formatLabel.frame = NSRect(x: 390, y: 348, width: 75, height: 24)
        formatLabel.autoresizingMask = [.minYMargin]
        rootView.addSubview(formatLabel)

        formatPopup.frame = NSRect(x: 468, y: 346, width: 220, height: 26)
        formatPopup.addItems(withTitles: formatOptions.map(\.title))
        formatPopup.selectItem(at: 2)
        formatPopup.autoresizingMask = [.minYMargin]
        rootView.addSubview(formatPopup)
#if OCR_APP
        formatLabel.isHidden = true
        formatPopup.isHidden = true
#endif

        let languageLabel = NSTextField(labelWithString: "识别语言：")
        languageLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        languageLabel.frame = NSRect(x: 30, y: 312, width: 75, height: 24)
        languageLabel.autoresizingMask = [.minYMargin]
        rootView.addSubview(languageLabel)

        languagePopup.frame = NSRect(x: 108, y: 310, width: 260, height: 26)
        languagePopup.autoresizingMask = [.minYMargin]
        rootView.addSubview(languagePopup)

        let tokenLabel = NSTextField(labelWithString: "MinerU Token：")
        tokenLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        tokenLabel.frame = NSRect(x: 390, y: 312, width: 95, height: 24)
        tokenLabel.autoresizingMask = [.minYMargin]
        rootView.addSubview(tokenLabel)

        mineruTokenField.frame = NSRect(x: 488, y: 310, width: 200, height: 24)
        mineruTokenField.placeholderString = "选 MinerU 时填写"
        mineruTokenField.autoresizingMask = [.width, .minYMargin]
        rootView.addSubview(mineruTokenField)
#if OCR_APP
        tokenLabel.isHidden = true
        mineruTokenField.isHidden = true
#endif

        progressIndicator.frame = NSRect(x: 30, y: 251, width: 660, height: 18)
        progressIndicator.autoresizingMask = [.width, .minYMargin]
        progressIndicator.controlSize = .regular
        progressIndicator.style = .bar
        rootView.addSubview(progressIndicator)

        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        statusLabel.frame = NSRect(x: 30, y: 224, width: 520, height: 20)
        statusLabel.autoresizingMask = [.minYMargin, .width]
        rootView.addSubview(statusLabel)

        outputLabel.font = NSFont.systemFont(ofSize: 12)
        outputLabel.textColor = .secondaryLabelColor
        outputLabel.lineBreakMode = .byTruncatingMiddle
        outputLabel.frame = NSRect(x: 30, y: 200, width: 660, height: 18)
        outputLabel.autoresizingMask = [.width, .minYMargin]
        rootView.addSubview(outputLabel)

        elapsedLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        elapsedLabel.textColor = .secondaryLabelColor
        elapsedLabel.alignment = .right
        elapsedLabel.frame = NSRect(x: 580, y: 224, width: 110, height: 20)
        elapsedLabel.autoresizingMask = [.minYMargin, .minXMargin]
        rootView.addSubview(elapsedLabel)

        let logLabel = NSTextField(labelWithString: "日志：")
        logLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        logLabel.textColor = .secondaryLabelColor
        logLabel.frame = NSRect(x: 30, y: 183, width: 80, height: 16)
        logLabel.autoresizingMask = [.minYMargin]
        rootView.addSubview(logLabel)

        let logScroll = NSScrollView(frame: NSRect(x: 30, y: 62, width: 660, height: 120))
        logScroll.autoresizingMask = [.width, .minYMargin]
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .bezelBorder
        logView.isEditable = false
        logView.isSelectable = true
        logView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textColor = .labelColor
        logView.drawsBackground = true
        logView.backgroundColor = .textBackgroundColor
        logView.textContainerInset = NSSize(width: 8, height: 8)
        logView.minSize = NSSize(width: 0, height: logScroll.contentSize.height)
        logView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        logView.isVerticallyResizable = true
        logView.isHorizontallyResizable = false
        logView.autoresizingMask = [.width]
        logView.textContainer?.containerSize = NSSize(width: logScroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        logView.textContainer?.widthTracksTextView = true
        logView.string = "日志会显示在这里。\n"
        logScroll.documentView = logView
        rootView.addSubview(logScroll)

        startButton.title = "开始转换"
        startButton.target = self
        startButton.action = #selector(startProcessing)
        startButton.frame = NSRect(x: 30, y: 22, width: 105, height: 30)
        startButton.autoresizingMask = [.minYMargin]
        startButton.isEnabled = false
        rootView.addSubview(startButton)

        cancelButton.title = "终止并清理"
        cancelButton.target = self
        cancelButton.action = #selector(cancelProcessing)
        cancelButton.frame = NSRect(x: 145, y: 22, width: 125, height: 30)
        cancelButton.autoresizingMask = [.minYMargin]
        cancelButton.isEnabled = false
        rootView.addSubview(cancelButton)

        openOutputButton.title = "打开输出目录"
        openOutputButton.target = self
        openOutputButton.action = #selector(openOutputDirectory)
        openOutputButton.frame = NSRect(x: 280, y: 22, width: 140, height: 30)
        openOutputButton.autoresizingMask = [.minYMargin]
        openOutputButton.isEnabled = false
        rootView.addSubview(openOutputButton)
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
        if let defaultIndex = options.firstIndex(where: { $0.code == "chi_sim+eng" }) {
            languagePopup.selectItem(at: defaultIndex)
        }
        if options.isEmpty { statusLabel.stringValue = "没有可用的 OCR 语言包" }
    }

    private func selectedLanguage() -> LanguageOption? {
        guard languagePopup.indexOfSelectedItem >= 0, languagePopup.indexOfSelectedItem < languageOptions.count else { return nil }
        return languageOptions[languagePopup.indexOfSelectedItem]
    }

    private func selectedParser() -> ParserOption? {
        guard parserPopup.indexOfSelectedItem >= 0, parserPopup.indexOfSelectedItem < parserOptions.count else { return nil }
        return parserOptions[parserPopup.indexOfSelectedItem]
    }

    private func selectedFormat() -> FormatOption? {
        guard formatPopup.indexOfSelectedItem >= 0, formatPopup.indexOfSelectedItem < formatOptions.count else { return nil }
        return formatOptions[formatPopup.indexOfSelectedItem]
    }

    private func setInput(_ url: URL) {
        guard process == nil else { return }
        guard url.pathExtension.lowercased() == "pdf" else {
            showFailure("请选择 PDF 文件")
            return
        }
        inputURL = url.standardizedFileURL
        outputURL = nil
        fileLabel.stringValue = "已选择：\(url.lastPathComponent)"
        dropView.titleText = url.lastPathComponent
        dropView.subtitleText = "双击此区域可重新选择 PDF"
        dropView.needsDisplay = true
        statusLabel.stringValue = "文件已就绪，可以选择格式并开始转换"
        statusLabel.textColor = .labelColor
        outputLabel.stringValue = "完成后会显示保存位置"
        openOutputButton.isEnabled = false
        startButton.isEnabled = !languageOptions.isEmpty
        logView.string = "日志会显示在这里。\n"
    }

    private func updateControls(isRunning: Bool) {
        startButton.isEnabled = !isRunning && inputURL != nil && !languageOptions.isEmpty
        cancelButton.isEnabled = isRunning
        parserPopup.isEnabled = !isRunning
        formatPopup.isEnabled = !isRunning
        languagePopup.isEnabled = !isRunning
        mineruTokenField.isEnabled = !isRunning
        openOutputButton.isEnabled = !isRunning && outputURL != nil && fileManager.fileExists(atPath: outputURL!.path)
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let startDate = self.startDate, self.process?.isRunning == true else { return }
            let elapsed = Int(Date().timeIntervalSince(startDate))
            self.elapsedLabel.stringValue = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
        }
    }

    private func consumeWorkerOutput(_ text: String) {
        appendLog(text)
        let combined = partialWorkerLine + text
        let lines = combined.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if combined.hasSuffix("\n") {
            partialWorkerLine = ""
        } else {
            partialWorkerLine = lines.last ?? ""
        }
        let completeLines = combined.hasSuffix("\n") ? lines.dropLast() : lines.dropLast()
        for line in completeLines {
            if line.hasPrefix("PHASE=") {
                let phase = String(line.dropFirst(6))
                currentPhase = phase
                if phase == "TXT" {
                    statusLabel.stringValue = "正在生成 TXT..."
                } else if phase == "MD" {
                    statusLabel.stringValue = "正在生成 Markdown..."
                } else if phase == "EPUB" {
                    statusLabel.stringValue = "正在生成可调字体 EPUB..."
                } else if phase == "MINERU" {
                    statusLabel.stringValue = "正在用 MinerU 精准解析..."
                } else if phase == "EXTRACT" {
                    statusLabel.stringValue = "正在提取 PDF 已有文字层..."
                } else {
                    statusLabel.stringValue = "正在识别 PDF 文字..."
                }
                if phase == "EXTRACT" || phase == "OCR" {
                    progressIndicator.isIndeterminate = false
                    progressIndicator.doubleValue = max(progressIndicator.doubleValue, 1)
                } else if phase == "TXT" || phase == "EPUB" || phase == "MD" {
                    progressIndicator.isIndeterminate = false
                    progressIndicator.doubleValue = max(progressIndicator.doubleValue, 82)
                } else if phase == "MINERU" {
                    progressIndicator.isIndeterminate = false
                    progressIndicator.doubleValue = max(progressIndicator.doubleValue, 2)
                }
            } else if line.hasPrefix("STATUS=") {
                if lastWorkerError != nil { continue }
                statusLabel.stringValue = String(line.dropFirst(7))
            } else if line.hasPrefix("TEMP_DIR=") {
                tempURL = URL(fileURLWithPath: String(line.dropFirst(9)))
            } else if line.hasPrefix("PART_PATH=") {
                partURL = URL(fileURLWithPath: String(line.dropFirst(10)))
            } else if line.hasPrefix("CHILD_PID=") {
                childPID = pid_t(String(line.dropFirst(10))) ?? nil
            } else if line.hasPrefix("TOTAL_PAGES=") {
                totalPages = Int(line.dropFirst(12))
            } else if line.hasPrefix("PROGRESS="), let value = Double(line.dropFirst(9)) {
                progressIndicator.stopAnimation(nil)
                progressIndicator.isIndeterminate = false
                progressIndicator.doubleValue = value
            } else if line.hasPrefix("OUTPUT_PATH=") {
                outputURL = URL(fileURLWithPath: String(line.dropFirst(12)))
            } else if line.hasPrefix("ERROR=") {
                let message = String(line.dropFirst(6))
                lastWorkerError = message
                statusLabel.stringValue = message
                statusLabel.textColor = .systemRed
                outputLabel.stringValue = "失败原因：\(message)"
            } else if line.hasPrefix("LOG=") {
                continue
            } else {
                updatePageProgress(from: line)
            }
        }
    }

    private func updatePageProgress(from line: String) {
        guard let totalPages, totalPages > 0 else { return }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.split(separator: " ", maxSplits: 1).first, let page = Int(first), page > 0, page <= totalPages else { return }
        progressIndicator.stopAnimation(nil)
        progressIndicator.isIndeterminate = false
        progressIndicator.doubleValue = min(82, max(1, Double(page) / Double(totalPages) * 82))
        if currentPhase == "EXTRACT" {
            statusLabel.stringValue = "正在提取文字：第 \(page) / \(totalPages) 页"
        } else {
            statusLabel.stringValue = "正在识别 PDF 文字：第 \(page) / \(totalPages) 页"
        }
    }

    private func workerFinished(_ worker: Process) {
        progressTimer?.invalidate()
        progressTimer = nil
        if let handle = outputPipe?.fileHandleForReading {
            handle.readabilityHandler = nil
            let remaining = handle.readDataToEndOfFile()
            if !remaining.isEmpty {
                consumeWorkerOutput(String(decoding: remaining, as: UTF8.self))
            }
        }
        if !partialWorkerLine.isEmpty {
            consumeWorkerOutput("\n")
        }
        outputPipe = nil
        process = nil
        if isCancelling {
            cleanupKnownTemporaryFiles()
            progressIndicator.stopAnimation(nil)
            progressIndicator.isIndeterminate = false
            progressIndicator.doubleValue = 0
            statusLabel.stringValue = "已终止，临时产物已清理"
            statusLabel.textColor = .systemOrange
            outputLabel.stringValue = "本次转换未生成产物"
            outputURL = nil
            updateControls(isRunning: false)
            return
        }
        if worker.terminationStatus == 0, let outputURL, fileManager.fileExists(atPath: outputURL.path) {
            progressIndicator.stopAnimation(nil)
            progressIndicator.isIndeterminate = false
            progressIndicator.doubleValue = 100
            statusLabel.stringValue = "转换完成"
            statusLabel.textColor = .systemGreen
            outputLabel.stringValue = "产物位置：\(outputURL.path)"
            openOutputButton.isEnabled = true
        } else {
            cleanupKnownTemporaryFiles()
            progressIndicator.stopAnimation(nil)
            progressIndicator.isIndeterminate = false
            progressIndicator.doubleValue = 0
            if let lastWorkerError {
                statusLabel.stringValue = lastWorkerError
                outputLabel.stringValue = "失败原因：\(lastWorkerError)"
            } else {
                statusLabel.stringValue = "转换失败，但后台没有返回具体原因"
                outputLabel.stringValue = "请把下方日志截图发给我，我继续定位"
            }
            statusLabel.textColor = .systemRed
        }
        updateControls(isRunning: false)
    }

    private func appendLog(_ text: String) {
        logView.string = String((logView.string + text).suffix(20000))
        logView.scrollToEndOfDocument(nil)
    }

    private func cleanupKnownTemporaryFiles() {
        if let tempURL, fileManager.fileExists(atPath: tempURL.path) { try? fileManager.removeItem(at: tempURL) }
        if let partURL, fileManager.fileExists(atPath: partURL.path) { try? fileManager.removeItem(at: partURL) }
        tempURL = nil
        partURL = nil
    }

    private func showFailure(_ message: String) {
        statusLabel.stringValue = message
        statusLabel.textColor = .systemRed
    }

    private func nextOutputURL(for input: URL, format: FormatOption) -> URL {
        let directory = input.deletingLastPathComponent()
        let stem = input.deletingPathExtension().lastPathComponent
        var candidate = directory.appendingPathComponent(stem + format.suffix)
        var index = 2
        while fileManager.fileExists(atPath: candidate.path) {
            if format.code == "txt" {
                candidate = directory.appendingPathComponent(stem + "_ocr_\(index).txt")
            } else if format.code == "md" {
                candidate = directory.appendingPathComponent(stem + "_reflow_\(index).md")
            } else {
                candidate = directory.appendingPathComponent(stem + "_reflow_\(index).epub")
            }
            index += 1
        }
        return candidate
    }

    private func nextOCROutputURL(for input: URL) -> URL {
        let directory = input.deletingLastPathComponent()
        let stem = input.deletingPathExtension().lastPathComponent
        var candidate = directory.appendingPathComponent(stem + "_ocr.pdf")
        var index = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent(stem + "_ocr_\(index).pdf")
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
