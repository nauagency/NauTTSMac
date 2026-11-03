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
    let preset: String
    let output: URL
}

private enum EngineError: LocalizedError {
    case missingFile(String)
    case invalidResponse(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missingFile(let path): return "Không tìm thấy \(path). Hãy chạy ứng dụng từ thư mục KittenTTS."
        case .invalidResponse(let message): return "Engine trả về dữ liệu không hợp lệ: \(message)"
        case .failed(let message): return message
        }
    }
}

private enum EngineRunner {
    static func projectRoot() -> URL {
        if let configured = Bundle.main.object(forInfoDictionaryKey: "KittenTTSProjectRoot") as? String,
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
            throw EngineError.missingFile(".venv/bin/python")
        }
        guard FileManager.default.fileExists(atPath: bridge.path) else {
            throw EngineError.missingFile("macos/engine.py")
        }

        let process = Process()
        let outputPipe = Pipe()
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("KittenTTSMac-\(UUID().uuidString).log")
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
            "--voice", request.voice,
            "--preset", request.preset,
            "--output", request.output.path,
        ]
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
    @Published var text = "Xin chào! Đây là Kitten TTS đang chạy bằng MLX trên máy Mac."
    @Published var voice = "Bruno"
    @Published var preset = "stable"
    @Published var isGenerating = false
    @Published var status = "Sẵn sàng · MLX trên Apple Silicon"
    @Published var lastOutput: URL?

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
                Text("Kitten TTS for Mac")
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
                TextField("Giọng đọc", text: $model.voice)
                    .textFieldStyle(.roundedBorder)
                Picker("Phong cách", selection: $model.preset) {
                    Text("Ổn định").tag("stable")
                    Text("Biểu cảm").tag("expressive")
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }

            HStack {
                Button("Tạo file WAV") { model.chooseOutputAndGenerate() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isGenerating || model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

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
private struct KittenTTSMacApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
            .defaultSize(width: 760, height: 560)
    }
}
