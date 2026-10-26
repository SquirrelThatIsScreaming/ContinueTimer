// ContinueTimer — menu bar app that resumes a Codex / Claude Code session
// with a "continue" message once a usage limit has reset.
import SwiftUI
import AppKit

// MARK: - Sessions

enum Harness: String, Codable, CaseIterable, Identifiable {
    case codex = "Codex", claude = "Claude Code"
    var id: String { rawValue }
    var symbol: String { self == .codex ? "chevron.left.forwardslash.chevron.right" : "sparkle" }
    var permissions: [(value: String, label: String)] {
        switch self {
        case .codex: return [("workspace-write", "Workspace write"), ("read-only", "Read only"), ("full", "Full access (no sandbox)")]
        case .claude: return [("acceptEdits", "Accept edits"), ("auto", "Auto"), ("bypassPermissions", "Bypass permissions")]
        }
    }
}

struct SessionInfo: Identifiable, Hashable {
    let id: String
    let cwd: String
    let title: String
    let modified: Date
}

enum SessionStore {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static func recent(_ h: Harness, limit: Int = 40) -> [SessionInfo] {
        h == .codex ? codex(limit) : claude(limit)
    }

    private static func mtime(_ u: URL) -> Date {
        (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func json(_ line: Substring) -> [String: Any]? {
        guard let d = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    /// Reads from the start of a file until `lines` complete lines (or `maxBytes`) are available.
    private static func head(_ u: URL, lines: Int, maxBytes: Int = 8 << 20) -> [Substring] {
        guard let fh = try? FileHandle(forReadingFrom: u) else { return [] }
        defer { try? fh.close() }
        var data = Data()
        while data.count < maxBytes, let chunk = try? fh.read(upToCount: 256 << 10), !chunk.isEmpty {
            data.append(chunk)
            if data.reduce(0, { $0 + ($1 == 10 ? 1 : 0) }) >= lines { break }
        }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").prefix(lines).map { $0 }
    }

    private static func tail(_ u: URL, bytes: Int = 2 << 20) -> [Substring] {
        guard let fh = try? FileHandle(forReadingFrom: u) else { return [] }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        try? fh.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        let data = (try? fh.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self).split(separator: "\n")
    }

    // ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl, titles in ~/.codex/session_index.jsonl
    private static func codex(_ limit: Int) -> [SessionInfo] {
        let root = home.appendingPathComponent(".codex/sessions")
        var files: [URL] = []
        if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let u as URL in e where u.pathExtension == "jsonl" { files.append(u) }
        }
        var titles: [String: String] = [:]
        if let idx = try? String(contentsOf: home.appendingPathComponent(".codex/session_index.jsonl"), encoding: .utf8) {
            for line in idx.split(separator: "\n") {
                if let o = json(line), let id = o["id"] as? String, let t = o["thread_name"] as? String { titles[id] = t }
            }
        }
        // Over-fetch, since subagent threads (parent_thread_id set) are dropped.
        return files.sorted { mtime($0) > mtime($1) }.prefix(limit * 4).lazy.compactMap { u -> SessionInfo? in
            guard let first = head(u, lines: 1).first, let o = json(first),
                  let p = o["payload"] as? [String: Any], let id = p["id"] as? String,
                  p["parent_thread_id"] == nil else { return nil }
            let cwd = p["cwd"] as? String ?? home.path
            return SessionInfo(id: id, cwd: cwd, title: titles[id] ?? (cwd as NSString).lastPathComponent, modified: mtime(u))
        }.prefix(limit).map { $0 }
    }

    // ~/.claude/projects/<encoded-cwd>/<session-id>.jsonl
    private static func claude(_ limit: Int) -> [SessionInfo] {
        let root = home.appendingPathComponent(".claude/projects")
        let fm = FileManager.default
        var files: [URL] = []
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            files += ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { $0.pathExtension == "jsonl" }
        }
        return files.sorted { mtime($0) > mtime($1) }.prefix(limit).compactMap { u in
            let id = u.deletingPathExtension().lastPathComponent
            guard let cwd = head(u, lines: 30).lazy.compactMap({ json($0)?["cwd"] as? String }).first else { return nil }
            var custom: String?, ai: String?
            for line in tail(u).reversed() where line.contains("-title\"") {
                guard let o = json(line) else { continue }
                if custom == nil, let t = o["customTitle"] as? String { custom = t; break }
                if ai == nil, let t = o["aiTitle"] as? String { ai = t }
            }
            return SessionInfo(id: id, cwd: cwd, title: custom ?? ai ?? (cwd as NSString).lastPathComponent, modified: mtime(u))
        }
    }
}

// MARK: - Jobs

struct Job: Codable, Identifiable {
    enum Status: String, Codable { case scheduled, running, done, failed }
    var id = UUID()
    var harness: Harness
    var sessionId: String
    var cwd: String
    var title: String
    var message: String
    var permission: String
    var fireDate: Date
    var status: Status = .scheduled
    var exitCode: Int32?
    var logPath: String?
    var note: String?
}

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

func command(for j: Job) -> String {
    var args: [String]
    switch j.harness {
    case .codex:
        args = ["codex", "exec", "resume", "--skip-git-repo-check"]
        switch j.permission {
        case "full": args.append("--dangerously-bypass-approvals-and-sandbox")
        case "read-only": args += ["-c", "sandbox_mode=\"read-only\""]
        default: args += ["-c", "sandbox_mode=\"workspace-write\""]
        }
        args += [j.sessionId, j.message]
    case .claude:
        args = ["claude", "--resume", j.sessionId, "--permission-mode", j.permission, "-p", j.message]
    }
    return "cd \(shellQuote(j.cwd)) && exec " + args.map(shellQuote).joined(separator: " ")
}

func notify(_ title: String, _ body: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "display notification \(appleString(body)) with title \(appleString(title))"]
    try? p.run()
}

