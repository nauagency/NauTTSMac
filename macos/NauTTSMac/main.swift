import AppKit
import Foundation
import SwiftUI

private struct EngineResponse: Decodable {
    let ok: Bool
    let output: String?
    let backend: String?
    let device: String?
    let error: String?
}

private struct GenerationRequest: Sendable {
    let projectRoot: URL
    let text: String
    let voice: String
    let reference: URL?
    let referenceText: String
    let preset: String
    let output: URL
}

private enum EngineError: LocalizedError {
    case missingFile(String)
    case invalidResponse(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missingFile(let path): return "Không tìm thấy \(path). Hãy cài lại Nau TTS Mac từ thư mục dự án."
        case .invalidResponse(let message): return "Engine trả về dữ liệu không hợp lệ: \(message)"
        case .failed(let message): return message
        }
    }
}

private enum EngineRunner {
    static func projectRoot() -> URL {
        if let configured = Bundle.main.object(forInfoDictionaryKey: "NauTTSProjectRoot") as? String,
           configured != "__PROJECT_ROOT__",
           FileManager.default.fileExists(atPath: configured) {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }

    static func generate(_ request: GenerationRequest) throws -> EngineResponse {
        let python = request.projectRoot.appendingPathComponent(".venv/bin/python")
        let bridge = request.projectRoot.appendingPathComponent("macos/engine.py")

        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw EngineError.missingFile("môi trường Nau TTS (.venv/bin/python)")
        }
        guard FileManager.default.fileExists(atPath: bridge.path) else {
            throw EngineError.missingFile("macos/engine.py")
        }

        let process = Process()
        let outputPipe = Pipe()
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NauTTSMac-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        defer {
            try? logHandle.close()
            try? FileManager.default.removeItem(at: logURL)
        }

        process.executableURL = python
        process.currentDirectoryURL = request.projectRoot
        process.arguments = [
            bridge.path,
            "--text", request.text,
            "--preset", request.preset,
            "--output", request.output.path,
        ]
        if let reference = request.reference {
            process.arguments?.append(contentsOf: ["--reference", reference.path])
            if !request.referenceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                process.arguments?.append(contentsOf: ["--reference-text", request.referenceText])
            }
        } else {
            process.arguments?.append(contentsOf: ["--voice", request.voice])
        }
        process.standardOutput = outputPipe
        process.standardError = logHandle

        try process.run()
        process.waitUntilExit()

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        guard let response = try? JSONDecoder().decode(EngineResponse.self, from: data) else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw EngineError.invalidResponse([raw, log].filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        guard process.terminationStatus == 0, response.ok else {
            let fallback = log.isEmpty ? "Không thể tạo âm thanh." : log
            throw EngineError.failed(response.error ?? fallback)
        }
        return response
    }
}

@MainActor
private final class AppModel: ObservableObject {
    enum VoiceMode: String, CaseIterable, Identifiable {
        case builtIn
        case clone

        var id: Self { self }
        var title: String { self == .builtIn ? "Giọng có sẵn" : "Clone giọng" }
    }

    @Published var text = "Xin chào! Đây là Nau TTS đang chạy bằng MLX trên máy Mac."
    @Published var voiceMode = VoiceMode.builtIn
    @Published var voice = "Bruno"
    @Published var referenceURL: URL?
    @Published var referenceText = ""
    @Published var preset = "stable"
    @Published var isGenerating = false
    @Published var status = "Sẵn sàng · MLX trên Apple Silicon"
    @Published var lastOutput: URL?

    var canGenerate: Bool {
        guard !isGenerating, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return voiceMode == .builtIn || referenceURL != nil
    }

    func chooseReference() {
        let panel = NSOpenPanel()
        panel.title = "Chọn đoạn ghi âm 5–30 giây"
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK else { return }
        referenceURL = panel.url
        status = "Đã chọn giọng tham chiếu: \(panel.url?.lastPathComponent ?? "")"
    }

    func chooseOutputAndGenerate() {
        let panel = NSSavePanel()
        panel.title = "Lưu âm thanh"
        panel.nameFieldStringValue = "kitten-output.wav"
        panel.allowedContentTypes = [.wav]
        guard panel.runModal() == .OK, let output = panel.url else { return }

        let request = GenerationRequest(
            projectRoot: EngineRunner.projectRoot(),
            text: text,
            voice: voice,
            reference: voiceMode == .clone ? referenceURL : nil,
            referenceText: referenceText,
            preset: preset,
            output: output
        )
        isGenerating = true
        status = "Đang tạo âm thanh… lần đầu có thể cần tải model."

        Task {
            do {
                let response = try await Task.detached { try EngineRunner.generate(request) }.value
                lastOutput = response.output.map { URL(fileURLWithPath: $0) } ?? output
                status = "Đã tạo xong bằng \(response.backend?.uppercased() ?? "MLX")."
            } catch {
                status = error.localizedDescription
            }
            isGenerating = false
        }
    }

    func revealOutput() {
        guard let lastOutput else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastOutput])
    }
}

private struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Nau TTS Mac")
                    .font(.largeTitle.bold())
                Text("Tạo giọng nói cục bộ bằng SwiftUI + MLX")
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: $model.text)
                .font(.body)
                .frame(minHeight: 180)
                .padding(8)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 16) {
                Picker("Nguồn giọng", selection: $model.voiceMode) {
                    ForEach(AppModel.VoiceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                Picker("Phong cách", selection: $model.preset) {
                    Text("Ổn định").tag("stable")
                    Text("Biểu cảm").tag("expressive")
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }

            if model.voiceMode == .builtIn {
                TextField("Tên giọng có sẵn, ví dụ Bruno, Luna, Kiki", text: $model.voice)
                    .textFieldStyle(.roundedBorder)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Button("Chọn file giọng…") { model.chooseReference() }
                        Text(model.referenceURL?.lastPathComponent ?? "Chưa chọn file (cần 5–30 giây, một người nói)")
                            .foregroundStyle(model.referenceURL == nil ? .secondary : .primary)
                            .lineLimit(1)
                    }
                    TextField("Nội dung được nói trong file (tùy chọn, giúp xử lý nhanh hơn)", text: $model.referenceText)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(12)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            }

            HStack {
                Button("Tạo file WAV") { model.chooseOutputAndGenerate() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canGenerate)

                if model.isGenerating { ProgressView().controlSize(.small) }

                Button("Hiện trong Finder") { model.revealOutput() }
                    .disabled(model.lastOutput == nil || model.isGenerating)

                Spacer()
            }

            Text(model.status)
                .font(.callout)
                .foregroundStyle(model.status.hasPrefix("Đã tạo") ? .green : .secondary)
                .textSelection(.enabled)
        }
        .padding(24)
        .frame(minWidth: 680, minHeight: 480)
    }
}

@main
private struct NauTTSMacApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
            .defaultSize(width: 760, height: 560)
    }
}
