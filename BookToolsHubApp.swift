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
    FormatOption(title: "MD（推荐，MinerU/Markdown）", code: "md", suffix: "_reflow.md"),
    FormatOption(title: "TXT（纯文字）", code: "txt", suffix: "_ocr.txt"),
    FormatOption(title: "EPUB（可调字体）", code: "epub", suffix: "_reflow.epub")
]

private let parserOptions = [
    "MinerU 精准解析 API（推荐）",
    "本地 OCRmyPDF / Tesseract（备用）"
]

private protocol DropZoneDelegate: AnyObject {
    func dropZone(_ view: DropZone, received url: URL)
    func dropZoneWasDoubleClicked(_ view: DropZone)
}

private final class DropZone: NSView {
    weak var delegate: DropZoneDelegate?
    var titleText = "把 PDF / TXT / MD 文件拖到这里"
    var subtitleText = "也可以双击此区域选择文件"
    var isHighlighted = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 2, dy: 2)
        let path = NSBezierPath(roundedRect: box, xRadius: 16, yRadius: 16)
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
        guard firstSupportedURL(from: sender.draggingPasteboard) != nil else { return [] }
        isHighlighted = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isHighlighted = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isHighlighted = false
        guard let url = firstSupportedURL(from: sender.draggingPasteboard) else { return false }
        delegate?.dropZone(self, received: url)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            delegate?.dropZoneWasDoubleClicked(self)
        }
        super.mouseDown(with: event)
    }

    private func firstSupportedURL(from pasteboard: NSPasteboard) -> URL? {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else { return nil }
        return urls.first(where: { ["pdf", "txt", "md", "markdown"].contains($0.pathExtension.lowercased()) })
    }
}

private final class MainWindowController: NSWindowController, NSWindowDelegate, DropZoneDelegate {
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

    private let titleLabel = NSTextField(labelWithString: appTitle)
    private let subtitleLabel = NSTextField(labelWithString: "三步完成：PDF 解析（默认 MinerU）→ 转换为 MD / TXT / EPUB → MD / TXT 交给 AI 排版")
    private let dropZone = DropZone(frame: .zero)
    private let fileLabel = NSTextField(labelWithString: "尚未选择文件")
    private let statusLabel = NSTextField(labelWithString: "请选择 PDF、TXT 或 MD")
    private let outputLabel = NSTextField(labelWithString: "完成后会显示产物位置")
    private let progressIndicator = NSProgressIndicator(frame: .zero)
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let parserPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let mineruTokenField = NSSecureTextField(string: "")
    private let ocrButton = NSButton(frame: .zero)
    private let parseButton = NSButton(frame: .zero)
    private let aiButton = NSButton(frame: .zero)
    private let cancelButton = NSButton(frame: .zero)
    private let openOutputButton = NSButton(frame: .zero)
    private let chooseButton = NSButton(frame: .zero)
    private let logView = NSTextView(frame: .zero)

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = appTitle
        window.minSize = NSSize(width: 740, height: 680)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildInterface()
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

    func dropZoneWasDoubleClicked(_ view: DropZone) {
        chooseFile()
    }

