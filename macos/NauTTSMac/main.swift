import AppKit
import Foundation
import SwiftUI

private struct EngineResponse: Decodable, Sendable {
    let ok: Bool
    let output: String?
    let backend: String?
    let voices: [String]?
    let error: String?
}

private struct VoiceProfile: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    let audioFileName: String
    var transcript: String
    let createdAt: Date
    var provider: String?
}

private enum AppPage: String, CaseIterable, Identifiable {
    case home, create, library
    var id: Self { self }
    var title: String {
        switch self { case .home: "Trang chủ"; case .create: "Tạo âm thanh"; case .library: "Thư viện giọng" }
    }
    var icon: String {
        switch self { case .home: "house"; case .create: "waveform"; case .library: "person.2.wave.2" }
    }
}

private enum VoiceSource: String, CaseIterable, Identifiable {
    case builtIn, created
    var id: Self { self }
    var title: String { self == .builtIn ? "Giọng có sẵn" : "Giọng đã tạo" }
}

private enum EngineError: LocalizedError {
    case failed(String)
    var errorDescription: String? { if case .failed(let message) = self { message } else { nil } }
}

private enum EngineRunner {
    static func root() -> URL {
        if let path = Bundle.main.object(forInfoDictionaryKey: "NauTTSProjectRoot") as? String,
           path != "__PROJECT_ROOT__", FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }

    static func run(_ arguments: [String]) throws -> EngineResponse {
        let root = root()
        let python = root.appendingPathComponent(".venv/bin/python")
        let bridge = root.appendingPathComponent("macos/engine.py")
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(atPath: bridge.path) else {
            throw EngineError.failed("Không tìm thấy engine Nau TTS. Hãy cài lại ứng dụng.")
        }
        let process = Process()
        let output = Pipe()
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("NauTTS-\(UUID()).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close(); try? FileManager.default.removeItem(at: logURL) }
        process.executableURL = python
        process.currentDirectoryURL = root
        process.arguments = [bridge.path] + arguments
        process.standardOutput = output
        process.standardError = log
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let logText = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        guard let response = try? JSONDecoder().decode(EngineResponse.self, from: data) else {
            throw EngineError.failed(logText.isEmpty ? "Engine trả về dữ liệu không hợp lệ." : logText)
        }
        guard process.terminationStatus == 0, response.ok else {
            throw EngineError.failed(response.error ?? logText)
        }
        return response
    }
}

@MainActor
private final class AppModel: ObservableObject {
    @Published var page = AppPage.home
    @Published var profiles: [VoiceProfile] = []
    @Published var voices = ["Bella", "Bruno", "Hugo", "Jasper", "Kiki", "Leo", "Luna", "Rosie"]
    @Published var loadingVoices = false
    @Published var source = VoiceSource.builtIn
    @Published var selectedVoice = "Bruno"
    @Published var selectedProfileID: UUID?
    @Published var text = "Xin chào! Đây là Nau TTS đang chạy bằng MLX trên máy Mac."
    @Published var preset = "stable"
    @Published var generating = false
    @Published var status = "Sẵn sàng · MLX trên Apple Silicon"
    @Published var lastOutput: URL?

    private let appDirectory: URL
    private let voiceDirectory: URL
    private let indexURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        appDirectory = support.appendingPathComponent("Nau TTS Mac", isDirectory: true)
        voiceDirectory = appDirectory.appendingPathComponent("Voices", isDirectory: true)
        indexURL = appDirectory.appendingPathComponent("voices.json")
        try? FileManager.default.createDirectory(at: voiceDirectory, withIntermediateDirectories: true)
        loadProfiles()
    }

    var selectedProfile: VoiceProfile? { profiles.first { $0.id == selectedProfileID } }
    var canGenerate: Bool {
        !generating && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (source == .builtIn || selectedProfile != nil)
    }
    func audioURL(_ profile: VoiceProfile) -> URL { voiceDirectory.appendingPathComponent(profile.audioFileName) }

    func loadVoices() {
        guard !loadingVoices else { return }
        loadingVoices = true
        Task {
            do {
                let loaded = try await Task.detached { try EngineRunner.run(["--list-voices"]).voices ?? [] }.value
                if !loaded.isEmpty { voices = loaded; if !loaded.contains(selectedVoice) { selectedVoice = loaded[0] } }
            } catch { status = error.localizedDescription }
            loadingVoices = false
        }
    }

