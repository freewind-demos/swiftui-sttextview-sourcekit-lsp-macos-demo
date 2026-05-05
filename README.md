# STTextView + 手写 Syntax/LSP

## 简介

这个 Demo 演示两件事：

1. 用 `STTextView` 做原生编辑器
2. 你自己接一层最小 syntax highlight 与 `sourcekit-lsp`

它不是完整 IDE，只是最小闭环：

- 编辑 Swift 文本
- 本地关键字着色
- 起 `sourcekit-lsp`
- 收 diagnostics
- 手动请求 completion

## 快速开始

### 环境要求

- macOS 14+
- Xcode.app 已安装
- 本机可执行  
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp`

### 运行

```bash
cd /Volumes/SN550-2T/freewind-demos/swiftui-sttextview-sourcekit-lsp-macos-demo
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run
```

## 概念讲解

### 第一部分：自己做 syntax highlight

这里没有接现成高亮插件，而是自己跑正则：

```swift
private static let keywordRegex = try? NSRegularExpression(
    pattern: #"\b(import|struct|class|enum|protocol|func|let|var|if|else|for|while|return|switch|case|default|extension|guard|in)\b"#
)
```

然后把匹配范围加颜色：

```swift
value.addAttribute(.foregroundColor, value: NSColor.systemPink, range: match.range)
```

这当然不如 tree-sitter 准，但很适合演示“我自己接一层语法”。

### 第二部分：自己起 sourcekit-lsp

这个 Demo 没引 editor SDK，而是直接起进程：

```swift
process.executableURL = executableURL
process.standardInput = inputPipe
process.standardOutput = outputPipe
process.standardError = outputPipe
```

随后按 LSP 规范写 `Content-Length` header：

```swift
let header = "Content-Length: \(data.count)\r\n\r\n"
inputPipe.fileHandleForWriting.write(headerData)
inputPipe.fileHandleForWriting.write(data)
```

### 第三部分：最小 LSP 闭环

启动顺序是：

1. 创建临时 SwiftPM workspace
2. 写 `Package.swift`
3. 写 `Sources/LSPDemo/main.swift`
4. 发 `initialize`
5. 发 `initialized`
6. 发 `textDocument/didOpen`
7. 文本更新时发 `textDocument/didChange`

手动点“请求补全”时，再发：

```swift
sendRequest(
    method: "textDocument/completion",
    params: [
        "textDocument": ["uri": fileURL.absoluteString],
        "position": ["line": max(line - 1, 0), "character": max(column - 1, 0)],
    ]
)
```

## 完整示例

完整实现都在 `Sources/swiftui-sttextview-sourcekit-lsp-macos-demo/swiftui_sttextview_sourcekit_lsp_macos_demo.swift`。

运行后右侧有两块结果：

- `Diagnostics`
- `Completions`

初始示例里特意写了：

```swift
func title(for user: User) -> String {
    user.
}
```

所以你能直接拿这个位置去试 completion。

## 注意事项

- 这里的 syntax highlight 是演示级，不是完整 Swift 语法解析
- `didChange` 里版本号固定为 `1`，为最小 demo 省掉版本管理
- completion 位置靠右侧手动行列输入，不是跟编辑器光标联动
- 要做生产版，建议继续接：
  - 光标同步
  - 版本号递增
  - hover / definition
  - tree-sitter 或正式高亮方案

## 完整讲解

这个 demo 的重点不是“把体验做到最好”，而是证明架构链路通：

- `STTextView` 能做原生编辑区
- 你可以自己给它加一层语法着色
- 也可以自己起 `sourcekit-lsp`，不必等某个现成 editor SDK

它适合回答一个工程问题：  
“如果我不用 WebView，不用 Monaco，不用现成 IDE，我能不能自己拼一个最小 Swift editor？”  
答案是：能，但你要自己补协议层和体验层。

这个 demo 刻意保留了最小实现痕迹：

- 行列位置手填
- 正则高亮
- diagnostics/completion 只做读结果

这样代码短，路径清楚。  
如果你后面决定继续投这个方向，最先该补的是光标同步与文档版本管理。
