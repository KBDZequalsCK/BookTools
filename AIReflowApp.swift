import AppKit
import Foundation

private let appTitle = "AI TXT-MD 排版"
private let settingsAPIURLKey = "apiURL"
private let settingsModelKey = "model"
private let settingsChunkSizeKey = "chunkSize"
private let settingsFormatCodeKey = "formatCode"
private let settingsAPIKeyKey = "apiKey"
private let legacySettingsDomain = "local.codex.ai-txt-reflow"
private let supportedInputExtensions = ["txt", "md", "markdown"]

private struct FormatOption {
    let title: String
    let code: String
    let suffix: String
}

private struct ResumeState: Codable {
    let inputPath: String
    let inputByteCount: UInt64
    let inputModificationTime: TimeInterval
    let outputPath: String
    let formatCode: String
    let chunkSize: Int
    let totalChunks: Int
    let nextChunkIndex: Int
    let results: [String]
}

private let formatOptions = [
    FormatOption(title: "TXT（AI 重排）", code: "txt", suffix: "_ai_reflow.txt"),
    FormatOption(title: "MD（AI Markdown 排版）", code: "md", suffix: "_ai_reflow.md")
]

private struct ChatMessage: Encodable {
    let role: String
    let content: String
}

private struct ChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let stream: Bool
}

private struct ChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }
        let message: Message
    }
    let choices: [Choice]
}

private struct APIErrorResponse: Decodable {
    struct APIError: Decodable {
        let message: String?
    }
    let error: APIError?
}

final class AIReflowWindowController: NSWindowController, NSWindowDelegate, FileDropZoneDelegate {
    private let fileManager = FileManager.default
    private var inputURL: URL?
    private var outputURL: URL?
    private var partURL: URL?
    private var requestTask: URLSessionDataTask?
    private var isCancelling = false
    private var chunks: [String] = []
    private var chunkContexts: [String] = []
    private var results: [String] = []
    private var nextChunkIndex = 0
    private var totalCharacters = 0
    private var outputFormatCode = "txt"
    private var checkpointURL: URL?
    private var availableResumeState: ResumeState?