    func addProfile(name: String, source: URL, transcript: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw EngineError.failed("Hãy đặt tên cho giọng.") }
        let id = UUID(), ext = source.pathExtension.isEmpty ? "wav" : source.pathExtension.lowercased()
        let fileName = "\(id).\(ext)", destination = voiceDirectory.appendingPathComponent(fileName)
        try FileManager.default.copyItem(at: source, to: destination)
        profiles.insert(VoiceProfile(id: id, name: name, audioFileName: fileName,
                                     transcript: transcript.trimmingCharacters(in: .whitespacesAndNewlines),
                                     createdAt: Date(), provider: "Cục bộ"), at: 0)
        try saveProfiles()
        selectedProfileID = id
        self.source = .created
        status = "Đã lưu giọng \(name)."
    }

    func deleteProfile(_ profile: VoiceProfile) {
        try? FileManager.default.removeItem(at: audioURL(profile))
        profiles.removeAll { $0.id == profile.id }
        if selectedProfileID == profile.id { selectedProfileID = profiles.first?.id }
        try? saveProfiles()
    }
    func use(_ voice: String) { selectedVoice = voice; source = .builtIn; page = .create }
    func use(_ profile: VoiceProfile) { selectedProfileID = profile.id; source = .created; page = .create }

    func generate() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "nau-tts-output.wav"
        panel.allowedContentTypes = [.wav]
        guard panel.runModal() == .OK, let output = panel.url else { return }
        var args = ["--text", text, "--preset", preset, "--output", output.path]
        if source == .builtIn { args += ["--voice", selectedVoice] }
        else if let profile = selectedProfile {
            args += ["--reference", audioURL(profile).path]
            if !profile.transcript.isEmpty { args += ["--reference-text", profile.transcript] }
        }
        generating = true; status = "Đang tạo âm thanh…"
        Task {
            do {
                let response = try await Task.detached { [args] in try EngineRunner.run(args) }.value
                lastOutput = response.output.map { URL(fileURLWithPath: $0) } ?? output
                status = "Đã tạo xong bằng \(response.backend?.uppercased() ?? "MLX")."
            } catch { status = error.localizedDescription }
            generating = false
        }
    }
    func reveal() { if let lastOutput { NSWorkspace.shared.activateFileViewerSelecting([lastOutput]) } }
    private func loadProfiles() {
        guard let data = try? Data(contentsOf: indexURL),
              let saved = try? JSONDecoder().decode([VoiceProfile].self, from: data) else { return }
        profiles = saved.filter { FileManager.default.fileExists(atPath: audioURL($0).path) }
        selectedProfileID = profiles.first?.id
    }
    private func saveProfiles() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: indexURL, options: .atomic)
    }
}

private struct ContentView: View {
    @StateObject private var model = AppModel()
    var body: some View {
        NavigationSplitView {
            List(AppPage.allCases, selection: $model.page) { Label($0.title, systemImage: $0.icon).tag($0) }
                .navigationTitle("Nau TTS Mac").frame(minWidth: 190)
        } detail: {
            switch model.page {
            case .home: HomeView(model: model)
            case .create: CreateView(model: model)
            case .library: LibraryView(model: model)
            }
        }
        .task { model.loadVoices() }
    }
}

private struct HomeView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Trang chủ").font(.largeTitle.bold())
                HStack { metric("Giọng có sẵn", model.voices.count); metric("Giọng đã tạo", model.profiles.count) }
                header("Giọng đã tạo", button: "Quản lý") { model.page = .library }
                if model.profiles.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "person.wave.2").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Chưa có giọng riêng").font(.headline)
                        Text("Vào Thư viện giọng để thêm đoạn ghi âm 5–30 giây.").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 150)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))]) {
                        ForEach(model.profiles) { profile in
                            card(profile.name, profile.provider ?? "Giọng đã tạo") { model.use(profile) }
                        }
                    }
                }
                header("Giọng có sẵn", button: model.loadingVoices ? "Đang tải…" : "\(model.voices.count) giọng") {}
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160))]) {
                    ForEach(model.voices, id: \.self) { voice in card(voice, "Nau TTS") { model.use(voice) } }
                }
            }.padding(28)
        }.frame(minWidth: 720, minHeight: 580)
    }
    private func metric(_ title: String, _ count: Int) -> some View {
        VStack(alignment: .leading) { Text("\(count)").font(.title.bold()); Text(title).foregroundStyle(.secondary) }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
    }
    private func header(_ title: String, button: String, action: @escaping () -> Void) -> some View {
        HStack { Text(title).font(.title2.bold()); Spacer(); Button(button, action: action).buttonStyle(.plain).foregroundStyle(.tint) }
    }
    private func card(_ title: String, _ subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { Image(systemName: "waveform.circle.fill").font(.title2); VStack(alignment: .leading) {
                Text(title).font(.headline).lineLimit(1); Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }; Spacer() }.padding(13).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }
}

