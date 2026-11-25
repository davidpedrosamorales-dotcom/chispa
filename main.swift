import Cocoa
import Carbon.HIToolbox
import SwiftUI
import IOKit.ps
import ServiceManagement
import UserNotifications

let home = FileManager.default.homeDirectoryForCurrentUser
let cacheDir = home.appendingPathComponent("Library/Caches/local.chispa")
let claudeStateDir = cacheDir.appendingPathComponent("claude")
/// Carpeta donde viven los proyectos. Se elige en el menú; si no, ~/Documents/Proyectos Claude.
var projectsURL: URL {
    if let p = UserDefaults.standard.string(forKey: "projectsFolder") { return URL(fileURLWithPath: p) }
    return home.appendingPathComponent("Documents/Proyectos Claude")
}
var projectsName: String { projectsURL.lastPathComponent }
/// El código de Chispa, si está en la carpeta de proyectos (para «Editar Chispa»).
var ownSourceURL: URL { projectsURL.appendingPathComponent("Chispa") }

// MARK: - pmset
func isSleepDisabled() -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = ["-g"]
    let pipe = Pipe()
    p.standardOutput = pipe
    try? p.run()
    p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    for line in out.split(separator: "\n") where line.contains("SleepDisabled") {
        return line.trimmingCharacters(in: .whitespaces).hasSuffix("1")
    }
    return false
}

func setSleepDisabled(_ disabled: Bool) -> Bool {
    let value = disabled ? "1" : "0"
    // 1) Sin contraseña (regla en /etc/sudoers.d/chispa)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
    p.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", value]
    p.standardError = Pipe()
    try? p.run()
    p.waitUntilExit()
    if p.terminationStatus == 0 { return true }
    // 2) Si no, pide la contraseña con el diálogo de macOS
    let src = "do shell script \"/usr/bin/pmset -a disablesleep \(value)\" with administrator privileges"
    var err: NSDictionary?
    NSAppleScript(source: src)?.executeAndReturnError(&err)
    return err == nil
}

/// true si la tapa está cerrada (IOPMrootDomain → AppleClamshellState)
func isLidClosed() -> Bool {
    let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard root != 0 else { return false }
    defer { IOObjectRelease(root) }
    let v = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
    return (v?.takeRetainedValue() as? Bool) ?? false
}

/// Pone el Mac en reposo ya (no necesita permisos de administrador)
func sleepNow() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = ["sleepnow"]
    try? p.run()
}

/// Tras volver al reposo normal: si la tapa ya estaba cerrada, macOS no lo
/// duerme solo (el cierre de tapa ya pasó), así que lo dormimos nosotros.
func sleepIfLidClosed() {
    guard isLidClosed() else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {   // deja salir la notificación
        if isLidClosed() && !isSleepDisabled() { sleepNow() }
    }
}

func displayOffNow() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = ["displaysleepnow"]
    try? p.run()
}

// MARK: - Batería
struct Battery { let level: Int; let charging: Bool; let onAC: Bool }

func readBattery() -> Battery? {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
    for ps in list {
        guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
        let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
        let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
        let charging = d[kIOPSIsChargingKey] as? Bool ?? false
        let onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        return Battery(level: max > 0 ? cur * 100 / max : cur, charging: charging, onAC: onAC)
    }
    return nil
}

// MARK: - CPU y memoria
/// Uso de CPU (0–1) desde la última llamada, a partir de los ticks del sistema.
var prevCPUTicks: (used: UInt64, total: UInt64)?
func readCPU() -> Double? {
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
    let r = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
    }
    guard r == KERN_SUCCESS else { return nil }
    let t = info.cpu_ticks
    let user = UInt64(t.0), sys = UInt64(t.1), idle = UInt64(t.2), nice = UInt64(t.3)
    let used = user + sys + nice, total = used + idle
    defer { prevCPUTicks = (used, total) }
    guard let p = prevCPUTicks, total > p.total else { return nil }
    return Double(used - p.used) / Double(total - p.total)
}

/// Memoria usada (como "Memoria usada" del Monitor de Actividad) y total, en bytes.
func readMemory() -> (used: UInt64, total: UInt64)? {
    var s = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
    let r = withUnsafeMutablePointer(to: &s) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
    }
    guard r == KERN_SUCCESS else { return nil }
    let page = UInt64(vm_kernel_page_size)
    let app = UInt64(s.internal_page_count) - min(UInt64(s.internal_page_count), UInt64(s.purgeable_count))
    let used = (app + UInt64(s.wire_count) + UInt64(s.compressor_page_count)) * page
    return (used, ProcessInfo.processInfo.physicalMemory)
}

/// Apps que más memoria usan (huella física, como el Monitor de Actividad),
/// agrupando los procesos auxiliares con su app (p. ej. todas las pestañas de Chrome).
/// Solo ve los procesos del usuario; los del sistema no dejan leerse sin ser root.
func readTopApps(_ n: Int) -> [(name: String, bytes: UInt64, app: String?)] {
    var bundles: [String: String] = [:]
    let cap = proc_listallpids(nil, 0) + 64
    guard cap > 64 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(cap))
    let got = Int(proc_listallpids(&pids, cap * Int32(MemoryLayout<pid_t>.size)))
    var totals: [String: UInt64] = [:]
    var pathBuf = [CChar](repeating: 0, count: 4096)
    for pid in pids.prefix(max(0, got)) where pid > 0 {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard ok == 0, info.ri_phys_footprint > 0 else { continue }
        guard proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 else { continue }
        let path = String(cString: pathBuf)
        var name: String
        var bundle: String? = nil
        if let r = path.range(of: ".app/") {
            name = String(path[..<r.lowerBound].split(separator: "/").last ?? "")
            bundle = String(path[..<r.lowerBound]) + ".app"
        } else {
            name = (path as NSString).lastPathComponent
        }
        if name == "claude" || path.contains("/claude/versions/") { name = "Claude Code" }
        else if name.hasPrefix("com.apple.Virtualization") { name = "Máquina virtual"; bundle = nil }
        else if name == "MTLCompilerService" { name = "Gráficos del sistema" }
        else if name == "node" { name = "Node.js" }
        totals[name, default: 0] += info.ri_phys_footprint
        if let bundle, bundles[name] == nil { bundles[name] = bundle }
    }
    return totals.sorted { $0.value > $1.value }.prefix(n).map { ($0.key, $0.value, bundles[$0.key]) }
}

/// Espacio del disco de arranque: libre (el que muestra Finder) y total, en bytes.
func readDisk() -> (free: Int64, total: Int64)? {
    let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
    guard let free = v?.volumeAvailableCapacityForImportantUsage, let total = v?.volumeTotalCapacity, total > 0 else { return nil }
    return (free, Int64(total))
}

// MARK: - Claude: límites de uso (sesión, semana, por modelo)
struct UsageLimit { let name: String; let percent: Double; let resetsAt: Date? }

