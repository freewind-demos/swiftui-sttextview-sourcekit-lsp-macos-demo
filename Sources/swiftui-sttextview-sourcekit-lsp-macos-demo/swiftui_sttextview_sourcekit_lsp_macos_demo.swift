import AppKit
import Foundation
import STTextViewSwiftUI
import SwiftUI

private enum CodeSampleKind: String, CaseIterable, Identifiable {
    case swift = "Swift"
    case javascript = "JavaScript"

    var id: String { rawValue }

    var sampleCode: String {
        switch self {
        case .swift:
            swiftSampleCode
        case .javascript:
            javaScriptSampleCode
        }
    }

    var supportsSourceKit: Bool {
        self == .swift
    }
}

private let swiftSampleCode = """
import Foundation

struct UserFormatter {
    let prefix: String

    func render(_ user: String) -> String {
        "\\(prefix)-\\(user)"
    }
}

let title = ["Freewind", "LSP", "Swift"]
    .map(UserFormatter(prefix: "user").render)
    .filter { $0.contains("i") }
    .joined(separator: " / ")
    .lowercased()

print(title)
"""

private let javaScriptSampleCode = """
const renderUser = (value) => `user-${value}`

const title = ["freewind", "lsp", "swift"]
  .map(renderUser)
  .filter((value) => value.includes("i"))
  .join(" / ")
  .toLowerCase()

console.log(title)
"""

@main
struct STTextViewSourceKitLSPDemoApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1280, height: 820)
    }
}

private struct ContentView: View {
    @State private var sampleKind: CodeSampleKind = .swift
    @State private var text = SwiftSyntaxHighlighter.highlight(swiftSampleCode)
    @State private var plainText = swiftSampleCode
    @State private var selection: NSRange? = NSRange(location: 0, length: 0)
    @State private var line = 8
    @State private var column = 10
    @StateObject private var lspClient = SourceKitLSPClient()

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Picker("代码", selection: $sampleKind) {
                    ForEach(CodeSampleKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .frame(width: 150)
                .onChange(of: sampleKind) { _, newValue in
                    loadSample(for: newValue)
                }

                Button("加载示例") {
                    loadSample(for: sampleKind)
                }

                Button("请求补全") {
                    lspClient.requestCompletions(line: line, column: column)
                }
                .disabled(!sampleKind.supportsSourceKit)

                Button("Duplicate 当前行 (⌘D)") {
                    duplicateCurrentLine()
                }
                .keyboardShortcut("d", modifiers: [.command])

                Button("扩选父节点 (⌘E)") {
                    expandSelection()
                }
                .keyboardShortcut("e", modifiers: [.command])

                Text(lspClient.status)
                    .foregroundStyle(.secondary)

                Spacer()
            }

            HSplitView {
                STTextViewSwiftUI.TextView(
                    text: $text,
                    selection: $selection,
                    options: [.wrapLines, .highlightSelectedLine, .showLineNumbers]
                )
                .textViewFont(.monospacedSystemFont(ofSize: 14, weight: .regular))
                .frame(minWidth: 780, maxWidth: .infinity, maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 12) {
                    Stepper("行 \(line)", value: $line, in: 1...200)
                    Stepper("列 \(column)", value: $column, in: 1...200)

                    Text("Diagnostics")
                        .font(.headline)

                    List(lspClient.diagnostics) { item in
                        Text(item.summary)
                    }
                    .frame(minHeight: 180)

                    Text("Completions")
                        .font(.headline)

                    List(lspClient.completions, id: \.self) { item in
                        Text(item)
                    }
                }
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 420, maxHeight: .infinity)
            }
        }
        .padding(16)
        .onAppear {
            lspClient.start(text: plainText)
        }
        .onDisappear {
            lspClient.stop()
        }
        .onChange(of: text) { _, newValue in
            let newPlainText = String(newValue.characters)
            guard newPlainText != plainText else {
                return
            }

            plainText = newPlainText
            text = SwiftSyntaxHighlighter.highlight(newPlainText)
            lspClient.updateDocument(text: newPlainText)
        }
    }

    private func duplicateCurrentLine() {
        let result = duplicateCurrentLineInText(
            in: plainText,
            selection: selection ?? NSRange(location: 0, length: 0)
        )
        plainText = result.text
        text = SwiftSyntaxHighlighter.highlight(result.text)
        selection = result.selection
        lspClient.updateDocument(text: result.text)
    }

    private func expandSelection() {
        let currentSelection = selection ?? NSRange(location: 0, length: 0)
        lspClient.requestSelectionExpansion(text: plainText, selection: currentSelection) { expandedSelection in
            guard let expandedSelection else {
                return
            }
            selection = expandedSelection
        }
    }

    private func loadSample(for kind: CodeSampleKind) {
        plainText = kind.sampleCode
        text = SwiftSyntaxHighlighter.highlight(kind.sampleCode)
        selection = NSRange(location: 0, length: 0)
        line = 1
        column = 1

        if kind.supportsSourceKit {
            lspClient.start(text: kind.sampleCode)
        } else {
            lspClient.stop()
            lspClient.status = "当前是 JavaScript 示例，sourcekit-lsp 不支持"
            lspClient.diagnostics = []
            lspClient.completions = []
        }
    }
}

