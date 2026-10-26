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
    let path: URL
    /// Tokens the last model call read; roughly what a resume re-reads uncached once the cache has expired.
    let contextTokens: Int?
}

/// Above this, resuming after a long limit wait is expensive enough to suggest a fresh session.
let largeContext = 100_000

func tokenLabel(_ n: Int) -> String { n >= 1000 ? "\(Int((Double(n) / 1000).rounded()))k" : "\(n)" }

enum SessionStore {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static func recent(_ h: Harness, limit: Int = 40) -> [SessionInfo] {
        h == .codex ? codex(limit) : claude(limit)
    }

    private static func mtime(_ u: URL) -> Date {
        (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    static func json(_ line: Substring) -> [String: Any]? {
        guard let d = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    /// Reads from the start of a file until `lines` complete lines (or `maxBytes`) are available.
    static func head(_ u: URL, lines: Int, maxBytes: Int = 8 << 20) -> [Substring] {
        guard let fh = try? FileHandle(forReadingFrom: u) else { return [] }
        defer { try? fh.close() }
        var data = Data()
        while data.count < maxBytes, let chunk = try? fh.read(upToCount: 256 << 10), !chunk.isEmpty {
            data.append(chunk)
            if data.reduce(0, { $0 + ($1 == 10 ? 1 : 0) }) >= lines { break }
        }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").prefix(lines).map { $0 }
    }

    static func tail(_ u: URL, bytes: Int = 2 << 20) -> [Substring] {
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
            return SessionInfo(id: id, cwd: cwd, title: titles[id] ?? (cwd as NSString).lastPathComponent,
                               modified: mtime(u), path: u, contextTokens: codexContext(u))
        }.prefix(limit).map { $0 }
    }

    private static func codexContext(_ u: URL) -> Int? {
        // token_count events are frequent, so a small tail usually suffices.
        for bytes in [128 << 10, 2 << 20] {
            for line in tail(u, bytes: bytes).reversed() where line.contains("\"last_token_usage\"") {
                if let p = json(line)?["payload"] as? [String: Any], let info = p["info"] as? [String: Any],
                   let last = info["last_token_usage"] as? [String: Any], let n = last["input_tokens"] as? Int { return n }
            }
        }
        return nil
    }

    private static func claudeContext(_ lines: [Substring]) -> Int? {
        for line in lines.reversed() where line.contains("\"cache_read_input_tokens\"") {
            guard let o = json(line), o["type"] as? String == "assistant", o["isSidechain"] as? Bool != true,
                  let u = (o["message"] as? [String: Any])?["usage"] as? [String: Any] else { continue }
            return ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].reduce(0) { $0 + (u[$1] as? Int ?? 0) }
        }
        return nil
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
            let lines = tail(u)
            // A session can change folders. Prefer the latest cwd that maps to the transcript's
            // project dir (where `claude --resume` looks for it), else the latest, else the first.
            let cwds = lines.reversed().compactMap { json($0)?["cwd"] as? String }
                + head(u, lines: 30).compactMap { json($0)?["cwd"] as? String }
            let project = u.deletingLastPathComponent().lastPathComponent
            let encode = { (p: String) in String(p.map { $0.isLetter || $0.isNumber ? $0 : "-" }) }
            guard let cwd = cwds.first(where: { encode($0) == project }) ?? cwds.first else { return nil }
            var custom: String?, ai: String?
            for line in lines.reversed() where line.contains("-title\"") {
                guard let o = json(line) else { continue }
                if custom == nil, let t = o["customTitle"] as? String { custom = t; break }
                if ai == nil, let t = o["aiTitle"] as? String { ai = t }
            }
            return SessionInfo(id: id, cwd: cwd, title: custom ?? ai ?? (cwd as NSString).lastPathComponent,
                               modified: mtime(u), path: u, contextTokens: claudeContext(lines))
        }
    }
}

// MARK: - Jobs

// MARK: - Handoff
// A fresh session avoids re-reading a large expired cache. It starts from a summary built
// deterministically from the old transcript, so building it costs no tokens.