/// Lee el token de Claude Code del Llavero (no lo renueva: eso lo hace Claude Code) y pide el uso a Anthropic.
func fetchClaudeUsage(_ done: @escaping ([String: UsageLimit]?) -> Void) {
    DispatchQueue.global(qos: .utility).async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let cred = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = cred["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return DispatchQueue.main.async { done(nil) } }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            var out: [String: UsageLimit]?
            if (resp as? HTTPURLResponse)?.statusCode == 200, let data,
               let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let limits = j["limits"] as? [[String: Any]] {
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                var m: [String: UsageLimit] = [:]
                for l in limits {
                    let kind = l["kind"] as? String ?? ""
                    let pct = (l["percent"] as? NSNumber)?.doubleValue ?? 0
                    let reset = (l["resets_at"] as? String).flatMap { iso.date(from: $0) }
                    let model = ((l["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                    let key = kind == "session" ? "session" : kind == "weekly_all" ? "weekly" : model ?? kind
                    m[key] = UsageLimit(name: model ?? key, percent: pct, resetsAt: reset)
                }
                out = m
            }
            DispatchQueue.main.async { done(out) }
        }.resume()
    }
}

func shortUntil(_ d: Date?) -> String {
    guard let d else { return "" }
    let s = max(0, Int(d.timeIntervalSinceNow))
    return s >= 86400 ? "\(s / 86400) d" : s >= 3600 ? "\(s / 3600) h" : "\(max(1, s / 60)) min"
}

// MARK: - Notificaciones
func notify(_ title: String, _ body: String) {
    let c = UNMutableNotificationContent()
    c.title = title
    c.body = body
    c.sound = .default
    UNUserNotificationCenter.current().add(
        UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
}

// MARK: - Claude: proyectos y lanzamiento
func isDir(_ u: URL) -> Bool { (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }

func sortedSubdirs(_ u: URL) -> [URL] {
    let items = (try? FileManager.default.contentsOfDirectory(
        at: u, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
    return items.filter(isDir).sorted {
        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
}

func listProjects() -> [(name: String, url: URL)] {
    try? FileManager.default.createDirectory(at: projectsURL, withIntermediateDirectories: true)
    var out: [(String, URL)] = [(projectsName, projectsURL)]
    let fm = FileManager.default
    for d in sortedSubdirs(projectsURL) {
        out.append((d.lastPathComponent, d))
        for d2 in sortedSubdirs(d) where
            fm.fileExists(atPath: d2.appendingPathComponent(".git").path) ||
            fm.fileExists(atPath: d2.appendingPathComponent("package.json").path) {
            out.append(("\(d.lastPathComponent)/\(d2.lastPathComponent)", d2))
        }
    }
    return out
}

func launchClaude(in dir: URL, continueLast: Bool, prompt: String? = nil) {
    try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    let id = UUID().uuidString
    let f = cacheDir.appendingPathComponent("launch-\(id).command")
    let q = "'" + dir.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    var cmd = continueLast ? "claude --continue || claude" : "claude"
    var pre = ""
    if let prompt {
        // La petición viaja en un archivo aparte: así no hay que escaparla dentro del comando
        let pf = cacheDir.appendingPathComponent("prompt-\(id).txt")
        guard (try? prompt.write(to: pf, atomically: true, encoding: .utf8)) != nil else { return }
        let pq = "'" + pf.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        pre = "export WIDGET_PROMPT=\"$(cat \(pq))\"\nrm -f \(pq)\n"
        cmd = "claude -- \"$WIDGET_PROMPT\""
    }
    let script = "#!/bin/zsh\nrm -f \"$0\"\ncd \(q)\n\(pre)clear\nexec zsh -lic '\(cmd)'\n"
    do {
        try script.write(to: f, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
    } catch { return }
    NSWorkspace.shared.open([f], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                            configuration: NSWorkspace.OpenConfiguration())
}

// MARK: - Claude: estado (escrito por los hooks de Claude Code)
struct ClaudeSession { let id: String; let state: String; let cwd: String; let date: Date; var tty = ""
    var activity = ""; var start: Date?; var steps = 0; var end: Date?
    var project: String { cwd.isEmpty ? "Claude" : (cwd as NSString).lastPathComponent }
}

func readClaudeSessions() -> [ClaudeSession] {
    let fm = FileManager.default
    let files = (try? fm.contentsOfDirectory(at: claudeStateDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    var out: [ClaudeSession] = []
    for f in files {
        guard let txt = try? String(contentsOf: f, encoding: .utf8) else { continue }
        let lines = txt.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let state = lines.first ?? ""
        let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        let age = Date().timeIntervalSince(date)
        // Limpieza de estados viejos (sesiones cerradas a lo bruto, etc.)
        let maxAge: TimeInterval = state == "working" ? 3 * 3600 : state == "done" ? 30 * 60 : 3600
        if age > maxAge { try? fm.removeItem(at: f); continue }
        func epoch(_ i: Int) -> Date? { lines.count > i ? Double(lines[i]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil } : nil }
        out.append(ClaudeSession(id: f.lastPathComponent, state: state, cwd: lines.count > 1 ? lines[1] : "", date: date,
                                 tty: lines.count > 2 ? lines[2].trimmingCharacters(in: .whitespaces) : "",
                                 activity: lines.count > 3 ? lines[3] : "", start: epoch(4),
                                 steps: lines.count > 5 ? Int(lines[5]) ?? 0 : 0, end: epoch(6)))
    }
    return out
}

/// Trae al frente la pestaña de Terminal de esa sesión (por su tty). Devuelve false si no la encuentra.
func focusTerminalTab(tty: String) -> Bool {
    guard tty.hasPrefix("ttys"), tty.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
    let src = """
    tell application "Terminal"
        repeat with w in windows
            repeat with t in tabs of w
                if tty of t is "/dev/\(tty)" then
                    set selected of t to true
                    set index of w to 1
                    activate
                    return true
                end if
            end repeat
        end repeat
    end tell
    return false
    """
    var err: NSDictionary?
    let r = NSAppleScript(source: src)?.executeAndReturnError(&err)
    return err == nil && r?.booleanValue == true
}

func clearDoneSessions() {
    for s in readClaudeSessions() where s.state == "done" {
        try? FileManager.default.removeItem(at: claudeStateDir.appendingPathComponent(s.id))
    }
}

// MARK: - Claude: resultados (leídos de las transcripciones reales de Claude Code)
struct WorkStats { var tasks = 0; var seconds = 0.0; var projects = 0 }

/// Lee ~/.claude/projects/*/*.jsonl de forma incremental (solo lo nuevo de cada archivo).
/// Tarea = petición tuya que Claude ha respondido. Tiempo = lo que Claude ha estado trabajando
/// dentro de cada tarea, sin contar pausas de más de 5 minutos (esperas de permiso, etc.).
final class WorkStatsReader {
    private struct Turn { var start: Date; var active: Double; var answered: Bool }
    private struct FileState { var offset: UInt64 = 0; var turns: [Turn] = []; var last: Date?; var project = ""; var title = "" }
    private let titleTag = Data("\"type\":\"ai-title\"".utf8)

    /// Sesiones de los últimos 7 días, para el informe.
    func weekSessions(exclude: Set<String> = [], _ done: @escaping ([SessionReport], _ previousWeekTasks: Int) -> Void) {
        queue.async {
            self.scan()
            let since = Calendar.current.startOfDay(for: Date().addingTimeInterval(-6 * 86400))
            let before = since.addingTimeInterval(-7 * 86400)
            let prev = self.files.values.filter { !exclude.contains($0.project) }
                .reduce(0) { $0 + $1.turns.filter { $0.answered && $0.start >= before && $0.start < since }.count }
            let out: [SessionReport] = self.files.values.filter { !exclude.contains($0.project) }.compactMap { f in
                let t = f.turns.filter { $0.answered && $0.start >= since }
                return t.isEmpty ? nil : SessionReport(project: f.project, title: f.title, turns: t.map { ($0.start, $0.active) })
            }
            DispatchQueue.main.async { done(out, prev) }
        }
    }
    private var files: [String: FileState] = [:]
    private let queue = DispatchQueue(label: "local.chispa.stats", qos: .utility)
    private let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private let isoPlain = ISO8601DateFormatter()
    private let userTag = Data("\"type\":\"user\"".utf8), asstTag = Data("\"type\":\"assistant\"".utf8)
    private let apiTag = Data("{\"type\":\"api-".utf8)

    /// Proyectos vistos (últimos 8 días) y carpeta de origen de cada sesión (por su id). Solo en el hilo principal.
    private(set) var projects: [String] = []
    private(set) var projectBySession: [String: String] = [:]

    func refresh(exclude: Set<String> = [], _ done: @escaping (_ today: WorkStats, _ week: WorkStats, _ perDay: [Int]) -> Void) {
        queue.async {
            self.scan()
            let projs = Array(Set(self.files.values.filter { !$0.turns.isEmpty && !$0.project.isEmpty }.map(\.project))).sorted()
            let bySession = Dictionary(self.files.map { ((($0.key as NSString).lastPathComponent as NSString).deletingPathExtension, $0.value.project) },
                                       uniquingKeysWith: { a, _ in a })
            DispatchQueue.main.async { self.projects = projs; self.projectBySession = bySession }
            let now = Date()
            let midnight = Calendar.current.startOfDay(for: now)
            let weekAgo = now.addingTimeInterval(-7 * 86400)
            func stats(since: Date) -> WorkStats {
                var st = WorkStats(); var projs = Set<String>()
                for (_, f) in self.files where !exclude.contains(f.project) {
                    for t in f.turns where t.answered && t.start >= since {
                        st.tasks += 1; st.seconds += t.active; projs.insert(f.project)
                    }
                }
                st.projects = projs.count
                return st
            }
            let a = stats(since: midnight), b = stats(since: weekAgo)
            // Tareas de cada uno de los últimos 7 días (el último es hoy)
            var perDay = [Int](repeating: 0, count: 7)
            let cal = Calendar.current
            for (_, f) in self.files where !exclude.contains(f.project) {
                for t in f.turns where t.answered {
                    let d = cal.dateComponents([.day], from: cal.startOfDay(for: t.start), to: midnight).day ?? 99
                    if d >= 0 && d < 7 { perDay[6 - d] += 1 }
                }
            }
            DispatchQueue.main.async { done(a, b, perDay) }
        }
    }

    private func scan() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-15 * 86400)
        var seen = Set<String>()
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
            where f.pathExtension == "jsonl" {
                guard let v = try? f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let m = v.contentModificationDate, m > cutoff, let size = v.fileSize else { continue }
                seen.insert(f.path)
                var st = files[f.path] ?? FileState()
                if UInt64(size) < st.offset { st = FileState() }            // archivo reescrito: empezar de cero
                if UInt64(size) > st.offset { autoreleasepool { read(f, &st) } }
                // Solo interesan los últimos 8 días
                st.turns.removeAll { $0.start < cutoff }
                files[f.path] = st
            }
        }
        files = files.filter { seen.contains($0.key) }
    }

    private func read(_ url: URL, _ st: inout FileState) {
        // Mapeado en memoria: no carga el archivo entero, solo las páginas que se leen
        guard let whole = try? Data(contentsOf: url, options: .alwaysMapped), UInt64(whole.count) > st.offset else { return }
        let data = whole[whole.index(whole.startIndex, offsetBy: Int(st.offset))...]
        var lineStart = data.startIndex
        while let nl = data[lineStart...].firstIndex(of: 0x0A) {
            let line = data[lineStart..<nl]
            lineStart = data.index(after: nl)
            if line.count < 40 || line.starts(with: apiTag) { continue }
            if line.count < 3000, line.range(of: titleTag) != nil {          // título que Claude le pone a la sesión
                if let d = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let t = d["aiTitle"] as? String { st.title = t }
                continue
            }
            let head = line.prefix(4000)
            // "type" aparece al principio o al final según la versión: se mira toda la línea si hace falta
            if head.range(of: userTag) == nil && head.range(of: asstTag) == nil
                && line.range(of: userTag) == nil && line.range(of: asstTag) == nil { continue }
            let parsed: Any? = autoreleasepool { try? JSONSerialization.jsonObject(with: line) }
            guard let d = parsed as? [String: Any],
                  let type = d["type"] as? String, type == "user" || type == "assistant",
                  (d["isSidechain"] as? Bool) != true,
                  let tsStr = d["timestamp"] as? String,
                  let ts = iso.date(from: tsStr) ?? isoPlain.date(from: tsStr) else { continue }
            if st.project.isEmpty, let cwd = d["cwd"] as? String { st.project = cwd }
            let content = (d["message"] as? [String: Any])?["content"]
            var realPrompt = false
            if type == "user" && (d["isMeta"] as? Bool) != true {
                if content is String { realPrompt = true }
                else if let blocks = content as? [[String: Any]] {
                    realPrompt = !blocks.contains { ($0["type"] as? String) == "tool_result" }
                }
            }
            if realPrompt {
                st.turns.append(Turn(start: ts, active: 0, answered: false))
                st.last = ts
            } else if !st.turns.isEmpty, let last = st.last {
                let gap = ts.timeIntervalSince(last)
                if gap > 0 && gap <= 300 { st.turns[st.turns.count - 1].active += gap }
                st.last = ts
                if type == "assistant" { st.turns[st.turns.count - 1].answered = true }
            }
        }
        st.offset += UInt64(lineStart - data.startIndex)     // la última línea a medias se relee luego
    }
}

struct SessionReport { let project: String; let title: String; let turns: [(start: Date, seconds: Double)] }

// MARK: - Informe semanal (página HTML lista para imprimir o guardar como PDF)
func htmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
}

func longDuration(_ s: Double) -> String {
    let m = Int((s / 60).rounded())
    return m < 60 ? "\(m) min" : m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
}

/// Capturas fijadas en la cuerda (CapturasClip), reducidas e incrustadas en la página.
func pinnedShotsHTML() -> String {
    let paths = (UserDefaults(suiteName: "local.capturasclip")?.stringArray(forKey: "pinned") ?? []).prefix(6)
    var out = ""
    for p in paths {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1400, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary),
              let jpg = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { continue }
        out += "<figure><img src=\"data:image/jpeg;base64,\(jpg.base64EncodedString())\"><figcaption contenteditable>Escribe un pie para esta captura</figcaption></figure>\n"
    }
    return out
}

func buildWeeklyReport(_ sessions: [SessionReport], previousWeekTasks: Int = 0) -> String {
    let cal = Calendar.current
    let today = cal.startOfDay(for: Date())
    let days = (0..<7).map { cal.date(byAdding: .day, value: $0 - 6, to: today)! }
    let es = Locale(identifier: "es_ES")
    let dRange = DateFormatter(); dRange.locale = es; dRange.dateFormat = "d 'de' MMMM"
    let dDay = DateFormatter(); dDay.locale = es; dDay.dateFormat = "d"
    let dShort = DateFormatter(); dShort.locale = es; dShort.dateFormat = "EEE d"
    let dLong = DateFormatter(); dLong.locale = es; dLong.dateFormat = "EEEE d"
    let dYear = DateFormatter(); dYear.locale = es; dYear.dateFormat = "yyyy"

    let turns = sessions.flatMap { s in s.turns.map { (project: s.project, start: $0.start, seconds: $0.seconds) } }
    let totalTasks = turns.count

    // Pico de agentes trabajando a la vez (sesiones distintas con tareas solapadas)
    var events: [(Date, Int)] = []
    for s in sessions { for t in s.turns where t.seconds > 1 { events.append((t.start, 1)); events.append((t.start.addingTimeInterval(t.seconds), -1)) } }
    events.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
    var cur = 0, peak = 0
    for e in events { cur += e.1; peak = max(peak, cur) }

    // Por proyecto
    struct Proj { var name: String; var path: String; var tasks = 0; var secs = 0.0; var sessions = 0; var titles: [String] = []
                  var perDay = [Int](repeating: 0, count: 7); var grid = [Int](repeating: 0, count: 168); var longest = 0.0 }
    var projs: [String: Proj] = [:]
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    for s in sessions {
        let name = s.project.isEmpty ? "Sin carpeta" : s.project == home ? "Carpeta personal" : (s.project as NSString).lastPathComponent
        var p = projs[s.project] ?? Proj(name: name, path: s.project)
        p.tasks += s.turns.count
        p.secs += s.turns.reduce(0) { $0 + $1.seconds }
        p.sessions += 1
        for t in s.turns {
            p.longest = max(p.longest, t.seconds)
            if let i = days.firstIndex(where: { cal.isDate(t.start, inSameDayAs: $0) }) {
                p.perDay[i] += 1
                p.grid[i * 24 + cal.component(.hour, from: t.start)] += 1
            }
        }
        if !s.title.isEmpty && !p.titles.contains(s.title) { p.titles.append(s.title) }
        projs[s.project] = p
    }
    let list = projs.values.sorted { $0.secs > $1.secs }
    let palette = ["#f08a66", "#7c9bff", "#4fd696", "#f2c14e", "#c491ff", "#4fd0e0", "#ff7fa3", "#a3acbb"]

    var dayCols = "", dayLabels = "", gridRows = ""
    for d in days {
        let weekend = cal.isDateInWeekend(d)
        dayCols += "<div class=\"col\"><i></i><div class=\"bar\"></div></div>"
        dayLabels += "<span class=\"\(weekend ? "we" : "")\">\(dShort.string(from: d))</span>"
        gridRows += "<div class=\"gl\">\(dShort.string(from: d))</div>" + String(repeating: "<div class=\"gc\"></div>", count: 24)
    }
    var projHTML = ""
    for (i, p) in list.enumerated() {
        projHTML += """
        <section class="proj" style="--c:\(palette[min(i, palette.count - 1)]);--d:\(i)" data-tasks="\(p.tasks)" data-secs="\(Int(p.secs))" data-max="\(Int(p.longest))" data-days="\(p.perDay.map(String.init).joined(separator: ","))" data-grid="\(p.grid.map(String.init).joined(separator: ","))">
          <button class="rm" title="Quitar este proyecto del informe (las cifras se recalculan)">Quitar</button>
          <span class="dot"></span>
          <div class="pmid"><div class="phead"><h3 contenteditable>\(htmlEscape(p.name))</h3><span class="pm">\(p.tasks) tareas · \(longDuration(p.secs))</span></div>
            <div class="track"><div class="fill"></div></div></div>
          <span class="pct"></span>
        </section>

        """
    }
    let shots = pinnedShotsHTML()
    let sameMonth = cal.component(.month, from: days[0]) == cal.component(.month, from: days[6])
    let range = "\(sameMonth ? dDay.string(from: days[0]) : dRange.string(from: days[0])) – \(dRange.string(from: days[6])) de \(dYear.string(from: days[6]))"
    let dayNames = days.map { "\"" + dLong.string(from: $0) + "\"" }.joined(separator: ",")

    return """
    <!doctype html><html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Informe semanal · \(range)</title>
    <style>
    :root{--ink:#f4f4f6;--mut:#9a9aa6;--line:rgba(255,255,255,.09);--acc:#f08a66;--bg:#08080a;--card:rgba(255,255,255,.055)}
    *{box-sizing:border-box}html{background:var(--bg)}
    body{margin:0;color:var(--ink);font:15px/1.5 -apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;-webkit-font-smoothing:antialiased;
      background:radial-gradient(1100px 700px at 12% -8%,rgba(240,138,102,.20),transparent 60%),radial-gradient(900px 700px at 100% 28%,rgba(124,155,255,.13),transparent 60%),radial-gradient(900px 800px at 0% 78%,rgba(79,214,150,.08),transparent 60%),var(--bg)}
    .page{max-width:940px;margin:0 auto;padding:26px 28px 70px}
    .tools{display:flex;gap:12px;align-items:center;margin-bottom:18px;color:var(--mut);font-size:13px}
    .tools button{font:inherit;font-weight:650;color:#1a0f0b;background:linear-gradient(180deg,#ffb399,#f08a66);border:0;border-radius:999px;padding:8px 17px;cursor:pointer;box-shadow:0 6px 20px rgba(240,138,102,.35)}
    @keyframes up{from{opacity:0;transform:translateY(18px)}to{opacity:1;transform:none}}
    @keyframes drift{0%,100%{transform:translate(0,0) scale(1)}50%{transform:translate(60px,30px) scale(1.15)}}
    @keyframes bob{0%,100%{transform:translateY(0)}50%{transform:translateY(-5px)}}
    @keyframes flick{0%,100%{transform:scaleY(1) skewX(0)}30%{transform:scaleY(1.18) skewX(-5deg)}60%{transform:scaleY(.92) skewX(4deg)}}
    @keyframes grow{from{transform:scaleY(0)}to{transform:scaleY(1)}}
    @keyframes widen{from{transform:scaleX(0)}to{transform:scaleX(1)}}
    @keyframes spin{from{transform:rotate(-90deg);opacity:0}to{transform:rotate(0);opacity:1}}
    @keyframes pop{from{opacity:0;transform:scale(.6)}to{opacity:1;transform:none}}
    .a{animation:up .7s cubic-bezier(.2,.8,.2,1) both;animation-delay:calc(var(--d,0)*70ms)}
    .hero{position:relative;overflow:hidden;border-radius:34px;padding:34px 36px 30px;background:#101013;border:1px solid rgba(255,255,255,.10);
      box-shadow:0 30px 90px rgba(0,0,0,.6),0 0 0 1px rgba(240,138,102,.10),0 0 120px rgba(240,138,102,.16)}
    .orb{position:absolute;border-radius:50%;filter:blur(70px);animation:drift 14s ease-in-out infinite}
    .o1{width:520px;height:380px;left:-140px;top:-170px;background:rgba(240,138,102,.60)}
    .o2{width:420px;height:340px;right:-140px;bottom:-190px;background:rgba(124,155,255,.34);animation-duration:19s;animation-direction:reverse}
    .o3{width:260px;height:220px;right:22%;top:-150px;background:rgba(196,145,255,.26);animation-duration:23s}
    .hero>*:not(.orb){position:relative}
    .top{display:flex;gap:18px;align-items:center}
    .top svg{flex:none;width:92px;height:102px;overflow:visible;filter:drop-shadow(0 10px 24px rgba(240,138,102,.6));animation:bob 3.2s ease-in-out infinite}
    .top svg .fl{transform-origin:38px 24px;animation:flick .9s ease-in-out infinite}
    .k{font-size:11.5px;font-weight:700;letter-spacing:.14em;text-transform:uppercase;color:#ffb399}
    h1{font-size:38px;line-height:1.1;margin:4px 0 4px;letter-spacing:-.03em;font-weight:780}
    .who{color:rgba(255,255,255,.6)}
    .big{display:flex;align-items:flex-end;gap:22px;margin:30px 0 26px;flex-wrap:wrap}
    .big b{font-size:168px;line-height:.82;font-weight:850;letter-spacing:-.06em;font-variant-numeric:tabular-nums;
      background:linear-gradient(175deg,#fff 25%,#ffc4ae 60%,#f08a66);-webkit-background-clip:text;background-clip:text;color:transparent;filter:drop-shadow(0 10px 40px rgba(240,138,102,.35))}
    .big>span{font-size:22px;line-height:1.25;color:rgba(255,255,255,.7);padding-bottom:10px}.big em{font-style:normal;color:#fff;font-weight:680;font-size:27px}
    .delta{display:inline-flex;align-items:center;gap:6px;margin-top:10px;font-size:14px;font-weight:700;border-radius:999px;padding:5px 12px;animation:pop .5s .9s both}
    .delta.up{color:#0c2417;background:linear-gradient(180deg,#7ff0b6,#4fd696);box-shadow:0 6px 22px rgba(79,214,150,.35)}
    .delta.down{color:#ffd9d2;background:rgba(255,255,255,.10)}
    .kpis{display:grid;grid-template-columns:repeat(5,1fr);gap:10px}
    .kpi{background:rgba(255,255,255,.07);border:1px solid rgba(255,255,255,.10);border-radius:18px;padding:13px 15px;backdrop-filter:blur(20px)}
    .kpi b{display:block;font-size:23px;font-weight:720;letter-spacing:-.02em;font-variant-numeric:tabular-nums;white-space:nowrap}
    .kpi span{color:rgba(255,255,255,.55);font-size:12px;line-height:1.3;display:block}
    .summary{margin:16px 0 0;font-size:17.5px;padding:17px 20px;background:var(--card);border-radius:20px;border:1px solid var(--line);min-height:60px}
    .summary:empty::before{content:"Escribe aquí, en dos o tres líneas, lo más importante de la semana: qué se entregó y qué cambia para el equipo.";color:#6c6c78}
    .ins{display:grid;grid-template-columns:repeat(3,1fr);gap:12px;margin-top:12px}
    .in{position:relative;overflow:hidden;background:var(--card);border:1px solid var(--line);border-radius:20px;padding:15px 17px}
    .in::after{content:"";position:absolute;right:-30px;top:-30px;width:90px;height:90px;border-radius:50%;background:var(--g,#f08a66);opacity:.16;filter:blur(18px)}
    .in small{display:block;font-size:11px;font-weight:700;letter-spacing:.09em;text-transform:uppercase;color:var(--g,#f08a66)}
    .in b{display:block;font-size:21px;letter-spacing:-.015em;margin-top:3px;text-transform:capitalize}.in b.raw{text-transform:none}
    .in span{color:var(--mut);font-size:13px}
    h2{font-size:12px;font-weight:700;letter-spacing:.12em;text-transform:uppercase;color:var(--mut);margin:38px 0 12px}
    .card{background:var(--card);border:1px solid var(--line);border-radius:22px;padding:20px 22px 16px}
    .plot{position:relative;height:216px;display:flex;gap:16px;align-items:flex-end;padding-top:26px}
    .col{position:relative;flex:1;height:100%;display:flex;align-items:flex-end;justify-content:center}
    .bar{width:100%;max-width:84px;border-radius:12px 12px 4px 4px;background:rgba(255,255,255,.07);transform-origin:bottom;animation:grow .9s cubic-bezier(.2,.9,.2,1) both;animation-delay:calc(var(--i)*80ms + .2s)}
    .col.on .bar{background:linear-gradient(180deg,rgba(240,138,102,.75),rgba(240,138,102,.28))}
    .col.best .bar{background:linear-gradient(180deg,#ffb399,#f08a66 45%,#c7583a);box-shadow:0 0 44px rgba(240,138,102,.55)}
    .col i{position:absolute;left:0;right:0;text-align:center;font-style:normal;font-size:14px;font-weight:720;font-variant-numeric:tabular-nums;animation:up .5s both;animation-delay:calc(var(--i)*80ms + .8s)}
    .col.best i{color:#ffb399;font-size:17px}
    .avg{position:absolute;left:0;right:0;border-top:1.5px dashed rgba(255,255,255,.28);pointer-events:none}
    .avg span{position:absolute;right:0;top:-19px;font-size:11px;color:var(--mut)}
    .labels{display:flex;gap:16px;margin-top:9px}.labels span{flex:1;text-align:center;font-size:12.5px;color:var(--mut);text-transform:capitalize}.labels .we{opacity:.55}
    .two{display:grid;grid-template-columns:1fr 1fr;gap:12px}.two h2{margin-top:0}.two>div{display:flex;flex-direction:column}.two .card{flex:1}
    .split{display:flex;gap:18px;align-items:center;height:100%}
    .split svg{flex:none;width:150px;height:150px;animation:spin 1.1s .3s cubic-bezier(.2,.8,.2,1) both;filter:drop-shadow(0 0 22px rgba(240,138,102,.22))}
    .leg{flex:1;min-width:0}.leg div{display:flex;align-items:center;gap:8px;font-size:13.5px;padding:3.5px 0}
    .leg i{flex:none;width:9px;height:9px;border-radius:3px}.leg b{flex:1;min-width:0;font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    .leg span{color:var(--mut);font-variant-numeric:tabular-nums;white-space:nowrap}
    .grid{display:grid;grid-template-columns:50px repeat(24,1fr);gap:3px;align-items:center}
    .gl{font-size:11px;line-height:1;color:var(--mut);text-transform:capitalize;white-space:nowrap}
    .gc{height:15px;border-radius:3.5px;background:rgba(255,255,255,.06)}
    .hax{display:grid;grid-template-columns:50px repeat(4,1fr);font-size:11px;color:var(--mut);margin-top:6px}
    .hnote{font-size:13.5px;margin:0 0 13px;color:#d6d6de}.hnote b{font-weight:680;color:#fff}
    .proj{position:relative;overflow:hidden;background:var(--card);border:1px solid var(--line);border-radius:22px;padding:19px 26px 19px 24px;margin-bottom:12px;break-inside:avoid;display:flex;align-items:center;gap:20px;
      animation:up .6s both;animation-delay:calc(var(--d)*80ms + .2s)}
    .proj::after{content:"";position:absolute;left:-70px;top:-70px;width:260px;height:180px;background:var(--c);opacity:.16;filter:blur(50px);pointer-events:none}
    .rm{position:absolute;right:130px;top:12px;z-index:2;font:inherit;font-size:12px;color:var(--mut);background:rgba(0,0,0,.4);border:1px solid var(--line);border-radius:999px;padding:3px 11px;cursor:pointer;opacity:0;transition:opacity .15s}
    .proj:hover .rm{opacity:1}.rm:hover{color:#ff8f85;border-color:#ff8f85}
    .pmid{flex:1;min-width:0}.phead{display:flex;align-items:baseline;gap:12px}.dot{width:12px;height:12px;border-radius:50%;background:var(--c);box-shadow:0 0 12px var(--c);flex:none}
    h3{margin:0;font-size:21px;letter-spacing:-.015em}.pct{flex:none;min-width:96px;text-align:right;font-size:34px;line-height:1;font-weight:800;letter-spacing:-.03em;font-variant-numeric:tabular-nums;color:var(--c)}
    .pm{color:var(--mut);font-size:13px;font-variant-numeric:tabular-nums}
    .spark{display:flex;gap:3px;align-items:flex-end;height:26px}.spark i{width:8px;border-radius:2.5px;background:var(--c);min-height:2px}.spark i.z{background:rgba(255,255,255,.10)}
    .track{height:6px;background:rgba(255,255,255,.08);border-radius:3px;margin:9px 0 0;overflow:hidden}
    .fill{height:100%;background:var(--c);border-radius:3px;transform-origin:left;animation:widen 1s .5s cubic-bezier(.2,.8,.2,1) both}
    ul{margin:10px 0 0;padding-left:20px;color:#dcdce4}li{margin:2px 0}li::marker{color:var(--c)}
    figure{margin:0 0 14px;background:var(--card);border:1px solid var(--line);border-radius:22px;padding:10px;break-inside:avoid}
    figure img{width:100%;border-radius:13px;display:block}figcaption{color:var(--mut);font-size:13px;margin:8px 6px 2px}
    footer{margin-top:38px;color:#6f6f7b;font-size:12px;border-top:1px solid var(--line);padding-top:13px}
    [contenteditable]{outline:none;border-radius:6px}[contenteditable]:focus{box-shadow:0 0 0 2px rgba(240,138,102,.55)}
    .still *{animation:none!important}
    @media(max-width:720px){.kpis{grid-template-columns:repeat(2,1fr)}.ins,.two{grid-template-columns:1fr}h1{font-size:28px}.big b{font-size:110px}}
    @media print{.tools,.rm{display:none}.page{padding:14px;max-width:none}.summary:empty{display:none}.orb{animation:none}
      .card,.proj,.in,.summary,figure,.hero{break-inside:avoid}*{-webkit-print-color-adjust:exact;print-color-adjust:exact;animation:none!important}}
    </style></head><body><div class="page">
    <div class="tools"><button onclick="window.print()">Guardar como PDF</button><span>Antes de compartirlo, revisa tu nombre, los proyectos y las capturas: puedes editar o quitar lo que quieras. Nada de esto sale de tu Mac.</span></div>
    <section class="hero a">
      <div class="orb o1"></div><div class="orb o2"></div><div class="orb o3"></div>
      <div class="top">
        <svg viewBox="0 0 76 84"><defs><radialGradient id="mb" cx="35%" cy="30%" r="80%"><stop offset="0" stop-color="#ffd0ab"/><stop offset=".55" stop-color="#e8805c"/><stop offset="1" stop-color="#a84c33"/></radialGradient></defs>
          <g class="fl"><path d="M31 24 Q28 12 40 2 Q46 14 45 24 Z" fill="#ff9e40"/><path d="M34.5 24 Q33.5 17 39 11 Q42 18 41.5 24 Z" fill="#ffedb0"/></g>
          <circle cx="38" cy="50" r="30" fill="url(#mb)"/><ellipse cx="27" cy="33" rx="8" ry="4.5" fill="#fff" opacity=".3"/>
          <ellipse cx="20" cy="56" rx="5.5" ry="3" fill="#ff6b73" opacity=".42"/><ellipse cx="56" cy="56" rx="5.5" ry="3" fill="#ff6b73" opacity=".42"/>
          <path d="M22 49 Q27 42 32 49 M44 49 Q49 42 54 49" fill="none" stroke="#21140f" stroke-width="3" stroke-linecap="round"/>
          <path d="M30.5 57 Q38 66 45.5 57" fill="none" stroke="#21140f" stroke-width="2.8" stroke-linecap="round"/></svg>
        <div><div class="k">Informe semanal · trabajo con IA</div>
          <h1 contenteditable>\(range)</h1>
          <div class="who" contenteditable>\(htmlEscape(NSFullUserName()))</div></div>
      </div>
      <div class="big"><b id="kT">\(totalTasks)</b><span><em>tareas resueltas</em><br>por agentes de IA en 7 días<br><span id="delta"></span></span></div>
      <div class="kpis">
        <div class="kpi"><b id="kS"></b><span>de trabajo de los agentes</span></div>
        <div class="kpi"><b id="kP"></b><span>proyectos</span></div>
        <div class="kpi"><b id="kD"></b><span>días con actividad</span></div>
        <div class="kpi"><b id="kR"></b><span>tareas por día activo</span></div>
        <div class="kpi"><b id="kA"></b><span>de media por tarea</span></div>
      </div>
    </section>
    <div class="ins" id="ins"></div>
    <h2>Tareas por día</h2>
    <div class="card a" style="--d:4"><div class="plot">\(dayCols)</div><div class="labels">\(dayLabels)</div></div>
    <div class="two" style="margin-top:38px">
      <div><h2>Reparto del tiempo</h2><div class="card a" style="--d:5"><div class="split"><svg id="donut" viewBox="0 0 150 150"></svg><div class="leg" id="leg"></div></div></div></div>
      <div><h2>Cuándo trabajan los agentes</h2><div class="card a" style="--d:6"><p class="hnote" id="hnote"></p><div class="grid" id="grid">\(gridRows)</div>
        <div class="hax"><span></span><span>0 h</span><span>6 h</span><span>12 h</span><span>18 h</span></div></div></div>
    </div>
    <h2>Por proyecto</h2>
    \(projHTML.isEmpty ? "<p>No hay actividad registrada en los últimos 7 días.</p>" : projHTML)
    \(shots.isEmpty ? "" : "<h2>Capturas</h2>\n" + shots)
    <footer>Datos tomados de las sesiones de Claude Code de este Mac, sin estimaciones. «Tarea» es cada petición que el agente ha resuelto.
    El tiempo de los agentes no cuenta las pausas de más de 5 minutos. Los títulos de cada proyecto son los que Claude pone a cada sesión.</footer>
    </div>
    <script>
    // Todo se calcula a partir de las tarjetas de proyecto: al quitar una, el informe entero se rehace con lo que queda
    var STILL=location.hash=="#still";if(STILL)document.documentElement.classList.add("still");
    var DAYS=[\(dayNames)],CIRC=2*Math.PI*58,PREV=\(previousWeekTasks),PEAK=\(peak),first=true,edited=false;
    function dur(s){var m=Math.round(s/60);return m<60?m+" min":(m%60==0?(m/60)+" h":Math.floor(m/60)+" h "+(m%60)+" min")}
    function set(id,v){document.getElementById(id).textContent=v}
    function countUp(el,to){var t0=null;function f(ts){if(!t0)t0=ts;var k=Math.min(1,(ts-t0)/1400),e=1-Math.pow(1-k,4);el.textContent=Math.round(to*e);if(k<1)requestAnimationFrame(f)}requestAnimationFrame(f)}
    function card(g,label,big,sub,raw,i){return '<div class="in a" style="--g:'+g+';--d:'+(3+i*0.6)+'"><small>'+label+'</small><b'+(raw?' class="raw"':'')+'>'+big+'</b><span>'+sub+'</span></div>'}
    function render(){
      var ps=[].slice.call(document.querySelectorAll(".proj")),t=0,s=0,lg=0,d=[0,0,0,0,0,0,0],g=[],i;
      for(i=0;i<168;i++)g.push(0);
      ps.forEach(function(p){t+=+p.dataset.tasks;s+=+p.dataset.secs;lg=Math.max(lg,+p.dataset.max);
        p.dataset.days.split(",").forEach(function(v,i){d[i]+=+v});p.dataset.grid.split(",").forEach(function(v,i){g[i]+=+v})});
      var act=d.filter(function(v){return v>0}).length;
      if(first&&!STILL&&matchMedia("screen").matches)countUp(document.getElementById("kT"),t);else set("kT",t);
      set("kS",dur(s));set("kP",ps.length);set("kD",act+" de 7");set("kR",act?Math.round(t/act):0);set("kA",t?dur(s/t):"—");
      // comparación con la semana anterior (solo mientras el informe está completo)
      var de=document.getElementById("delta");
      if(PREV>0&&!edited&&t>PREV){var pc=Math.round((t-PREV)/PREV*100);de.className="delta up";
        de.textContent="▲ +"+pc+" % frente a la semana anterior ("+PREV+")"}else{de.className="";de.textContent=""}
      // barras
      var mx=Math.max.apply(null,d.concat([1])),best=d.indexOf(Math.max.apply(null,d));
      [].slice.call(document.querySelectorAll(".col")).forEach(function(c,i){
        var pc=d[i]?Math.max(3,d[i]/mx*100):1.5;c.style.setProperty("--i",i);
        c.querySelector(".bar").style.height=pc+"%";
        var n=c.querySelector("i");n.textContent=d[i]||"";n.style.bottom="calc("+pc+"% + 5px)";
        c.className="col"+(d[i]?" on":"")+(d[i]&&i==best?" best":"")});
      // reparto
      var acc=0,arcs='<circle cx="75" cy="75" r="58" fill="none" stroke="rgba(255,255,255,.07)" stroke-width="18"/>',leg="";
      ps.forEach(function(p){
        var f=s?p.dataset.secs/s:0,c=getComputedStyle(p).getPropertyValue("--c").trim(),pct=Math.round(f*100);
        if(f>0)arcs+='<circle cx="75" cy="75" r="58" fill="none" stroke="'+c+'" stroke-width="18" stroke-linecap="butt" stroke-dasharray="'+Math.max(0.5,f*CIRC-3)+' '+CIRC+'" stroke-dashoffset="'+(-acc*CIRC)+'" transform="rotate(-90 75 75)"/>';
        acc+=f;
        var pt=(f>0&&pct<1?"<1":pct)+" %";
        leg+='<div><i style="background:'+c+'"></i><b></b><span>'+pt+' · '+dur(+p.dataset.secs)+'</span></div>';
        p.querySelector(".pct").textContent=pt;
        p.querySelector(".fill").style.width=Math.max(2,pct)+"%"});
      arcs+='<text x="75" y="73" text-anchor="middle" font-size="16.5" font-weight="780" fill="#fff">'+dur(s)+'</text><text x="75" y="90" text-anchor="middle" font-size="10.5" fill="#9a9aa6">de agente</text>';
      document.getElementById("donut").innerHTML=arcs;
      var lge=document.getElementById("leg");lge.innerHTML=leg;
      [].slice.call(lge.querySelectorAll("b")).forEach(function(b,i){b.textContent=ps[i].querySelector("h3").textContent});
      // mapa día × hora
      var gm=Math.max.apply(null,g.concat([1])),h=[],hb=0,off=0;for(i=0;i<24;i++)h.push(0);
      g.forEach(function(v,i){h[i%24]+=v;if(i%24<9||i%24>=19)off+=v});hb=h.indexOf(Math.max.apply(null,h));
      [].slice.call(document.querySelectorAll(".gc")).forEach(function(c,i){
        var v=g[i];c.title=v+" tareas";c.style.background=v?"rgba(240,138,102,"+(0.22+0.78*Math.sqrt(v/gm)).toFixed(2)+")":"";
        c.style.boxShadow=v&&v/gm>0.6?"0 0 10px rgba(240,138,102,.6)":""});
      document.getElementById("hnote").innerHTML=t?"Hora punta: <b>de "+hb+" a "+(hb+1)+" h</b>. "+(off?"<b>"+Math.round(off/t*100)+" %</b> de las tareas, fuera del horario de 9 a 19 h.":"Todo dentro del horario de 9 a 19 h."):"Sin actividad.";
      // titulares
      var top=ps.slice().sort(function(a,b){return b.dataset.secs-a.dataset.secs})[0],ins="",run=0,bestRun=0;
      d.forEach(function(v){run=v?run+1:0;bestRun=Math.max(bestRun,run)});
      if(t){
        ins+=card("#f08a66","Mejor día",DAYS[best],d[best]+" tareas resueltas",false,0);
        ins+=card("#7c9bff","Proyecto principal",'<span id="topn" style="color:inherit;font-size:inherit"></span>',Math.round(top.dataset.secs/s*100)+" % del tiempo de los agentes",true,1);
        ins+=card("#4fd696","Ritmo",(act?Math.round(t/act):0)+" tareas al día","una cada "+dur(s/t)+" de trabajo de agente",true,2);
        if(PEAK>1&&!edited)ins+=card("#c491ff","En paralelo",PEAK+" agentes a la vez","pico de trabajo simultáneo",true,3);
        ins+=card("#f2c14e","Tarea más larga",dur(lg),"de trabajo seguido de un agente",true,4);
        ins+=card("#4fd0e0","Constancia",bestRun+(bestRun==1?" día":" días")+" seguidos","con tareas resueltas",true,5);
      }
      document.getElementById("ins").innerHTML=ins;
      if(t)document.getElementById("topn").textContent=top.querySelector("h3").textContent;
      first=false;
    }
    document.addEventListener("click",function(e){if(e.target.classList.contains("rm")){e.target.closest(".proj").remove();edited=true;render()}});
    document.addEventListener("input",function(e){if(e.target.tagName=="H3")render()});
    render();
    </script>
    </body></html>
    """
}

// MARK: - Utilidades de dibujo
func glyphImage(_ s: String, size: CGFloat) -> CGImage? {
    let str = NSAttributedString(string: s, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: .heavy), .foregroundColor: NSColor.white])
    let img = NSImage(size: str.size(), flipped: false) { _ in str.draw(at: .zero); return true }
    return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
}

func dotImage(_ d: CGFloat) -> CGImage? {
    let img = NSImage(size: NSSize(width: d, height: d), flipped: false) { r in
        NSColor.white.setFill(); NSBezierPath(ovalIn: r).fill(); return true }
    return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
}

func symbol(_ name: String, _ size: CGFloat, _ weight: NSFont.Weight = .semibold, color: NSColor? = nil) -> NSImage? {
    var cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
    if let color { cfg = cfg.applying(.init(paletteColors: [color])) }
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
}

let claudeOrange = NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)

// MARK: - Interfaz (SwiftUI): modelo
struct AgentVM: Identifiable, Equatable {
    let id: String
    var name: String
    var state: String          // working · attention · done
    var activity: String
    var start: Date?
    var end: Date?
    var steps: Int
    var tip: String
}

struct ProjectVM: Identifiable { let id: String; let name: String; let level: Int; let current: Bool; let root: Bool }
struct UsageVM: Identifiable {
    let id: String; var label: String; var left: Double?; var detail: String; var tip: String
    var timeLeft: Double? = nil      // parte del periodo que falta para que se renueve (0…1)
    var runsOut: Double? = nil       // segundos hasta agotarse, si al ritmo actual no llega a la renovación
}

func roughSpan(_ sec: Double) -> String {
    let s = Int(sec)
    return s >= 2 * 86400 ? "\(s / 86400) días" : s >= 86400 ? "1 día" : s >= 2 * 3600 ? "\(s / 3600) h" : s >= 3600 ? "1 h" : "\(max(5, s / 300 * 5)) min"
}
struct AppMem: Identifiable { let id: Int; let name: String; let bytes: UInt64; var icon: NSImage? = nil }

final class WidgetModel: ObservableObject {
    @Published var agents: [AgentVM] = []
    @Published var more = 0
    @Published var moreTip = ""
    @Published var mood = "idle"
    @Published var now = Date()
    @Published var project = ""
    @Published var today = WorkStats()
    @Published var week = WorkStats()
    @Published var perDay = [Int](repeating: 0, count: 7)
    @Published var statsLoaded = false
    @Published var usage: [UsageVM] = [
        UsageVM(id: "session", label: "Sesión", left: nil, detail: "…", tip: ""),
        UsageVM(id: "week", label: "Semana", left: nil, detail: "…", tip: ""),
        ]
    @Published var cpu = 0.0
    @Published var memFraction = 0.0
    @Published var memText = "…"
    @Published var diskFraction = 0.0
    @Published var diskText = "…"
    @Published var diskTip = ""
    @Published var showApps = false
    @Published var topApps: [AppMem] = []
    @Published var awake = false
    @Published var sleepTitle = "Reposo normal"
    @Published var timerOn = false
    @Published var timerMinutes = 0
    @Published var batteryText = ""
    @Published var batterySymbol = "battery.100percent"
    @Published var batteryLow = false
    @Published var batteryCharging = false
    @Published var sleepTip = ""
    @Published var presentation = false
    @Published var visible = true          // escondido en el borde = sin animaciones
    @Published var partyAt: Date?          // última tarea terminada (para la celebración)
    @Published var partyName = ""
    @Published var bump = false            // el número de tareas acaba de subir
    var renderMode = false
    var renderT = 0.9
    let brain = MascotBrain()

    var onToggle: (() -> Void)?
    var onTimer: ((Int) -> Void)?
    var onDisplayOff: (() -> Void)?
    var onProject: (() -> Void)?
    var onNew: (() -> Void)?
    var onContinue: (() -> Void)?
    var onAgent: ((String?) -> Void)?
    var onReport: (() -> Void)?
    var onHeight: ((CGFloat) -> Void)?
    var onShowApps: (() -> Void)?
    var onUsagePick: (() -> Void)?
    @Published var prompt = ""
    @Published var hideResults = false     // plegadas cuando no cabe todo en la pantalla
    @Published var hideUsage = false
    @Published var usageEnabled = false   // «Lo que te queda de Claude»: hasta activarlo se ve una invitación
    var onEnableUsage: (() -> Void)?
    @Published var usagePick: String? = nil   // anillo pulsado: se explica debajo
    @Published var picking = false         // selector de proyecto abierto
    @Published var projects: [ProjectVM] = []
    @Published var pickQuery = ""
    var canEditSelf = false
    var onPick: ((String) -> Void)?
    var onChooseFolder: (() -> Void)?
    var onEditSelf: (() -> Void)?
    var onAsk: ((String) -> Void)?
}

// MARK: - Interfaz: piezas
let uiAccent = Color(nsColor: claudeOrange)

func stateColor(_ s: String) -> Color {
    switch s {
    case "working": return uiAccent
    case "attention", "att": return Color(red: 1.0, green: 0.33, blue: 0.30)
    case "done": return Color(red: 0.30, green: 0.85, blue: 0.50)
    default: return Color.white.opacity(0.35)
    }
}

func clock(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct Blur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow; v.blendingMode = .behindWindow; v.state = .active
        v.appearance = NSAppearance(named: .vibrantDark)
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// Tarjeta de cristal oscuro.
struct Card<Content: View>: View {
    var padding: CGFloat = 14
    let content: Content
    init(padding: CGFloat = 14, @ViewBuilder content: () -> Content) { self.padding = padding; self.content = content() }
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.065)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 9.5, weight: .bold)).tracking(0.9).foregroundColor(.white.opacity(0.42))
    }
}