private func appleString(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

// MARK: - Codex app delivery
// While a chat is open in the Codex desktop app, the app holds
// ~/.codex/thread-writer-locks/<id>.lock and `codex exec resume` refuses the chat
// ("already has an active writer"). Then the message is typed into the app instead.

enum CodexApp {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    /// The GUI app whose process tree holds the chat's writer lock, if any.
    static func lockHolder(of sessionId: String) -> NSRunningApplication? {
        let lock = home.appendingPathComponent(".codex/thread-writer-locks/\(sessionId).lock")
        guard FileManager.default.fileExists(atPath: lock.path) else { return nil }
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-t", lock.path]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        for pid in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap({ pid_t($0) }) {
            var cur = pid
            while cur > 1 {
                if let app = NSRunningApplication(processIdentifier: cur), app.activationPolicy == .regular { return app }
                cur = parentPid(cur)
            }
        }
        return nil
    }

    private static func parentPid(_ pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        return sysctl(&mib, 4, &info, &size, nil, 0) == 0 ? info.kp_eproc.e_ppid : 0
    }

    static func rollout(of sessionId: String) -> URL? {
        let root = home.appendingPathComponent(".codex/sessions")
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let u as URL in e where u.lastPathComponent.hasSuffix("-\(sessionId).jsonl") { return u }
        return nil
    }

    /// True once the chat record holds a user message equal to `text`, written after `date`.
    static func recorded(_ text: String, in rollout: URL, after date: Date) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: rollout) else { return false }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        try? fh.seek(toOffset: size > 1 << 20 ? size - (1 << 20) : 0)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let want = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lines = String(decoding: (try? fh.readToEnd()) ?? Data(), as: UTF8.self).split(separator: "\n")
        for line in lines.reversed() where line.contains("\"user\"") {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let ts = (o["timestamp"] as? String).flatMap(iso.date(from:)),
                  let p = o["payload"] as? [String: Any], p["role"] as? String == "user" else { continue }
            if ts < date { return false }
            let texts = (p["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
            if texts.contains(where: { $0.lowercased().contains(want) }) { return true }
        }
        return false
    }

    @discardableResult
    static func accessibilityGranted(prompt: Bool) -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary)
    }

    static var screenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    static func type(_ text: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        var units = Array(text.utf16)[...]
        while !units.isEmpty {
            let chunk = Array(units.prefix(16))
            units = units.dropFirst(16)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
                e?.flags = []
                e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                e?.post(tap: .cghidEventTap)
            }
        }
    }

    static func pressReturn() { press(36) }

    /// Cmd+A, so typing replaces any leftover draft in the message box.
    static func selectAll() { press(0, flags: .maskCommand) }

    private static func press(_ key: CGKeyCode, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }
}

@MainActor
final class Model: ObservableObject {
    @Published var jobs: [Job] = [] { didSet { save(); updateSleepAssertion() } }
    @Published var now = Date()
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private let key = "jobs"
    static let logDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ContinueTimer")

