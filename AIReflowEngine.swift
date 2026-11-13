import AppKit
import Foundation

private let settingsAPIURLKey = "apiURL"
private let settingsModelKey = "model"
private let settingsChunkSizeKey = "chunkSize"
private let settingsFormatCodeKey = "formatCode"
private let settingsAPIKeyKey = "apiKey"
private let legacySettingsDomain = "local.codex.ai-txt-reflow"

struct AIFormatOption {
    let title: String
    let code: String
    let suffix: String
}

let aiFormatOptions = [
    AIFormatOption(title: "TXT（AI 重排）", code: "txt", suffix: "_ai_reflow.txt"),
    AIFormatOption(title: "MD（AI Markdown 排版）", code: "md", suffix: "_ai_reflow.md")
]

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

final class AIReflowEngine {
    private let fileManager = FileManager.default
    private var inputURL: URL?
    private(set) var outputURL: URL?
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

    // 与录制设置一一对应，由内嵌界面同步进来
    var apiURLString = "https://api.openai.com/v1/chat/completions"
    var modelString = "gpt-4o-mini"
    var apiKeyString = ""
    var chunkSize = 8000
    var formatCode = "txt"

    private(set) var isProcessing = false

    var onStatus: ((String, NSColor) -> Void)?
    var onProgress: ((Double) -> Void)?
    var onProgressLabel: ((String) -> Void)?
    var onOutput: ((String) -> Void)?
    var onLog: ((String) -> Void)?
    var onStateChange: (() -> Void)?
    var onResumeStateChanged: (() -> Void)?

    var isRunning: Bool { isProcessing }
    var resumeAvailable: Bool { availableResumeState != nil }
    var resumeCompletedChunks: Int { availableResumeState?.nextChunkIndex ?? 0 }
    var resumeTotalChunks: Int { availableResumeState?.totalChunks ?? 0 }
    var resumeFormatCode: String? { availableResumeState?.formatCode }
    var resumeChunkSize: Int? { availableResumeState?.chunkSize }

    init() {
        loadSavedSettings()
        loadSavedAPIKey()
    }

    deinit {
        requestTask?.cancel()
    }

    // MARK: - Public actions

    @discardableResult
    func start(input: URL) -> String? {
        guard requestTask == nil, !isProcessing else { return "AI 排版正在进行中" }
        if availableResumeState != nil {
            return "检测到未完成任务，请先「继续未完成」；如需重新开始，请先清理断点。"
        }
        guard let endpoint = normalizedEndpoint() else { return "请填写有效的 API 地址" }
        guard let model = nonEmpty(modelString) else { return "请填写模型" }
        guard let apiKey = nonEmpty(apiKeyString) else { return "请填写 API Key" }
        guard (1000...30000).contains(chunkSize) else { return "分块字符数应在 1000 到 30000 之间" }
        guard let format = aiFormatOptions.first(where: { $0.code == formatCode }) else { return "请选择输出格式" }
        guard let text = try? String(contentsOf: input, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "无法读取 TXT / MD，或文件内容为空"
        }

        saveAPIKey(apiKey)
        saveSettings()
        inputURL = input.standardizedFileURL
        let inputIsMarkdown = isMarkdownInput(input)
        chunks = splitText(text, maxCharacters: chunkSize, preferMarkdownBoundaries: inputIsMarkdown)
        chunkContexts = inputIsMarkdown ? buildMarkdownChunkContexts(chunks) : []
        results = Array(repeating: "", count: chunks.count)
        totalCharacters = text.count
        nextChunkIndex = 0
        outputFormatCode = format.code
        isCancelling = false
        outputURL = nextOutputURL(for: input, format: format)
        partURL = outputURL?.appendingPathExtension("part")
        checkpointURL = resumeStateURL(for: input, formatCode: format.code)
        availableResumeState = nil

        guard let outputURL, let partURL else { return "无法创建输出路径" }
        try? "".write(to: partURL, atomically: true, encoding: .utf8)
        persistCheckpoint()

        isProcessing = true
        onStateChange?()
        onProgress?(0)
        onProgressLabel?("0 / \(chunks.count) 块")
        onStatus?("正在准备 AI 排版...", .labelColor)
        onOutput?("完成后会显示保存位置")
        let chunkMode = inputIsMarkdown ? "Markdown 标题/段落边界" : "普通段落边界"
        onLog?("输入字符数：\(totalCharacters)")
        onLog?("分块数量：\(chunks.count)")
        onLog?("分块方式：\(chunkMode)")
        onLog?("输出文件：\(outputURL.lastPathComponent)")
        onLog?("每完成一块都会保存断点。")
        processNextChunk(endpoint: endpoint, model: model, apiKey: apiKey)
        return nil
    }