/// El orbe de cada agente: gira y late mientras trabaja.
struct Orb: View {
    let state: String
    let t: Double
    var body: some View {
        let c = stateColor(state)
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [c.opacity(state == "idle" ? 0.0 : 0.55), c.opacity(0)], center: .center, startRadius: 0, endRadius: 24))
                .scaleEffect(state == "working" ? 1.05 + 0.14 * sin(t * 2.4) : state == "attention" ? 1.05 + 0.22 * sin(t * 7) : 1)
            if state == "working" {
                Circle().stroke(Color.white.opacity(0.10), lineWidth: 2.5).padding(5)
                Circle().trim(from: 0, to: 0.7)
                    .stroke(AngularGradient(colors: [c.opacity(0), c, .white], center: .center, startAngle: .degrees(0), endAngle: .degrees(252)),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(t * 230))
                    .padding(5)
                Circle().fill(c).frame(width: 9, height: 9).scaleEffect(1 + 0.28 * sin(t * 4.8))
            } else if state == "attention" {
                Circle().fill(c).padding(7)
                Image(systemName: "exclamationmark").font(.system(size: 13, weight: .heavy)).foregroundColor(.white)
            } else if state == "done" {
                Circle().fill(c.opacity(0.92)).padding(7)
                Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundColor(.black.opacity(0.75))
            } else {
                Circle().stroke(Color.white.opacity(0.16), lineWidth: 2).padding(7)
                Circle().fill(Color.white.opacity(0.28)).frame(width: 6, height: 6)
            }
        }
        .frame(width: 40, height: 40)
    }
}

struct AgentCard: View {
    let a: AgentVM
    let now: Date
    var animated = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                if animated && (a.state == "working" || a.state == "attention") {
                    TimelineView(.animation(minimumInterval: 1.0 / 24)) { ctx in
                        Orb(state: a.state, t: ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600))
                    }
                } else {
                    Orb(state: a.state, t: 0)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.name).font(.system(size: 14.5, weight: .semibold)).lineLimit(1)
                    Text(a.activity).font(.system(size: 11.5)).foregroundColor(.white.opacity(0.58)).lineLimit(1)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 2) {
                    if let s = a.start {
                        Text(clock((a.end ?? now).timeIntervalSince(s)))
                            .font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                    }
                    Text(a.state == "attention" ? "te necesita" : a.state == "done" ? "terminado" : a.steps > 0 ? "\(a.steps) pasos" : "en marcha")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(a.state == "working" ? .white.opacity(0.45) : stateColor(a.state))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.065)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(stateColor(a.state).opacity(a.state == "attention" ? 0.7 : a.state == "working" ? 0.28 : 0.07), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help(a.tip)
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct CapsuleStyle: ButtonStyle {
    var filled = false
    var selected = false
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(filled || selected ? .white : .white.opacity(0.9))
            .padding(.horizontal, compact ? 10 : 12).frame(height: 30)
            .background(Capsule().fill(filled ? uiAccent : selected ? Color.orange : Color.white.opacity(0.09)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(filled || selected ? 0.25 : 0.08), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct RowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0)))
    }
}

struct MiniStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold)).foregroundColor(.white.opacity(0.75))
            .labelStyle(.titleAndIcon).lineLimit(1)
            .padding(.horizontal, 9).frame(height: 24)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.08)))
    }
}

struct ChipStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(.white.opacity(selected ? 1 : 0.8))
            .frame(width: 27, height: 24)
            .background(Capsule().fill(selected ? Color.orange : Color.white.opacity(0.09)))
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct WeekBars: View {
    let values: [Int]
    var body: some View {
        let mx = max(1, values.max() ?? 1)
        let cal = Calendar.current
        let letters = ["D", "L", "M", "X", "J", "V", "S"]
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(0..<7, id: \.self) { i in
                let d = cal.date(byAdding: .day, value: i - 6, to: Date()) ?? Date()
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(i == 6 ? uiAccent : Color.white.opacity(0.20))
                        .frame(width: 12, height: max(3, 46 * CGFloat(i < values.count ? values[i] : 0) / CGFloat(mx)))
                    Text(letters[(cal.component(.weekday, from: d) - 1) % 7])
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundColor(.white.opacity(i == 6 ? 0.9 : 0.35))
                }
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: values)
    }
}

struct Ring: View {
    let u: UsageVM
    var picked = false, dimmed = false
    var body: some View {
        let left = u.left ?? 0
        let c: Color = u.left == nil ? .white.opacity(0.2) : (left < 0.2 || u.runsOut != nil) ? stateColor("attention") : uiAccent
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.09), lineWidth: 5)
                Circle().trim(from: 0, to: CGFloat(min(1, max(0.001, left))))
                    .stroke(c, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.6), value: left)
                if let tl = u.timeLeft, u.left != nil {
                    // Marca del tiempo: si el arco llega más allá de ella, vas con margen
                    Circle().fill(Color.white).frame(width: 5, height: 5)
                        .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1.5))
                        .offset(y: -26)
                        .rotationEffect(.degrees(360 * min(0.985, max(0.015, tl))))
                }
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(u.left == nil ? "–" : "\(Int((left * 100).rounded()))")
                        .font(.system(size: 16, weight: .bold, design: .rounded)).monospacedDigit()
                    if u.left != nil { Text("%").font(.system(size: 8.5, weight: .bold)).foregroundColor(.white.opacity(0.5)) }
                }
            }
            .frame(width: 52, height: 52)
            VStack(spacing: 1) {
                Text(u.label).font(.system(size: 11, weight: .semibold))
                HStack(spacing: 2) {
                    if u.left != nil { Image(systemName: "arrow.clockwise").font(.system(size: 7.5, weight: .bold)) }
                    Text(u.detail).font(.system(size: 9.5)).lineLimit(1)
                }
                .foregroundColor(.white.opacity(0.45))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(picked ? 0.09 : 0)))
        .opacity(dimmed ? 0.45 : 1)
        .contentShape(Rectangle())
    }
}

struct MiniMeter: View {
    let icon: String, label: String, value: String
    let fraction: Double
    var body: some View {
        let w: CGFloat = 74
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .semibold))
                Text(label).font(.system(size: 9.5, weight: .bold)).tracking(0.5)
            }
            .foregroundColor(.white.opacity(0.42))
            Text(value).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10)).frame(width: w, height: 3)
                Capsule().fill(fraction > 0.9 ? stateColor("attention") : Color.white.opacity(0.75))
                    .frame(width: max(3, w * CGFloat(min(1, max(0, fraction)))), height: 3)
                    .animation(.easeOut(duration: 0.5), value: fraction)
            }
        }
        .frame(width: w, alignment: .leading)
    }
}