    init() {
        if let d = UserDefaults.standard.data(forKey: key), let j = try? JSONDecoder().decode([Job].self, from: d) {
            jobs = j.map { var j = $0; if j.status == .running { j.status = .failed }; return j }
        }
        // Polling (instead of one Timer per job) also catches jobs that came due while the Mac slept.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    var nextJob: Job? { jobs.filter { $0.status == .scheduled }.min { $0.fireDate < $1.fireDate } }

    func tick() {
        now = Date()
        for j in jobs where j.status == .scheduled && j.fireDate <= now { run(j.id) }
    }

    func schedule(_ j: Job) { jobs.append(j); tick() }
    func remove(_ id: UUID) { jobs.removeAll { $0.id == id } }

    private func openLog(_ j: Job) -> (URL, FileHandle)? {
        try? FileManager.default.createDirectory(at: Self.logDir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let log = Self.logDir.appendingPathComponent("\(stamp)-\(j.harness == .codex ? "codex" : "claude").log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        guard let fh = try? FileHandle(forWritingTo: log) else { return nil }
        return (log, fh)
    }

    private func finish(_ id: UUID, ok: Bool, code: Int32? = nil, note: String? = nil) {
        guard let k = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[k].status = ok ? .done : .failed
        jobs[k].exitCode = code
        jobs[k].note = note
        let job = jobs[k]
        notify("\(job.harness.rawValue) " + (ok ? "continued" : "failed" + (code.map { " (exit \($0))" } ?? "")),
               note.map { "\(job.title) — \($0)" } ?? job.title)
    }

    func run(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        if jobs[i].harness == .codex, let app = CodexApp.lockHolder(of: jobs[i].sessionId) {
            return typeIntoApp(id, app)
        }
        let cmd = command(for: jobs[i])
        guard let (log, fh) = openLog(jobs[i]) else { return }
        fh.write(Data("$ \(cmd)\n\n".utf8))

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", cmd]          // login shell so PATH finds codex / claude
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = fh
        p.standardError = fh
        let job = jobs[i]
        p.terminationHandler = { proc in
            let code = proc.terminationStatus
            try? fh.close()
            Task { @MainActor in self.finish(id, ok: code == 0, code: code) }
        }
        jobs[i].status = .running
        jobs[i].logPath = log.path
        do { try p.run(); notify("Sent \"\(job.message)\" to \(job.harness.rawValue)", job.title) }
        catch { jobs[i].status = .failed; fh.write(Data("\(error)\n".utf8)) }
    }

    /// Opens the chat in the app that holds its lock, types the message + Return, then
    /// waits until Codex's chat record shows it, so "done" means it was actually received.
    private func typeIntoApp(_ id: UUID, _ app: NSRunningApplication) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), let (logURL, fh) = openLog(jobs[i]) else { return }
        let job = jobs[i]
        let name = app.localizedName ?? "the Codex app"
        func log(_ s: String) { fh.write(Data("\(Date().formatted(date: .omitted, time: .standard))  \(s)\n".utf8)) }
        func fail(_ why: String) { log("FAILED: \(why)"); try? fh.close(); finish(id, ok: false, note: why) }

        jobs[i].status = .running
        jobs[i].logPath = logURL.path
        log("Chat is open in \(name) (pid \(app.processIdentifier)), which holds its writer lock; typing into the app instead of running codex exec.")
        guard CodexApp.accessibilityGranted(prompt: true) else {
            return fail("needs Accessibility permission (System Settings → Privacy & Security → Accessibility)")
        }
        guard !CodexApp.screenLocked else { return fail("screen was locked, so keystrokes can't reach \(name)") }
        guard let rollout = CodexApp.rollout(of: job.sessionId) else { return fail("chat record not found") }

        Task { @MainActor in
            let sentAt = Date()
            let link = URL(string: "codex://threads/\(job.sessionId)")!
            if let appURL = app.bundleURL {
                _ = try? await NSWorkspace.shared.open([link], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
            }
            log("Opened \(link)")
            try? await Task.sleep(for: .seconds(3))
            app.activate()
            try? await Task.sleep(for: .seconds(1))
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
                return fail("couldn't bring \(name) to the front")
            }
            CodexApp.selectAll()
            try? await Task.sleep(for: .milliseconds(150))
            CodexApp.type(job.message)
            try? await Task.sleep(for: .milliseconds(300))
            CodexApp.pressReturn()
            log("Typed \"\(job.message)\" + Return; waiting for the chat record to show it…")
            notify("Typed \"\(job.message)\" into \(name)", job.title)
            for _ in 0..<24 {
                try? await Task.sleep(for: .seconds(5))
                if CodexApp.recorded(job.message, in: rollout, after: sentAt) {
                    log("Received: the chat record shows the message.")
                    try? fh.close()
                    return finish(id, ok: true, note: "received in \(name)")
                }
            }
            fail("typed into \(name), but the chat didn't record it within 2 minutes")
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(jobs) { UserDefaults.standard.set(d, forKey: key) }
    }

    // Keep the Mac from idle-sleeping while a timer is pending or a resume is running.
    private func updateSleepAssertion() {
        let busy = jobs.contains { $0.status == .scheduled || $0.status == .running }
        if busy, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "Continue timer pending")
        } else if !busy, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }
}

func countdown(_ s: TimeInterval) -> String {
    let m = max(0, Int((s / 60).rounded(.up)))
    return m >= 60 ? String(format: "%d:%02d", m / 60, m % 60) : "\(m)m"
}

// MARK: - UI

