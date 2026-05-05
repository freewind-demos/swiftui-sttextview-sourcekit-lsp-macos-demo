import AppKit
import Foundation
import STTextViewSwiftUI
import SwiftUI

private let sampleCode = """
import Foundation

struct User {
    let name: String
}

func title(for user: User) -> String {
    user.
}

print(title(for: User(name: "Freewind")))
"""

@main
struct STTextViewSourceKitLSPDemoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1280, height: 820)
    }
}

private struct ContentView: View {
    @State private var text = SwiftSyntaxHighlighter.highlight(sampleCode)
    @State private var plainText = sampleCode
    @State private var selection: NSRange? = NSRange(location: 0, length: 0)
    @State private var line = 8
    @State private var column = 10
    @StateObject private var lspClient = SourceKitLSPClient()

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button("加载示例") {
                    plainText = sampleCode
                    text = SwiftSyntaxHighlighter.highlight(sampleCode)
                    lspClient.start(text: sampleCode)
                }

                Button("请求补全") {
                    lspClient.requestCompletions(line: line, column: column)
                }

                Button("Duplicate 当前行 (⌘D)") {
                    duplicateCurrentLine()
                }
                .keyboardShortcut("d", modifiers: [.command])

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
                self?.queue.async {
                    self?.buffer.append(data)
                    self?.drainBuffer()
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
}