/// Estado que la mascota recuerda entre fotogramas (mirada suavizada, toque).
final class MascotBrain {
    var gaze = CGPoint.zero
    var near: CGFloat = 0
    var pokeAt: Date?
    var pokes: [Date] = []
    var angryUntil = Date.distantPast
    var level = 0                        // 1 = molesta · 2 = furiosa
    /// Un toque le hace gracia; si insistes, se enfada (y cada vez más).
    func poke() {
        let now = Date()
        pokes = pokes.filter { now.timeIntervalSince($0) < 5 } + [now]
        pokeAt = now
        if pokes.count >= 6 { level = 2; angryUntil = now.addingTimeInterval(5) }
        else if pokes.count >= 3 { level = max(level, now < angryUntil ? level : 1); angryUntil = now.addingTimeInterval(3.2) }
        if now >= angryUntil { level = 0 }
    }
    var center: (() -> CGPoint?)?        // centro de la mascota en la pantalla
    /// Hacia dónde mira: sigue al cursor, con suavidad.
    func update() {
        var target = CGPoint.zero; var n: CGFloat = 0
        if let c = center?() {
            let m = NSEvent.mouseLocation
            let dx = m.x - c.x, dy = c.y - m.y           // y hacia abajo, como en el dibujo
            let d = max(1, hypot(dx, dy))
            let k = min(1, d / 160)
            target = CGPoint(x: dx / d * k, y: dy / d * k)
            n = d < 130 ? 1 : 0
        }
        gaze.x += (target.x - gaze.x) * 0.18; gaze.y += (target.y - gaze.y) * 0.18
        near += (n - near) * 0.12
    }
}

/// La mascota del widget: una chispa redonda con su llama, que duerme, trabaja, te llama o celebra.
/// Sigue el cursor con la mirada, se despierta si te acercas y reacciona si la tocas.
struct Mascot: View {
    let mood: String            // idle · work · att · done
    let t: Double
    let party: Double?          // segundos desde que terminó una tarea
    var brain: MascotBrain? = nil
    var now = Date()

