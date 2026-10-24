import SwiftUI
import FlowKit
import CodeGenKit

/// Which half of the transaction the inspector shows.
private enum Side: CaseIterable {
    case request
    case response

    var title: LocalizedStringKey {
        switch self {
        case .request: return "common.request"
        case .response: return "common.response"
        }
    }
}

/// How the body payload is rendered.
private enum BodyMode: CaseIterable {
    case pretty
    case raw
    case hex

    var title: LocalizedStringKey {
        switch self {
        case .pretty: return "common.pretty"
        case .raw: return "common.raw"
        case .hex: return "common.hex"
        }
    }
}

/// Request/response inspector for a single captured flow.
struct FlowDetailView: View {
    let flow: Flow

    @State private var side: Side = .response
    @State private var bodyMode: BodyMode = .pretty
    /// Drives the brief "Copied" state so the button confirms the pasteboard write.
    @State private var didCopyCurl = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $side) {
                ForEach(Side.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if side == .request { requestSection } else { responseSection }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .contextMenu {
            Button("main.copyURL") { Self.copyToPasteboard(flow.url) }
            Menu("main.export") {
                Button("main.exportCurl") { Self.copyToPasteboard(flow.curlCommand) }
            }
        }
    }

    private static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(flow.method)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundStyle(MainView.methodColor(flow.method))
                if let status = flow.statusCode {
                    Text(verbatim: "\(status)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(MainView.statusColor(status))
                    Text(HTTPStatusText.text(for: status)).font(.callout).foregroundStyle(.secondary)
                }
                if flow.isIntercepted {
                    Label("inspector.decrypted", systemImage: "lock.open")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if flow.request.isHTTPS {
                    Label("inspector.tunneled", systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if flow.isMappedLocally {
                    Label("common.mapLocal", systemImage: "doc.text")
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .help(flow.localMapSource ?? "")
                }
                Spacer()
                exportMenu
            }
            Text(flow.url)
                .font(.callout)
                .textSelection(.enabled)
                .lineLimit(3)
            HStack(spacing: 14) {
                metric(L10n.string("common.total"), flow.timing.total)
                metric(L10n.string("common.latency"), flow.timing.latency)
                if let client = flow.clientAddress { Text(client).font(.caption).foregroundStyle(.tertiary) }
            }
        }
        .padding(12)
    }

    /// The context menu already offers this, but a menu nobody opens hides the feature.
    /// The button sits in the header so it is visible as soon as a flow is selected.
    private var exportMenu: some View {
        Menu {
            Button(didCopyCurl ? L10n.string("common.copied") : L10n.string("main.exportCurl")) {
                Self.copyToPasteboard(flow.curlCommand)
                didCopyCurl = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    didCopyCurl = false
                }
            }
        } label: {
            Label(L10n.string("main.export"), systemImage: "square.and.arrow.up")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .controlSize(.small)
        .help("inspector.copyCurlHelp")
    }

    @ViewBuilder
    private func metric(_ title: String, _ value: TimeInterval?) -> some View {
        if let value {
            let formatted = value < 1
                ? String(format: "%.0f ms", value * 1000)
                : String(format: "%.2f s", value)
            Text(L10n.format("inspector.metric", title, formatted))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Sections

    private var requestSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("common.general")
            keyValueTable([
                ("common.method", flow.request.method),
                ("common.url", flow.request.urlString),
                ("common.version", flow.request.httpVersion),
                ("common.client", flow.clientApp ?? "—"),
            ])
            headersSection("inspector.requestHeaders", flow.request.headers)
            bodySection("inspector.requestBody", data: flow.request.body, contentType: flow.request.contentType, encoding: flow.request.contentEncoding)
        }
    }

    private var responseSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let error = flow.error, flow.response == nil {
                sectionTitle("common.error")
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            } else if let response = flow.response {
                sectionTitle("common.general")
                keyValueTable([
                    ("common.status", "\(response.statusCode) \(response.statusText)"),
                    ("common.version", response.httpVersion),
                    ("inspector.contentType", response.headers["Content-Type"] ?? "—"),
                    ("inspector.contentLength", response.headers["Content-Length"] ?? "\(response.body.count)"),
                ])
                if let source = flow.localMapSource {
                    keyValueTable([("inspector.mappedFrom", source)])
                }
                headersSection("inspector.responseHeaders", response.headers)
                bodySection("inspector.responseBody", data: response.body, contentType: response.contentType, encoding: response.contentEncoding)
                if let messages = flow.webSocketMessages, !messages.isEmpty {
                    webSocketSection(messages)
                }
            } else {
                HStack { ProgressView().controlSize(.small); Text("inspector.waiting").foregroundStyle(.secondary) }
            }
        }
    }

    private func sectionTitle(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.headline)
    }

    private func keyValueTable(_ pairs: [(LocalizedStringKey, String)]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(pairs.indices, id: \.self) { index in
                let pair = pairs[index]
                HStack(alignment: .top, spacing: 8) {
                    Text(pair.0)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 110, alignment: .leading)
                    Text(pair.1)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Frames that crossed a connection after its `101` upgrade, oldest first.
    private func webSocketSection(_ messages: [WebSocketMessage]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                sectionTitle("inspector.webSocketFrames")
                Text(verbatim: "\(messages.count)").font(.caption).foregroundStyle(.secondary)
            }
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                    HStack(alignment: .top, spacing: 8) {
                        Text(message.direction == .clientToServer ? "→" : "←")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(message.direction == .clientToServer ? Color.blue : Color.green)
                        Text(message.opcode)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 76, alignment: .leading)
                        Text(Self.preview(of: message))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    /// Text frames read as text; everything else keeps a short hex hint, which is
    /// enough to recognise a payload without decoding a binary protocol.
    private static func preview(of message: WebSocketMessage) -> String {
        let textOpcode = message.opcode == "text"
            || message.opcode == "continuation"
            || message.opcode == "close"
        if textOpcode, let text = String(data: message.payload, encoding: .utf8), !text.isEmpty {
            return text
        }
        if message.payload.isEmpty {
            return L10n.string("inspector.empty")
        }
        let prefix = message.payload.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
        let hint = message.payload.count > 32 ? prefix + " …" : prefix
        return L10n.format("inspector.bodySize", message.payload.count, hint)
    }

    private func headersSection(_ title: LocalizedStringKey, _ headers: HTTPHeaders) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(title)
            if headers.isEmpty {
                Text("common.none").font(.caption).foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(headers.entries.enumerated()), id: \.offset) { _, header in
                        HStack(alignment: .top, spacing: 8) {
                            Text(header.name)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.blue)
                                .frame(width: 160, alignment: .leading)
                            Text(header.value)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func bodySection(_ title: LocalizedStringKey, data: Data, contentType: MIMEType?, encoding: String? = nil) -> some View {
        // Decode once, here, so every mode below (preview, pretty, raw, hex) sees the
        // payload the server actually produced rather than its compressed form.
        let decoded = ContentDecoding.decode(data, encoding: encoding)
        let displayData = decoded ?? data
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionTitle(title)
                Spacer()
                if decoded != nil, let encoding {
                    Text(L10n.format("inspector.decoded", encoding))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(BodyFormatting.byteCount(displayData.count))
                    .font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $bodyMode) {
                    ForEach(BodyMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
            }
            BodyPayloadView(data: displayData, contentType: contentType, mode: bodyMode)
                .equatable()
        }
    }
}

/// Renders a body payload: an image preview, pretty/raw text, or a hex dump.
///
/// `Equatable` so SwiftUI skips the decode and format work when the inspector is
/// redrawn with an unchanged body. The traffic list redraws up to ten times a second
/// while capture runs, and re-parsing a large body on every one of those redraws was
/// the dominant cost in the inspector.
private struct BodyPayloadView: View, Equatable {
    let data: Data
    let contentType: MIMEType?
    let mode: BodyMode

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.data == rhs.data && lhs.contentType == rhs.contentType && lhs.mode == rhs.mode
    }

    var body: some View {
        if data.isEmpty {
            Text("common.empty").font(.caption).foregroundStyle(.tertiary)
        } else if let image = imagePreview() {
            image
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 260)
                .background(Color.black.opacity(0.05))
        } else {
            Text(renderedBody)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func imagePreview() -> Image? {
        guard contentType?.isImage == true, let image = NSImage(data: data) else { return nil }
        return Image(nsImage: image)
    }

    private var renderedBody: String {
        switch mode {
        case .hex:
            return BodyFormatting.hexDump(data)
        case .raw:
            return BodyFormatting.text(from: data, contentType: contentType) ?? ""
        case .pretty:
            if contentType?.isJSON == true || BodyFormatting.isValidJSON(data) {
                return BodyFormatting.prettyJSON(data) ?? (BodyFormatting.text(from: data, contentType: contentType) ?? "")
            }
            if contentType?.isForm == true {
                let pairs = BodyFormatting.formPairs(data)
                if !pairs.isEmpty {
                    return pairs.map { "\($0.name) = \($0.value)" }.joined(separator: "\n")
                }
            }
            return BodyFormatting.text(from: data, contentType: contentType) ?? BodyFormatting.hexDump(data)
        }
    }
}