    @discardableResult
    func resume() -> String? {
        guard requestTask == nil, !isProcessing, let state = availableResumeState else {
            return "没有可继续的断点"
        }
        let sourceURL = URL(fileURLWithPath: state.inputPath)
        guard fileManager.fileExists(atPath: sourceURL.path) else { return "找不到断点对应的输入文件" }
        guard let endpoint = normalizedEndpoint() else { return "请填写有效的 API 地址" }
        guard let model = nonEmpty(modelString) else { return "请填写模型" }
        guard let apiKey = nonEmpty(apiKeyString) else { return "请填写 API Key" }
        guard let text = try? String(contentsOf: sourceURL, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "无法读取断点对应的输入文件"
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: sourceURL.path),
              let byteCount = attributes[.size] as? UInt64,
              let modificationDate = attributes[.modificationDate] as? Date,
              byteCount == state.inputByteCount,
              abs(modificationDate.timeIntervalSince1970 - state.inputModificationTime) < 1 else {
            return "输入文件已经改变，不能安全继续；请重新开始排版"
        }

        formatCode = state.formatCode
        chunkSize = state.chunkSize
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
            return "输入文件的分块方式已经变化，不能安全继续；请重新开始排版"
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
        guard let partURL else { return "找不到断点临时文件路径" }
        try? results.prefix(nextChunkIndex).joined(separator: "\n\n")
            .appending(nextChunkIndex > 0 ? "\n\n" : "")
            .write(to: partURL, atomically: true, encoding: .utf8)

        isProcessing = true
        onStateChange?()
        onProgress?(Double(nextChunkIndex) / Double(max(chunks.count, 1)) * 100)
        onProgressLabel?("\(nextChunkIndex) / \(chunks.count) 块")
        onStatus?("继续处理：从第 \(nextChunkIndex + 1) / \(chunks.count) 块开始", .labelColor)
        onOutput?("断点产物：\(outputURL?.lastPathComponent ?? "")")
        onLog?("已恢复断点：已完成 \(nextChunkIndex) / \(chunks.count) 块")
        onLog?("将只重新请求未完成的块。")
        processNextChunk(endpoint: endpoint, model: model, apiKey: apiKey)
        return nil
    }

    @discardableResult
    func skipChunkAndContinue() -> String? {
        guard requestTask == nil, !isProcessing, let state = availableResumeState else {
            return "没有可跳过的断点"
        }
        let sourceURL = URL(fileURLWithPath: state.inputPath)
        guard fileManager.fileExists(atPath: sourceURL.path) else { return "找不到断点对应的输入文件" }
        guard let endpoint = normalizedEndpoint() else { return "请填写有效的 API 地址" }
        guard let model = nonEmpty(modelString) else { return "请填写模型" }
        guard let apiKey = nonEmpty(apiKeyString) else {
            return "请填写 API 地址、模型和 API Key，跳过当前块后才能继续处理后续块"
        }
        guard let text = try? String(contentsOf: sourceURL, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "无法读取断点对应的输入文件"
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: sourceURL.path),
              let byteCount = attributes[.size] as? UInt64,
              let modificationDate = attributes[.modificationDate] as? Date,
              byteCount == state.inputByteCount,
              abs(modificationDate.timeIntervalSince1970 - state.inputModificationTime) < 1 else {
            return "输入文件已经改变，不能安全跳过；请重新开始排版"
        }
        guard state.nextChunkIndex < state.totalChunks else { return "断点已经没有可跳过的块" }

        formatCode = state.formatCode
        chunkSize = state.chunkSize
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
            return "输入文件的分块方式已经变化，不能安全跳过；请重新开始排版"
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
        saveSettings()
        persistPartialResult()

        isProcessing = true
        onStateChange?()
        onProgress?(Double(nextChunkIndex) / Double(max(chunks.count, 1)) * 100)
        onProgressLabel?("正在 \(min(nextChunkIndex + 1, chunks.count)) / \(chunks.count) 块")
        onStatus?("已用原文保留第 \(skippedIndex + 1) 块，继续处理后续块...", .labelColor)
        onOutput?("断点产物：\(outputURL?.lastPathComponent ?? "")")
        onLog?("第 \(skippedIndex + 1) 块已跳过，已用原文保留：\(chunkHeadingSummary(chunks[skippedIndex]))")

        if nextChunkIndex >= chunks.count {
            finishSuccessfully()
        } else {
            processNextChunk(endpoint: endpoint, model: model, apiKey: apiKey)
        }
        return nil
    }

    func cancelOrCleanup() {
        if requestTask == nil && !isProcessing {
            guard availableResumeState != nil else { return }
            cleanupResumeArtifacts()
            availableResumeState = nil
            onStatus?("未完成任务和临时产物已清理", .systemOrange)
            onOutput?("本次断点已删除，可以重新开始")
            onProgressLabel?("")
            onStateChange?()
            onResumeStateChanged?()
            return
        }
        isCancelling = true
        requestTask?.cancel()
        requestTask = nil
        cleanupResumeArtifacts()
        availableResumeState = nil
        isProcessing = false
        onStatus?("已取消，未完成产物已清理", .systemOrange)
        onProgressLabel?("")
        onStateChange?()
        onResumeStateChanged?()
    }