    var body: some View {
        Canvas { ctx, size in
            brain?.update()
            let gaze = brain?.gaze ?? .zero
            let near = brain?.near ?? 0
            let poke = brain?.pokeAt.map { now.timeIntervalSince($0) }.flatMap { $0 < 1.4 ? $0 : nil }
            let cx = size.width / 2, base = size.height / 2 + 11
            let R: CGFloat = 25
            let celebrating = party != nil && party! < 2.4
            var state = celebrating ? "party" : mood
            let awake = state == "idle" && near > 0.5          // dormía y te has acercado
            if poke != nil && state != "party" { state = "poke" }
            let anger = brain.map { now < $0.angryUntil ? $0.level : 0 } ?? 0
            if anger > 0 && state != "party" { state = "angry" }
            let fury = anger >= 2

            // --- Cuerpo: movimiento ---
            var bob: CGFloat = 0, sx: CGFloat = 1, sy: CGFloat = 1, tilt: CGFloat = 0
            switch state {
            case "work": bob = CGFloat(sin(t * 3.0)) * 1.2; sy = 1 + 0.02 * CGFloat(sin(t * 6)); tilt = CGFloat(sin(t * 1.4)) * 0.04
            case "att":  let b = abs(CGFloat(sin(t * 5.5))); bob = -b * 6; sy = 1 + 0.05 * b; sx = 1 - 0.03 * b; tilt = CGFloat(sin(t * 11)) * 0.05
            case "party":
                let p = CGFloat(party ?? 0)
                let hop = p < 1.2 ? abs(CGFloat(sin(Double(p) * .pi / 0.6))) : 0
                bob = -hop * 11; sy = 1 + 0.06 * hop; sx = 1 - 0.04 * hop; tilt = CGFloat(sin(Double(p) * 10)) * 0.08
            case "poke":
                let p = CGFloat(poke ?? 0)
                if p < 0.12 { let q = p / 0.12; sy = 1 - 0.16 * q; sx = 1 + 0.12 * q; bob = 4 * q }          // se aplasta
                else if p < 0.7 { let q = (p - 0.12) / 0.58; let h = sin(q * .pi); bob = -13 * h; sy = 1 + 0.08 * h; sx = 1 - 0.05 * h }
                else { let q = (p - 0.7) / 0.7; let w = sin(q * .pi * 3) * (1 - q); sy = 1 - 0.05 * w; sx = 1 + 0.04 * w }
            case "angry":
                // tiembla de rabia, hinchada
                sy = 1.03 + 0.02 * CGFloat(sin(t * 22)); sx = 1.03
                tilt = CGFloat(sin(t * 41)) * (fury ? 0.05 : 0.02)
                bob = fury ? CGFloat(sin(t * 33)) * 1.2 : 0
            case "done":
                // se mece, y cada pocos segundos da un saltito
                let ph = t.truncatingRemainder(dividingBy: 5.5)
                let hop: CGFloat = ph < 0.5 ? CGFloat(sin(ph / 0.5 * .pi)) : 0
                bob = CGFloat(sin(t * 1.6)) * 1.2 - hop * 6; sy = 1 + 0.04 * hop; tilt = CGFloat(sin(t * 0.9)) * 0.05
            default:
                let br = CGFloat(sin(t * (awake ? 1.6 : 1.1)))
                bob = br * 1.5; sy = 1 + 0.03 * br; sx = 1 - 0.015 * br
            }
            let cy = base + bob
            let asleep = state == "idle" && !awake
            let cold = state == "idle"
            var main: Color = cold ? Color(red: 0.56, green: 0.50, blue: 0.66) : uiAccent
            var light: Color = cold ? Color(red: 0.78, green: 0.73, blue: 0.88) : Color(red: 1.0, green: 0.78, blue: 0.62)
            var dark: Color = cold ? Color(red: 0.36, green: 0.31, blue: 0.46) : Color(red: 0.66, green: 0.30, blue: 0.20)
            if fury {   // roja de furia
                main = Color(red: 0.90, green: 0.24, blue: 0.18); light = Color(red: 1.0, green: 0.56, blue: 0.44); dark = Color(red: 0.50, green: 0.08, blue: 0.08)
            }
            let ink = Color(red: 0.13, green: 0.08, blue: 0.08)

            // --- Sombra ---
            let lift = max(0, -bob) / 12
            ctx.fill(Path(ellipseIn: CGRect(x: cx - 17 * (1 - 0.35 * lift), y: base + R + 5, width: 34 * (1 - 0.35 * lift), height: 6)),
                     with: .color(.black.opacity(0.30 * (1 - 0.5 * lift))))

            // --- Resplandor ---
            let glowC: Color = state == "att" || fury ? stateColor("attention") : state == "done" ? stateColor("done") : main
            let pulse = state == "work" ? 0.5 + 0.2 * sin(t * 2.4) : state == "att" ? 0.55 + 0.3 * sin(t * 7) : cold ? 0.22 : 0.45
            ctx.fill(Path(ellipseIn: CGRect(x: cx - 42, y: cy - 42, width: 84, height: 84)),
                     with: .radialGradient(Gradient(colors: [glowC.opacity(pulse), glowC.opacity(0)]),
                                           center: CGPoint(x: cx, y: cy), startRadius: 8, endRadius: 42))
            if state == "att" {
                let ph = CGFloat((t * 1.2).truncatingRemainder(dividingBy: 1))
                let rr = R + 4 + 16 * ph
                ctx.stroke(Path(ellipseIn: CGRect(x: cx - rr, y: cy - rr, width: rr * 2, height: rr * 2)),
                           with: .color(stateColor("attention").opacity(Double(1 - ph) * 0.8)), lineWidth: 2)
            }

            // Todo lo del personaje se inclina a la vez
            var c = ctx
            c.translateBy(x: cx, y: cy + R); c.rotate(by: .radians(Double(tilt))); c.translateBy(x: -cx, y: -(cy + R))

            // --- Llama de la cabeza ---
            let topY = cy - R * sy + 3
            let fl = sin(t * 9) * 0.5 + sin(t * 14.3) * 0.3 + sin(t * 23) * 0.2                    // parpadeo irregular
            var fh: CGFloat = 11, fw: CGFloat = 5.5, sway = CGFloat(sin(t * 4.1)) * 2
            var fOuter = Color(red: 1.0, green: 0.62, blue: 0.25), fInner = Color(red: 1.0, green: 0.93, blue: 0.62), fAlpha = 1.0
            switch state {
            case "work": fh = 13 + CGFloat(fl) * 3
            case "att":  fh = 15 + CGFloat(fl) * 4; sway = CGFloat(sin(t * 13)) * 3; fOuter = stateColor("attention"); fInner = Color(red: 1, green: 0.8, blue: 0.5)
            case "party", "poke": fh = 18 + CGFloat(fl) * 4; fw = 6.5
            case "angry":
                fh = (fury ? 23 : 15) + CGFloat(fl) * (fury ? 6 : 3); fw = fury ? 8 : 6; sway = CGFloat(sin(t * 17)) * 3
                if fury { fOuter = Color(red: 1.0, green: 0.25, blue: 0.12); fInner = Color(red: 1.0, green: 0.75, blue: 0.3) }
            case "done": fh = 11 + CGFloat(fl) * 2
            default:
                // dormida: una brasa que respira; despierta: llamita azulada
                fh = awake ? 9 + CGFloat(fl) * 1.5 : 5 + CGFloat(sin(t * 1.1)) * 1
                fw = awake ? 4.5 : 3.5; sway *= 0.4
                fOuter = Color(red: 0.72, green: 0.66, blue: 0.95); fInner = Color(red: 0.92, green: 0.90, blue: 1.0)
                fAlpha = awake ? 0.95 : 0.55 + 0.25 * sin(t * 1.1)
            }
            sway -= gaze.x * -1.5 * (asleep ? 0 : 1)
            func flame(_ h: CGFloat, _ w: CGFloat) -> Path {
                var p = Path()
                p.move(to: CGPoint(x: cx - w, y: topY))
                p.addQuadCurve(to: CGPoint(x: cx + sway, y: topY - h), control: CGPoint(x: cx - w * 1.25, y: topY - h * 0.55))
                p.addQuadCurve(to: CGPoint(x: cx + w, y: topY), control: CGPoint(x: cx + w * 1.25 + sway * 0.3, y: topY - h * 0.45))
                p.closeSubpath()
                return p
            }
            c.fill(Path(ellipseIn: CGRect(x: cx - 11, y: topY - fh - 3, width: 22, height: fh + 8)),
                   with: .radialGradient(Gradient(colors: [fOuter.opacity(0.35 * fAlpha), fOuter.opacity(0)]),
                                         center: CGPoint(x: cx, y: topY - fh * 0.4), startRadius: 1, endRadius: 12))
            c.fill(flame(fh, fw), with: .color(fOuter.opacity(fAlpha)))
            c.fill(flame(fh * 0.55, fw * 0.55), with: .color(fInner.opacity(fAlpha)))

            // --- Cuerpo ---
            let body = CGRect(x: cx - R * sx, y: cy - R * sy, width: 2 * R * sx, height: 2 * R * sy)
            c.fill(Path(ellipseIn: body),
                   with: .radialGradient(Gradient(colors: [light, main, dark]),
                                         center: CGPoint(x: cx - R * 0.35, y: cy - R * 0.45), startRadius: 1, endRadius: R * 1.75))
            c.fill(Path(ellipseIn: CGRect(x: cx - R * 0.55, y: cy - R * 0.72, width: R * 0.5, height: R * 0.3)),
                   with: .color(.white.opacity(cold ? 0.18 : 0.32)))

            // --- Cara: se desplaza hacia donde mira ---
            var gx = gaze.x * 4.5, gy = gaze.y * 3.2
            if state == "work" { gx = CGFloat(sin(t * 1.4)) * 3.2; gy = 1.5 + CGFloat(sin(t * 2.8)) * 0.8 }     // leyendo, concentrada
            if asleep { gx = 0; gy = 1 }
            let fx = cx + gx * 0.6, eyeY = cy - 3 + gy * 0.6

            // Mofletes
            let blush: Double = (state == "done" || state == "party" || state == "poke") ? 0.42 : state == "att" || state == "angry" ? 0.0 : asleep ? 0.18 : 0.26
            if blush > 0 {
                for side in [CGFloat(-1), CGFloat(1)] {
                    c.fill(Path(ellipseIn: CGRect(x: fx + side * 15 - 4.5, y: eyeY + 6, width: 9, height: 5)),
                           with: .color(Color(red: 1.0, green: 0.42, blue: 0.45).opacity(blush)))
                }
            }

            // Ojos
            let happyBeat = state == "done" && t.truncatingRemainder(dividingBy: 5.5) < 0.9      // sonríe con los ojos al saltar
            let pokeHappy = state == "poke" && (poke ?? 0) > 0.22
            for side in [CGFloat(-1), CGFloat(1)] {
                let ex = fx + side * 9
                if asleep {
                    var p = Path()
                    p.addArc(center: CGPoint(x: ex, y: eyeY - 1), radius: 4, startAngle: .degrees(20), endAngle: .degrees(160), clockwise: false)
                    c.stroke(p, with: .color(ink.opacity(0.85)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                } else if state == "angry" {
                    // mirada fulminante: ojo medio cerrado bajo una ceja inclinada
                    let px = ex + gx * 0.4, py = eyeY + 1 + gy * 0.4
                    let h: CGFloat = fury ? 5.5 : 7
                    c.fill(Path(roundedRect: CGRect(x: px - 3.2, y: py - h / 2, width: 6.4, height: h), cornerRadius: 3), with: .color(ink))
                    c.fill(Path(ellipseIn: CGRect(x: px - 1.8 + gx * 0.15, y: py - h / 2 + 1, width: 2, height: 2)), with: .color(.white.opacity(0.9)))
                    let slope: CGFloat = fury ? 5 : 3.2
                    c.stroke(Path { $0.move(to: CGPoint(x: px + side * 5.5, y: py - h / 2 - 3.5 - slope * 0.4))
                                    $0.addLine(to: CGPoint(x: px - side * 5, y: py - h / 2 - 1.5 + slope * 0.6)) },
                             with: .color(ink), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                } else if state == "party" || happyBeat || pokeHappy {
                    var p = Path()
                    p.addArc(center: CGPoint(x: ex, y: eyeY + 2.5), radius: 4.2, startAngle: .degrees(200), endAngle: .degrees(340), clockwise: false)
                    c.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                } else {
                    // parpadeo: sencillo y, de vez en cuando, doble
                    let phase = t.truncatingRemainder(dividingBy: 4.2)
                    func lid(_ at: Double) -> CGFloat { let d = phase - at; return d >= 0 && d < 0.14 ? CGFloat(d < 0.07 ? d / 0.07 : 1 - (d - 0.07) / 0.07) : 0 }
                    let double = Int(t / 4.2) % 3 == 0
                    let blink = max(lid(0), double ? lid(0.24) : 0)
                    let surprised = state == "att" || state == "poke"
                    let sleepy = awake ? 0.55 : 1.0                              // recién despertada: ojos entornados
                    let w: CGFloat = surprised ? 8.5 : 6
                    let h: CGFloat = ((surprised ? 9.5 : 10) * CGFloat(sleepy)) * (1 - blink) + 1.6 * blink
                    let px = ex + gx * 0.4, py = eyeY + gy * 0.4
                    c.fill(Path(roundedRect: CGRect(x: px - w / 2, y: py - h / 2, width: w, height: h), cornerRadius: w / 2), with: .color(ink))
                    if blink < 0.5 && h > 4 {
                        c.fill(Path(ellipseIn: CGRect(x: px - w / 2 + 1.2 + gx * 0.15, y: py - h / 2 + 1.4, width: 2.2, height: 2.2)), with: .color(.white.opacity(0.9)))
                    }
                    if awake {   // párpado caído
                        c.stroke(Path { $0.move(to: CGPoint(x: px - 4.5, y: py - h / 2 - 0.5)); $0.addLine(to: CGPoint(x: px + 4.5, y: py - h / 2 - 0.5)) },
                                 with: .color(ink.opacity(0.8)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    }
                }
            }

            // Boca
            let mx = fx, my = cy + 6 + gy * 0.5
            if state == "angry" {
                if fury {
                    // grita, enseñando los dientes
                    let o = 5 + abs(CGFloat(sin(t * 16))) * 2
                    c.fill(Path(roundedRect: CGRect(x: mx - 6.5, y: my - 0.5, width: 13, height: o), cornerRadius: 2.5), with: .color(ink))
                    c.fill(Path(roundedRect: CGRect(x: mx - 5, y: my, width: 10, height: 2.2), cornerRadius: 0.8), with: .color(.white.opacity(0.95)))
                } else {
                    var m = Path()
                    m.addArc(center: CGPoint(x: mx, y: my + 6), radius: 5, startAngle: .degrees(205), endAngle: .degrees(335), clockwise: false)
                    c.stroke(m, with: .color(ink), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                }
            } else if state == "party" || pokeHappy {
                // risa abierta
                var m = Path()
                m.move(to: CGPoint(x: mx - 6, y: my - 1))
                m.addQuadCurve(to: CGPoint(x: mx + 6, y: my - 1), control: CGPoint(x: mx, y: my + 10))
                m.closeSubpath()
                c.fill(m, with: .color(ink))
                c.fill(Path(ellipseIn: CGRect(x: mx - 2.5, y: my + 2.2, width: 5, height: 2.6)), with: .color(Color(red: 1, green: 0.5, blue: 0.5)))
            } else if state == "done" {
                var m = Path()
                m.addArc(center: CGPoint(x: mx, y: my - 1), radius: 5.5, startAngle: .degrees(15), endAngle: .degrees(165), clockwise: false)
                c.stroke(m, with: .color(ink), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
            } else if state == "att" || state == "poke" {
                c.fill(Path(ellipseIn: CGRect(x: mx - 2.8, y: my, width: 5.6, height: 6.5)), with: .color(ink))
            } else if state == "work" {
                // murmura mientras trabaja
                let o = 1.2 + abs(CGFloat(sin(t * 5))) * 1.6
                c.fill(Path(ellipseIn: CGRect(x: mx - 2.2, y: my + 1, width: 4.4, height: o)), with: .color(ink.opacity(0.85)))
            } else if awake {
                // bostezo al despertar, luego media sonrisa
                var m = Path()
                m.addArc(center: CGPoint(x: mx, y: my), radius: 3.5, startAngle: .degrees(20), endAngle: .degrees(160), clockwise: false)
                c.stroke(m, with: .color(ink.opacity(0.85)), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            } else {
                // dormida: respira por la boquita
                let o = 1.6 + CGFloat(sin(t * 1.1) + 1) * 0.9
                c.fill(Path(ellipseIn: CGRect(x: mx - 1.6, y: my + 1, width: 3.2, height: o)), with: .color(ink.opacity(0.6)))
            }

            // --- Manitas ---
            func hand(_ x: CGFloat, _ y: CGFloat) {
                c.fill(Path(ellipseIn: CGRect(x: x - 5, y: y - 5, width: 10, height: 10)), with: .color(dark))
                c.fill(Path(ellipseIn: CGRect(x: x - 4, y: y - 4.3, width: 8, height: 8)), with: .color(main))
            }
            switch state {
            case "work":       // teclea
                hand(cx - 10, cy + R * sy - 3 - abs(CGFloat(sin(t * 11))) * 3.5)
                hand(cx + 10, cy + R * sy - 3 - abs(CGFloat(sin(t * 11 + 1.6))) * 3.5)
            case "att":        // agita los brazos
                hand(cx - R - 4, cy - 8 + CGFloat(sin(t * 13)) * 6)
                hand(cx + R + 4, cy - 8 + CGFloat(sin(t * 13 + .pi)) * 6)
            case "party", "poke":   // brazos arriba
                hand(cx - R - 2, cy - 15 + CGFloat(sin(t * 9)) * 2)
                hand(cx + R + 2, cy - 15 + CGFloat(sin(t * 9 + 1)) * 2)
            case "angry":      // puños: en jarras, o agitándolos si está furiosa
                if fury {
                    hand(cx - R - 3, cy - 10 + CGFloat(sin(t * 24)) * 4)
                    hand(cx + R + 3, cy - 10 + CGFloat(sin(t * 24 + 2)) * 4)
                } else { hand(cx - R + 1, cy + 9); hand(cx + R - 1, cy + 9) }
            case "done":       // saluda con una mano
                hand(cx - R + 1, cy + 9)
                hand(cx + R + 3, cy - 4 + CGFloat(sin(t * 6)) * (t.truncatingRemainder(dividingBy: 5.5) < 1.6 ? 5 : 0.6))
            default:
                if awake { hand(cx - R + 1, cy + 10); hand(cx + R - 1, cy + 10) }
            }

            // --- Extras ---
            if asleep {
                for k in 0..<2 {
                    let ph = (t * 0.32 + Double(k) * 0.5).truncatingRemainder(dividingBy: 1)
                    let pt = CGPoint(x: cx + R * 0.75 + 12 * CGFloat(ph), y: cy - R * 0.55 - 20 * CGFloat(ph))
                    ctx.draw(Text("z").font(.system(size: 9 + 5 * CGFloat(ph), weight: .heavy, design: .rounded))
                        .foregroundColor(.white.opacity(sin(ph * .pi) * 0.75)), at: pt)
                }
            } else if state == "work" {
                // pavesas que suben de la llama
                for k in 0..<4 {
                    let ph = (t * 0.55 + Double(k) * 0.25).truncatingRemainder(dividingBy: 1)
                    let x = cx + CGFloat(sin(Double(k) * 2.4 + ph * 5)) * (4 + 7 * CGFloat(ph))
                    let y = topY - fh - 2 - 22 * CGFloat(ph)
                    let d = 2.6 * CGFloat(1 - ph) + 0.6
                    ctx.fill(Path(ellipseIn: CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d)),
                             with: .color(Color(red: 1, green: 0.85, blue: 0.5).opacity((1 - ph) * 0.9)))
                }
            } else if state == "att" {
                let s = 1 + 0.12 * CGFloat(sin(t * 7))
                let bc = CGPoint(x: cx + R * 0.95, y: cy - R * 1.0)
                ctx.fill(Path(ellipseIn: CGRect(x: bc.x - 9 * s, y: bc.y - 9 * s, width: 18 * s, height: 18 * s)), with: .color(stateColor("attention")))
                ctx.draw(Text("!").font(.system(size: 13, weight: .black, design: .rounded)).foregroundColor(.white), at: bc)
            } else if state == "angry" {
                // la marca de enfado, latiendo
                let red = Color(red: 1.0, green: 0.30, blue: 0.26)
                let k = 1 + 0.18 * CGFloat(sin(t * 10))
                let mc = CGPoint(x: cx + R * 0.92, y: cy - R * 0.95)
                for q in 0..<4 {
                    let a = Double(q) * .pi / 2 + .pi / 4
                    let ax = CGFloat(cos(a)), ay = CGFloat(sin(a))
                    var v = Path()
                    v.move(to: CGPoint(x: mc.x + (ax * 6.5 - ay * 3.6) * k, y: mc.y + (ay * 6.5 + ax * 3.6) * k))
                    v.addQuadCurve(to: CGPoint(x: mc.x + (ax * 6.5 + ay * 3.6) * k, y: mc.y + (ay * 6.5 - ax * 3.6) * k),
                                   control: CGPoint(x: mc.x + ax * 1.2 * k, y: mc.y + ay * 1.2 * k))
                    ctx.stroke(v, with: .color(red), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                }
                if fury {
                    // echa humo por los lados
                    for side in [CGFloat(-1), CGFloat(1)] {
                        for q in 0..<3 {
                            let ph = (t * 1.1 + Double(q) * 0.33).truncatingRemainder(dividingBy: 1)
                            let d = 5 + 7 * CGFloat(ph)
                            let pt = CGPoint(x: cx + side * (R + 3 + 9 * CGFloat(ph)), y: cy - 4 - 20 * CGFloat(ph))
                            ctx.fill(Path(ellipseIn: CGRect(x: pt.x - d / 2, y: pt.y - d / 2, width: d, height: d)),
                                     with: .color(.white.opacity((1 - ph) * 0.55)))
                        }
                    }
                }
            } else if state == "party" || state == "poke" {
                let p = state == "party" ? (party ?? 0) : (poke ?? 0)
                let prog = min(1, p / (state == "party" ? 1.5 : 0.9))
                let ease = 1 - pow(1 - prog, 3)
                let cols: [Color] = [.white, uiAccent, Color(red: 1, green: 0.85, blue: 0.4), stateColor("done")]
                let n = state == "party" ? 12 : 7
                for k in 0..<n {
                    let a = Double(k) * 2 * .pi / Double(n) + 0.3
                    let dist = R + 4 + (state == "party" ? 30 : 18) * CGFloat(ease) * (k % 2 == 0 ? 1 : 0.72)
                    let pt = CGPoint(x: cx + CGFloat(cos(a)) * dist, y: cy + CGFloat(sin(a)) * dist)
                    let d: CGFloat = (k % 3 == 0 ? 5 : 3.5) * CGFloat(1 - prog * 0.5)
                    ctx.fill(Path(ellipseIn: CGRect(x: pt.x - d / 2, y: pt.y - d / 2, width: d, height: d)),
                             with: .color(cols[k % cols.count].opacity(1 - prog)))
                }
            } else if state == "done" {
                // destellos sueltos
                for k in 0..<3 {
                    let ph = (t * 0.45 + Double(k) * 0.37).truncatingRemainder(dividingBy: 1)
                    let a = Double(k) * 2.1 + 0.6
                    let pt = CGPoint(x: cx + CGFloat(cos(a)) * (R + 11), y: cy + CGFloat(sin(a)) * (R + 6) - 6)
                    let s = CGFloat(sin(ph * .pi)) * 4
                    var star = Path()
                    star.move(to: CGPoint(x: pt.x, y: pt.y - s)); star.addLine(to: CGPoint(x: pt.x + s * 0.28, y: pt.y - s * 0.28))
                    star.addLine(to: CGPoint(x: pt.x + s, y: pt.y)); star.addLine(to: CGPoint(x: pt.x + s * 0.28, y: pt.y + s * 0.28))
                    star.addLine(to: CGPoint(x: pt.x, y: pt.y + s)); star.addLine(to: CGPoint(x: pt.x - s * 0.28, y: pt.y + s * 0.28))
                    star.addLine(to: CGPoint(x: pt.x - s, y: pt.y)); star.addLine(to: CGPoint(x: pt.x - s * 0.28, y: pt.y - s * 0.28))
                    star.closeSubpath()
                    ctx.fill(star, with: .color(.white.opacity(0.85)))
                }
            }
        }
        .frame(width: 96, height: 100)
    }
}

// MARK: - Interfaz: el widget
struct WidgetUI: View {
    @ObservedObject var model: WidgetModel

    var summary: String {
        let att = model.agents.filter { $0.state == "attention" }.count
        let work = model.agents.filter { $0.state == "working" }.count
        if att > 0 { return att == 1 ? "1 te necesita" : "\(att) te necesitan" }
        if work > 0 { return work == 1 ? "1 agente trabajando" : "\(work) agentes trabajando" }
        return model.agents.isEmpty ? "En calma" : "Todo terminado"
    }

    var body: some View {
        VStack(spacing: 0) {
            content
            Spacer(minLength: 0)
        }
        .frame(width: WidgetView.W)
        .frame(maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(HeightKey.self) { h in model.onHeight?(h) }
        .environment(\.colorScheme, .dark)
    }

    var content: some View {
        VStack(spacing: 10) {
            header
            agents
            ask
            actions
            if model.picking {
                picker.transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity))
            } else {
                if !model.hideResults { results.transition(.opacity) }
                if !model.hideUsage { usage.transition(.opacity) }
                footer
            }
        }
        .padding(12)
        .frame(width: WidgetView.W)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundColor(.white)
        .background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
        .background(backdrop)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
    }

    /// Cristal negro con un resplandor arriba del color del estado.
    var backdrop: some View {
        ZStack(alignment: .topLeading) {
            if model.renderMode { Color(red: 0.10, green: 0.09, blue: 0.11) } else { Blur() }
            Color.black.opacity(model.renderMode ? 0.35 : 0.58)
            RadialGradient(colors: [stateColor(model.mood == "idle" ? "working" : model.mood).opacity(model.mood == "idle" ? 0.16 : 0.42), .clear],
                           center: UnitPoint(x: 0.15, y: 0.0), startRadius: 0, endRadius: 260)
                .animation(.easeInOut(duration: 0.8), value: model.mood)
        }
    }

    var celebrating: Bool { model.partyAt.map { model.now.timeIntervalSince($0) < 5 } ?? false }

    var headline: String {
        if celebrating { return "¡Tarea terminada!" }
        let att = model.agents.filter { $0.state == "attention" }.count
        let work = model.agents.filter { $0.state == "working" }.count
        if att > 0 { return att == 1 ? "Te necesita" : "\(att) te necesitan" }
        if work > 0 { return work == 1 ? "Trabajando" : "\(work) agentes trabajando" }
        return model.agents.isEmpty ? "En calma" : "Todo terminado"
    }

    var subline: String {
        if celebrating { return model.partyName.isEmpty ? "Lista para revisar" : model.partyName }
        if let a = model.agents.first(where: { $0.state == "attention" }) { return "Permiso en \(a.name)" }
        if let a = model.agents.first(where: { $0.state == "working" }) { return a.activity }
        return model.agents.isEmpty ? "Ningún agente en marcha" : "Pulsa un agente para revisarlo"
    }

    var header: some View {
        HStack(spacing: 6) {
            Group {
                if model.visible && !model.renderMode {
                    TimelineView(.animation(minimumInterval: model.mood == "idle" && !celebrating ? 1.0 / 20 : 1.0 / 30)) { ctx in
                        Mascot(mood: model.mood, t: ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600),
                               party: model.partyAt.map { ctx.date.timeIntervalSince($0) }, brain: model.brain, now: ctx.date)
                    }
                } else {
                    Mascot(mood: model.mood, t: model.renderT, party: model.partyAt.map { model.now.timeIntervalSince($0) })
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { model.brain.poke() }
            .help("Chispa. Tócala.")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: "sparkle").font(.system(size: 9.5, weight: .bold)).foregroundColor(uiAccent)
                    Text("CHISPA").font(.system(size: 9.5, weight: .bold)).tracking(1.1).foregroundColor(.white.opacity(0.45))
                    if model.presentation {
                        Image(systemName: "eye.slash.fill").font(.system(size: 9.5, weight: .semibold)).foregroundColor(.white.opacity(0.5))
                            .help("Modo presentación: los proyectos privados no se muestran")
                    }
                }
                Text(headline).font(.system(size: 20, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
                    .foregroundColor(model.mood == "att" && !celebrating ? stateColor("attention") : .white)
                Text(subline).font(.system(size: 12)).foregroundColor(.white.opacity(0.55)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 0).padding(.trailing, 8).padding(.top, 2)
        .animation(.easeInOut(duration: 0.25), value: headline)
    }

    var agents: some View {
        VStack(spacing: 7) {
            ForEach(model.agents) { a in
                AgentCard(a: a, now: model.now, animated: model.visible) { model.onAgent?(a.id) }
                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
            }
            if model.more > 0 {
                Text("+\(model.more) más").font(.system(size: 11, weight: .semibold)).foregroundColor(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, alignment: .center).help(model.moreTip)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: model.agents.map(\.id))
    }

    /// Selector de proyecto, dentro del propio widget.
    var picker: some View {
        let q = model.pickQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let list = q.isEmpty ? model.projects : model.projects.filter { $0.name.lowercased().contains(q) }
        let rows = VStack(spacing: 2) {
            ForEach(list) { p in
                Button(action: { model.onPick?(p.id) }) {
                    HStack(spacing: 9) {
                        Image(systemName: p.root ? "square.grid.2x2.fill" : p.level > 0 && q.isEmpty ? "arrow.turn.down.right" : "folder.fill")
                            .font(.system(size: p.level > 0 && q.isEmpty ? 9 : 11, weight: .semibold))
                            .foregroundColor(p.current ? uiAccent : .white.opacity(p.level > 0 && q.isEmpty ? 0.3 : 0.45))
                            .frame(width: 16)
                        Text(p.name).font(.system(size: 13, weight: p.current ? .semibold : .regular)).lineLimit(1)
                            .foregroundColor(.white.opacity(p.current ? 1 : p.level > 0 ? 0.72 : 0.88))
                        Spacer(minLength: 4)
                        if p.current { Image(systemName: "checkmark").font(.system(size: 10.5, weight: .heavy)).foregroundColor(uiAccent) }
                    }
                    .padding(.leading, 9 + (q.isEmpty ? CGFloat(p.level) * 14 : 0)).padding(.trailing, 10).frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(p.current ? uiAccent.opacity(0.16) : Color.white.opacity(0.001)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowStyle())
            }
            if list.isEmpty {
                Text("Ningún proyecto con ese nombre").font(.system(size: 12)).foregroundColor(.white.opacity(0.4)).frame(height: 60)
            }
        }
        return Card(padding: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionLabel(text: "PROYECTO")
                    Spacer()
                    Button(action: { model.picking = false }) {
                        Image(systemName: "xmark").font(.system(size: 8.5, weight: .heavy)).foregroundColor(.white.opacity(0.6))
                            .frame(width: 20, height: 20).background(Circle().fill(Color.white.opacity(0.09)))
                    }
                    .buttonStyle(PressStyle())
                }
                .padding(.horizontal, 4).padding(.top, 2)
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundColor(.white.opacity(0.4))
                    if model.renderMode {
                        Text("Buscar…").font(.system(size: 12.5)).foregroundColor(.white.opacity(0.35)).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        TextField("", text: $model.pickQuery, prompt: Text("Buscar…").foregroundColor(.white.opacity(0.35)))
                            .textFieldStyle(.plain).font(.system(size: 12.5))
                            .onSubmit { if let f = list.first { model.onPick?(f.id) } }
                    }
                }
                .padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.28)))
                Group {
                    if model.renderMode { rows.frame(height: 300, alignment: .top).clipped() }
                    else { ScrollView(.vertical, showsIndicators: false) { rows }.frame(height: min(300, CGFloat(max(2, list.count)) * 32)) }
                }
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                HStack(spacing: 6) {
                    Button(action: { model.onChooseFolder?() }) { Label("Cambiar carpeta", systemImage: "folder.badge.gearshape") }
                        .buttonStyle(MiniStyle()).fixedSize()
                    if model.canEditSelf {
                        Button(action: { model.onEditSelf?() }) { Label("Editar Chispa", systemImage: "terminal") }
                            .buttonStyle(MiniStyle()).fixedSize()
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// Pedirle una tarea a Claude sin salir del widget.
    var ask: some View {
        let ready = !model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(spacing: 8) {
            Image(systemName: "sparkle").font(.system(size: 11, weight: .bold)).foregroundColor(uiAccent)
            if model.renderMode {
                Text(model.prompt.isEmpty ? "Pídele algo a Claude…" : model.prompt).font(.system(size: 13)).lineLimit(1)
                    .foregroundColor(.white.opacity(model.prompt.isEmpty ? 0.38 : 1)).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("", text: $model.prompt, prompt: Text("Pídele algo a Claude…").foregroundColor(.white.opacity(0.38)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit { send() }
            }
            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(size: 11, weight: .heavy))
                    .foregroundColor(ready ? .white : .white.opacity(0.35))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(ready ? uiAccent : Color.white.opacity(0.09)))
            }
            .buttonStyle(PressStyle())
            .help("Abre un agente nuevo en «\(model.project)» con esta petición (o pulsa Intro). Atajo para escribir aquí: ⌃⌥C")
        }
        .padding(.leading, 12).padding(.trailing, 6).frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 19, style: .continuous).fill(Color.white.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).strokeBorder(Color.white.opacity(ready ? 0.22 : 0.09), lineWidth: 1))
    }

    func send() {
        let text = model.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.prompt = ""
        model.onAsk?(text)
    }

    var actions: some View {
        HStack(spacing: 7) {
            Button(action: { model.onProject?() }) {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill").font(.system(size: 10.5))
                    Text(model.project).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.5)
                        .rotationEffect(.degrees(model.picking ? 180 : 0))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(CapsuleStyle())
            .help("Elegir proyecto")
            Button(action: { model.onNew?() }) {
                HStack(spacing: 4) { Image(systemName: "plus").font(.system(size: 10, weight: .bold)); Text("Nueva") }
            }
                .buttonStyle(CapsuleStyle(filled: true, compact: true))
                .fixedSize()
                .help("Crear una carpeta nueva de proyecto y abrir Claude en ella")
            Button(action: { model.onContinue?() }) { Text("Seguir") }
                .buttonStyle(CapsuleStyle(compact: true))
                .fixedSize()
                .help("Retomar la última conversación del proyecto")
        }
    }

    var results: some View {
        Button(action: { model.onReport?() }) {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        SectionLabel(text: "RESULTADOS")
                        Spacer()
                        HStack(spacing: 3) {
                            Text("Informe semanal")
                            Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .bold))
                        }
                        .font(.system(size: 10.5, weight: .semibold)).foregroundColor(uiAccent)
                    }
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: -2) {
                            Text(model.statsLoaded ? "\(model.today.tasks)" : "–")
                                .font(.system(size: 50, weight: .bold, design: .rounded)).monospacedDigit()
                                .contentTransition(.numericText())
                                .foregroundColor(model.bump ? uiAccent : .white)
                                .scaleEffect(model.bump ? 1.12 : 1, anchor: .bottomLeading)
                                .animation(.spring(response: 0.45, dampingFraction: 0.55), value: model.bump)
                                .animation(.spring(response: 0.5, dampingFraction: 0.8), value: model.today.tasks)
                            Text("tareas hoy").font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.55))
                        }
                        Spacer()
                        WeekBars(values: model.perDay)
                    }
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                    HStack(spacing: 0) {
                        stat(model.statsLoaded ? StatsText.duration(model.today.seconds) : "–", "de agente hoy")
                        stat(model.statsLoaded ? "\(model.week.tasks)" : "–", "tareas · 7 días")
                        stat(model.statsLoaded ? StatsText.duration(model.week.seconds) : "–", "de agente · 7 días")
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help("Clic para generar el informe semanal.\n\nSale de tus sesiones reales de Claude Code.\n• Tareas: peticiones tuyas que Claude ha resuelto.\n• Agente: tiempo que Claude ha estado trabajando (no cuenta pausas de más de 5 min).")
    }

    func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 13.5, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 9.5)).foregroundColor(.white.opacity(0.45)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// ¿Te llega lo que queda hasta que se renueve, al ritmo que llevas?
    var verdict: (text: String, bad: Bool)? {
        let known = model.usage.filter { $0.left != nil }
        guard !known.isEmpty else { return nil }
        if let w = known.filter({ $0.runsOut != nil }).min(by: { $0.runsOut! < $1.runsOut! }) {
            return ("\(w.label): a este ritmo se agota en ~\(roughSpan(w.runsOut!))", true)
        }
        if let e = known.first(where: { ($0.left ?? 1) <= 0.005 }) { return ("\(e.label) agotada", true) }
        guard known.contains(where: { $0.timeLeft != nil }) else { return nil }
        return ("A este ritmo te llega hasta que se renueve", false)
    }

    /// La explicación del anillo pulsado, una idea por línea.
    func usageLines(_ u: UsageVM) -> [String] {
        var out = u.tip.components(separatedBy: ". ").filter { !$0.hasPrefix("La marca blanca") }
        if u.runsOut == nil, u.timeLeft != nil, u.left != nil { out.append("A este ritmo te llega hasta que se renueve") }
        return out
    }

    var usage: some View {
        Group { if model.usageEnabled { usageRings } else { usageInvite } }
    }

    /// Antes de activarlo: qué es y un botón. Nada se lee del Llavero hasta que se pulsa.
    var usageInvite: some View {
        Card {
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(text: "TE QUEDA DE CLAUDE")
                HStack(spacing: 10) {
                    Text("Cuánto te queda de la sesión y de la semana, y si a tu ritmo te llega.")
                        .font(.system(size: 11)).foregroundColor(.white.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(action: { model.onEnableUsage?() }) {
                        Text("Activar").font(.system(size: 11.5, weight: .semibold)).foregroundColor(.white)
                            .padding(.horizontal, 13).frame(height: 28)
                            .background(Capsule().fill(uiAccent))
                    }
                    .buttonStyle(PressStyle())
                    .help("Te explicará qué hace antes de activarlo")
                }
            }
        }
    }

    var usageRings: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "TE QUEDA DE CLAUDE")
                HStack(spacing: 0) {
                    ForEach(model.usage) { u in
                        Button(action: {
                            guard u.left != nil || !u.tip.isEmpty else { return }
                            withAnimation(.easeInOut(duration: 0.2)) { model.usagePick = model.usagePick == u.id ? nil : u.id }
                            model.onUsagePick?()
                        }) { Ring(u: u, picked: model.usagePick == u.id, dimmed: model.usagePick != nil && model.usagePick != u.id) }
                        .buttonStyle(PressStyle())
                        .help(model.usagePick == u.id ? "Clic para cerrar" : "Clic para ver el detalle")
                    }
                }
                .padding(.vertical, -5)
                if let u = model.usage.first(where: { $0.id == model.usagePick }), !u.tip.isEmpty {
                    let bad = u.runsOut != nil || (u.left ?? 1) < 0.2
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(usageLines(u).enumerated()), id: \.offset) { i, line in
                            Text(line).font(.system(size: 11, weight: i == 0 ? .semibold : .regular))
                                .foregroundColor(i == 0 ? .white : .white.opacity(0.62))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill((bad ? stateColor("attention") : Color.white).opacity(bad ? 0.12 : 0.07)))
                    .transition(.opacity)
                } else if let v = verdict {
                    HStack(spacing: 5) {
                        Image(systemName: v.bad ? "exclamationmark.triangle.fill" : "checkmark.circle.fill").font(.system(size: 10, weight: .bold))
                        Text(v.text).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85)
                    }
                    .foregroundColor(v.bad ? stateColor("attention") : stateColor("done"))
                    .frame(maxWidth: .infinity).frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill((v.bad ? stateColor("attention") : stateColor("done")).opacity(0.12)))
                }
            }
        }
    }

    var footer: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                Button(action: { model.onShowApps?() }) {
                    HStack(spacing: 0) {
                        MiniMeter(icon: "cpu", label: "CPU", value: "\(Int((model.cpu * 100).rounded())) %", fraction: model.cpu)
                        Spacer(minLength: 0)
                        MiniMeter(icon: "memorychip", label: "MEMORIA", value: model.memText, fraction: model.memFraction)
                        Spacer(minLength: 0)
                        MiniMeter(icon: "internaldrive", label: "DISCO", value: model.diskText, fraction: model.diskFraction).help(model.diskTip)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .help(model.presentation ? "" : "Clic para ver qué apps usan más memoria")
                if model.showApps && !model.presentation {
                    VStack(alignment: .leading, spacing: 5) {
                        SectionLabel(text: "LO QUE MÁS MEMORIA USA").padding(.bottom, 1)
                        let top = max(1, model.topApps.map(\.bytes).max() ?? 1)
                        ForEach(model.topApps) { app in
                            let gb = Double(app.bytes) / 1_073_741_824
                            HStack(spacing: 8) {
                                Group {
                                    if let icon = app.icon {
                                        Image(nsImage: icon).resizable().interpolation(.high)
                                    } else {
                                        Image(systemName: "gearshape.fill").font(.system(size: 9.5, weight: .semibold)).foregroundColor(.white.opacity(0.6))
                                            .frame(width: 18, height: 18)
                                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.12)))
                                    }
                                }
                                .frame(width: 18, height: 18)
                                Text(app.name).font(.system(size: 12, weight: .medium)).lineLimit(1).foregroundColor(.white.opacity(0.9))
                                Spacer(minLength: 6)
                                Text(gb >= 1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", gb * 1024))
                                    .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                                    .foregroundColor(.white.opacity(app.id == 0 ? 1 : 0.8))
                            }
                            .padding(.horizontal, 7).frame(height: 28)
                            .background(GeometryReader { g in
                                // la barra de fondo es la proporción respecto a la que más usa
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(app.id == 0 ? uiAccent.opacity(0.30) : Color.white.opacity(0.09))
                                    .frame(width: max(28, g.size.width * CGFloat(Double(app.bytes) / Double(top))))
                                    .animation(.easeOut(duration: 0.5), value: app.bytes)
                            })
                        }
                    }
                    .padding(.top, 2)
                    .transition(.opacity)
                }
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                HStack(spacing: 4) {
                    Button(action: { model.onToggle?() }) {
                        HStack(spacing: 7) {
                            Image(systemName: model.awake ? "cup.and.heat.waves.fill" : "moon.zzz.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(model.awake ? .orange : Color(red: 0.62, green: 0.60, blue: 1.0))
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(model.sleepTitle).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                                    .foregroundColor(model.timerOn ? .orange : .white).lineLimit(1).minimumScaleFactor(0.8)
                                HStack(spacing: 3) {
                                    Image(systemName: model.batterySymbol).font(.system(size: 9.5))
                                    Text(model.batteryText).font(.system(size: 10)).monospacedDigit().lineLimit(1)
                                }
                                .fixedSize()
                                .foregroundColor(model.batteryLow ? stateColor("attention") : model.batteryCharging ? stateColor("done") : .white.opacity(0.45))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                    .help(model.sleepTip)
                    .layoutPriority(1)
                    Spacer(minLength: 2)
                    ForEach([30, 60, 120], id: \.self) { m in
                        Button(action: { model.onTimer?(m) }) { Text(m == 30 ? "½h" : m == 60 ? "1h" : "2h") }
                            .buttonStyle(ChipStyle(selected: model.timerOn && model.timerMinutes == m))
                            .help(model.timerOn && model.timerMinutes == m ? "Pulsa otra vez para cancelar" : "Mantener despierto \(m == 30 ? "media hora" : m == 60 ? "1 hora" : "2 horas")")
                    }
                    Button(action: { model.onDisplayOff?() }) { Image(systemName: "display").font(.system(size: 10.5, weight: .semibold)) }
                        .buttonStyle(ChipStyle())
                        .help("Apagar la pantalla ahora (sin dormir)")
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.showApps)
    }
}

enum StatsText {
    static func duration(_ s: Double) -> String {
        let m = Int((s / 60).rounded())
        return m < 60 ? "\(m) min" : String(format: "%d h %02d", m / 60, m % 60)
    }
}

/// Luz que recorre el borde mientras hay agentes trabajando o te necesitan. No recibe clics.
final class GlowView: NSView {
    private let hostLayer = CALayer()
    private let maskLayer = CAShapeLayer()
    private let conic = CAGradientLayer()
    private var mood = ""
    private var active = true
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        conic.type = .conic
        conic.startPoint = CGPoint(x: 0.5, y: 0.5)
        conic.endPoint = CGPoint(x: 0.5, y: 0)
        conic.locations = [0, 0.55, 0.80, 0.90, 1]
        hostLayer.addSublayer(conic)
        maskLayer.fillColor = nil
        maskLayer.strokeColor = NSColor.white.cgColor
        maskLayer.lineWidth = 2
        hostLayer.mask = maskLayer
        hostLayer.opacity = 0
        layer?.addSublayer(hostLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        hostLayer.frame = bounds
        maskLayer.frame = bounds
        maskLayer.path = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: 27, cornerHeight: 27, transform: nil)
        let side = 2 * max(bounds.width, bounds.height)
        conic.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        conic.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    func set(mood m: String, active a: Bool) {
        guard m != mood || a != active else { return }
        mood = m; active = a
        let on = a && (m == "work" || m == "att")
        let c = m == "att" ? NSColor(red: 1.0, green: 0.33, blue: 0.30, alpha: 1) : claudeOrange
        conic.colors = [c.withAlphaComponent(0).cgColor, c.withAlphaComponent(0).cgColor, c.cgColor,
                        NSColor.white.cgColor, c.withAlphaComponent(0).cgColor]
        conic.removeAnimation(forKey: "spin")
        if on {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0; spin.toValue = -2 * Double.pi
            spin.duration = m == "att" ? 1.8 : 4.0
            spin.repeatCount = .infinity
            conic.add(spin, forKey: "spin")
        }
        hostLayer.opacity = on ? 1 : 0
    }
}

// MARK: - Vista (contenedor AppKit de la interfaz SwiftUI)
final class WidgetHost<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

class WidgetView: NSView {
    static let W: CGFloat = 300
    let model = WidgetModel()
    private(set) var height: CGFloat = 560
    var onExtraChanged: (() -> Void)?
    var onMood: ((String, Int) -> Void)?
    var onSession: ((ClaudeSession?) -> Void)?
    var isSecret: (ClaudeSession) -> Bool = { _ in false }
    var lidText = ""
    private var sessions: [ClaudeSession] = []
    private var lastTopApps = Date.distantPast
    /// Alto disponible en la pantalla para el widget.
    var room: CGFloat = 900 { didSet { if abs(room - oldValue) > 1 { updateClaude(sessions) } } }
    private var host: NSView!
    private let glow = GlowView(frame: .zero)

    override var isFlipped: Bool { true }
    override var menu: NSMenu? { didSet { host?.menu = menu } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let h = WidgetHost(rootView: WidgetUI(model: model))
        h.sizingOptions = []
        h.frame = bounds
        h.autoresizingMask = [.width, .height]
        addSubview(h)
        host = h
        glow.frame = bounds
        glow.autoresizingMask = [.width, .height]
        addSubview(glow)
        model.showApps = UserDefaults.standard.bool(forKey: "showMemPage")
        model.brain.center = { [weak self] in
            guard let w = self?.window, w.isVisible else { return nil }
            return CGPoint(x: w.frame.minX + 60, y: w.frame.maxY - 73)
        }
        model.onHeight = { [weak self] v in
            guard let self, v > 50, abs(v - self.height) > 0.5 else { return }
            self.height = v
            self.onExtraChanged?()
        }
        model.onAgent = { [weak self] id in
            guard let self else { return }
            self.onSession?(id.flatMap { i in self.sessions.first { $0.id == i } })
        }
        model.onUsagePick = { [weak self] in
            guard let self else { return }
            self.updateClaude(self.sessions)
        }
        model.onShowApps = { [weak self] in
            guard let self, !self.model.presentation else { return }
            self.model.showApps.toggle()
            UserDefaults.standard.set(self.model.showApps, forKey: "showMemPage")
            self.lastTopApps = .distantPast
            self.updateSystem()
            self.updateClaude(self.sessions)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Escondido en el borde: se paran las animaciones para no gastar CPU.
    private func findField(_ v: NSView) -> NSTextField? {
        if let f = v as? NSTextField, f.isEditable { return f }
        for sub in v.subviews { if let f = findField(sub) { return f } }
        return nil
    }
    var fieldIsActive: Bool { window?.firstResponder is NSTextView }
    func focusField() { if let f = findField(host) { window?.makeFirstResponder(f) } }

    func setVisible(_ v: Bool) {
        if model.visible != v { model.visible = v }
        glow.set(mood: model.mood, active: v)
    }

    func update(disabled: Bool) { if model.awake != disabled { model.awake = disabled } }

    func updateDetails(disabled: Bool, timerEnd: Date?, timerMinutes: Int, battery: Battery?) {
        model.now = Date()
        var left = ""
        if disabled, let end = timerEnd { left = clock(end.timeIntervalSinceNow) }
        let timerOn = disabled && timerEnd != nil
        let title = timerOn ? "Despierto \(left)" : disabled ? "Siempre despierto" : "Reposo normal"
        if model.sleepTitle != title { model.sleepTitle = title }
        if model.timerOn != timerOn { model.timerOn = timerOn }
        if model.timerMinutes != timerMinutes { model.timerMinutes = timerMinutes }
        lidText = disabled ? "Con la tapa cerrada: no duerme" : "Con la tapa cerrada: duerme"
        let tip = "Clic para cambiar entre reposo normal y siempre despierto. \(lidText)."
        if model.sleepTip != tip { model.sleepTip = tip }
        var text = "Corriente", sym = "powerplug.fill", low = false, charging = false
        if let b = battery {
            let step = b.level >= 88 ? 100 : b.level >= 63 ? 75 : b.level >= 38 ? 50 : b.level >= 13 ? 25 : 0
            low = b.level <= 20 && !b.onAC
            charging = b.charging
            sym = b.charging ? "battery.100percent.bolt" : "battery.\(step)percent"
            text = "\(b.level) % · \(b.charging ? "cargando" : b.onAC ? "enchufado" : "batería")"
        }
        if model.batteryText != text { model.batteryText = text }
        if model.batterySymbol != sym { model.batterySymbol = sym }
        if model.batteryLow != low { model.batteryLow = low }
        if model.batteryCharging != charging { model.batteryCharging = charging }
    }

    func updateSystem() {
        if model.showApps && !model.presentation && Date().timeIntervalSince(lastTopApps) >= 3 {
            lastTopApps = Date()
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let top = readTopApps(5)
                DispatchQueue.main.async { self?.model.topApps = top.enumerated().map { AppMem(id: $0.offset, name: $0.element.name, bytes: $0.element.bytes,
                                                                                               icon: $0.element.app.map { NSWorkspace.shared.icon(forFile: $0) }) } }
            }
        }
        if let c = readCPU() { model.cpu = c }
        if let m = readMemory() {
            model.memFraction = Double(m.used) / Double(m.total)
            model.memText = String(format: "%.1f GB", Double(m.used) / 1_073_741_824)
        }
    }

    func updateDisk() {
        guard let d = readDisk() else { return }
        let gb = Double(d.free) / 1_000_000_000
        model.diskFraction = 1 - Double(d.free) / Double(d.total)
        model.diskText = gb >= 1000 ? String(format: "%.2f TB", gb / 1000) : String(format: "%.0f GB", gb)
        model.diskTip = String(format: "%.1f GB libres de %.0f GB", gb, Double(d.total) / 1_000_000_000)
    }

    func updateUsage(_ u: [String: UsageLimit]?) {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "es_ES")
        fmt.dateFormat = "EEE d 'a las' H:mm"
        func tipBase(_ left: Double, _ what: String, _ l: UsageLimit) -> String {
            "Te queda el \(Int(left)) % \(what)" + (l.resetsAt.map { ". Se reinicia el \(fmt.string(from: $0))" } ?? "")
        }
        func vm(_ id: String, _ label: String, _ l: UsageLimit?, _ what: String) -> UsageVM {
            guard let l else {
                return UsageVM(id: id, label: label, left: nil, detail: u == nil ? "sin datos" : "—",
                               tip: u == nil ? "No se pudo leer el uso (abre Claude Code para renovar la sesión)" : "")
            }
            let left = max(0, 100 - l.percent)
            let r = shortUntil(l.resetsAt)
            // Ritmo: lo gastado frente al tiempo transcurrido del periodo (5 h la sesión, 7 días lo semanal)
            var timeLeft: Double? = nil, runsOut: Double? = nil
            if let reset = l.resetsAt {
                let window: Double = id == "session" ? 5 * 3600 : 7 * 86400
                let remain = min(window, max(0, reset.timeIntervalSinceNow))
                let elapsed = window - remain
                timeLeft = remain / window
                let used = l.percent / 100
                if elapsed > window * 0.08, used > 0.05, left > 0 {
                    let secondsToEmpty = (left / 100) / (used / elapsed)
                    if secondsToEmpty < remain * 0.95 { runsOut = secondsToEmpty }
                }
            }
            let pace = runsOut.map { ". A este ritmo se agota en unos \(roughSpan($0)), antes de renovarse" }
                ?? (timeLeft != nil ? ". La marca blanca es el tiempo que falta: si el arco la supera, vas con margen" : "")
            return UsageVM(id: id, label: label, left: left / 100, detail: r.isEmpty ? " " : "en \(r)", tip: tipBase(left, what, l) + pace, timeLeft: timeLeft, runsOut: runsOut)
            // (sin ritmo)
            return UsageVM(id: id, label: label, left: left / 100, detail: r.isEmpty ? " " : "en \(r)",
                           tip: "Te queda el \(Int(left)) % \(what)" + (l.resetsAt.map { ". Se reinicia el \(fmt.string(from: $0))" } ?? ""))
        }
        var new = [vm("session", "Sesión", u?["session"], "de la sesión (5 h)"),
                   vm("week", "Semana", u?["weekly"], "de la semana (todos los modelos)")]
        if let name = u?.keys.filter({ $0 != "session" && $0 != "weekly" }).sorted().first {
            new.append(vm("model", name, u?[name], "de la semana para \(name)"))
        }
        model.usage = new
    }

    func updateProject(_ name: String) { model.project = name }

    func setStats(today: WorkStats, week: WorkStats, perDay: [Int]) {
        let rose = model.statsLoaded && today.tasks > model.today.tasks
        model.today = today; model.week = week; model.perDay = perDay; model.statsLoaded = true
        if rose {
            model.bump = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in self?.model.bump = false }
        }
    }

    /// Un agente acaba de terminar: el personaje lo celebra.
    func celebrate(_ name: String) {
        model.partyName = name
        model.partyAt = Date()
    }

    func refit() { updateClaude(sessions) }

    func updateClaude(_ all: [ClaudeSession]) {
        sessions = all
        let order = ["attention": 0, "working": 1, "done": 2]
        let list = all.filter { order[$0.state] != nil }
            .sorted { (order[$0.state]!, $1.date) < (order[$1.state]!, $0.date) }
        // Que quepa en la pantalla: si no hay sitio, primero se pliegan tarjetas y luego se muestran menos agentes
        let apps = model.showApps && !model.presentation
        var maxR = min(4, max(1, list.count)), hideR = false, hideU = false
        func est() -> CGFloat {
            let shownN = min(list.count, maxR)
            return 125 + CGFloat(shownN) * 67 + (list.count > maxR ? 22 : 0) + 44 + 40
                + (hideR ? 0 : 180) + (hideU ? 0 : !model.usageEnabled ? 100 : 180 + (model.usagePick != nil ? 40 : 0)) + (apps ? 315 : 130) + 12
        }
        var steps: [() -> Void] = []
        if apps { steps.append { hideR = true } }
        steps.append { maxR = min(maxR, 3) }
        if apps { steps.append { hideU = true } }
        steps += [{ maxR = min(maxR, 2) }, { hideU = true }, { hideR = true }, { maxR = 1 }]
        for step in steps where est() > room { step() }
        if model.hideResults != hideR || model.hideUsage != hideU {
            withAnimation(.easeInOut(duration: 0.25)) { model.hideResults = hideR; model.hideUsage = hideU }
        }
        let shown = Array(list.prefix(maxR))
        let vms: [AgentVM] = shown.map { s in
            let secret = isSecret(s)
            let fallback = s.state == "attention" ? "Espera tu permiso" : s.state == "done" ? "Listo para revisar" : "Trabajando"
            return AgentVM(id: s.id, name: secret ? "Proyecto privado" : s.project, state: s.state,
                           activity: secret || s.activity.isEmpty ? fallback : s.activity,
                           start: s.start, end: s.state == "done" ? (s.end ?? s.date) : nil, steps: s.steps,
                           tip: secret ? "Clic para ir a su Terminal" : "\(s.cwd)\nClic para ir a su Terminal")
        }
        if vms != model.agents { model.agents = vms }
        let rest = list.dropFirst(maxR)
        if model.more != rest.count { model.more = rest.count }
        model.moreTip = rest.map { isSecret($0) ? "Proyecto privado" : $0.project }.joined(separator: "\n")
        let key = list.contains { $0.state == "attention" } ? "att" : list.contains { $0.state == "working" } ? "work"
            : list.contains { $0.state == "done" } ? "done" : "idle"
        if model.mood != key { model.mood = key }
        glow.set(mood: key, active: model.visible)
        onMood?(key, list.filter { $0.state != "done" }.count)
    }
}