private func duplicateCurrentLineInText(in text: String, selection: NSRange) -> (text: String, selection: NSRange) {
    let nsText = text as NSString
    let location = min(selection.location, nsText.length)
    let lineRange = nsText.lineRange(for: NSRange(location: location, length: 0))
    let lineText = nsText.substring(with: lineRange)
    let insertionText =
        lineRange.upperBound == nsText.length && !lineText.hasSuffix("\n")
        ? "\n" + lineText
        : lineText
    let insertedLength = (insertionText as NSString).length
    let updatedText = nsText.replacingCharacters(
        in: NSRange(location: lineRange.upperBound, length: 0),
        with: insertionText
    )

    return (
        text: updatedText,
        selection: NSRange(location: location + insertedLength, length: selection.length)
    )
}

private struct DiagnosticItem: Identifiable {
    let id = UUID()
    let severity: Int
    let line: Int
    let column: Int
    let message: String

    var summary: String {
        "[\(severityLabel)] L\(line):C\(column) \(message)"
    }

    private var severityLabel: String {
        switch severity {
        case 1:
            "error"
        case 2:
            "warning"
        case 3:
            "info"
        default:
            "hint"
        }
    }
}

private enum SwiftSyntaxHighlighter {
    private static let keywordRegex = try? NSRegularExpression(
        pattern: #"\b(import|struct|class|enum|protocol|func|let|var|if|else|for|while|return|switch|case|default|extension|guard|in)\b"#
    )
    private static let stringRegex = try? NSRegularExpression(pattern: #""[^"]*""#)

    static func highlight(_ text: String) -> AttributedString {
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let value = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.textColor,
            ]
        )

        keywordRegex?.matches(in: text, range: fullRange).forEach {
            value.addAttribute(.foregroundColor, value: NSColor.systemPink, range: $0.range)
        }

        stringRegex?.matches(in: text, range: fullRange).forEach {
            value.addAttribute(.foregroundColor, value: NSColor.systemGreen, range: $0.range)
        }

        return AttributedString(value)
    }
}

private final class SourceKitLSPClient: ObservableObject, @unchecked Sendable {
    @Published var diagnostics: [DiagnosticItem] = []
    @Published var completions: [String] = []
    @Published var status = "准备启动 sourcekit-lsp"

    private let queue = DispatchQueue(label: "sourcekit-lsp-client")
    private let executableURL = URL(
        fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp"
    )

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var buffer = Data()
    private var nextID = 1
    private var didOpenDocument = false
    private var fileURL: URL?
    private var workspaceURL: URL?
    private var handlers: [Int: (Any?) -> Void] = [:]

    func start(text: String) {
        queue.async {
            if self.process == nil {
                self.boot(text: text)
            } else {
                self.writeWorkspaceFile(text: text)
                if self.didOpenDocument {
                    self.sendDidChange(text: text)
                }
            }
        }
    }

    func updateDocument(text: String) {
        queue.async {
            self.writeWorkspaceFile(text: text)
            guard self.didOpenDocument else {
                return
            }

            self.sendDidChange(text: text)
        }
    }