    func loadResumeState(for input: URL?) {
        availableResumeState = nil
        checkpointURL = nil
        if let input {
            for format in aiFormatOptions {
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
                break
            }
        }
        onStateChange?()
        onResumeStateChanged?()
    }

    func shutdownForTermination() {
        let hadActiveRequest = requestTask != nil || isProcessing
        isCancelling = true
        requestTask?.cancel()
        requestTask = nil
        if hadActiveRequest || processHasActiveWork {
            persistCheckpoint()
        }
        isProcessing = false
    }

    // MARK: - Networking

    private func processNextChunk(endpoint: URL, model: String, apiKey: String) {
        guard !isCancelling, nextChunkIndex < chunks.count else {
            if !isCancelling {
                finishSuccessfully()
            }
            return
        }

        let index = nextChunkIndex
        let text = chunks[index]
        onStatus?("AI 正在重排第 \(index + 1) / \(chunks.count) 块...", .labelColor)
        onProgressLabel?("正在 \(index + 1) / \(chunks.count) 块")

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
                        self.onLog?("接口原始错误：\(message)")
                        self.onLog?("失败块标题：\(self.chunkHeadingSummary(self.chunks[index]))")
                    } else {
                        self.fail(message)
                    }
                    return
                }
                do {
                    let result = try JSONDecoder().decode(ChatResponse.self, from: data)
                    guard let content = result.choices.first?.message.content?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                          !content.isEmpty else {
                        self.fail("API 返回中没有可用文本")
                        return
                    }
                    self.results[index] = content
                    self.nextChunkIndex += 1
                    self.persistPartialResult()
                    self.onLog?("第 \(index + 1) 块完成，\(content.count) 字符")
                    self.onProgress?(Double(self.nextChunkIndex) / Double(max(self.chunks.count, 1)) * 100)
                    self.onProgressLabel?("\(self.nextChunkIndex) / \(self.chunks.count) 块")
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
            isProcessing = false
            onProgress?(100)
            onProgressLabel?("\(chunks.count) / \(chunks.count) 块")
            onStatus?("AI 排版完成", .systemGreen)
            self.outputURL = outputURL
            onOutput?("产物位置：\(outputURL.path)")
            onStateChange?()
            onResumeStateChanged?()
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
        isProcessing = false
        onStatus?(message, .systemRed)
        onLog?("\(message)\n已保留已完成块，可点击「继续未完成」重试当前失败块。")
        onOutput?("断点已保留：已完成 \(nextChunkIndex) / \(chunks.count) 块")
        loadResumeState(for: inputURL)
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

    private func normalizedEndpoint() -> URL? {
        guard let raw = nonEmpty(apiURLString) else { return nil }
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

    private func nextOutputURL(for input: URL, format: AIFormatOption) -> URL {
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

    private func resumeStateURL(for input: URL, formatCode: String) -> URL {
        let stem = input.deletingPathExtension().lastPathComponent
        return input.deletingLastPathComponent()
            .appendingPathComponent("\(stem)_ai_reflow.\(formatCode).resume.json")
    }

    private func isMarkdownInput(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
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
            chunkSize: chunkSize,
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

    // MARK: - Saved settings

    private func loadSavedAPIKey() {
        let defaults = UserDefaults.standard
        let legacyDefaults = UserDefaults(suiteName: legacySettingsDomain)
        if let value = defaults.string(forKey: settingsAPIKeyKey)
            ?? legacyDefaults?.string(forKey: settingsAPIKeyKey) {
            apiKeyString = value
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
            apiURLString = apiURL
        }
        if let model = defaults.string(forKey: settingsModelKey)
            ?? legacyDefaults?.string(forKey: settingsModelKey),
           !model.isEmpty {
            modelString = model
        }
        if let chunkSizeValue = defaults.string(forKey: settingsChunkSizeKey)
            ?? legacyDefaults?.string(forKey: settingsChunkSizeKey),
           let value = Int(chunkSizeValue) {
            chunkSize = value
        }
        if let code = defaults.string(forKey: settingsFormatCodeKey)
            ?? legacyDefaults?.string(forKey: settingsFormatCodeKey),
           aiFormatOptions.contains(where: { $0.code == code }) {
            formatCode = code
        }
    }

    private func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(apiURLString.trimmingCharacters(in: .whitespacesAndNewlines), forKey: settingsAPIURLKey)
        defaults.set(modelString.trimmingCharacters(in: .whitespacesAndNewlines), forKey: settingsModelKey)
        defaults.set(String(chunkSize), forKey: settingsChunkSizeKey)
        defaults.set(formatCode, forKey: settingsFormatCodeKey)
    }
}