// MARK: - Escondido en el borde izquierdo
/// Panel que puede colocarse fuera de la pantalla.
final class EdgePanel: NSPanel {
    override var canBecomeKey: Bool { true }      // para poder escribir en el widget
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Pestañita que queda en el borde cuando el widget está escondido: color del estado y nº de agentes activos.
/// Lo que enseña la pestañita del borde.
final class TabModel: ObservableObject {
    @Published var mood = "idle"        // idle · work · att · done
    @Published var working = 0
    @Published var partyAt: Date? = nil
    @Published var visible = false
    var renderT: Double = 0.9           // solo para --render-tab
    var renderNow = Date()
}

/// La mascota en pequeño. Al terminar una tarea celebra y vuelve a su reposo, sin abrir el widget.
struct TabMascot: View {
    @ObservedObject var m: TabModel
    static let mascotSize = CGSize(width: 76, height: 100)
    static let scale: CGFloat = 0.44
    func shownMood(_ now: Date) -> String {
        m.mood == "done" ? "idle" : m.mood          // terminado → vuelve al reposo
    }
    func mascot(t: Double, now: Date) -> some View {
        Mascot(mood: shownMood(now), t: t, party: m.partyAt.map { now.timeIntervalSince($0) }.flatMap { $0 < 3 ? $0 : nil })
            .frame(width: Self.mascotSize.width, height: Self.mascotSize.height)
            .scaleEffect(Self.scale)
            .frame(width: Self.mascotSize.width * Self.scale, height: Self.mascotSize.height * Self.scale)
    }
    var body: some View {
        VStack(spacing: 0) {
            Group {
                if m.visible {
                    let partying = m.partyAt.map { Date().timeIntervalSince($0) < 3 } ?? false
                    TimelineView(.animation(minimumInterval: partying ? 1.0 / 24 : m.mood == "idle" ? 1.0 / 5 : 1.0 / 12)) { ctx in
                        mascot(t: ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600), now: ctx.date)
                    }
                } else {
                    mascot(t: m.renderT, now: m.renderNow)
                }
            }
            Text(m.working > 0 ? "\(m.working)" : " ")
                .font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(.white)
                .frame(height: 14)
        }
        .frame(width: TabView.size.width, height: TabView.size.height, alignment: .center)
    }
}