    func requestCompletions(line: Int, column: Int) {
        queue.async {
            guard let fileURL = self.fileURL else {
                DispatchQueue.main.async {
                    self.status = "LSP 尚未就绪"
                }
                return
            }

            self.sendRequest(
                method: "textDocument/completion",
                params: [
                    "textDocument": ["uri": fileURL.absoluteString],
                    "position": [
                        "line": max(line - 1, 0),
                        "character": max(column - 1, 0),
                    ],
                    "context": ["triggerKind": 1],
                ]
            ) { result in
                let labels = Self.extractCompletionLabels(result)
                DispatchQueue.main.async {
                    self.completions = labels
                    self.status = labels.isEmpty ? "completion 为空" : "completion 返回 \(labels.count) 项"
                }
            }
        }
    }

    func requestSelectionExpansion(
        text: String,
        selection: NSRange,
        handler: @escaping @MainActor @Sendable (NSRange?) -> Void
    ) {
        queue.async {
            guard let fileURL = self.fileURL else {
                Task { @MainActor in
                    self.status = "LSP 尚未就绪"
                    handler(nil)
                }
                return
            }

            let position = Self.makeSelectionPosition(in: text, selection: selection)
            self.sendRequest(
                method: "textDocument/selectionRange",
                params: [
                    "textDocument": ["uri": fileURL.absoluteString],
                    "positions": [
                        [
                            "line": position.line,
                            "character": position.character,
                        ],
                    ],
                ]
            ) { result in
                let ranges = Self.extractSelectionRanges(result, text: text)
                let nextSelection = Self.nextSelectionRange(from: ranges, current: selection, text: text)
                Task { @MainActor in
                    self.status = nextSelection == nil ? "无更大 LSP 节点" : "已扩选到更大 LSP 节点"
                    handler(nextSelection)
                }
            }
        }
    }

    func stop() {
        queue.sync {
            handlers.removeAll()
            outputPipe?.fileHandleForReading.readabilityHandler = nil
            process?.terminate()
            process = nil
            inputPipe = nil
            outputPipe = nil
            didOpenDocument = false
            buffer = Data()
        }
    }

    private func boot(text: String) {
        do {
            try prepareWorkspace(text: text)

            let process = Process()
            process.executableURL = executableURL
            process.currentDirectoryURL = workspaceURL

            let inputPipe = Pipe()
            let outputPipe = Pipe()
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    return
                }
                guard let self else {
                    return
                }
                self.queue.async {
                    self.buffer.append(data)
                    self.drainBuffer()
                }
            }

            try process.run()

            self.process = process
            self.inputPipe = inputPipe
            self.outputPipe = outputPipe

            DispatchQueue.main.async {
                self.status = "sourcekit-lsp 已启动"
            }