private struct CreateView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            Text("Tạo âm thanh").font(.largeTitle.bold())
            Picker("Nguồn giọng", selection: $model.source) { ForEach(VoiceSource.allCases) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented).frame(width: 360)
            if model.source == .builtIn {
                Picker("Giọng đọc", selection: $model.selectedVoice) { ForEach(model.voices, id: \.self) { Text($0).tag($0) } }.frame(width: 400)
            } else if model.profiles.isEmpty {
                HStack { Text("Chưa có giọng đã tạo."); Button("Thêm giọng") { model.page = .library } }
            } else {
                Picker("Giọng đọc", selection: $model.selectedProfileID) {
                    ForEach(model.profiles) { Text($0.name).tag(Optional($0.id)) }
                }.frame(width: 400)
            }
            Text("Nội dung").font(.headline)
            TextEditor(text: $model.text).frame(minHeight: 230).padding(10)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
            Picker("Phong cách", selection: $model.preset) { Text("Ổn định").tag("stable"); Text("Biểu cảm").tag("expressive") }
                .pickerStyle(.segmented).frame(width: 240)
            HStack { Button("Tạo file WAV") { model.generate() }.buttonStyle(.borderedProminent).disabled(!model.canGenerate)
                if model.generating { ProgressView().controlSize(.small) }
                Button("Hiện trong Finder") { model.reveal() }.disabled(model.lastOutput == nil || model.generating) }
            Text(model.status).foregroundStyle(.secondary).textSelection(.enabled)
        }.padding(28) }.frame(minWidth: 720, minHeight: 580)
    }
}

private struct LibraryView: View {
    @ObservedObject var model: AppModel
    @State private var name = ""
    @State private var transcript = ""
    @State private var sourceURL: URL?
    @State private var error: String?
    @State private var deleting: VoiceProfile?
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 22) {
            Text("Thư viện giọng").font(.largeTitle.bold())
            GroupBox("Thêm giọng mới") { VStack(alignment: .leading, spacing: 12) {
                TextField("Tên giọng", text: $name).textFieldStyle(.roundedBorder)
                HStack { Button("Chọn file ghi âm…", action: choose); Text(sourceURL?.lastPathComponent ?? "Cần 5–30 giây, một người nói").foregroundStyle(.secondary) }
                TextField("Nội dung trong đoạn ghi âm (tùy chọn)", text: $transcript).textFieldStyle(.roundedBorder)
                HStack { Button("Lưu vào thư viện", action: save).buttonStyle(.borderedProminent)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sourceURL == nil)
                    if let error { Text(error).foregroundStyle(.red) } }
            }.padding(8) }
            Text("Giọng đã tạo (\(model.profiles.count))").font(.title2.bold())
            if model.profiles.isEmpty { Text("Chưa có giọng nào trong thư viện.").foregroundStyle(.secondary) }
            ForEach(model.profiles) { profile in HStack {
                Image(systemName: "person.crop.circle.fill").font(.title).foregroundStyle(.tint)
                VStack(alignment: .leading) { Text(profile.name).font(.headline)
                    Text(profile.provider ?? "Cục bộ").font(.caption).foregroundStyle(.secondary)
                    Text(profile.transcript.isEmpty ? "Không có transcript" : profile.transcript).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(); Button("Sử dụng") { model.use(profile) }
                Button(role: .destructive) { deleting = profile } label: { Image(systemName: "trash") }
            }.padding(14).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12)) }
        }.padding(28) }.frame(minWidth: 720, minHeight: 580)
        .alert("Xóa giọng?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Hủy", role: .cancel) { deleting = nil }
            Button("Xóa", role: .destructive) { if let deleting { model.deleteProfile(deleting) }; deleting = nil }
        } message: { Text("File ghi âm và thông tin đã lưu sẽ bị xóa khỏi máy.") }
    }
    private func choose() { let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { sourceURL = panel.url } }
    private func save() { guard let sourceURL else { return }; do { try model.addProfile(name: name, source: sourceURL, transcript: transcript)
        name = ""; transcript = ""; self.sourceURL = nil; error = nil } catch { self.error = error.localizedDescription } }
}

@main
private struct NauTTSMacApp: App {
    var body: some Scene { WindowGroup { ContentView() }.defaultSize(width: 1040, height: 700) }
}