enum Handoff {
    private struct Parts {
        var requests: [String] = []
        var lastAssistant: String?
        var plan: [(status: String, text: String)] = []
    }

    private static func clip(_ s: String, _ n: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > n ? String(t.prefix(n)) + " […]" : t
    }

    /// Typed by a person, as opposed to injected context (AGENTS.md, <system-…> tags, tool results).
    private static func isTyped(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && !t.hasPrefix("<") && !t.hasPrefix("# AGENTS.md")
    }

    private static func planItems(_ list: [[String: Any]]?) -> [(status: String, text: String)] {
        (list ?? []).compactMap { i in
            guard let text = (i["content"] ?? i["step"]) as? String else { return nil }
            return (i["status"] as? String ?? "pending", text)
        }
    }

    /// The desktop app's update_plan sends the full list once, then progress-only calls
    /// ({advance}, {done: [1-based], start: n}) that must be replayed onto it.
    private static func applyPlanUpdate(_ plan: inout [(status: String, text: String)], _ input: [String: Any]) {
        if let items = input["items"] as? [[String: Any]] { plan = planItems(items); return }
        if input["advance"] as? Bool == true {
            if let i = plan.firstIndex(where: { $0.status == "in_progress" }) { plan[i].status = "completed" }
            if let i = plan.firstIndex(where: { $0.status == "pending" }) { plan[i].status = "in_progress" }
        }
        for n in input["done"] as? [Int] ?? [] where plan.indices.contains(n - 1) { plan[n - 1].status = "completed" }
        if let n = input["start"] as? Int, plan.indices.contains(n - 1) {
            for i in plan.indices where plan[i].status == "in_progress" { plan[i].status = "pending" }
            plan[n - 1].status = "in_progress"
        }
    }

    private static func claudeParts(_ lines: [Substring]) -> Parts {
        var p = Parts()
        for line in lines {
            guard let o = SessionStore.json(line), o["isSidechain"] as? Bool != true,
                  let m = o["message"] as? [String: Any] else { continue }
            let blocks: [[String: Any]] = (m["content"] as? String).map { [["type": "text", "text": $0]] }
                ?? m["content"] as? [[String: Any]] ?? []
            switch o["type"] as? String {
            case "user" where o["isMeta"] as? Bool != true:
                let typed = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.filter(isTyped)
                if !typed.isEmpty { p.requests.append(typed.joined(separator: "\n")) }
            case "assistant":
                for b in blocks {
                    if b["type"] as? String == "text", let t = b["text"] as? String, !t.isEmpty { p.lastAssistant = t }
                    if b["type"] as? String == "tool_use", let input = b["input"] as? [String: Any] {
                        let name = b["name"] as? String ?? ""
                        if name == "TodoWrite" { p.plan = planItems(input["todos"] as? [[String: Any]]) }
                        if name.hasSuffix("update_plan") { applyPlanUpdate(&p.plan, input) }
                    }
                }
            default: break
            }
        }
        return p
    }