final class TabView: NSView {
    static let size = NSSize(width: 38, height: 64)
    let model = TabModel()
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let blur = NSVisualEffectView(frame: bounds)
        blur.material = .hudWindow; blur.state = .active; blur.blendingMode = .behindWindow
        blur.appearance = NSAppearance(named: .vibrantDark)
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 14
        blur.layer?.cornerCurve = .continuous
        blur.layer?.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 1
        blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        let shade = NSView(frame: bounds)
        shade.wantsLayer = true
        shade.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        blur.addSubview(shade)
        addSubview(blur)
        let host = NSHostingView(rootView: TabMascot(m: model))
        host.frame = bounds
        addSubview(host)
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(mood: String, working: Int) {
        if model.working != working { model.working = working }
        if model.mood != mood { model.mood = mood }
    }
    func celebrate() { model.partyAt = Date() }
    /// Solo se anima mientras se ve.
    func setVisible(_ v: Bool) { if model.visible != v { model.visible = v } }
}

// MARK: - App
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    var panel: NSPanel!
    var view: WidgetView!
    let loginItem = NSMenuItem(title: "Abrir al iniciar sesión", action: #selector(toggleLogin), keyEquivalent: "")
    let lidItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let hideItem = NSMenuItem(title: "Esconder en el borde izquierdo", action: #selector(toggleAutoHide), keyEquivalent: "")
    let presentItem = NSMenuItem(title: "Modo presentación", action: #selector(togglePresentation), keyEquivalent: "")
    let soundItem = NSMenuItem(title: "Sonido al terminar una tarea", action: #selector(toggleSound), keyEquivalent: "")
    let usageItem = NSMenuItem(title: "Mostrar lo que te queda de Claude (experimental)", action: #selector(toggleUsage), keyEquivalent: "")
    var showUsage: Bool {
        get { defaults.bool(forKey: "showUsage") }
        set { defaults.set(newValue, forKey: "showUsage") }
    }
    var doneSound: Bool {
        get { UserDefaults.standard.object(forKey: "doneSound") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "doneSound") }
    }
    let privateItem = NSMenuItem(title: "Proyectos privados", action: nil, keyEquivalent: "")
    var lastSessions: [ClaudeSession] = []

    /// Modo presentación: oculta los proyectos privados en el widget y en sus cifras.
    var presentation: Bool {
        get { defaults.bool(forKey: "presentation") }
        set { defaults.set(newValue, forKey: "presentation") }
    }
    /// Carpetas marcadas como privadas (nunca salen en el informe semanal).
    var privateProjects: Set<String> {
        get { Set(defaults.stringArray(forKey: "privateProjects") ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: "privateProjects") }
    }
    /// Carpeta donde se abrió la sesión (no la carpeta en la que está ahora mismo).
    func root(of s: ClaudeSession) -> String { statsReader.projectBySession[s.id] ?? s.cwd }
    func isPrivate(_ s: ClaudeSession) -> Bool { privateProjects.contains(root(of: s)) || privateProjects.contains(s.cwd) }
    func shortName(_ path: String) -> String {
        path == FileManager.default.homeDirectoryForCurrentUser.path ? "Carpeta personal" : (path as NSString).lastPathComponent
    }

    // Posición: esquina superior (fija) y x «de casa» cuando no se esconde
    var topY: CGFloat = 0
    var homeX: CGFloat = 0
    var autoHide: Bool {
        get { defaults.object(forKey: "autoHide") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoHide") }
    }
    var shown = true
    var revealUntil = Date.distantPast
    var outsideSince: Date?
    var edgeSince: Date?
    var edgeTimer: Timer?
    var tabPanel: EdgePanel!
    var tabView: TabView!

    var disabled = false
    var lastPmsetCheck = Date.distantPast
    var lowBatteryHandled = false
    var prevClaude: [String: String] = [:]
    var claudeInitialized = false
    var lastUsage: [String: UsageLimit]?
    var lastUsageFetch = Date.distantPast
    var lastDiskCheck = Date.distantPast
    let statsReader = WorkStatsReader()
    var lastStats = Date.distantPast

    let defaults = UserDefaults.standard
    var timerEnd: Date? {
        get { let t = defaults.double(forKey: "timerEnd"); return t > 0 ? Date(timeIntervalSince1970: t) : nil }
        set { defaults.set(newValue?.timeIntervalSince1970 ?? 0, forKey: "timerEnd") }
    }
    var timerMinutes: Int {
        get { defaults.integer(forKey: "timerMinutes") }
        set { defaults.set(newValue, forKey: "timerMinutes") }
    }
    var projectPath: String {
        get { defaults.string(forKey: "projectPath") ?? projectsURL.path }
        set { defaults.set(newValue, forKey: "projectPath") }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        let W = WidgetView.W, H: CGFloat = 560
        panel = EdgePanel(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Justo por debajo de las ventanas normales: queda en el escritorio, detrás de todo
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true

        view = WidgetView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        panel.contentView = view
        let m = view.model
        m.onToggle = { [weak self] in self?.toggle() }
        m.onTimer = { [weak self] minutes in
            guard let self else { return }
            // Pulsar la opción ya marcada la cancela
            if self.timerEnd != nil && self.timerMinutes == minutes { self.cancelTimer() } else { self.startTimer(minutes: minutes) }
        }
        m.onDisplayOff = { displayOffNow() }
        m.onProject = { [weak self] in self?.showProjectMenu() }
        m.onNew = { [weak self] in self?.launchNew() }
        m.onContinue = { [weak self] in self?.launch(continueLast: true) }
        m.onReport = { [weak self] in self?.makeReport() }
        m.onPick = { [weak self] path in
            guard let self else { return }
            self.projectPath = path
            self.view.updateProject(self.projectName(path))
            self.panel.makeFirstResponder(nil)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { self.view.model.picking = false }
        }
        m.onChooseFolder = { [weak self] in self?.closePicker(); self?.chooseProjectsFolder() }
        m.onEditSelf = { [weak self] in self?.closePicker(); self?.openOwnProject() }
        m.onAsk = { [weak self] text in
            guard let self else { return }
            self.panel.makeFirstResponder(nil)
            var url = URL(fileURLWithPath: self.projectPath)
            if !isDir(url) { url = projectsURL }
            launchClaude(in: url, continueLast: false, prompt: text)
        }
        view.onSession = { [weak self] s in self?.goToTerminal(s) }
        view.isSecret = { [weak self] s in self.map { $0.presentation && $0.isPrivate(s) } ?? false }
        m.presentation = presentation
        // Al soltar tras arrastrar el widget, se guarda su nueva posición
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] e in
            if let self, e.window === self.panel, self.panel.frame != self.targetFrame() {
                DispatchQueue.main.async { self.dragEnded() }
            }
            return e
        }

        let menu = NSMenu()
        menu.delegate = self
        loginItem.target = self
        lidItem.isEnabled = false
        menu.addItem(lidItem)
        menu.addItem(.separator())
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Salir", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q")
        view.menu = menu

        // Pestaña del borde
        tabPanel = EdgePanel(contentRect: NSRect(origin: .zero, size: TabView.size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        tabPanel.isOpaque = false
        tabPanel.backgroundColor = .clear
        tabPanel.hasShadow = true
        tabPanel.level = .statusBar
        tabPanel.ignoresMouseEvents = true
        tabPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        tabPanel.hidesOnDeactivate = false
        tabView = TabView(frame: NSRect(origin: .zero, size: TabView.size))
        tabPanel.contentView = tabView
        tabView.set(mood: "idle", working: 0)

        // Restaurar posición (se guarda la esquina superior, no el alto)
        let vf = screenFrame()
        if defaults.object(forKey: "topY") != nil {
            topY = defaults.double(forKey: "topY"); homeX = defaults.double(forKey: "homeX")
        } else {
            topY = vf.maxY - 24; homeX = vf.minX + 24
        }
        clampPosition()
        view.onExtraChanged = { [weak self] in self?.layoutPanel(animated: true) }
        view.onMood = { [weak self] mood, working in self?.tabView.set(mood: mood, working: working) }
        registerHotKey()
        hideItem.target = self
        menu.insertItem(hideItem, at: 2)
        let connectItem = NSMenuItem(title: "Conectar con Claude Code", action: #selector(connectClaude), keyEquivalent: "")
        connectItem.target = self
        menu.insertItem(connectItem, at: 3)
        let reportItem = NSMenuItem(title: "Informe semanal…", action: #selector(makeReport), keyEquivalent: "")
        reportItem.target = self
        menu.insertItem(reportItem, at: 0)
        menu.insertItem(.separator(), at: 1)
        presentItem.target = self
        privateItem.submenu = NSMenu()
        menu.insertItem(presentItem, at: 2)
        soundItem.target = self
        soundItem.state = doneSound ? .on : .off
        menu.insertItem(soundItem, at: 3)
        usageItem.target = self
        usageItem.state = showUsage ? .on : .off
        menu.insertItem(usageItem, at: 4)
        view.model.usageEnabled = showUsage
        view.model.onEnableUsage = { [weak self] in self?.toggleUsage() }
        menu.insertItem(privateItem, at: 3)
        menu.insertItem(.separator(), at: 4)
        panel.setFrame(targetFrame(), display: false)
        panel.orderFrontRegardless()
        applyAutoHideMode()

        let nc = UNUserNotificationCenter.current()
        nc.delegate = self
        nc.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        view.updateProject(projectName(projectPath))
        tick()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.ensureClaudeHooks(askIfMissing: true) }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // MARK: Bucle principal (cada segundo)
    func tick() {
        if Date().timeIntervalSince(lastPmsetCheck) >= 5 {
            disabled = isSleepDisabled()
            lastPmsetCheck = Date()
        }

        // Temporizador
        if let end = timerEnd {
            if !disabled {
                timerEnd = nil   // lo han desactivado por otro lado
            } else if end <= Date() {
                if setSleepDisabled(false) { disabled = false }
                timerEnd = nil
                notify("Temporizador terminado", "El Mac vuelve al reposo normal.")
                if !disabled { sleepIfLidClosed() }
            }
        }

        // Batería baja estando "siempre despierto" y sin cargador
        let bat = readBattery()
        if let b = bat, !b.onAC, b.level <= 15 {
            if disabled && !lowBatteryHandled {
                lowBatteryHandled = true
                if setSleepDisabled(false) { disabled = false; timerEnd = nil }
                notify("Batería baja (\(b.level) %)", "He vuelto al reposo normal para que no se agote.")
                if !disabled { sleepIfLidClosed() }
            }
        } else if bat?.onAC == true || (bat?.level ?? 100) > 20 {
            lowBatteryHandled = false
        }

        view.update(disabled: disabled)
        view.updateDetails(disabled: disabled, timerEnd: timerEnd, timerMinutes: timerMinutes, battery: bat)
        view.updateSystem()
        if Date().timeIntervalSince(lastDiskCheck) >= 30 { lastDiskCheck = Date(); view.updateDisk() }
        if !showUsage {
            // apagado: no se consulta nada
        } else if Date().timeIntervalSince(lastUsageFetch) >= 120 {
            lastUsageFetch = Date()
            fetchClaudeUsage { [weak self] u in
                guard let self else { return }
                if u != nil || self.lastUsage == nil { self.lastUsage = u }   // si falla, conserva lo último
                self.view.updateUsage(self.lastUsage)
            }
        } else if lastUsage != nil {
            view.updateUsage(lastUsage)   // para que la cuenta atrás avance
        }
        tickClaude()
        if Date().timeIntervalSince(lastStats) >= 30 { refreshStats() }
    }

    func refreshStats() {
        lastStats = Date()
        statsReader.refresh(exclude: presentation ? privateProjects : []) { [weak self] today, week, perDay in
            self?.view.setStats(today: today, week: week, perDay: perDay)
        }
    }

    func tickClaude() {
        let sessions = readClaudeSessions()
        lastSessions = sessions
        let terminalFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Terminal"
        if claudeInitialized && !terminalFront {
            for s in sessions where prevClaude[s.id] != s.state {
                let where_ = presentation && isPrivate(s) ? "un proyecto" : s.project
                if s.state == "done" { notify("Claude ha terminado", "En \(where_)") }
                if s.state == "attention" { notify("Claude te necesita", "Está esperando tu permiso en \(where_)") }
            }
        }
        // Escondido, ya no se abre: lo cuenta la mascota de la pestañita
        // Al terminar una tarea, los resultados se actualizan al momento
        if claudeInitialized, let s = sessions.first(where: { $0.state == "done" && prevClaude[$0.id] != "done" }) {
            view.celebrate(presentation && isPrivate(s) ? "" : s.project)
            tabView.celebrate()
            if doneSound { NSSound(named: "Glass")?.play() }
            // la tarea tarda un instante en quedar escrita en la sesión
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.refreshStats() }
        }
        prevClaude = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.state) })
        claudeInitialized = true
        view.updateClaude(sessions)
    }

    // MARK: Posición y escondido en el borde
    func screenFrame() -> NSRect { (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900) }

    func clampPosition() {
        let vf = screenFrame()
        topY = min(max(topY, vf.minY + 200), vf.maxY - 4)
        homeX = min(max(homeX, vf.minX + 4), vf.maxX - WidgetView.W - 4)
    }

    func dragEnded() {
        topY = panel.frame.maxY
        if !autoHide { homeX = panel.frame.minX }
        clampPosition()
        savePosition()
        layoutPanel(animated: true)
    }

    func savePosition() { defaults.set(Double(topY), forKey: "topY"); defaults.set(Double(homeX), forKey: "homeX") }

    func targetFrame() -> NSRect {
        let vf = screenFrame()
        view.room = vf.height - 16
        let h = view.height
        let x = !autoHide ? homeX : shown ? vf.minX + 10 : vf.minX - WidgetView.W - 24
        // Nunca por debajo del borde de la pantalla: si no cabe desde donde está, sube
        let top = min(vf.maxY - 4, max(topY, vf.minY + 6 + h))
        return NSRect(x: x, y: top - h, width: WidgetView.W, height: h)
    }

    func layoutPanel(animated: Bool) {
        let f = targetFrame()
        let hidden = autoHide && !shown
        // Escondido, el panel se retira del todo: si se quedara fuera de la pantalla,
        // asomaría al deslizarse los escritorios cuando cambias de uno a otro.
        if hidden {
            if animated && panel.isVisible {
                NSAnimationContext.runAnimationGroup({ c in
                    c.duration = 0.32
                    c.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)
                    panel.animator().setFrame(f, display: true)
                }, completionHandler: { [weak self] in
                    guard let self, self.autoHide, !self.shown else { return }
                    self.panel.orderOut(nil)
                    self.view.setVisible(false)
                    self.closePicker()
                })
            } else {
                panel.setFrame(f, display: false)
                panel.orderOut(nil)
                view.setVisible(false)
            }
        } else {
            view.setVisible(true)
            if !panel.isVisible {
                // vuelve a entrar desde el borde
                var start = f; start.origin.x = screenFrame().minX - f.width - 24
                panel.setFrame(start, display: false)
                panel.orderFrontRegardless()
            }
            if animated {
                NSAnimationContext.runAnimationGroup { c in
                    c.duration = 0.32
                    c.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)
                    panel.animator().setFrame(f, display: true)
                }
            } else {
                panel.setFrame(f, display: true)
            }
        }
        // Pestaña: solo cuando está escondido
        let vf = screenFrame()
        tabPanel.setFrame(NSRect(x: vf.minX, y: topY - 18 - TabView.size.height, width: TabView.size.width, height: TabView.size.height), display: true)
        tabView.setVisible(hidden)
        if hidden {
            if !tabPanel.isVisible {
                tabPanel.alphaValue = 0
                tabPanel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { c in c.duration = 0.35; tabPanel.animator().alphaValue = 1 }
            }
        } else if tabPanel.isVisible {
            tabPanel.orderOut(nil)
        }
    }

    var hotKeyRef: EventHotKeyRef?
    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.summon() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x53544731), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_C), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    /// ⌃⌥C: muestra el widget listo para escribir; si ya lo estaba, lo esconde.
    func summon() {
        if panel.isKeyWindow && view.fieldIsActive {
            panel.makeFirstResponder(nil)
            if autoHide { revealUntil = .distantPast; shown = false; layoutPanel(animated: true) }
            return
        }
        reveal(for: 8)
        DispatchQueue.main.asyncAfter(deadline: .now() + (panel.isVisible ? 0.05 : 0.3)) { [weak self] in
            guard let self else { return }
            self.panel.makeKey()
            self.view.focusField()
        }
    }

    func reveal(for seconds: TimeInterval) {
        guard autoHide else { return }
        revealUntil = max(revealUntil, Date().addingTimeInterval(seconds))
        outsideSince = nil
        if !shown { shown = true; layoutPanel(animated: true) }
    }

    func applyAutoHideMode() {
        edgeTimer?.invalidate(); edgeTimer = nil
        shown = true
        if autoHide {
            // Flota sobre las ventanas: así puede salir estés en la app que estés
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            revealUntil = Date().addingTimeInterval(4)
            edgeTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.edgeTick() }
        } else {
            // Como antes: en el escritorio, detrás de las ventanas
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        }
        layoutPanel(animated: true)
    }

    func edgeTick() {
        let m = NSEvent.mouseLocation
        if shown {
            let inside = panel.frame.insetBy(dx: -12, dy: -12).contains(m)
            if inside || NSEvent.pressedMouseButtons != 0 || Date() < revealUntil || !view.model.prompt.isEmpty || (panel.isKeyWindow && view.fieldIsActive) {
                outsideSince = nil
            } else {
                if outsideSince == nil { outsideSince = Date() }
                if Date().timeIntervalSince(outsideSince!) > 0.9 {
                    shown = false; outsideSince = nil; edgeSince = nil
                    layoutPanel(animated: true)
                }
            }
        } else {
            let t = tabPanel.frame
            let hot = m.x <= t.maxX + 2 && m.y >= t.minY - 8 && m.y <= t.maxY + 8
            if hot {
                if edgeSince == nil { edgeSince = Date() }
                if Date().timeIntervalSince(edgeSince!) > 0.1 {
                    shown = true; edgeSince = nil; outsideSince = nil
                    layoutPanel(animated: true)
                }
            } else { edgeSince = nil }
        }
    }

    /// Genera la página del informe de los últimos 7 días y la abre en el navegador.
    @objc func makeReport() {
        // Los proyectos privados nunca entran en el informe
        statsReader.weekSessions(exclude: privateProjects) { sessions, prev in
            let html = buildWeeklyReport(sessions, previousWeekTasks: prev)
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Informes Claude", isDirectory: true)
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
            let file = dir.appendingPathComponent("Informe semanal \(df.string(from: Date())).html")
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try html.write(to: file, atomically: true, encoding: .utf8)
                NSWorkspace.shared.open(file)
            } catch {
                let a = NSAlert(); a.messageText = "No se pudo crear el informe"; a.informativeText = error.localizedDescription; a.runModal()
            }
        }
    }

    @objc func toggleUsage() {
        if !showUsage {
            let a = NSAlert()
            a.messageText = "¿Mostrar lo que te queda de Claude?"
            a.informativeText = "Para saberlo, Chispa usa la sesión que Claude Code guarda en el Llavero (macOS te pedirá permiso: pulsa «Permitir», no «Permitir siempre») y pregunta a Anthropic cuánto uso te queda. Es una función no oficial: puede dejar de funcionar sin aviso. Tu sesión no se guarda ni se envía a ningún otro sitio."
            a.addButton(withTitle: "Mostrar"); a.addButton(withTitle: "Cancelar")
            NSApp.activate(ignoringOtherApps: true)
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        showUsage.toggle()
        usageItem.state = showUsage ? .on : .off
        view.model.usageEnabled = showUsage
        lastUsageFetch = .distantPast
        view.refit()
    }

    @objc func toggleSound() {
        doneSound.toggle()
        soundItem.state = doneSound ? .on : .off
        if doneSound { NSSound(named: "Glass")?.play() }
    }

    @objc func togglePresentation() {
        presentation.toggle()
        privacyChanged()
    }

    @objc func togglePrivate(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        var p = privateProjects
        if p.contains(path) { p.remove(path) } else { p.insert(path) }
        privateProjects = p
        privacyChanged()
    }

    func privacyChanged() {
        view.model.presentation = presentation
        view.updateProject(projectName(projectPath))
        refreshStats()
        tickClaude()
    }

    @objc func toggleAutoHide() {
        autoHide.toggle()
        applyAutoHideMode()
    }

    // MARK: Acciones de reposo
    /// Máximo que puede estar despierto (también al tocar arriba): 2 h.
    static let maxAwakeMinutes = 120

    func toggle() {
        // Tocar arriba: si está despierto vuelve al reposo; si no, despierto con el máximo (2 h)
        if disabled { cancelTimer() } else { startTimer(minutes: AppDelegate.maxAwakeMinutes) }
    }

    func startTimer(minutes: Int) {
        if disabled || setSleepDisabled(true) {
            disabled = true
            timerEnd = Date().addingTimeInterval(TimeInterval(minutes * 60))
            timerMinutes = minutes
            lastPmsetCheck = Date()
        }
        tick()
    }

    func cancelTimer() {
        timerEnd = nil
        if setSleepDisabled(false) { disabled = false }
        lastPmsetCheck = Date()
        tick()
    }

    // MARK: Acciones de Claude
    func projectName(_ path: String) -> String {
        if presentation && privateProjects.contains(path) { return "Proyecto" }
        if path == projectsURL.path { return projectsName }
        if path.hasPrefix(projectsURL.path + "/") { return String(path.dropFirst(projectsURL.path.count + 1)) }
        return (path as NSString).lastPathComponent
    }

    func launch(continueLast: Bool) {
        var url = URL(fileURLWithPath: projectPath)
        if !isDir(url) { url = projectsURL; projectPath = projectsURL.path; view.updateProject(projectsName) }
        launchClaude(in: url, continueLast: continueLast)
    }

    /// «Nueva»: pregunta siempre qué carpeta crear en la raíz de Anti y abre Claude dentro.
    func launchNew() {
        var message = "¿Qué carpeta creo en \(projectsName)?"
        var typed = ""
        while true {
            let a = NSAlert()
            a.messageText = message
            a.informativeText = "Se creará en \((projectsURL.path as NSString).abbreviatingWithTildeInPath) y Claude se abrirá dentro."
            a.addButton(withTitle: "Crear y abrir")
            a.addButton(withTitle: "Cancelar")
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            field.placeholderString = "Nombre de la carpeta"
            field.stringValue = typed
            a.accessoryView = field
            a.window.initialFirstResponder = field
            NSApp.activate(ignoringOtherApps: true)
            guard a.runModal() == .alertFirstButtonReturn else { return }

            typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if typed.isEmpty { message = "Escribe un nombre para la carpeta"; continue }
            if typed.contains("/") || typed.contains(":") || typed.hasPrefix(".") {
                message = "Ese nombre no vale (sin «/», «:» ni punto inicial)"; continue
            }
            let url = projectsURL.appendingPathComponent(typed, isDirectory: true)
            let fm = FileManager.default
            if fm.fileExists(atPath: url.path) {
                if !isDir(url) { message = "Ya hay un archivo con ese nombre"; continue }
                let e = NSAlert()
                e.messageText = "«\(typed)» ya existe"
                e.informativeText = "¿Abro Claude en esa carpeta?"
                e.addButton(withTitle: "Abrir")
                e.addButton(withTitle: "Otro nombre")
                if e.runModal() != .alertFirstButtonReturn { message = "¿Qué carpeta creo en \(projectsName)?"; continue }
            } else {
                do { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
                catch { message = "No se pudo crear: \(error.localizedDescription)"; continue }
            }
            projectPath = url.path
            view.updateProject(projectName(url.path))
            launchClaude(in: url, continueLast: false)
            return
        }
    }

    func showProjectMenu() {
        let m = view.model
        if m.picking { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { m.picking = false }; return }
        m.projects = listProjects().map { p in
            let sub = p.name.contains("/")
            return ProjectVM(id: p.url.path, name: sub ? (p.name as NSString).lastPathComponent : p.name, level: sub ? 1 : 0,
                             current: p.url.path == projectPath, root: p.url.path == projectsURL.path)
        }
        m.pickQuery = ""
        m.canEditSelf = FileManager.default.fileExists(atPath: ownSourceURL.appendingPathComponent("main.swift").path)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { m.picking = true }
    }

    func closePicker() { if view.model.picking { view.model.picking = false } }

    @objc func chooseProjectsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = projectsURL
        panel.prompt = "Usar esta carpeta"
        panel.message = "Elige la carpeta donde guardas tus proyectos. «Nueva» creará los proyectos dentro."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        defaults.set(url.path, forKey: "projectsFolder")
        projectPath = url.path
        view.updateProject(projectName(url.path))
    }

    // MARK: Conexión con Claude Code (hooks en ~/.claude/settings.json)
    /// Comprueba que Claude Code avisa a este widget. Si la app se ha movido, corrige la ruta;
    /// si nunca se ha conectado, pregunta antes de tocar nada. Siempre deja copia de seguridad.
    func ensureClaudeHooks(askIfMissing: Bool) {
        guard let script = Bundle.main.path(forResource: "claude-hook", ofType: "sh") else { return }
        let fm = FileManager.default
        let file = home.appendingPathComponent(".claude/settings.json")
        guard isDir(home.appendingPathComponent(".claude")) else {
            if !askIfMissing {     // lo ha pedido desde el menú
                let a = NSAlert(); a.messageText = "No encuentro Claude Code en este Mac"
                a.informativeText = "Instala Claude Code, ábrelo una vez y vuelve a elegir «Conectar con Claude Code»."
                NSApp.activate(ignoringOtherApps: true); a.runModal()
            }
            return
        }
        var root = ((try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        if fm.fileExists(atPath: file.path) && root.isEmpty,
           let d = try? Data(contentsOf: file), !d.isEmpty, (try? JSONSerialization.jsonObject(with: d)) == nil { return }  // no se entiende: no se toca
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let wanted: [(event: String, state: String, matcher: String?)] = [
            ("UserPromptSubmit", "working", nil), ("PostToolUse", "working", "*"), ("Stop", "done", nil),
            ("Notification", "attention", "permission_prompt|elicitation_dialog"), ("SessionEnd", "end", nil)]
        func isOurs(_ cmd: String) -> Bool { cmd.contains("Chispa") && cmd.contains("claude-hook.sh") }
        var present = 0, changed = false
        for w in wanted {
            let cmd = "'" + script.replacingOccurrences(of: "'", with: "'\\''") + "' \(w.state)"
            var entries = hooks[w.event] as? [[String: Any]] ?? []
            var found = false
            for i in entries.indices {
                guard var hs = entries[i]["hooks"] as? [[String: Any]] else { continue }
                for j in hs.indices {
                    guard let c = hs[j]["command"] as? String, isOurs(c) else { continue }
                    found = true
                    if c != cmd { hs[j]["command"] = cmd; changed = true }      // la app se ha movido
                }
                entries[i]["hooks"] = hs
            }
            if found { present += 1 } else {
                var e: [String: Any] = ["hooks": [["type": "command", "command": cmd, "timeout": 5]]]
                if let m = w.matcher { e["matcher"] = m }
                entries.append(e); changed = true
            }
            hooks[w.event] = entries
        }
        guard changed else { return }
        if present == 0 {
            // Primera vez en este Mac: se pregunta (una sola vez si viene del arranque)
            if askIfMissing && defaults.bool(forKey: "hooksAsked") { return }
            defaults.set(true, forKey: "hooksAsked")
            let a = NSAlert()
            a.messageText = "¿Conecto el widget con Claude Code?"
            a.informativeText = "Añadiré unos avisos a ~/.claude/settings.json para que Claude Code le diga al widget cuándo está trabajando, cuándo termina y cuándo te necesita. Guardo antes una copia del archivo. Puedes hacerlo más tarde desde el clic derecho."
            a.addButton(withTitle: "Conectar")
            a.addButton(withTitle: "Ahora no")
            NSApp.activate(ignoringOtherApps: true)
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        root["hooks"] = hooks
        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        if fm.fileExists(atPath: file.path) {
            let backup = file.deletingLastPathComponent().appendingPathComponent("settings.json.antes-chispa")
            if !fm.fileExists(atPath: backup.path) { try? fm.copyItem(at: file, to: backup) }   // solo la primera vez
        }
        try? out.write(to: file, options: .atomic)
    }

    @objc func connectClaude() { defaults.set(false, forKey: "hooksAsked"); ensureClaudeHooks(askIfMissing: false) }

    @objc func openOwnProject() {
        launchClaude(in: ownSourceURL, continueLast: false)
    }

    @objc func pickProject(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        projectPath = path
        view.updateProject(projectName(path))
    }

    /// Va a la pestaña de Terminal de esa sesión; si no se sabe cuál es, abre Terminal sin más.
    func goToTerminal(_ s: ClaudeSession? = nil) {
        if let s {
            if s.state == "done" { try? FileManager.default.removeItem(at: claudeStateDir.appendingPathComponent(s.id)) }
            if focusTerminalTab(tty: s.tty) { tickClaude(); return }
        } else {
            clearDoneSessions()
        }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                           configuration: NSWorkspace.OpenConfiguration())
        tickClaude()
    }

    // MARK: Menú contextual
    func menuWillOpen(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        hideItem.state = autoHide ? .on : .off
        presentItem.state = presentation ? .on : .off
        // Proyectos de la última semana, los que están abiertos ahora y los ya marcados
        let priv = privateProjects
        let all = Set(statsReader.projects).union(lastSessions.map { root(of: $0) }).union(priv).filter { !$0.isEmpty }
        let sub = privateItem.submenu!
        sub.removeAllItems()
        let head = NSMenuItem(title: "Marca los que no quieres enseñar:", action: nil, keyEquivalent: "")
        head.isEnabled = false
        sub.addItem(head)
        for path in all.sorted(by: { shortName($0).localizedCaseInsensitiveCompare(shortName($1)) == .orderedAscending }) {
            let it = NSMenuItem(title: shortName(path), action: #selector(togglePrivate(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = path
            it.toolTip = path
            it.state = priv.contains(path) ? .on : .off
            sub.addItem(it)
        }
        privateItem.title = priv.isEmpty ? "Proyectos privados" : "Proyectos privados (\(priv.count))"
        lidItem.title = view.lidText
    }

    @objc func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            let a = NSAlert(); a.messageText = "No se pudo cambiar"; a.informativeText = error.localizedDescription; a.runModal()
        }
    }
}

// Prueba desde Terminal: `Chispa --informe ruta.html` escribe el informe y sale (no abre nada)
if let i = CommandLine.arguments.firstIndex(of: "--informe"), i + 1 < CommandLine.arguments.count {
    let out = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    WorkStatsReader().weekSessions { sessions, prev in
        try? buildWeeklyReport(sessions, previousWeekTasks: prev).write(to: out, atomically: true, encoding: .utf8)
        exit(0)
    }
    RunLoop.main.run()
}

// `Chispa --render salida.png [busy|idle|alert]` dibuja el widget con datos de ejemplo y sale
if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 1 < CommandLine.arguments.count {
    let scenario = CommandLine.arguments.count > i + 2 ? CommandLine.arguments[i + 2] : "busy"
    let m = WidgetModel()
    m.renderMode = true
    m.project = "web-clientes"
    let now = Date()
    if scenario != "idle" {
        m.agents = [
            AgentVM(id: "1", name: "web-clientes", state: scenario == "alert" ? "attention" : "working",
                    activity: scenario == "alert" ? "Espera tu permiso" : "Edición · checkout.tsx", start: now.addingTimeInterval(-161), end: nil, steps: 14, tip: ""),
            AgentVM(id: "2", name: "informes-ventas", state: "working", activity: "Ejecutando las pruebas", start: now.addingTimeInterval(-47), end: nil, steps: 5, tip: ""),
            AgentVM(id: "3", name: "migracion-datos", state: "done", activity: "Listo para revisar", start: now.addingTimeInterval(-900), end: now.addingTimeInterval(-388), steps: 31, tip: "")]
        m.mood = scenario == "alert" ? "att" : "work"
    }
    if scenario == "pick" {
        m.picking = true
        let names: [(String, Int)] = [("Anti", 0), ("_cerebro", 0), ("Anochece", 0), ("AppGuion", 0), ("Guion", 1), ("V12", 1), ("V13", 1), ("Asistente MB", 0), ("Caserio", 0), ("cerebro-panel", 0), ("Daytrader", 0)]
        m.projects = names.enumerated().map { ProjectVM(id: "\($0.offset)", name: $0.element.0, level: $0.element.1, current: $0.offset == 5, root: $0.offset == 0) }
        m.canEditSelf = true; m.project = "V12"
    }
    if scenario == "apps" {
        m.showApps = true
        func ic(_ p: String) -> NSImage? { FileManager.default.fileExists(atPath: p) ? NSWorkspace.shared.icon(forFile: p) : nil }
        m.topApps = [AppMem(id: 0, name: "Google Chrome", bytes: 2_576_980_377, icon: ic("/Applications/Google Chrome.app")),
                     AppMem(id: 1, name: "Máquina virtual", bytes: 2_040_109_465),
                     AppMem(id: 2, name: "Gráficos del sistema", bytes: 536_870_912),
                     AppMem(id: 3, name: "Docker", bytes: 520_000_000, icon: ic("/Applications/Docker.app")),
                     AppMem(id: 4, name: "Node.js", bytes: 322_122_547)]
    }
    if scenario == "ask" { m.prompt = "Añade el filtro por fecha al listado" }
    if scenario == "party" { m.partyAt = now.addingTimeInterval(-0.45); m.partyName = "migracion-datos"; m.mood = "work" }
    if scenario == "done" { m.agents = [m.agents[2]]; m.mood = "done" }
    m.now = now
    m.today = WorkStats(tasks: 59, seconds: 2820, projects: 3)
    m.week = WorkStats(tasks: 184, seconds: 19620, projects: 7)
    m.perDay = [5, 11, 23, 20, 1, 65, 59]
    m.statsLoaded = true
    m.usageEnabled = scenario != "sinuso"
    if scenario == "uso" { m.usagePick = "s" }
    m.usage = [UsageVM(id: "s", label: "Sesión", left: 0.57, detail: "en 34 min", tip: scenario == "uso" ? "Te queda el 57 % de la sesión (5 h). Se reinicia el mié 25 a las 6:10" : "", timeLeft: 0.11),
               UsageVM(id: "w", label: "Semana", left: 0.81, detail: "en 5 d", tip: "", timeLeft: 0.71),
               UsageVM(id: "m", label: "Opus", left: scenario == "alert" ? 0.14 : 0.86, detail: "en 5 d", tip: "", timeLeft: 0.71,
                       runsOut: scenario == "alert" ? 9 * 3600 : nil)]
    m.cpu = 0.16; m.memFraction = 0.53; m.memText = "17.0 GB"; m.diskFraction = 0.14; m.diskText = "1.71 TB"
    m.batteryText = "68 % · batería"; m.batterySymbol = "battery.75percent"
    let scene = ZStack {
        LinearGradient(colors: [Color(red: 0.95, green: 0.62, blue: 0.38), Color(red: 0.36, green: 0.30, blue: 0.45), Color(red: 0.12, green: 0.14, blue: 0.22)],
                       startPoint: .top, endPoint: .bottom)
        WidgetUI(model: m).fixedSize().padding(36)
    }
    let outPath = CommandLine.arguments[i + 1]
    MainActor.assumeIsolated {
        let r = ImageRenderer(content: scene)
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: outPath))
        }
    }
    exit(0)
}