    func dropZone(_ view: DropZone, received url: URL) {
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

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        let root = NSView(frame: content.bounds)
        root.autoresizingMask = [.width, .height]
        window?.contentView = root

        titleLabel.font = NSFont.systemFont(ofSize: 27, weight: .bold)
        titleLabel.frame = NSRect(x: 30, y: 666, width: 720, height: 32)
        titleLabel.autoresizingMask = [.minYMargin, .width]
        root.addSubview(titleLabel)

        subtitleLabel.font = NSFont.systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.frame = NSRect(x: 32, y: 642, width: 720, height: 20)
        subtitleLabel.autoresizingMask = [.minYMargin, .width]
        root.addSubview(subtitleLabel)

        dropZone.frame = NSRect(x: 30, y: 510, width: 720, height: 112)
        dropZone.autoresizingMask = [.width, .minYMargin]
        dropZone.delegate = self
        root.addSubview(dropZone)

        chooseButton.title = "选择文件"
        chooseButton.target = self
        chooseButton.action = #selector(chooseFile)
        chooseButton.frame = NSRect(x: 30, y: 470, width: 100, height: 30)
        chooseButton.autoresizingMask = [.minYMargin]
        root.addSubview(chooseButton)

        fileLabel.font = NSFont.systemFont(ofSize: 13)
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.frame = NSRect(x: 145, y: 475, width: 605, height: 20)
        fileLabel.autoresizingMask = [.minYMargin, .width]
        root.addSubview(fileLabel)

        addLabel("识别语言：", frame: NSRect(x: 32, y: 431, width: 78, height: 22), to: root)
        languagePopup.frame = NSRect(x: 112, y: 429, width: 220, height: 26)
        languagePopup.autoresizingMask = [.minYMargin]
        root.addSubview(languagePopup)

        addLabel("PDF 解析：", frame: NSRect(x: 360, y: 431, width: 70, height: 22), to: root)
        parserPopup.frame = NSRect(x: 432, y: 429, width: 318, height: 26)
        parserPopup.addItems(withTitles: parserOptions)
        parserPopup.selectItem(at: 0)
        parserPopup.target = self
        parserPopup.action = #selector(parserSelectionChanged)
        parserPopup.autoresizingMask = [.minYMargin, .width]
        root.addSubview(parserPopup)

        addLabel("输出格式：", frame: NSRect(x: 32, y: 396, width: 78, height: 22), to: root)
        formatPopup.frame = NSRect(x: 112, y: 394, width: 220, height: 26)
        formatPopup.addItems(withTitles: formatOptions.map(\.title))
        formatPopup.selectItem(at: 0)
        formatPopup.autoresizingMask = [.minYMargin]
        root.addSubview(formatPopup)

        addLabel("MinerU Token：", frame: NSRect(x: 360, y: 396, width: 96, height: 22), to: root)
        mineruTokenField.frame = NSRect(x: 456, y: 394, width: 294, height: 24)
        mineruTokenField.placeholderString = "只需填写一次，会记住"
        mineruTokenField.autoresizingMask = [.minYMargin, .width]
        root.addSubview(mineruTokenField)

        addStepLabel("1. PDF 解析（默认 MinerU）", frame: NSRect(x: 32, y: 345, width: 250, height: 22), to: root)
        ocrButton.title = "本地 OCR 备用"
        ocrButton.target = self
        ocrButton.action = #selector(runOCRPDF)
        ocrButton.frame = NSRect(x: 250, y: 341, width: 130, height: 30)
        ocrButton.autoresizingMask = [.minYMargin]
        root.addSubview(ocrButton)

        addStepLabel("2. 转换为 MD / TXT / EPUB", frame: NSRect(x: 32, y: 306, width: 230, height: 22), to: root)
        parseButton.title = "开始转换"
        parseButton.target = self
        parseButton.action = #selector(runPDFParse)
        parseButton.frame = NSRect(x: 250, y: 302, width: 130, height: 30)
        parseButton.autoresizingMask = [.minYMargin]
        root.addSubview(parseButton)

        addStepLabel("3. MD / TXT 交给 AI 排版", frame: NSRect(x: 32, y: 267, width: 230, height: 22), to: root)
        aiButton.title = "打开 AI 排版"
        aiButton.target = self
        aiButton.action = #selector(sendToAIReflow)
        aiButton.frame = NSRect(x: 250, y: 263, width: 150, height: 30)
        aiButton.autoresizingMask = [.minYMargin]
        root.addSubview(aiButton)

        progressIndicator.frame = NSRect(x: 30, y: 225, width: 720, height: 18)
        progressIndicator.autoresizingMask = [.width, .minYMargin]
        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = false
        root.addSubview(progressIndicator)

        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        statusLabel.frame = NSRect(x: 32, y: 198, width: 718, height: 20)
        statusLabel.autoresizingMask = [.width, .minYMargin]
        root.addSubview(statusLabel)

        outputLabel.font = NSFont.systemFont(ofSize: 12)
        outputLabel.textColor = .secondaryLabelColor
        outputLabel.lineBreakMode = .byTruncatingMiddle
        outputLabel.frame = NSRect(x: 32, y: 176, width: 718, height: 18)
        outputLabel.autoresizingMask = [.width, .minYMargin]
        root.addSubview(outputLabel)

        let logScroll = NSScrollView(frame: NSRect(x: 30, y: 64, width: 720, height: 100))
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
        logView.string = "日志会显示在这里。\n"
        logScroll.documentView = logView
        root.addSubview(logScroll)

        cancelButton.title = "终止并清理"
        cancelButton.target = self
        cancelButton.action = #selector(cancelProcessing)
        cancelButton.frame = NSRect(x: 30, y: 22, width: 125, height: 30)
        cancelButton.autoresizingMask = [.minYMargin]
        root.addSubview(cancelButton)

        openOutputButton.title = "打开产物目录"
        openOutputButton.target = self
        openOutputButton.action = #selector(openOutputDirectory)
        openOutputButton.frame = NSRect(x: 170, y: 22, width: 135, height: 30)
        openOutputButton.autoresizingMask = [.minYMargin]
        root.addSubview(openOutputButton)

        refreshModeUI()
    }

