import SwiftUI
import AppKit

@main
struct InstaIndirApp: App {
    @StateObject private var store = DownloadStore()

    var body: some Scene {
        WindowGroup("İnsta İndir") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 520, minHeight: 360)
        }
        .windowResizability(.contentMinSize)
    }
}

// MARK: - Model

enum DownloadState: Equatable {
    case running(String)
    case done(URL?)
    case failed(String)
}

enum TranscriptState: Equatable {
    case running(String)
    case done(URL)
    case failed(String)
}

@MainActor
final class DownloadItem: ObservableObject, Identifiable {
    let id = UUID()
    let link: String
    let isStory: Bool
    @Published var state: DownloadState = .running("Başlıyor…")
    @Published var progress: Double = 0
    @Published var transcript: TranscriptState?

    init(link: String, isStory: Bool = false) {
        self.link = link
        self.isStory = isStory
    }
}

enum VideoLink {
    /// Panodan otomatik yapıştırılacak siteler. "İndir" yt-dlp'nin desteklediği her linki kabul eder.
    static let knownHosts = ["instagram.com", "youtube.com", "youtu.be", "tiktok.com", "x.com",
                             "twitter.com", "facebook.com", "fb.watch", "vimeo.com", "reddit.com"]

    static func isLink(_ s: String) -> Bool {
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return false }
        return true
    }

    static func isKnown(_ s: String) -> Bool {
        guard isLink(s), let host = URL(string: s)?.host?.lowercased() else { return false }
        return knownHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

enum StoryLink {
    static let reserved: Set<String> = ["p", "reel", "reels", "tv", "explore", "accounts", "direct", "stories"]

    /// Profil linki, hikâye linki, "@kullanici" ya da "kullanici" → hikâye linki.
    static func make(from raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("@") { s.removeFirst() }

        let user: String
        if s.contains("instagram.com/") {
            guard let path = URLComponents(string: s.hasPrefix("http") ? s : "https://" + s)?.path else { return nil }
            let parts = path.split(separator: "/").map(String.init)
            if parts.first == "stories", parts.count >= 2 {
                user = parts[1]
            } else if let first = parts.first, !reserved.contains(first) {
                user = first
            } else {
                return nil
            }
        } else {
            user = s
        }

        guard user.range(of: #"^[A-Za-z0-9._]{1,30}$"#, options: .regularExpression) != nil else { return nil }
        return "https://www.instagram.com/stories/\(user)/"
    }
}

@MainActor
final class DownloadStore: ObservableObject {
    @Published var items: [DownloadItem] = []

    let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!

    func start(_ raw: String) {
        let links = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { VideoLink.isLink($0) }
        for link in links {
            let item = DownloadItem(link: link)
            items.insert(item, at: 0)
            Task { await run(item) }
        }
    }

    /// Profil linki ya da kullanıcı adından o kişinin güncel hikâyelerini indirir.
    @discardableResult
    func startStories(_ raw: String) -> Bool {
        guard let link = StoryLink.make(from: raw) else { return false }
        let item = DownloadItem(link: link, isStory: true)
        items.insert(item, at: 0)
        Task { await run(item) }
        return true
    }

    private func run(_ item: DownloadItem) async {
        // Önce çerezsiz dene; giriş gerekiyorsa tarayıcı çerezleriyle tekrar dene.
        // Hikâyeler her zaman giriş ister, çerezsiz denemeyi atla.
        var attempts: [[String]] = [[], ["--cookies-from-browser", "chrome"], ["--cookies-from-browser", "safari"]]
        if item.isStory { attempts.removeFirst() }
        var lastError = "Bilinmeyen hata"
        for (i, extra) in attempts.enumerated() {
            if !extra.isEmpty { item.state = .running("\(i > 0 ? "Giriş gerekiyor, " : "")\(extra[1]) çerezleriyle deneniyor…") }
            // Tek video linki (ör. YouTube &list=) bütün oynatma listesini indirmesin; hikâyeler listedir.
            let args = extra + (item.isStory ? [] : ["--no-playlist"])
            let result = await YTDLP.download(link: item.link, to: downloadsDir, extraArgs: args) { p, status in
                Task { @MainActor in
                    item.progress = p
                    item.state = .running(status)
                }
            }
            switch result {
            case .success(let file):
                item.progress = 1
                item.state = .done(file)
                if let file { await transcribe(item, video: file) }
                return
            case .failure(let err):
                lastError = err.message
                // yt-dlp, giriş başarılı olsa da hikâye listesi boşsa bu mesajı verir.
                if item.isStory, err.message.contains("You need to log in to access this content") {
                    item.state = .failed("Bu hesabın şu an aktif hikâyesi yok ya da Instagram hikâyeleri vermedi.")
                    return
                }
            }
        }
        item.state = .failed(lastError)
    }

    /// Videonun sesini whisper ile yazıya döker, yanına aynı adla .txt kaydeder.
    private func transcribe(_ item: DownloadItem, video: URL) async {
        item.transcript = .running("Transkript çıkarılıyor…")
        let result = await Whisper.transcribe(video: video) { pct in
            Task { @MainActor in item.transcript = .running("Transkript çıkarılıyor… %\(pct)") }
        }
        switch result {
        case .success(let txt): item.transcript = .done(txt)
        case .failure(let err): item.transcript = .failed(err.message)
        }
    }

    func clearFinished() {
        items.removeAll {
            if case .running = $0.state { return false }
            if case .running = $0.transcript { return false }
            return true
        }
    }
}

// MARK: - yt-dlp runner

struct YTError: Error { let message: String }

enum YTDLP {
    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    static func tool(_ name: String) -> String? {
        searchPaths.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func download(link: String, to dir: URL, extraArgs: [String],
                         onProgress: @escaping @Sendable (Double, String) -> Void) async -> Result<URL?, YTError> {
        guard let ytdlp = tool("yt-dlp") else {
            return .failure(YTError(message: "yt-dlp bulunamadı. Terminalde: brew install yt-dlp"))
        }
        var args = [
            
            "-f", "bv*+ba/b",
            // QuickTime'ın açabildiği codec'leri tercih et (YouTube varsayılanı VP9/Opus).
            "-S", "vcodec:h264,acodec:aac",
            "--merge-output-format", "mp4",
            "--remux-video", "mp4",
            "-o", dir.path + "/%(uploader,extractor|video)s_%(id)s.%(ext)s",
            "--newline", "--no-colors", "--restrict-filenames",
            "--print", "after_move:FILE:%(filepath)s",
        ]
        if let ffmpeg = tool("ffmpeg") {
            args += ["--ffmpeg-location", ffmpeg]
        }
        args += extraArgs
        args.append(link)

        return await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ytdlp)
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = (searchPaths + [env["PATH"] ?? ""]).joined(separator: ":")
            p.environment = env

            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err

            let collector = OutputCollector()
            out.fileHandleForReading.readabilityHandler = { h in
                let data = h.availableData
                guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
                for line in s.split(whereSeparator: \.isNewline) {
                    let line = String(line)
                    if line.hasPrefix("FILE:") {
                        collector.setFile(String(line.dropFirst(5)))
                    } else if line.contains("[download]"), let pct = parsePercent(line) {
                        onProgress(pct, "İndiriliyor… %\(Int(pct * 100))")
                    } else if line.contains("[Merger]") || line.contains("[VideoRemuxer]") {
                        onProgress(1, "Ses ve görüntü birleştiriliyor…")
                    }
                }
            }
            err.fileHandleForReading.readabilityHandler = { h in
                let data = h.availableData
                if !data.isEmpty, let s = String(data: data, encoding: .utf8) { collector.appendErr(s) }
            }
            p.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                if proc.terminationStatus == 0 {
                    cont.resume(returning: .success(collector.file.map { URL(fileURLWithPath: $0) }))
                } else {
                    cont.resume(returning: .failure(YTError(message: collector.errorSummary)))
                }
            }
            do { try p.run() } catch {
                cont.resume(returning: .failure(YTError(message: error.localizedDescription)))
            }
        }
    }

    static func parsePercent(_ line: String) -> Double? {
        guard let r = line.range(of: #"(\d+(\.\d+)?)%"#, options: .regularExpression) else { return nil }
        return Double(line[r].dropLast()).map { $0 / 100 }
    }
}

// MARK: - whisper runner

enum Whisper {
    static let modelName = "ggml-large-v3-turbo.bin"

    static var modelPath: String? {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let candidates = [
            support.appendingPathComponent("InstaIndir/\(modelName)").path,
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    static func transcribe(video: URL, onProgress: @escaping @Sendable (Int) -> Void) async -> Result<URL, YTError> {
        guard let whisper = YTDLP.tool("whisper-cli") else {
            return .failure(YTError(message: "whisper-cli bulunamadı. Terminalde: /opt/homebrew/bin/brew install whisper-cpp"))
        }
        guard let ffmpeg = YTDLP.tool("ffmpeg") else {
            return .failure(YTError(message: "ffmpeg bulunamadı. Terminalde: /opt/homebrew/bin/brew install ffmpeg"))
        }
        guard let model = modelPath else {
            return .failure(YTError(message: "Whisper modeli yok: ~/Library/Application Support/InstaIndir/\(modelName)"))
        }

        // whisper 16 kHz mono wav ister.
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        let conv = await run(ffmpeg, ["-y", "-i", video.path, "-vn", "-ar", "16000", "-ac", "1", wav.path])
        guard conv.status == 0 else {
            return .failure(YTError(message: "Videoda ses bulunamadı, transkript çıkarılamadı."))
        }

        let base = video.deletingPathExtension()
        let txt = base.appendingPathExtension("txt")
        let threads = String(max(4, ProcessInfo.processInfo.activeProcessorCount - 2))
        let res = await run(whisper, ["-m", model, "-f", wav.path, "-l", "auto", "-t", threads,
                                      "-nt", "-otxt", "-of", base.path, "-pp"]) { line in
            if let r = line.range(of: #"progress\s*=\s*(\d+)%"#, options: .regularExpression),
               let n = Int(line[r].filter(\.isNumber)) {
                onProgress(min(n, 100))
            }
        }
        guard res.status == 0, FileManager.default.fileExists(atPath: txt.path) else {
            return .failure(YTError(message: "Transkript başarısız: " + String(res.err.suffix(200))))
        }
        // whisper satır başlarına boşluk koyuyor; temizle.
        if let raw = try? String(contentsOf: txt, encoding: .utf8) {
            let clean = raw.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            try? (clean + "\n").write(to: txt, atomically: true, encoding: .utf8)
        }
        return .success(txt)
    }

    /// Komutu çalıştırır; stderr satırlarını onLine'a verir.
    private static func run(_ exe: String, _ args: [String],
                            onLine: (@Sendable (String) -> Void)? = nil) async -> (status: Int32, err: String) {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            let err = Pipe()
            p.standardOutput = FileHandle.nullDevice
            p.standardError = err
            let collector = OutputCollector()
            err.fileHandleForReading.readabilityHandler = { h in
                let data = h.availableData
                guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
                collector.appendErr(s)
                s.split(whereSeparator: \.isNewline).forEach { onLine?(String($0)) }
            }
            p.terminationHandler = { proc in
                err.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: (proc.terminationStatus, collector.rawErr))
            }
            do { try p.run() } catch {
                cont.resume(returning: (-1, error.localizedDescription))
            }
        }
    }
}

final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _file: String?
    private var _err = ""

    var file: String? { lock.withLock { _file } }
    var errorSummary: String {
        lock.withLock {
            let lines = _err.split(whereSeparator: \.isNewline).filter { $0.contains("ERROR") }
            return lines.last.map(String.init) ?? (_err.isEmpty ? "İndirme başarısız" : String(_err.suffix(300)))
        }
    }
    var rawErr: String { lock.withLock { _err } }
    func setFile(_ f: String) { lock.withLock { _file = f } }
    func appendErr(_ s: String) { lock.withLock { _err += s } }
}

// MARK: - UI

struct ContentView: View {
    @EnvironmentObject var store: DownloadStore
    @State private var link = ""
    @State private var storyError: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                TextField("Video linkini yapıştır (Instagram, YouTube, TikTok, X…)", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit(submit)
                Button("İndir", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Hikâye indir", action: submitStories)
                    .controlSize(.large)
                    .disabled(StoryLink.make(from: link) == nil)
                    .help("Profil linki, @kullanıcı ya da kullanıcı adı")
            }
            Text(storyError ?? "Kayıt yeri: \(store.downloadsDir.path)")
                .font(.caption).foregroundStyle(storyError == nil ? Color.secondary : Color.red)
                .frame(maxWidth: .infinity, alignment: .leading)

            if store.items.isEmpty {
                Spacer()
                Text("Linki yapıştır, Enter'a bas.").foregroundStyle(.secondary)
                Spacer()
            } else {
                List(store.items) { RowView(item: $0) }
                    .listStyle(.inset)
                HStack {
                    Spacer()
                    Button("Bitenleri temizle") { store.clearFinished() }
                }
            }
        }
        .padding()
        .onAppear {
            focused = true
            pasteIfInstagram()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            pasteIfInstagram()
        }
    }

    private func submit() {
        let t = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        store.start(t)
        link = ""
    }

    private func submitStories() {
        if store.startStories(link) {
            link = ""
            storyError = nil
        } else {
            storyError = "Kullanıcı adı bulunamadı. Profil linki ya da @kullanıcı yapıştır."
        }
    }

    private func pasteIfInstagram() {
        guard link.isEmpty,
              let s = NSPasteboard.general.string(forType: .string),
              VideoLink.isKnown(s.trimmingCharacters(in: .whitespacesAndNewlines)),
              !store.items.contains(where: { $0.link == s.trimmingCharacters(in: .whitespacesAndNewlines) })
        else { return }
        link = s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct RowView: View {
    @ObservedObject var item: DownloadItem

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 4) {
                Text(item.link).lineLimit(1).truncationMode(.middle).font(.callout)
                switch item.state {
                case .running(let s):
                    ProgressView(value: item.progress).progressViewStyle(.linear)
                    Text(s).font(.caption).foregroundStyle(.secondary)
                case .done(let url):
                    Text(url?.lastPathComponent ?? "İndirildi").font(.caption).foregroundStyle(.green)
                    transcriptLine
                case .failed(let e):
                    Text(e).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
                }
            }
            Spacer()
            if case .done(let url) = item.state, let url {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    Image(systemName: "magnifyingglass")
                }.help("Finder'da göster")
            }
            if case .done(let txt) = item.transcript {
                Button { NSWorkspace.shared.open(txt) } label: {
                    Image(systemName: "doc.text")
                }.help("Transkripti aç")
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var transcriptLine: some View {
        switch item.transcript {
        case .running(let s): Text(s).font(.caption).foregroundStyle(.secondary)
        case .done(let url): Text(url.lastPathComponent).font(.caption).foregroundStyle(.green)
        case .failed(let e): Text(e).font(.caption).foregroundStyle(.orange).lineLimit(2).textSelection(.enabled)
        case nil: EmptyView()
        }
    }

    @ViewBuilder private var icon: some View {
        switch item.state {
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}