            sendInitialize(text: text)
        } catch {
            DispatchQueue.main.async {
                self.status = "启动失败: \(String(describing: error))"
            }
        }
    }

    private func prepareWorkspace(text: String) throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftui-sttextview-sourcekit-lsp-demo-workspace", isDirectory: true)
        let sourcesURL = rootURL.appendingPathComponent("Sources/LSPDemo", isDirectory: true)
        let packageURL = rootURL.appendingPathComponent("Package.swift")
        let fileURL = sourcesURL.appendingPathComponent("main.swift")

        try FileManager.default.createDirectory(at: sourcesURL, withIntermediateDirectories: true)

        let packageText = """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "LSPDemo",
            targets: [
                .executableTarget(name: "LSPDemo"),
            ]
        )
        """

        try packageText.write(to: packageURL, atomically: true, encoding: String.Encoding.utf8)
        try text.write(to: fileURL, atomically: true, encoding: String.Encoding.utf8)

        workspaceURL = rootURL
        self.fileURL = fileURL
    }

    private func writeWorkspaceFile(text: String) {
        guard let fileURL else {
            return
        }

        try? text.write(to: fileURL, atomically: true, encoding: String.Encoding.utf8)
    }

    private func sendInitialize(text: String) {
        guard let workspaceURL else {
            return
        }

        sendRequest(
            method: "initialize",
            params: [
                "processId": ProcessInfo.processInfo.processIdentifier,
                "rootUri": workspaceURL.absoluteString,
                "capabilities": [:],
                "clientInfo": [
                    "name": "swiftui-sttextview-sourcekit-lsp-macos-demo",
                    "version": "1",
                ],
            ]
        ) { _ in
            self.sendNotification(method: "initialized", params: [:])
            self.sendDidOpen(text: text)
            DispatchQueue.main.async {
                self.status = "LSP 初始化完成"
            }
        }
    }

    private func sendDidOpen(text: String) {
        guard let fileURL else {
            return
        }

        sendNotification(
            method: "textDocument/didOpen",
            params: [
                "textDocument": [
                    "uri": fileURL.absoluteString,
                    "languageId": "swift",
                    "version": 1,
                    "text": text,
                ],
            ]
        )

        didOpenDocument = true
    }

    private func sendDidChange(text: String) {
        guard let fileURL else {
            return
        }

        sendNotification(
            method: "textDocument/didChange",
            params: [
                "textDocument": [
                    "uri": fileURL.absoluteString,
                    "version": 1,
                ],
                "contentChanges": [
                    ["text": text],
                ],
            ]
        )
    }

    private func sendRequest(method: String, params: [String: Any], handler: @escaping (Any?) -> Void) {
        let id = nextID
        nextID += 1
        handlers[id] = handler

        sendMessage([
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ])
    }

    private func sendNotification(method: String, params: [String: Any]) {
        sendMessage([
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        ])
    }

    private func sendMessage(_ payload: [String: Any]) {
        guard let inputPipe,
              let data = try? JSONSerialization.data(withJSONObject: payload)
        else {
            return
        }

        let header = "Content-Length: \(data.count)\r\n\r\n"
        guard let headerData = header.data(using: String.Encoding.utf8) else {
            return
        }

        inputPipe.fileHandleForWriting.write(headerData)
        inputPipe.fileHandleForWriting.write(data)
    }

    private func drainBuffer() {
        let separator = Data("\r\n\r\n".utf8)

        while let headerRange = buffer.range(of: separator) {
            let headerData = buffer.subdata(in: 0..<headerRange.lowerBound)
            guard let headerText = String(data: headerData, encoding: String.Encoding.utf8) else {
                buffer.removeAll()
                return
            }

            let contentLength = headerText
                .split(separator: "\r\n")
                .compactMap { line -> Int? in
                    let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                    guard parts.count == 2, parts[0].lowercased() == "content-length" else {
                        return nil
                    }
                    return Int(parts[1].trimmingCharacters(in: .whitespaces))
                }
                .first ?? 0

            let bodyStart = headerRange.upperBound
            let bodyEnd = bodyStart + contentLength

            guard buffer.count >= bodyEnd else {
                return
            }

            let bodyData = buffer.subdata(in: bodyStart..<bodyEnd)
            buffer.removeSubrange(0..<bodyEnd)
            processMessage(bodyData)
        }
    }

    private func processMessage(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let id = object["id"] as? Int, let handler = handlers.removeValue(forKey: id) {
            handler(object["result"])
            return
        }

        guard let method = object["method"] as? String else {
            return
        }

        switch method {
        case "textDocument/publishDiagnostics":
            let params = object["params"] as? [String: Any] ?? [:]
            let diagnostics = Self.extractDiagnostics(params)
            DispatchQueue.main.async {
                self.diagnostics = diagnostics
                self.status = diagnostics.isEmpty ? "无 diagnostics" : "收到 \(diagnostics.count) 条 diagnostics"
            }
        case "window/logMessage":
            let params = object["params"] as? [String: Any] ?? [:]
            let message = params["message"] as? String ?? "window/logMessage"
            DispatchQueue.main.async {
                self.status = message
            }
        default:
            break
        }
    }

    private static func extractDiagnostics(_ params: [String: Any]) -> [DiagnosticItem] {
        let diagnostics = params["diagnostics"] as? [[String: Any]] ?? []

        return diagnostics.compactMap { item in
            let range = item["range"] as? [String: Any] ?? [:]
            let start = range["start"] as? [String: Any] ?? [:]

            return DiagnosticItem(
                severity: item["severity"] as? Int ?? 4,
                line: (start["line"] as? Int ?? 0) + 1,
                column: (start["character"] as? Int ?? 0) + 1,
                message: item["message"] as? String ?? "unknown"
            )
        }
    }

    private static func extractCompletionLabels(_ result: Any?) -> [String] {
        if let dict = result as? [String: Any] {
            let items = dict["items"] as? [[String: Any]] ?? []
            return items.compactMap { $0["label"] as? String }
        }

        if let items = result as? [[String: Any]] {
            return items.compactMap { $0["label"] as? String }
        }

        return []
    }

    private static func makeSelectionPosition(in text: String, selection: NSRange) -> (line: Int, character: Int) {
        let nsText = text as NSString
        let location = min(max(selection.location, 0), nsText.length)
        let prefix = nsText.substring(to: location) as NSString
        let line = prefix.components(separatedBy: "\n").count - 1
        let lastNewlineRange = prefix.range(of: "\n", options: .backwards)
        let lineStart = lastNewlineRange.location == NSNotFound ? 0 : lastNewlineRange.location + 1
        return (line, location - lineStart)
    }

    private static func extractSelectionRanges(_ result: Any?, text: String) -> [NSRange] {
        let items = result as? [[String: Any]] ?? []
        guard let firstItem = items.first else {
            return []
        }

        var ranges: [NSRange] = []
        var cursor: [String: Any]? = firstItem

        while let current = cursor {
            if let range = current["range"] as? [String: Any],
               let nsRange = selectionNSRange(from: range, text: text)
            {
                ranges.append(nsRange)
            }
            cursor = current["parent"] as? [String: Any]
        }

        return uniqueRanges(ranges)
    }

    private static func selectionNSRange(from range: [String: Any], text: String) -> NSRange? {
        guard let start = range["start"] as? [String: Any],
              let end = range["end"] as? [String: Any],
              let startLine = start["line"] as? Int,
              let startCharacter = start["character"] as? Int,
              let endLine = end["line"] as? Int,
              let endCharacter = end["character"] as? Int
        else {
            return nil
        }

        let startOffset = utf16Offset(in: text, line: startLine, character: startCharacter)
        let endOffset = utf16Offset(in: text, line: endLine, character: endCharacter)
        return NSRange(location: startOffset, length: max(endOffset - startOffset, 0))
    }

    private static func utf16Offset(in text: String, line: Int, character: Int) -> Int {
        let nsText = text as NSString
        var currentLine = 0
        var location = 0

        while currentLine < line, location < nsText.length {
            let lineRange = nsText.lineRange(for: NSRange(location: location, length: 0))
            if lineRange.upperBound <= location {
                break
            }
            location = lineRange.upperBound
            currentLine += 1
        }

        let targetLineRange = nsText.lineRange(for: NSRange(location: min(location, nsText.length), length: 0))
        let lineEnd = min(targetLineRange.upperBound, nsText.length)
        return min(location + character, lineEnd)
    }

    private static func nextSelectionRange(from ranges: [NSRange], current: NSRange, text: String) -> NSRange? {
        let clampedCurrent = clamp(current, to: text)
        let currentUpperBound = clampedCurrent.location + clampedCurrent.length
        let sortedRanges = ranges
            .filter { $0.location <= clampedCurrent.location && $0.location + $0.length >= currentUpperBound }
            .sorted {
                if $0.length == $1.length {
                    return $0.location < $1.location
                }
                return $0.length < $1.length
            }

        if let exactIndex = sortedRanges.firstIndex(where: { NSEqualRanges($0, clampedCurrent) }) {
            return sortedRanges.dropFirst(exactIndex + 1).first
        }

        return sortedRanges.first(where: { !NSEqualRanges($0, clampedCurrent) })
    }
}

private func clamp(_ range: NSRange, to text: String) -> NSRange {
    let length = (text as NSString).length
    let location = min(max(range.location, 0), length)
    let upperBound = min(max(range.location + range.length, location), length)
    return NSRange(location: location, length: upperBound - location)
}

private func uniqueRanges(_ ranges: [NSRange]) -> [NSRange] {
    var seen = Set<String>()
    return ranges.filter { range in
        let key = "\(range.location)-\(range.length)"
        return seen.insert(key).inserted
    }
}