// `Chispa --render-tab salida.png` dibuja la pestañita en sus cuatro estados
if let i = CommandLine.arguments.firstIndex(of: "--render-tab"), i + 1 < CommandLine.arguments.count {
    // reposo · trabajando · te necesita · celebrando · después de terminar
    let now = Date()
    let cases: [(String, Int, Double?, Double)] = [("idle", 0, nil, 1.0), ("work", 2, nil, 0.9), ("att", 1, nil, 0.25), ("done", 0, 0.45, 0.4), ("done", 0, nil, 2.0)]
    let row = HStack(spacing: 14) {
        ForEach(Array(cases.enumerated()), id: \.offset) { _, c in
            let m: TabModel = { let m = TabModel(); m.mood = c.0; m.working = c.1; m.partyAt = c.2.map { now.addingTimeInterval(-$0) }; m.renderT = c.3; m.renderNow = now; return m }()
            TabMascot(m: m)
                .background(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 14, topTrailingRadius: 14, style: .continuous)
                    .fill(Color(white: 0.09)).overlay(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 14, topTrailingRadius: 14, style: .continuous).stroke(Color.white.opacity(0.14))))
        }
    }
    .padding(14)
    .background(Color(red: 0.42, green: 0.36, blue: 0.50))
    MainActor.assumeIsolated {
        let r = ImageRenderer(content: row)
        r.scale = 4
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        }
    }
    exit(0)
}

if CommandLine.arguments.contains("--login-off") { try? SMAppService.mainApp.unregister(); print("off"); exit(0) }
// `--login-item`: vuelve a apuntar el arranque al iniciar sesión a esta copia de la app (tras moverla o renombrarla)
if CommandLine.arguments.contains("--login-item") {
    try? SMAppService.mainApp.unregister()
    do { try SMAppService.mainApp.register(); print("ok") } catch { print("error: \(error.localizedDescription)") }
    exit(0)
}

// `Chispa --render-mascot salida.png` dibuja la mascota en todos sus estados
if let i = CommandLine.arguments.firstIndex(of: "--render-mascot"), i + 1 < CommandLine.arguments.count {
    let outPath = CommandLine.arguments[i + 1]
    MainActor.assumeIsolated {
        let now = Date()
        func brain(gaze: CGPoint = .zero, near: CGFloat = 0, poke: Double? = nil, anger: Int = 0) -> MascotBrain {
            let b = MascotBrain(); b.gaze = gaze; b.near = near; b.pokeAt = poke.map { now.addingTimeInterval(-$0) }
            if anger > 0 { b.level = anger; b.angryUntil = now.addingTimeInterval(3) }
            return b
        }
        let cells: [(String, Mascot)] = [
            ("dormida", Mascot(mood: "idle", t: 1.0, party: nil)),
            ("se despierta", Mascot(mood: "idle", t: 1.0, party: nil, brain: brain(gaze: CGPoint(x: 0.9, y: 0.5), near: 1), now: now)),
            ("trabaja", Mascot(mood: "work", t: 0.9, party: nil)),
            ("molesta", Mascot(mood: "done", t: 2.3, party: nil, brain: brain(gaze: CGPoint(x: 0.8, y: 0.3), anger: 1), now: now)),
            ("te necesita", Mascot(mood: "att", t: 0.25, party: nil)),
            ("terminado", Mascot(mood: "done", t: 2.0, party: nil, brain: brain(gaze: CGPoint(x: -1.1, y: -0.6)), now: now)),
            ("furiosa", Mascot(mood: "done", t: 5.72, party: nil, brain: brain(anger: 2), now: now)),
            ("celebra", Mascot(mood: "work", t: 0.4, party: 0.45)),
            ("tocada 1", Mascot(mood: "done", t: 1.0, party: nil, brain: brain(poke: 0.1), now: now)),
            ("tocada 2", Mascot(mood: "done", t: 1.0, party: nil, brain: brain(poke: 0.42), now: now))]
        let grid = VStack(spacing: 14) {
            ForEach(0..<2, id: \.self) { r in
                HStack(spacing: 14) {
                    ForEach(0..<5, id: \.self) { k in
                        VStack(spacing: 2) {
                            cells[r * 5 + k].1.scaleEffect(1.6).frame(width: 160, height: 156)
                            Text(cells[r * 5 + k].0).font(.system(size: 11, weight: .semibold)).foregroundColor(.white.opacity(0.6))
                        }
                    }
                }
            }
        }
        .padding(18).background(Color(red: 0.09, green: 0.09, blue: 0.10))
        let r = ImageRenderer(content: grid)
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: outPath)) }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