struct ContentView: View {
    @EnvironmentObject var model: Model
    @State private var harness: Harness = .codex
    @State private var sessions: [SessionInfo] = []
    @State private var sessionId = ""
    @State private var hours = 0
    @State private var minutes = 0
    @State private var message = "continue"
    @State private var permission = "workspace-write"

    private var fireDate: Date { model.now.addingTimeInterval(TimeInterval(hours * 3600 + minutes * 60)) }
    private var selected: SessionInfo? { sessions.first { $0.id == sessionId } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New timer").font(.headline)
            Picker("", selection: $harness) {
                ForEach(Harness.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()

            HStack {
                Picker("Session", selection: $sessionId) {
                    ForEach(sessions) { s in
                        Text("\(s.title) · \(s.modified.formatted(.relative(presentation: .named)))").tag(s.id)
                    }
                }
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }.help("Reload sessions")
            }
            if let s = selected {
                Text(s.cwd).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }

            HStack {
                Text("Resets in")
                TextField("", value: $hours, format: .number).frame(width: 40).multilineTextAlignment(.trailing)
                Stepper("h", value: $hours, in: 0...168)
                TextField("", value: $minutes, format: .number).frame(width: 40).multilineTextAlignment(.trailing)
                Stepper("m", value: $minutes, in: 0...59)
            }
            Text("Sends at \(fireDate.formatted(date: .omitted, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Text("Message")
                TextField("continue", text: $message)
            }
            Picker("Permissions", selection: $permission) {
                ForEach(harness.permissions, id: \.value) { Text($0.label).tag($0.value) }
            }

            Button("Schedule") { schedule() }
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil || message.isEmpty)
                .frame(maxWidth: .infinity, alignment: .trailing)

            if !model.jobs.isEmpty {
                Divider()
                Text("Timers").font(.headline)
                ForEach(model.jobs.sorted { $0.fireDate > $1.fireDate }) { JobRow(job: $0) }
            }

            Divider()
            HStack {
                Button("Logs") { NSWorkspace.shared.open(Model.logDir) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 380)
        .onAppear { reload() }
        .onChange(of: harness) { _, h in
            permission = h.permissions[0].value
            reload()
        }
    }

    private func reload() {
        sessions = SessionStore.recent(harness)
        if !sessions.contains(where: { $0.id == sessionId }) { sessionId = sessions.first?.id ?? "" }
    }

    private func schedule() {
        guard let s = selected else { return }
        // Ask now, while you're here: typing into the Codex app later needs Accessibility.
        if harness == .codex { CodexApp.accessibilityGranted(prompt: true) }
        model.schedule(Job(harness: harness, sessionId: s.id, cwd: s.cwd, title: s.title,
                           message: message, permission: permission, fireDate: fireDate))
    }
}

struct JobRow: View {
    @EnvironmentObject var model: Model
    let job: Job

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: job.harness.symbol).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title).lineLimit(1)
                Text(status).font(.caption).foregroundStyle(job.status == .failed ? .red : .secondary)
                    .lineLimit(2).help(job.note ?? "")
            }
            Spacer()
            if job.status == .scheduled {
                Button { model.run(job.id) } label: { Image(systemName: "play.fill") }.help("Send now")
            }
            if let log = job.logPath {
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: log)) } label: { Image(systemName: "doc.text") }.help("Open log")
            }
            if job.status != .running {
                Button { model.remove(job.id) } label: { Image(systemName: "xmark") }.help(job.status == .scheduled ? "Cancel" : "Remove")
            }
        }
        .buttonStyle(.borderless)
    }

    private var status: String {
        let t = job.fireDate.formatted(date: .omitted, time: .shortened)
        switch job.status {
        case .scheduled: return "\(job.harness.rawValue) · at \(t) · in \(countdown(job.fireDate.timeIntervalSince(model.now)))"
        case .running: return "\(job.harness.rawValue) · running…"
        case .done: return "\(job.harness.rawValue) · done at \(t)" + (job.note.map { " · \($0)" } ?? "")
        case .failed: return "\(job.harness.rawValue) · failed" + (job.exitCode.map { " (exit \($0))" } ?? "")
            + (job.note.map { " · \($0)" } ?? "")
        }
    }
}

struct MenuLabel: View {
    @ObservedObject var model: Model
    var body: some View {
        if let j = model.nextJob {
            HStack(spacing: 3) {
                Image(systemName: "timer")
                Text(countdown(j.fireDate.timeIntervalSince(model.now)))
            }
        } else if model.jobs.contains(where: { $0.status == .running }) {
            Image(systemName: "arrow.triangle.2.circlepath")
        } else {
            Image(systemName: "timer")
        }
    }
}

#if !TEST
@main
#endif
struct ContinueTimerApp: App {
    @StateObject private var model = Model()
    var body: some Scene {
        MenuBarExtra {
            ContentView().environmentObject(model)
        } label: {
            MenuLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