    private static func codexParts(_ lines: [Substring]) -> Parts {
        var p = Parts()
        for line in lines {
            guard let o = SessionStore.json(line), o["type"] as? String == "response_item",
                  let pl = o["payload"] as? [String: Any] else { continue }
            if pl["type"] as? String == "message" {
                let texts = (pl["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
                switch pl["role"] as? String {
                case "user": p.requests += texts.filter(isTyped)
                case "assistant": if let t = texts.last(where: { !$0.isEmpty }) { p.lastAssistant = t }
                default: break
                }
            }
            if pl["name"] as? String == "update_plan", let args = pl["arguments"] as? String,
               let a = SessionStore.json(Substring(args)) {
                p.plan = planItems(a["plan"] as? [[String: Any]])
            }
        }
        return p
    }

    // MARK: Subagents
    // A new session can't see or message the old session's subagents, so their state goes into the handoff.

    struct Subagent {
        var name: String
        var task: String?
        var status: String
        var report: String?
        var modified: Date
        var transcript: URL
    }

    private static func mtime(_ u: URL) -> Date {
        (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// Codex: every subagent has its own rollout whose session_meta names its parent thread.
    static func codexSubagents(of rootId: String, rollout: URL) -> [Subagent] {
        // Rollout names start with their creation time, so only later files can be children.
        let stamp = rollout.lastPathComponent.dropFirst("rollout-".count).prefix(19)
        let root = SessionStore.home.appendingPathComponent(".codex/sessions")
        var meta: [(url: URL, id: String, parent: String, name: String)] = []
        if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let u as URL in e where u.pathExtension == "jsonl" && u != rollout {
                let n = u.lastPathComponent
                guard n.hasPrefix("rollout-"), n.dropFirst("rollout-".count).prefix(19) >= stamp,
                      let first = SessionStore.head(u, lines: 1).first,
                      let p = SessionStore.json(first)?["payload"] as? [String: Any],
                      let id = p["id"] as? String, let parent = p["parent_thread_id"] as? String else { continue }
                let path = p["agent_path"] as? String ?? id
                let name = (p["agent_nickname"] as? String).map { "\(path) (\($0))" } ?? path
                meta.append((u, id, parent, name))
            }
        }
        // Include nested subagents (children of children).
        var ids: Set<String> = [rootId], picked: [(url: URL, name: String)] = [], grew = true
        while grew {
            grew = false
            for m in meta where ids.contains(m.parent) && !ids.contains(m.id) {
                ids.insert(m.id); picked.append((m.url, m.name)); grew = true
            }
        }
        return picked.map { m in
            var report: String?, finished = false
            for line in SessionStore.tail(m.url, bytes: 512 << 10).reversed() where line.contains("\"task_complete\"") {
                if let p = SessionStore.json(line)?["payload"] as? [String: Any], p["type"] as? String == "task_complete" {
                    finished = true
                    report = p["last_agent_message"] as? String
                    break
                }
            }
            // The task Codex sends a subagent is encrypted, so only its name is known.
            return Subagent(name: m.name, task: nil,
                            status: finished ? "finished" : "no final result recorded (still running, or cut off by the limit)",
                            report: report, modified: mtime(m.url), transcript: m.url)
        }
    }

    /// The string fields of a parent-transcript record that can carry a subagent hand-back.
    private static func frames(_ o: [String: Any]) -> [String] {
        var out: [String] = []
        if let s = o["content"] as? String { out.append(s) }
        if let s = (o["attachment"] as? [String: Any])?["prompt"] as? String { out.append(s) }
        if let m = o["message"] as? [String: Any] {
            if let s = m["content"] as? String { out.append(s) }
            out += (m["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        }
        return out
    }

    private static func between(_ s: String, _ a: String, _ b: String) -> String? {
        guard let r1 = s.range(of: a), let r2 = s.range(of: b, range: r1.upperBound..<s.endIndex) else { return nil }
        return String(s[r1.upperBound..<r2.lowerBound])
    }

    /// Claude: <session>/subagents/agent-<agentId>.jsonl plus .meta.json. The final report isn't in that
    /// transcript; the parent receives it as <agent-message from="<agentId>">, every report line indented.
    static func claudeSubagents(transcript: URL, parentLines: [Substring]) -> [Subagent] {
        let dir = transcript.deletingPathExtension().appendingPathComponent("subagents")
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "jsonl" }
        guard !files.isEmpty else { return [] }

        var reports: [String: String] = [:], states: [String: String] = [:]
        for line in parentLines where line.contains("agent-message from=") || line.contains("<task-notification>") {
            guard let o = SessionStore.json(line) else { continue }
            for s in frames(o) {
                if let id = between(s, "<agent-message from=\"", "\""), let body = between(s, "The report follows:\n", "</agent-message>") {
                    reports[id] = body.split(separator: "\n", omittingEmptySubsequences: false)
                        .map { $0.hasPrefix("  ") ? String($0.dropFirst(2)) : String($0) }.joined(separator: "\n")
                }
                if let id = between(s, "<task-id>", "</task-id>"), let st = between(s, "<status>", "</status>") { states[id] = st }
            }
        }

        return files.map { u in
            let agentId = String(u.deletingPathExtension().lastPathComponent.dropFirst("agent-".count))
            let metaURL = u.deletingPathExtension().appendingPathExtension("meta.json")
            let meta = (try? Data(contentsOf: metaURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let task = SessionStore.head(u, lines: 3).lazy.compactMap { SessionStore.json($0) }
                .first { $0["type"] as? String == "user" }
                .flatMap { ($0["message"] as? [String: Any])?["content"] as? String }
            let report = reports[agentId]
            let state = report != nil ? "finished" : states[agentId].map { $0 == "completed" ? "finished" : $0 }
            let desc = meta?["description"] as? String
            let type = meta?["agentType"] as? String
            let name = [desc, type.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
            return Subagent(name: name.isEmpty ? "agent \(agentId)" : name, task: task,
                            status: state ?? "no final result recorded (still running, or cut off by the limit)",
                            report: report, modified: mtime(u), transcript: u)
        }
    }

    private static func subagentSection(_ agents: [Subagent]) -> String {
        guard !agents.isEmpty else { return "" }
        let shown = agents.sorted { $0.modified > $1.modified }.prefix(15).sorted { $0.modified < $1.modified }
        var out = "\n## Subagents of the previous session\n"
        out += "They were started by the previous session and can't be messaged or listed from this one. "
        out += "Use their results instead of redoing their work; read a transcript only if you need more detail.\n"
        if agents.count > shown.count { out += "(\(agents.count) in total; the \(shown.count) most recently active are listed.)\n" }
        for a in shown {
            let when = a.modified.formatted(date: .omitted, time: .shortened)
            out += "\n### \(a.name)\nStatus: \(a.status); last active \(when)\nTranscript: \(a.transcript.path)\n"
            if let t = a.task { out += "Task: \(clip(t, 400))\n" }
            if let r = a.report { out += "Last report: \(clip(r, 700))\n" }
        }
        return out
    }

    static func build(harness: Harness, sessionId: String, cwd: String, transcript: URL,
                      contextTokens: Int?, message: String) -> String {
        let text = (try? String(contentsOf: transcript, encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n")
        let p = harness == .claude ? claudeParts(lines) : codexParts(lines)
        let agents = harness == .claude ? claudeSubagents(transcript: transcript, parentLines: lines)
                                        : codexSubagents(of: sessionId, rollout: transcript)
        let size = contextTokens.map { " (~\(tokenLabel($0)) tokens)" } ?? ""
        var out = """
        You are continuing work from an earlier \(harness.rawValue) session that stopped when the usage limit was reached. \
        Its full context\(size) is deliberately not loaded; below is a handoff extracted from its transcript.

        Working directory: \(cwd)
        Previous session: \(sessionId)
        Full transcript (JSONL, large): \(transcript.path). Search it for specifics only if you need them.

        """
        if let first = p.requests.first { out += "\n## Original request\n\(clip(first, 2500))\n" }
        let recent = p.requests.dropFirst().suffix(3)
        if !recent.isEmpty {
            out += "\n## Most recent user messages (oldest first)\n" + recent.map { "- " + clip($0, 1200) }.joined(separator: "\n") + "\n"
        }
        if !p.plan.isEmpty {
            out += "\n## Last plan\n" + p.plan.map { "- [\($0.status)] \($0.text)" }.joined(separator: "\n") + "\n"
        }
        if let a = p.lastAssistant { out += "\n## Last assistant message before the stop\n\(clip(a, 3000))\n" }
        out += subagentSection(agents)
        out += """

        ## Next step
        First re-establish the current state (git status / git diff, files named above); don't redo finished work. Then: \(message)
        """
        return out
    }
}

struct Job: Codable, Identifiable {
    enum Status: String, Codable { case scheduled, running, done, failed }
    enum Mode: String, Codable { case resume, fresh, new }
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
    var mode: Mode?             // nil (jobs saved before modes existed) means resume
    var transcript: String?
    var contextTokens: Int?
    var isFresh: Bool { mode == .fresh }
    /// Fresh handoffs and new tasks both start a new session instead of resuming one.
    var startsSession: Bool { mode == .fresh || mode == .new }
}

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

/// `prompt` is the handoff for fresh sessions; resumes send `j.message`.
func command(for j: Job, prompt: String? = nil) -> String {
    var args: [String]
    switch j.harness {
    case .codex:
        args = ["codex", "exec"] + (j.startsSession ? [] : ["resume"]) + ["--skip-git-repo-check"]
        switch j.permission {
        case "full": args.append("--dangerously-bypass-approvals-and-sandbox")
        case "read-only": args += ["-c", "sandbox_mode=\"read-only\""]
        default: args += ["-c", "sandbox_mode=\"workspace-write\""]
        }
        args += j.startsSession ? [prompt ?? j.message] : [j.sessionId, j.message]
    case .claude:
        args = ["claude"] + (j.startsSession ? [] : ["--resume", j.sessionId])
            + ["--permission-mode", j.permission, "-p", prompt ?? j.message]
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
        // A fresh session has no lock to conflict with, so only resumes need the app route.
        if jobs[i].harness == .codex, !jobs[i].startsSession, let app = CodexApp.lockHolder(of: jobs[i].sessionId) {
            return typeIntoApp(id, app)
        }
        var prompt: String?
        if jobs[i].isFresh {
            let j = jobs[i]
            let transcript = j.transcript.map(URL.init(fileURLWithPath:))
                ?? (j.harness == .codex ? CodexApp.rollout(of: j.sessionId) : nil)
            guard let t = transcript else {
                jobs[i].status = .failed
                return finish(id, ok: false, note: "transcript for the handoff not found")
            }
            prompt = Handoff.build(harness: j.harness, sessionId: j.sessionId, cwd: j.cwd, transcript: t,
                                   contextTokens: j.contextTokens, message: j.message)
        }
        let cmd = command(for: jobs[i], prompt: prompt)
        guard let (log, fh) = openLog(jobs[i]) else { return }
        if let prompt { fh.write(Data("Fresh session with this handoff:\n\n\(prompt)\n\n---\n".utf8)) }
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
    @State private var mode: Job.Mode = .resume
    @State private var newTask = false
    @State private var folder = ""
    @State private var prompt = ""

    private var fireDate: Date { model.now.addingTimeInterval(TimeInterval(hours * 3600 + minutes * 60)) }
    private var selected: SessionInfo? { sessions.first { $0.id == sessionId } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New timer").font(.headline)
            Picker("", selection: $harness) {
                ForEach(Harness.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Picker("", selection: $newTask) {
                Text("Continue a chat").tag(false)
                Text("New task").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden()

            if newTask {
                HStack {
                    Picker("Folder", selection: $folder) {
                        ForEach(recentFolders, id: \.self) { Text(($0 as NSString).abbreviatingWithTildeInPath).tag($0) }
                        if !recentFolders.contains(folder) { Text(folder).tag(folder) }
                    }
                    Button { chooseFolder() } label: { Image(systemName: "folder") }.help("Choose another folder")
                }
                Text("Prompt for the new session").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $prompt)
                    .font(.body).frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            } else {
            HStack {
                Picker("Session", selection: $sessionId) {
                    ForEach(sessions) { s in
                        Text("\(s.title) · \(s.modified.formatted(.relative(presentation: .named)))"
                             + (s.contextTokens.map { " · \(tokenLabel($0))" } ?? "")).tag(s.id)
                    }
                }
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }.help("Reload sessions")
            }
            if let s = selected {
                Text(s.cwd).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Picker("", selection: $mode) {
                    Text("Resume").tag(Job.Mode.resume)
                    Text("Fresh + handoff").tag(Job.Mode.fresh)
                }
                .pickerStyle(.segmented).labelsHidden()
                HStack(alignment: .firstTextBaseline) {
                    Text(modeHint(s)).font(.caption)
                        .foregroundStyle(mode == .resume && (s.contextTokens ?? 0) > largeContext ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if mode == .fresh {
                        Spacer()
                        Button("Preview") { preview(s) }.font(.caption).buttonStyle(.link)
                    }
                }
            }
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

            if !newTask {
                HStack {
                    Text("Message")
                    TextField("continue", text: $message)
                }
            }
            Picker("Permissions", selection: $permission) {
                ForEach(harness.permissions, id: \.value) { Text($0.label).tag($0.value) }
            }

            Button("Schedule") { schedule() }
                .keyboardShortcut(.defaultAction)
                .disabled(newTask ? prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !isDirectory(folder)
                                  : selected == nil || message.isEmpty)
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
        .onChange(of: sessionId) { _, _ in
            // Large chats default to a fresh session; you can still switch back to Resume.
            mode = (selected?.contextTokens ?? 0) > largeContext ? .fresh : .resume
        }
    }

    private func modeHint(_ s: SessionInfo) -> String {
        let size = s.contextTokens.map { "~\(tokenLabel($0)) tokens" } ?? "an unknown amount"
        switch mode {
        case .resume:
            return (s.contextTokens ?? 0) > largeContext
                ? "Resuming re-reads \(size) uncached once the cache has expired, which uses up a lot of the fresh limit."
                : "Resumes this chat with its full context (\(size))."
        case .fresh:
            return "Starts a new session with a summary built from this chat instead of re-reading \(size)."
        case .new:
            return ""
        }
    }

    private func preview(_ s: SessionInfo) {
        let text = Handoff.build(harness: harness, sessionId: s.id, cwd: s.cwd, transcript: s.path,
                                 contextTokens: s.contextTokens, message: message)
        try? FileManager.default.createDirectory(at: Model.logDir, withIntermediateDirectories: true)
        let u = Model.logDir.appendingPathComponent("handoff-preview.md")
        try? text.write(to: u, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(u)
    }

    private func reload() {
        sessions = SessionStore.recent(harness)
        if !sessions.contains(where: { $0.id == sessionId }) { sessionId = sessions.first?.id ?? "" }
        if folder.isEmpty { folder = recentFolders.first ?? FileManager.default.homeDirectoryForCurrentUser.path }
    }

    /// Folders of recent chats (this harness), newest first, as candidates for a new task.
    private var recentFolders: [String] {
        var seen = Set<String>()
        return sessions.map(\.cwd).filter { isDirectory($0) && seen.insert($0).inserted }
    }

    private func isDirectory(_ p: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: p, isDirectory: &dir) && dir.boolValue
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: folder)
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let u = panel.url { folder = u.path }
    }

    private func schedule() {
        if newTask {
            let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let firstLine = p.split(separator: "\n").first.map(String.init) ?? p
            model.schedule(Job(harness: harness, sessionId: "", cwd: folder,
                               title: firstLine.count > 60 ? String(firstLine.prefix(60)) + "…" : firstLine,
                               message: p, permission: permission, fireDate: fireDate, mode: .new))
            prompt = ""
            return
        }
        guard let s = selected else { return }
        // Ask now, while you're here: typing into the Codex app later needs Accessibility.
        if harness == .codex && mode == .resume { CodexApp.accessibilityGranted(prompt: true) }
        model.schedule(Job(harness: harness, sessionId: s.id, cwd: s.cwd, title: s.title,
                           message: message, permission: permission, fireDate: fireDate,
                           mode: mode, transcript: s.path.path, contextTokens: s.contextTokens))
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
        let h = job.harness.rawValue + (job.mode == .fresh ? " · fresh" : job.mode == .new ? " · new task" : "")
        switch job.status {
        case .scheduled: return "\(h) · at \(t) · in \(countdown(job.fireDate.timeIntervalSince(model.now)))"
        case .running: return "\(h) · running…"
        case .done: return "\(h) · done at \(t)" + (job.note.map { " · \($0)" } ?? "")
        case .failed: return "\(h) · failed" + (job.exitCode.map { " (exit \($0))" } ?? "")
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