    private let headerIconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "AI 排版")
    private let subtitleLabel = BTUI.label(
        "把 TXT / MD 交给 AI 清理、分章并重排 · 支持断点续传",
        size: 12,
        color: .secondaryLabelColor
    )
    private let fileLabel = BTUI.label("尚未选择 TXT / MD", size: 11, color: .tertiaryLabelColor)
    private let outputLabel = BTUI.label("完成后会显示保存位置", size: 11, color: .secondaryLabelColor)
    private let statusLabel = BTUI.label("请选择 TXT / MD 文件开始", size: 13, weight: .medium)
    private let progressLabel = BTUI.label("", size: 11, color: .secondaryLabelColor, alignment: .right)
    private let apiURLField = NSTextField(string: "https://api.openai.com/v1/chat/completions")
    private let modelField = NSTextField(string: "gpt-4o-mini")
    private let apiKeyField = NSSecureTextField(string: "")
    private let chunkSizeField = NSTextField(string: "8000")
    private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let progressBar = BTProgressBar()
    private let startButton = BTButton(title: "开始 AI 排版", symbol: "wand.and.stars", style: .primary, height: 30)
    private let resumeButton = BTButton(title: "继续未完成", symbol: "play.circle", style: .accent, height: 30)
    private let skipButton = BTButton(title: "跳过当前块", symbol: "forward.end", style: .secondary, height: 30)
    private let cancelButton = BTButton(title: "终止并清理", symbol: "stop.circle", style: .destructive, height: 30)
    private let openOutputButton = BTButton(title: "打开输出目录", symbol: "folder", style: .secondary, height: 30)
    private let chooseButton = BTButton(title: "选择文件", symbol: "folder", style: .ghost, height: 28)
    private let logView = NSTextView(frame: .zero)
    private let dropView = FileDropZoneView(
        acceptedExtensions: ["txt", "md", "markdown"],
        title: "把 TXT / MD 文件拖到这里",
        subtitle: "也可以双击此区域选择文件"
    )

    init(initialInput: URL? = nil) {
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
        loadSavedSettings()
        loadSavedAPIKey()
        if let initialInput {
            setInput(initialInput)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("This app does not use storyboards")
    }

    deinit {
        requestTask?.cancel()
    }

    func windowWillClose(_ notification: Notification) {
        shutdownForTermination()
    }

    func dropZoneWasDoubleClicked(_ view: FileDropZoneView) {
        chooseFile()
    }

    func dropZone(_ view: FileDropZoneView, received url: URL) {
        setInput(url)
    }

    func handleOpenURLs(_ urls: [URL]) {
        if let url = urls.first(where: { supportedInputExtensions.contains($0.pathExtension.lowercased()) }) {
            setInput(url)
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func loadInput(_ url: URL) {
        guard requestTask == nil else { return }
        setInput(url)
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func shutdownForTermination() {
        let hadActiveRequest = requestTask != nil
        isCancelling = true
        requestTask?.cancel()
        requestTask = nil
        if hadActiveRequest || processHasActiveWork {
            persistCheckpoint()
        }
    }

    @objc private func chooseFile() {
        guard requestTask == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "选择要 AI 排版的 TXT / MD"
        panel.message = "选择 OCR 提取出的 TXT，或已有 Markdown 文本"
        panel.allowedFileTypes = supportedInputExtensions
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.setInput(url)
        }
    }

    @objc private func startProcessing() {
        guard let inputURL, requestTask == nil else { return }
        if availableResumeState != nil {
            showFailure("检测到未完成任务，请点击“继续未完成”；如需重新开始，请先点击“终止并清理”。")
            return
        }
        guard let endpoint = normalizedEndpoint(),
              let model = nonEmpty(modelField.stringValue),
              let apiKey = nonEmpty(apiKeyField.stringValue) else {
            showFailure("请填写 API 地址、模型和 API Key")
            return
        }
        guard let chunkSize = Int(chunkSizeField.stringValue), (1000...30000).contains(chunkSize) else {
            showFailure("分块字符数应在 1000 到 30000 之间")
            return
        }
        guard let format = selectedFormat() else {
            showFailure("请选择输出格式")
            return
        }
        guard let text = try? String(contentsOf: inputURL, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showFailure("无法读取 TXT / MD，或文件内容为空")
            return
        }

        saveAPIKey(apiKey)
        saveSettings(format: format, chunkSize: chunkSize)
        let inputIsMarkdown = isMarkdownInput(inputURL)
        chunks = splitText(text, maxCharacters: chunkSize, preferMarkdownBoundaries: inputIsMarkdown)
        chunkContexts = inputIsMarkdown ? buildMarkdownChunkContexts(chunks) : []
        results = Array(repeating: "", count: chunks.count)
        totalCharacters = text.count
        nextChunkIndex = 0
        outputFormatCode = format.code
        isCancelling = false
        outputURL = nextOutputURL(for: inputURL, format: format)
        partURL = outputURL?.appendingPathExtension("part")
        checkpointURL = resumeStateURL(for: inputURL, formatCode: format.code)
        availableResumeState = nil

        guard let outputURL, let partURL else {
            showFailure("无法创建输出路径")
            return
        }
        try? "".write(to: partURL, atomically: true, encoding: .utf8)
        persistCheckpoint()
        updateControls(isRunning: true)
        setProgress(0)
        progressLabel.stringValue = "0 / \(chunks.count) 块"
        statusLabel.stringValue = "正在准备 AI 排版..."
        statusLabel.textColor = .labelColor
        outputLabel.stringValue = "完成后会显示保存位置"
        let chunkMode = inputIsMarkdown ? "Markdown 标题/段落边界" : "普通段落边界"
        logView.string = "输入字符数：\(totalCharacters)\n分块数量：\(chunks.count)\n分块方式：\(chunkMode)\n输出文件：\(outputURL.lastPathComponent)\n每完成一块都会保存断点。\n"
        processNextChunk(endpoint: endpoint, model: model, apiKey: apiKey)
    }

    @objc private func resumeProcessing() {
        guard requestTask == nil, let state = availableResumeState else { return }
        let sourceURL = URL(fileURLWithPath: state.inputPath)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            showFailure("找不到断点对应的输入文件")
            return
        }
        guard let endpoint = normalizedEndpoint(),
              let model = nonEmpty(modelField.stringValue),
              let apiKey = nonEmpty(apiKeyField.stringValue) else {
            showFailure("请填写 API 地址、模型和 API Key")
            return
        }
        guard let text = try? String(contentsOf: sourceURL, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showFailure("无法读取断点对应的输入文件")
            return
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: sourceURL.path),
              let byteCount = attributes[.size] as? UInt64,
              let modificationDate = attributes[.modificationDate] as? Date,
              byteCount == state.inputByteCount,
              abs(modificationDate.timeIntervalSince1970 - state.inputModificationTime) < 1 else {
            showFailure("输入文件已经改变，不能安全继续；请重新开始排版")
            return
        }
        let formatIndex = formatOptions.firstIndex(where: { $0.code == state.formatCode }) ?? 0
        formatPopup.selectItem(at: formatIndex)
        chunkSizeField.stringValue = String(state.chunkSize)
        let inputIsMarkdown = isMarkdownInput(sourceURL)
        let rebuiltChunks = splitTextForResume(
            text,
            maxCharacters: state.chunkSize,
            preferMarkdownBoundaries: inputIsMarkdown,
            expectedTotalChunks: state.totalChunks
        )
        guard rebuiltChunks.count == state.totalChunks,
              state.nextChunkIndex <= rebuiltChunks.count,
              state.results.count == rebuiltChunks.count else {
            showFailure("输入文件的分块方式已经变化，不能安全继续；请重新开始排版")
            return
        }

        inputURL = sourceURL
        outputURL = URL(fileURLWithPath: state.outputPath)
        partURL = outputURL?.appendingPathExtension("part")
        checkpointURL = resumeStateURL(for: sourceURL, formatCode: state.formatCode)
        outputFormatCode = state.formatCode
        chunks = rebuiltChunks
        chunkContexts = inputIsMarkdown ? buildMarkdownChunkContexts(rebuiltChunks) : []
        results = state.results
        nextChunkIndex = state.nextChunkIndex
        totalCharacters = text.count
        isCancelling = false
        guard let partURL else {
            showFailure("找不到断点临时文件路径")
            return
        }
        try? results.prefix(nextChunkIndex).joined(separator: "\n\n").appending(nextChunkIndex > 0 ? "\n\n" : "").write(to: partURL, atomically: true, encoding: .utf8)
        updateControls(isRunning: true)
        setProgress(Double(nextChunkIndex) / Double(max(chunks.count, 1)) * 100)
        progressLabel.stringValue = "\(nextChunkIndex) / \(chunks.count) 块"
        statusLabel.stringValue = "继续处理：从第 \(nextChunkIndex + 1) / \(chunks.count) 块开始"
        statusLabel.textColor = .labelColor
        outputLabel.stringValue = "断点产物：\(outputURL?.lastPathComponent ?? "")"
        logView.string = "已恢复断点：已完成 \(nextChunkIndex) / \(chunks.count) 块\n将只重新请求未完成的块。\n"
        processNextChunk(endpoint: endpoint, model: model, apiKey: apiKey)
    }

    @objc private func skipCurrentChunkAndContinue() {
        guard requestTask == nil, let state = availableResumeState else { return }
        let sourceURL = URL(fileURLWithPath: state.inputPath)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            showFailure("找不到断点对应的输入文件")
            return
        }
        guard let endpoint = normalizedEndpoint(),
              let model = nonEmpty(modelField.stringValue),
              let apiKey = nonEmpty(apiKeyField.stringValue) else {
            showFailure("请填写 API 地址、模型和 API Key，跳过当前块后才能继续处理后续块")
            return
        }
        guard let text = try? String(contentsOf: sourceURL, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showFailure("无法读取断点对应的输入文件")
            return
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: sourceURL.path),
              let byteCount = attributes[.size] as? UInt64,
              let modificationDate = attributes[.modificationDate] as? Date,
              byteCount == state.inputByteCount,
              abs(modificationDate.timeIntervalSince1970 - state.inputModificationTime) < 1 else {
            showFailure("输入文件已经改变，不能安全跳过；请重新开始排版")
            return
        }
        guard state.nextChunkIndex < state.totalChunks else {
            showFailure("断点已经没有可跳过的块")
            return
        }

        let formatIndex = formatOptions.firstIndex(where: { $0.code == state.formatCode }) ?? 0
        formatPopup.selectItem(at: formatIndex)
        chunkSizeField.stringValue = String(state.chunkSize)
        let inputIsMarkdown = isMarkdownInput(sourceURL)
        let rebuiltChunks = splitTextForResume(
            text,
            maxCharacters: state.chunkSize,
            preferMarkdownBoundaries: inputIsMarkdown,
            expectedTotalChunks: state.totalChunks
        )
        guard rebuiltChunks.count == state.totalChunks,
              state.nextChunkIndex < rebuiltChunks.count,
              state.results.count == rebuiltChunks.count else {
            showFailure("输入文件的分块方式已经变化，不能安全跳过；请重新开始排版")
            return
        }

        inputURL = sourceURL
        outputURL = URL(fileURLWithPath: state.outputPath)
        partURL = outputURL?.appendingPathExtension("part")
        checkpointURL = resumeStateURL(for: sourceURL, formatCode: state.formatCode)
        outputFormatCode = state.formatCode
        chunks = rebuiltChunks
        chunkContexts = inputIsMarkdown ? buildMarkdownChunkContexts(rebuiltChunks) : []
        results = state.results
        totalCharacters = text.count
        isCancelling = false

        let skippedIndex = state.nextChunkIndex
        results[skippedIndex] = chunks[skippedIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        nextChunkIndex = skippedIndex + 1
        saveAPIKey(apiKey)
        saveSettings(format: formatOptions[formatIndex], chunkSize: state.chunkSize)
        persistPartialResult()
        updateControls(isRunning: true)
        setProgress(Double(nextChunkIndex) / Double(max(chunks.count, 1)) * 100)
        progressLabel.stringValue = "正在 \(min(nextChunkIndex + 1, chunks.count)) / \(chunks.count) 块"
        statusLabel.stringValue = "已用原文保留第 \(skippedIndex + 1) 块，继续处理后续块..."
        statusLabel.textColor = .labelColor
        outputLabel.stringValue = "断点产物：\(outputURL?.lastPathComponent ?? "")"
        appendLog("第 \(skippedIndex + 1) 块已跳过，已用原文保留：\(chunkHeadingSummary(chunks[skippedIndex]))")

        if nextChunkIndex >= chunks.count {
            finishSuccessfully()
        } else {
            processNextChunk(endpoint: endpoint, model: model, apiKey: apiKey)
        }
    }

    @objc private func cancelProcessing() {
        if requestTask == nil {
            guard availableResumeState != nil else { return }
            cleanupResumeArtifacts()
            availableResumeState = nil
            statusLabel.stringValue = "未完成任务和临时产物已清理"
            statusLabel.textColor = .systemOrange
            outputLabel.stringValue = "本次断点已删除，可以重新开始"
            progressLabel.stringValue = ""
            updateControls(isRunning: false)
            return
        }
        isCancelling = true
        requestTask?.cancel()
        requestTask = nil
        cleanupResumeArtifacts()
        availableResumeState = nil
        statusLabel.stringValue = "已取消，未完成产物已清理"
        statusLabel.textColor = .systemOrange
        progressLabel.stringValue = ""
        updateControls(isRunning: false)
    }

    @objc private func openOutputDirectory() {
        guard let outputURL else { return }
        let target = fileManager.fileExists(atPath: outputURL.path) ? outputURL : outputURL.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([target])
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

        dropView.delegate = self
        dropView.translatesAutoresizingMaskIntoConstraints = false
        dropView.heightAnchor.constraint(equalToConstant: 70).isActive = true

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

        card.stack.addArrangedSubview(dropView)
        card.stack.addArrangedSubview(chooseRow)
        dropView.widthAnchor.constraint(equalTo: card.stack.widthAnchor).isActive = true
        chooseRow.widthAnchor.constraint(equalTo: card.stack.widthAnchor).isActive = true
        card.stack.spacing = 6
        return card
    }

    private func makeSettingsCard() -> NSView {
        let card = BTCardView(insets: NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16))

        let header = BTUI.sectionHeader(title: "接口设置", symbol: "network")
        card.stack.addArrangedSubview(header)

        let apiLabel = BTUI.formLabel("API 地址")
        let modelLabel = BTUI.formLabel("模型")
        let keyLabel = BTUI.formLabel("API Key")
        let chunkLabel = BTUI.formLabel("分块字符数")
        let outputLabelTitle = BTUI.formLabel("输出格式")
        for label in [apiLabel, modelLabel, keyLabel, chunkLabel, outputLabelTitle] {
            label.widthAnchor.constraint(equalToConstant: 86).isActive = true
        }

        for field in [apiURLField, modelField, chunkSizeField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.font = NSFont.systemFont(ofSize: 12)
            field.isBezeled = true
            field.bezelStyle = .roundedBezel
            field.heightAnchor.constraint(equalToConstant: 26).isActive = true
        }
        apiKeyField.translatesAutoresizingMaskIntoConstraints = false
        apiKeyField.font = NSFont.systemFont(ofSize: 12)
        apiKeyField.isBezeled = true
        apiKeyField.bezelStyle = .roundedBezel
        apiKeyField.heightAnchor.constraint(equalToConstant: 26).isActive = true
        apiKeyField.placeholderString = "sk-..."
        apiURLField.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        apiKeyField.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        modelField.widthAnchor.constraint(equalToConstant: 170).isActive = true
        chunkSizeField.widthAnchor.constraint(equalToConstant: 90).isActive = true

        formatPopup.translatesAutoresizingMaskIntoConstraints = false
        formatPopup.controlSize = .regular
        formatPopup.addItems(withTitles: formatOptions.map(\.title))
        formatPopup.widthAnchor.constraint(equalToConstant: 230).isActive = true
        formatPopup.heightAnchor.constraint(equalToConstant: 26).isActive = true

        let rowOne = NSStackView(views: [apiLabel, apiURLField])
        rowOne.orientation = .horizontal
        rowOne.alignment = .centerY
        rowOne.spacing = 10

        let rowTwo = NSStackView(views: [modelLabel, modelField, keyLabel, apiKeyField])
        rowTwo.orientation = .horizontal
        rowTwo.alignment = .centerY
        rowTwo.spacing = 10

        let rowThree = NSStackView(views: [chunkLabel, chunkSizeField, outputLabelTitle, formatPopup, BTUI.spacer()])
        rowThree.orientation = .horizontal
        rowThree.alignment = .centerY
        rowThree.spacing = 10

        card.stack.addArrangedSubview(rowOne)
        card.stack.addArrangedSubview(rowTwo)
        card.stack.addArrangedSubview(rowThree)
        rowOne.widthAnchor.constraint(equalTo: card.stack.widthAnchor).isActive = true
        rowTwo.widthAnchor.constraint(equalTo: card.stack.widthAnchor).isActive = true
        rowThree.widthAnchor.constraint(equalTo: card.stack.widthAnchor).isActive = true
        card.stack.spacing = 8
        return card
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

        logView.isEditable = false
        logView.isSelectable = true
        logView.drawsBackground = false
        logView.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        logView.textColor = .secondaryLabelColor
        logView.textContainerInset = NSSize(width: 6, height: 6)
        logView.string = "日志会显示在这里。\n"

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

    private func makeBottomBar() -> NSView {
        let bar = NSView()

        for button in [startButton, resumeButton, skipButton, cancelButton, openOutputButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(button)
        }

        startButton.target = self
        startButton.action = #selector(startProcessing)
        startButton.isEnabled = false
        resumeButton.target = self
        resumeButton.action = #selector(resumeProcessing)
        resumeButton.isEnabled = false
        skipButton.target = self
        skipButton.action = #selector(skipCurrentChunkAndContinue)
        skipButton.isEnabled = false
        cancelButton.target = self
        cancelButton.action = #selector(cancelProcessing)
        cancelButton.isEnabled = false
        openOutputButton.target = self
        openOutputButton.action = #selector(openOutputDirectory)
        openOutputButton.isEnabled = false

        NSLayoutConstraint.activate([
            bar.heightAnchor.constraint(equalToConstant: 30),

            startButton.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 2),
            startButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            startButton.widthAnchor.constraint(equalToConstant: 128),

            resumeButton.leadingAnchor.constraint(equalTo: startButton.trailingAnchor, constant: 8),
            resumeButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            resumeButton.widthAnchor.constraint(equalToConstant: 120),

            skipButton.leadingAnchor.constraint(equalTo: resumeButton.trailingAnchor, constant: 8),
            skipButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            skipButton.widthAnchor.constraint(equalToConstant: 118),

            openOutputButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -2),
            openOutputButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            openOutputButton.widthAnchor.constraint(equalToConstant: 128),

            cancelButton.trailingAnchor.constraint(equalTo: openOutputButton.leadingAnchor, constant: -8),
            cancelButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: 118)
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

    private func setInput(_ url: URL) {
        guard requestTask == nil else { return }
        guard supportedInputExtensions.contains(url.pathExtension.lowercased()) else {
            showFailure("请选择 TXT / MD 文件")
            return
        }
        inputURL = url.standardizedFileURL
        outputURL = nil
        selectOutputFormatForInput(url)
        fileLabel.stringValue = "已选择：\(url.path)"
        fileLabel.textColor = .secondaryLabelColor
        dropView.iconName = "doc.text"
        dropView.titleText = url.lastPathComponent
        dropView.subtitleText = "双击此区域可重新选择 TXT / MD"
        dropView.needsDisplay = true
        let formatTitle = selectedFormat()?.title ?? "当前格式"
        statusLabel.stringValue = "文件已就绪，已按输入自动选择：\(formatTitle)"
        statusLabel.textColor = .labelColor
        outputLabel.stringValue = "完成后会显示保存位置"
        setProgress(0)
        openOutputButton.isEnabled = false
        startButton.isEnabled = true
        loadResumeState(for: url)
        logView.string = ""
    }

    private func updateControls(isRunning: Bool) {
        startButton.isEnabled = !isRunning && inputURL != nil
        cancelButton.isEnabled = isRunning || availableResumeState != nil
        cancelButton.setTitleText(availableResumeState != nil && !isRunning ? "清理未完成" : "终止并清理")
        apiURLField.isEnabled = !isRunning
        modelField.isEnabled = !isRunning
        apiKeyField.isEnabled = !isRunning
        chunkSizeField.isEnabled = !isRunning
        formatPopup.isEnabled = !isRunning
        chooseButton.isEnabled = !isRunning
        dropView.isInteractionEnabled = !isRunning
        openOutputButton.isEnabled = !isRunning && outputURL != nil && fileManager.fileExists(atPath: outputURL!.path)
        resumeButton.isEnabled = !isRunning && availableResumeState != nil
        skipButton.isEnabled = !isRunning && availableResumeState != nil
    }

    private func selectedFormat() -> FormatOption? {
        guard formatPopup.indexOfSelectedItem >= 0, formatPopup.indexOfSelectedItem < formatOptions.count else {
            return nil
        }
        return formatOptions[formatPopup.indexOfSelectedItem]
    }

    private func selectOutputFormatForInput(_ url: URL) {
        let targetCode = isMarkdownInput(url) ? "md" : "txt"
        if let index = formatOptions.firstIndex(where: { $0.code == targetCode }) {
            formatPopup.selectItem(at: index)
        }
    }

    private func isMarkdownInput(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
    }

    private func processNextChunk(endpoint: URL, model: String, apiKey: String) {
        guard !isCancelling, nextChunkIndex < chunks.count else {
            if !isCancelling {
                finishSuccessfully()
            }
            return
        }

        let index = nextChunkIndex
        let text = chunks[index]
        statusLabel.stringValue = "AI 正在重排第 \(index + 1) / \(chunks.count) 块..."
        progressLabel.stringValue = "正在 \(index + 1) / \(chunks.count) 块"

        let systemPrompt = prompt(for: outputFormatCode)
        let chunkContext = markdownChunkContext(for: index)
        let userPrompt = outputFormatCode == "md"
            ? """
            以下是整本书 Markdown 的第 \(index + 1) / \(chunks.count) 块，请按系统规则只清理当前块。

            \(chunkContext)

            请整理下面这段 MinerU 输出的 Markdown 文本结构：

            \(text)
            """
            : "请重排下面这段文本：\n\n\(text)"
        let body = ChatRequest(
            model: model,
            messages: [
                ChatMessage(role: "system", content: systemPrompt),
                ChatMessage(role: "user", content: userPrompt)
            ],
            temperature: 0.1,
            stream: false
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            fail("无法生成 API 请求：\(error.localizedDescription)")
            return
        }

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.requestTask = nil
                if self.isCancelling {
                    return
                }
                if let error {
                    self.fail("API 请求失败：\(error.localizedDescription)")
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    self.fail("API 没有返回有效的 HTTP 响应")
                    return
                }
                guard let data else {
                    self.fail("API 返回为空")
                    return
                }
                guard (200...299).contains(http.statusCode) else {
                    let message = "API 返回 HTTP \(http.statusCode)：\(self.apiErrorMessage(from: data))"
                    if http.statusCode == 400 {
                        self.fail("API 内容安全过滤拒绝第 \(index + 1) / \(self.chunks.count) 块；已完成 \(self.nextChunkIndex) 块。")
                        self.appendLog("接口原始错误：\(message)")
                        self.appendLog("失败块标题：\(self.chunkHeadingSummary(self.chunks[index]))")
                    } else {
                        self.fail(message)
                    }
                    return
                }
                do {
                    let result = try JSONDecoder().decode(ChatResponse.self, from: data)
                    guard let content = result.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !content.isEmpty else {
                        self.fail("API 返回中没有可用文本")
                        return
                    }
                    self.results[index] = content
                    self.nextChunkIndex += 1
                    self.persistPartialResult()
                    self.appendLog("第 \(index + 1) 块完成，\(content.count) 字符")
                    self.setProgress(Double(self.nextChunkIndex) / Double(max(self.chunks.count, 1)) * 100)
                    self.progressLabel.stringValue = "\(self.nextChunkIndex) / \(self.chunks.count) 块"
                    self.processNextChunk(endpoint: endpoint, model: model, apiKey: apiKey)
                } catch {
                    self.fail("无法解析 API 返回：\(error.localizedDescription)")
                }
            }
        }
        requestTask = task
        task.resume()
    }

    private func finishSuccessfully() {
        guard let outputURL else {
            fail("没有输出路径")
            return
        }
        let result = results.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        do {
            try result.write(to: outputURL, atomically: true, encoding: .utf8)
            cleanupPartFile()
            cleanupCheckpoint()
            availableResumeState = nil
            setProgress(100)
            progressLabel.stringValue = "\(chunks.count) / \(chunks.count) 块"
            statusLabel.stringValue = "AI 排版完成"
            statusLabel.textColor = .systemGreen
            outputLabel.stringValue = "产物位置：\(outputURL.path)"
            updateControls(isRunning: false)
            openOutputButton.isEnabled = true
        } catch {
            fail("无法保存输出文件：\(error.localizedDescription)")
        }
    }

    private func persistPartialResult() {
        guard let partURL else { return }
        let partial = results.prefix(nextChunkIndex).joined(separator: "\n\n") + (nextChunkIndex > 0 ? "\n\n" : "")
        try? partial.write(to: partURL, atomically: true, encoding: .utf8)
        persistCheckpoint()
    }

    private func fail(_ message: String) {
        requestTask?.cancel()
        requestTask = nil
        persistCheckpoint()
        statusLabel.stringValue = message
        statusLabel.textColor = .systemRed
        appendLog("\(message)\n已保留已完成块，可点击“继续未完成”重试当前失败块。")
        outputLabel.stringValue = "断点已保留：已完成 \(nextChunkIndex) / \(chunks.count) 块"
        updateControls(isRunning: false)
    }

    private func splitText(_ text: String, maxCharacters: Int, preferMarkdownBoundaries: Bool) -> [String] {
        if preferMarkdownBoundaries {
            return splitMarkdownText(text, maxCharacters: maxCharacters)
        }
        return splitPlainText(text, maxCharacters: maxCharacters)
    }

    private func splitTextForResume(_ text: String, maxCharacters: Int, preferMarkdownBoundaries: Bool, expectedTotalChunks: Int) -> [String] {
        let current = splitText(text, maxCharacters: maxCharacters, preferMarkdownBoundaries: preferMarkdownBoundaries)
        if current.count == expectedTotalChunks || !preferMarkdownBoundaries {
            return current
        }
        let legacy = splitMarkdownTextLegacy(text, maxCharacters: maxCharacters)
        return legacy.count == expectedTotalChunks ? legacy : current
    }

    private func splitPlainText(_ text: String, maxCharacters: Int) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let paragraphs = normalized.components(separatedBy: "\n\n")
        var output: [String] = []
        var current = ""

        for paragraph in paragraphs {
            let candidate = current.isEmpty ? paragraph : current + "\n\n" + paragraph
            if candidate.count <= maxCharacters {
                current = candidate
            } else {
                if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    output.append(current)
                }
                if paragraph.count <= maxCharacters {
                    current = paragraph
                } else {
                    let pieces = hardSplit(paragraph, maxCharacters: maxCharacters)
                    output.append(contentsOf: pieces.dropLast())
                    current = pieces.last ?? ""
                }
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            output.append(current)
        }
        return output.isEmpty ? [normalized] : output
    }

    private func splitMarkdownText(_ text: String, maxCharacters: Int) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let blocks = markdownChapterBlocks(from: normalized)
        var output: [String] = []
        var current = ""

        for block in blocks {
            let candidate = current.isEmpty ? block : current + "\n\n" + block
            if candidate.count <= maxCharacters {
                current = candidate
                continue
            }
            if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                output.append(current)
            }
            if block.count <= maxCharacters {
                current = block
            } else {
                let pieces = splitOversizedMarkdownBlock(block, maxCharacters: maxCharacters)
                output.append(contentsOf: pieces.dropLast())
                current = pieces.last ?? ""
            }
        }

        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            output.append(current)
        }
        return output.isEmpty ? [normalized] : output
    }

    private func splitMarkdownTextLegacy(_ text: String, maxCharacters: Int) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let blocks = markdownBlocks(from: normalized)
        var output: [String] = []
        var current = ""

        for block in blocks {
            let candidate = current.isEmpty ? block : current + "\n\n" + block
            if candidate.count <= maxCharacters {
                current = candidate
                continue
            }
            if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                output.append(current)
            }
            if block.count <= maxCharacters {
                current = block
            } else {
                let pieces = splitPlainText(block, maxCharacters: maxCharacters)
                output.append(contentsOf: pieces.dropLast())
                current = pieces.last ?? ""
            }
        }

        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            output.append(current)
        }
        return output.isEmpty ? [normalized] : output
    }

    private func markdownChapterBlocks(from text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [String] = []
        var current: [String] = []
        var seenMainBody = false

        for line in lines {
            let startsMajorSection = isMajorMarkdownHeading(line)
            if startsMajorSection {
                seenMainBody = true
            }
            if startsMajorSection, !current.isEmpty {
                let block = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !block.isEmpty {
                    blocks.append(block)
                }
                current = [line]
            } else {
                current.append(line)
            }
        }

        let finalBlock = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalBlock.isEmpty {
            blocks.append(finalBlock)
        }

        if !seenMainBody || blocks.count <= 1 {
            return markdownBlocks(from: text)
        }
        return blocks
    }

    private func splitOversizedMarkdownBlock(_ block: String, maxCharacters: Int) -> [String] {
        let blocks = markdownBlocks(from: block)
        if blocks.count <= 1 {
            return splitPlainText(block, maxCharacters: maxCharacters)
        }

        var output: [String] = []
        var current = ""
        for piece in blocks {
            let candidate = current.isEmpty ? piece : current + "\n\n" + piece
            if candidate.count <= maxCharacters {
                current = candidate
            } else {
                if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    output.append(current)
                }
                if piece.count <= maxCharacters {
                    current = piece
                } else {
                    let hardPieces = splitPlainText(piece, maxCharacters: maxCharacters)
                    output.append(contentsOf: hardPieces.dropLast())
                    current = hardPieces.last ?? ""
                }
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            output.append(current)
        }
        return output.isEmpty ? [block] : output
    }

    private func markdownBlocks(from text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [String] = []
        var current: [String] = []

        for line in lines {
            if isMarkdownHeading(line), !current.isEmpty {
                let block = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !block.isEmpty {
                    blocks.append(block)
                }
                current = [line]
            } else {
                current.append(line)
            }
        }

        let finalBlock = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalBlock.isEmpty {
            blocks.append(finalBlock)
        }

        if blocks.count <= 1 {
            return text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        return blocks
    }

    private func isMarkdownHeading(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return false }
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), trimmed.count > hashes else { return false }
        let index = trimmed.index(trimmed.startIndex, offsetBy: hashes)
        return trimmed[index].isWhitespace
    }

    private func isMajorMarkdownHeading(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("# ") || trimmed.hasPrefix("## ") else { return false }
        let title = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
        if title.contains("目录") || title.uppercased().contains("CONTENTS") {
            return true
        }
        if title.range(of: #"^第[一二三四五六七八九十百零〇0-9]+[章节篇部卷]"#, options: .regularExpression) != nil {
            return true
        }
        return ["前言", "序", "导读", "引言", "绪论", "结语", "后记", "译后记", "附录"].contains { title.hasPrefix($0) }
    }

    private func hardSplit(_ text: String, maxCharacters: Int) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if current.count >= maxCharacters {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    private func buildMarkdownChunkContexts(_ chunks: [String]) -> [String] {
        var activeMajorHeading = ""
        return chunks.enumerated().map { index, chunk in
            let headings = markdownHeadings(in: chunk)
            if let major = headings.first(where: { isMajorMarkdownHeading($0.raw) }) {
                activeMajorHeading = major.clean
            }
            let visibleHeadings = headings.prefix(8).map(\.clean).joined(separator: "；")
            var lines = [
                "当前块编号：\(index + 1) / \(chunks.count)",
                "当前章/大节：\(activeMajorHeading.isEmpty ? "未检测到明确章节，请谨慎保留可疑标题" : activeMajorHeading)"
            ]
            if !visibleHeadings.isEmpty {
                lines.append("当前块内标题：\(visibleHeadings)")
            }
            lines.append("页眉污染判断时，请优先把“当前章/大节”和“当前块内标题”作为上下文；不确定是否为正文时保留原文。")
            return lines.joined(separator: "\n")
        }
    }

    private func markdownChunkContext(for index: Int) -> String {
        guard outputFormatCode == "md",
              index >= 0,
              index < chunkContexts.count,
              !chunkContexts[index].isEmpty else {
            return "当前块上下文：未检测到明确 Markdown 标题，请谨慎处理。"
        }
        return chunkContexts[index]
    }

    private func markdownHeadings(in text: String) -> [(raw: String, clean: String)] {
        text.components(separatedBy: "\n").compactMap { line in
            guard isMarkdownHeading(line) else { return nil }
            let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return (raw: line, clean: clean)
        }
    }

    private func normalizedEndpoint() -> URL? {
        guard let raw = nonEmpty(apiURLField.stringValue) else { return nil }
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.hasSuffix("chat/completions") {
            if !value.hasSuffix("/") {
                value += "/"
            }
            if value.hasSuffix("/v1/") {
                value += "chat/completions"
            } else {
                value += "v1/chat/completions"
            }
        }
        return URL(string: value)
    }

    private func nextOutputURL(for input: URL, format: FormatOption) -> URL {
        let directory = input.deletingLastPathComponent()
        let stem = input.deletingPathExtension().lastPathComponent
        var candidate = directory.appendingPathComponent(stem + format.suffix)
        var index = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent(stem + "_ai_reflow_\(index).\(format.code)")
            index += 1
        }
        return candidate
    }

    private func prompt(for formatCode: String) -> String {
        if formatCode == "md" {
            return """
            你是 OCR 中文书籍 Markdown 排版清理助手。用户给你的文本通常来自 MinerU 输出的 .md 文件。请只做排版与格式清理，只输出清理后的 Markdown，不要解释、不要改写正文、不要总结。

            你收到的通常只是整本书的一块文本。App 会尽量按目录、前言、章节、结语、译后记等边界分块，并在用户消息开头注明当前块编号、当前章/大节和当前块内标题。请只处理当前块实际出现的内容，不要补写其他块的目录或正文。

            文件结构通常按顺序分为四部分：
            1. 书名页/版权页：文件开头，含书名、作者、译者、出版社、ISBN、CIP、定价等。保持原样，只清理明显乱码和重复行。
            2. 目录/目次/CONTENTS：以 # 目录、# 外科医生手记 目录 或类似标题开头，到第一个正文自然段之前结束。这是重点整理区域。
            3. 正文：从第一个正文自然段开始，直到真正书末。
            4. OCR 尾部垃圾：真正书末之后的 Document generated by、Images have been losslessly、Information about the original file、含 pdg_main_pages_found / sha1 / filename / header_md5 的 JSON 或元数据段，全部删除。

            标题层级：
            1. # 用于章标题，例如 # 第一章 绞痛的心。
            2. ## 用于前言、导读、结语、译后记、附录等独立大节。
            3. ### 用于章内小节。
            4. 如果原文章内小节使用 ##，在能确认其属于某章时统一降级为 ###。

            目录区域规则：
            1. 把目录整理成有层级的 Markdown 列表，保留章节顺序、标题文字和页码信息。
            2. 页码统一为“条目 / 页码”，例如 - 第一章 绞痛的心 / 1。
            3. 前言、各章、结语、译后记等为一级条目；章内小节为二级条目，使用 4 个空格缩进。
            4. 删除目录中的点线、制表符、错乱换行、无效图片链接和 HTML 残留。
            5. 仅在目录条目名称中校正极明显 OCR 错字；不确定的保留原字。

            正文标题与页眉污染规则：
            1. 删除正文中孤立出现的章名或小节名页眉污染，例如裸文本“第一章 绞痛的心”或“第七章 爱的行为”。
            2. 删除紧接页码的标题行，以及同一章节标题在正文中反复出现的页眉。
            3. 如果标题夹在段落中间打断句子，删掉标题后把前后文字拼接成完整段落。
            4. 保留真正的章节标题和小节标题；只有在当前块证据充分时补全或统一层级，不确定则保留原文。
            5. 判断页眉污染时优先参考用户消息中的“当前章/大节”和“当前块内标题”，不要把正文中提到的其他章名误删。
            6. 只修正标题和目录中的明显 OCR 错字，不主动校正文中的普通 OCR 错字。

            正文轻量格式修复：
            1. 删除无效图片链接，例如 ![](images/...)。
            2. 删除 <table>...</table> 等 HTML 残留。
            3. 删除正文中单独一行、无上下文的纯数字页码。
            4. 删除上述垃圾后如造成段落断裂，必须修复。
            5. 段落间保留一个空行；不合并、不拆分正常自然段落；不改变正文顺序；不删除正文段落。

            禁止项：
            不改写正文。
            不润色正文。
            不扩写、概括或翻译。
            不添加解释、评论或处理报告。
            不使用代码块围栏。
            如果不确定某个片段是正文还是页眉污染，优先保留原文，不要臆造。

            目录示例：
            输入：
            # 外科医生手记 目录

            前言/1选择属于自己的死亡

            第一章 纹痛的心/1

            面对死亡 6
            缺血的心脏 8

            输出：
            # 外科医生手记 目录

            - 前言：选择属于自己的死亡 / 1
            - 第一章 绞痛的心 / 1
                - 面对死亡 / 6
                - 缺血的心脏 / 8

            页眉污染示例：
            输入：
            这时病房内只有我与麦卡提的尸体。我望着他那呆滞的眼神......

            第一章 绞痛的心

            口涌出的污黑血液。我哭了......

            输出：
            这时病房内只有我与麦卡提的尸体。我望着他那呆滞的眼神......口涌出的污黑血液。我哭了......

            处理顺序：
            1. 清理书名页/版权页。
            2. 整理目录为层级列表。
            3. 扫描正文，删除页眉污染并修复段落断裂。
            4. 根据当前块证据，在证据充分时补全缺失的 # 第 X 章 总标题。
            5. 统一标题层级：# 章节，## 前言/结语/译后记，### 小节。
            6. 删除无效图片链接、HTML 残留、孤立页码和尾部 OCR 垃圾。

            输出要求：
            只输出当前块整理后的 Markdown。
            段落之间保留一个空行。
            """
        }
        return """
        你是一名中文图书排版校对员。请把用户提供的 OCR 纯文本或 Markdown 文本重排成干净、通顺、符合中文阅读习惯的正文。

        任务：
        1. 清除汉字之间被错误插入的空格。
        2. 合并被 OCR 错误切断的句子和段落，把独占一行的标点归回前后文。
        3. 按原书自然段落分段：同一逻辑段落合并为连续段落，段落之间用一个空行隔开。
        4. 保留章节标题、小标题，并让它们单独成行。
        5. 删除明显的页眉、页脚、孤立页码、PDF 提取垃圾、文件名、sha1、pdg_main_pages_found、Document generated by Anna's Archive 等无关内容。
        6. 中文语境中的半角标点可改为全角标点；英文单词、数字、小数点和英文缩写保持原样。
        7. 只校正非常明显的 OCR 错字；不确定的字词必须保留原样。
        8. 保持原文顺序、内容和语气，不增删、不翻译、不概括、不改写。

        输出要求：
        只输出排版后的正文。
        段落之间用一个空行隔开。
        不要代码块、不要 Markdown、不要解释、不要评论。
        """
    }

    private var processHasActiveWork: Bool {
        requestTask != nil || (checkpointURL != nil && nextChunkIndex < chunks.count)
    }

    private func resumeStateURL(for input: URL, formatCode: String) -> URL {
        let stem = input.deletingPathExtension().lastPathComponent
        return input.deletingLastPathComponent()
            .appendingPathComponent("\(stem)_ai_reflow.\(formatCode).resume.json")
    }

    private func loadResumeState(for input: URL) {
        availableResumeState = nil
        checkpointURL = nil
        for format in formatOptions {
            let candidate = resumeStateURL(for: input, formatCode: format.code)
            guard let data = try? Data(contentsOf: candidate),
                  let state = try? JSONDecoder().decode(ResumeState.self, from: data),
                  state.inputPath == input.standardizedFileURL.path,
                  state.nextChunkIndex >= 0,
                  state.nextChunkIndex < state.totalChunks else {
                continue
            }
            availableResumeState = state
            checkpointURL = candidate
            if let index = formatOptions.firstIndex(where: { $0.code == state.formatCode }) {
                formatPopup.selectItem(at: index)
            }
            statusLabel.stringValue = "发现未完成任务：已完成 \(state.nextChunkIndex) / \(state.totalChunks) 块，可继续"
            outputLabel.stringValue = "断点文件：\(candidate.lastPathComponent)"
            updateControls(isRunning: false)
            return
        }
        updateControls(isRunning: false)
    }

    private func persistCheckpoint() {
        guard let inputURL,
              let outputURL,
              let checkpointURL,
              let attributes = try? fileManager.attributesOfItem(atPath: inputURL.path),
              let byteCount = attributes[.size] as? UInt64,
              let modificationDate = attributes[.modificationDate] as? Date else {
            return
        }
        let state = ResumeState(
            inputPath: inputURL.standardizedFileURL.path,
            inputByteCount: byteCount,
            inputModificationTime: modificationDate.timeIntervalSince1970,
            outputPath: outputURL.path,
            formatCode: outputFormatCode,
            chunkSize: Int(chunkSizeField.stringValue) ?? 8000,
            totalChunks: chunks.count,
            nextChunkIndex: nextChunkIndex,
            results: results
        )
        availableResumeState = state
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: checkpointURL, options: .atomic)
    }

    private func cleanupCheckpoint() {
        if let checkpointURL {
            try? fileManager.removeItem(at: checkpointURL)
        }
        checkpointURL = nil
    }

    private func cleanupResumeArtifacts() {
        if let partURL {
            try? fileManager.removeItem(at: partURL)
        } else if let availableResumeState {
            let savedPartURL = URL(fileURLWithPath: availableResumeState.outputPath).appendingPathExtension("part")
            try? fileManager.removeItem(at: savedPartURL)
        }
        cleanupCheckpoint()
    }

    private func cleanupPartFile() {
        if let partURL {
            try? fileManager.removeItem(at: partURL)
        }
        partURL = nil
    }

    private func appendLog(_ message: String) {
        let current = logView.string
        logView.string = String((current + message + "\n").suffix(12000))
        logView.scrollToEndOfDocument(nil)
    }

    private func showFailure(_ message: String) {
        statusLabel.stringValue = message
        statusLabel.textColor = .systemRed
        appendLog(message)
    }

    private func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func apiErrorMessage(from data: Data) -> String {
        if let decoded = try? JSONDecoder().decode(APIErrorResponse.self, from: data),
           let message = decoded.error?.message,
           !message.isEmpty {
            return message
        }
        return String(data: data, encoding: .utf8) ?? "未知错误"
    }

    private func chunkHeadingSummary(_ chunk: String) -> String {
        let headings = chunk
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("#") }
            .prefix(6)
        return headings.isEmpty ? "未检测到 Markdown 标题" : headings.joined(separator: "；")
    }

    private func loadSavedAPIKey() {
        let defaults = UserDefaults.standard
        let legacyDefaults = UserDefaults(suiteName: legacySettingsDomain)
        if let value = defaults.string(forKey: settingsAPIKeyKey)
            ?? legacyDefaults?.string(forKey: settingsAPIKeyKey) {
            apiKeyField.stringValue = value
        }
    }

    private func saveAPIKey(_ value: String) {
        UserDefaults.standard.set(value, forKey: settingsAPIKeyKey)
    }

    private func loadSavedSettings() {
        let defaults = UserDefaults.standard
        let legacyDefaults = UserDefaults(suiteName: legacySettingsDomain)
        if let apiURL = defaults.string(forKey: settingsAPIURLKey)
            ?? legacyDefaults?.string(forKey: settingsAPIURLKey),
           !apiURL.isEmpty {
            apiURLField.stringValue = apiURL
        }
        if let model = defaults.string(forKey: settingsModelKey)
            ?? legacyDefaults?.string(forKey: settingsModelKey),
           !model.isEmpty {
            modelField.stringValue = model
        }
        if let chunkSize = defaults.string(forKey: settingsChunkSizeKey)
            ?? legacyDefaults?.string(forKey: settingsChunkSizeKey),
           !chunkSize.isEmpty {
            chunkSizeField.stringValue = chunkSize
        }
        if let formatCode = defaults.string(forKey: settingsFormatCodeKey)
            ?? legacyDefaults?.string(forKey: settingsFormatCodeKey),
           let index = formatOptions.firstIndex(where: { $0.code == formatCode }) {
            formatPopup.selectItem(at: index)
        }
    }

    private func saveSettings(format: FormatOption, chunkSize: Int) {
        let defaults = UserDefaults.standard
        defaults.set(apiURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: settingsAPIURLKey)
        defaults.set(modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: settingsModelKey)
        defaults.set(String(chunkSize), forKey: settingsChunkSizeKey)
        defaults.set(format.code, forKey: settingsFormatCodeKey)
    }

}

private final class AIReflowAppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: AIReflowWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        windowController = AIReflowWindowController()
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