    private func addLabel(_ text: String, frame: NSRect, to view: NSView) {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.frame = frame
        label.autoresizingMask = [.minYMargin]
        view.addSubview(label)
    }

    private func addStepLabel(_ text: String, frame: NSRect, to view: NSView) {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        label.frame = frame
        label.autoresizingMask = [.minYMargin]
        view.addSubview(label)
    }

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
        dropZone.titleText = url.lastPathComponent
        dropZone.subtitleText = ext == "pdf" ? "默认直接用 MinerU 解析，OCR 是备用路线" : "可直接发送到 AI 排版"
        dropZone.needsDisplay = true
        fileLabel.stringValue = "已选择：\(url.path)"
        statusLabel.stringValue = ext == "pdf" ? "PDF 已就绪，默认可直接 MinerU 解析" : "文本文件已就绪，可以发送到 AI 排版"
        statusLabel.textColor = .labelColor
        outputLabel.stringValue = "完成后会显示产物位置"
        logView.string = "日志会显示在这里。\n"
        progressIndicator.doubleValue = 0
        updateControls(isRunning: false)
    }

    private func updateControls(isRunning: Bool) {
        let ext = selectedURL?.pathExtension.lowercased() ?? ""
        let isPDF = ext == "pdf"
        let parserIsLocal = selectedParserCode() == "local"
        chooseButton.isEnabled = !isRunning
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
        progressIndicator.doubleValue = 0
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
                progressIndicator.doubleValue = value
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
        progressIndicator.doubleValue = max(progressIndicator.doubleValue, value)
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
            progressIndicator.doubleValue = 0
            statusLabel.stringValue = "已终止，临时产物已清理"
            statusLabel.textColor = .systemOrange
            outputLabel.stringValue = "本次处理未生成产物"
            updateControls(isRunning: false)
            return
        }

        if worker.terminationStatus == 0, let outputURL, fileManager.fileExists(atPath: outputURL.path) {
            cleanupKnownTemporaryFiles()
            progressIndicator.doubleValue = 100
            statusLabel.stringValue = "处理完成"
            statusLabel.textColor = .systemGreen
            outputLabel.stringValue = "产物位置：\(outputURL.path)"
            if ["txt", "md", "markdown"].contains(outputURL.pathExtension.lowercased()) {
                lastTextURL = outputURL
                selectedURL = outputURL
                dropZone.titleText = outputURL.lastPathComponent
                dropZone.subtitleText = "可直接发送到 AI 排版"
                dropZone.needsDisplay = true
                fileLabel.stringValue = "当前文本产物：\(outputURL.path)"
            }
        } else {
            cleanupKnownTemporaryFiles()
            progressIndicator.doubleValue = 0
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

    @objc private func parserSelectionChanged() {
        refreshModeUI()
        updateControls(isRunning: process?.isRunning == true)
    }

    private func refreshModeUI() {
        let parserIsMineru = selectedParserCode() == "mineru"
        ocrButton.title = parserIsMineru ? "本地 OCR 备用" : "执行本地 OCR"
        if let ext = selectedURL?.pathExtension.lowercased(), ext == "pdf" {
            dropZone.subtitleText = parserIsMineru
                ? "默认直接用 MinerU 解析，OCR 只是备用路线"
                : "当前切换为本地 OCR 模式"
            dropZone.needsDisplay = true
            fileLabel.stringValue = selectedURL.map { "已选择：\($0.path)" } ?? fileLabel.stringValue
        }
        subtitleLabel.stringValue = parserIsMineru
            ? "三步流程：PDF 解析（MinerU）→ 转换为 MD / TXT / EPUB → MD / TXT 交给 AI 排版"
            : "三步流程：PDF 解析（本地 OCR，自动跳过已有文字层）→ 转换为 MD / TXT / EPUB → MD / TXT 交给 AI 排版"
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
