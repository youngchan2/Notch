import Foundation
import Darwin

/// Discover aliases without running ssh -G, Match exec, ProxyCommand or reading keys.
enum SSHConfigHosts {
    struct Result {
        var hosts: [String]
        var unreadableFiles: Int
    }
    static func read(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Result {
        let base = home.appendingPathComponent(".ssh", isDirectory: true)
        var visited: Set<String> = [], aliases: Set<String> = []
        var failures = 0, totalBytes = 0
        func visit(_ url: URL, depth: Int) {
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            guard depth <= 16, visited.count < 128, totalBytes < 2_000_000,
                  visited.insert(canonical.path).inserted else { return }
            guard let values = try? canonical.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, let size = values.fileSize, size <= 262144,
                  let data = try? Data(contentsOf: canonical),
                  let text = String(data: data, encoding: .utf8) else { failures += 1; return }
            totalBytes += data.count
            for line in text.components(separatedBy: .newlines) {
                let fields = tokens(line)
                guard let keyword = fields.first?.lowercased() else { continue }
                if keyword == "host" {
                    for host in fields.dropFirst() where RemoteClaude.validHost(host) { aliases.insert(host) }
                } else if keyword == "include" {
                    for value in fields.dropFirst() {
                        var pattern: String
                        if value == "~" { pattern = home.path }
                        else if value.hasPrefix("~/") { pattern = home.appendingPathComponent(String(value.dropFirst(2))).path }
                        else if value.hasPrefix("/") { pattern = value }
                        else { pattern = base.appendingPathComponent(value).path }
                        // Expand ordinary environment references, never commands or shell syntax.
                        if let regex = try? NSRegularExpression(pattern: #"\$\{([A-Za-z_][A-Za-z0-9_]*)\}"#) {
                            for match in regex.matches(in: pattern, range: NSRange(pattern.startIndex..., in: pattern)).reversed() {
                                guard let range = Range(match.range, in: pattern), let keyRange = Range(match.range(at: 1), in: pattern) else { continue }
                                let key = String(pattern[keyRange])
                                pattern.replaceSubrange(range, with: ProcessInfo.processInfo.environment[key] ?? "")
                            }
                        }
                        var matches = glob_t()
                        let status = pattern.withCString { Darwin.glob($0, 0, nil, &matches) }
                        defer { globfree(&matches) }
                        guard status == 0, let paths = matches.gl_pathv else { continue }
                        for index in 0..<min(Int(matches.gl_pathc), 128) {
                            if let path = paths[index] { visit(URL(fileURLWithPath: String(cString: path)), depth: depth + 1) }
                        }
                    }
                }
            }
        }
        let config = base.appendingPathComponent("config")
        if FileManager.default.fileExists(atPath: config.path) { visit(config, depth: 0) }
        return Result(hosts: aliases.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, unreadableFiles: failures)
    }
    static func tokens(_ line: String) -> [String] {
        var result: [String] = [], token = "", quoted = false, escaped = false
        func flush() { if !token.isEmpty { result.append(token); token = "" } }
        for character in line {
            if escaped { token.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "\"" { quoted.toggle(); continue }
            if !quoted && character == "#" { break }
            if !quoted && (character.isWhitespace || character == "=") { flush() }
            else { token.append(character) }
        }
        if quoted || escaped { return [] }
        flush(); return result
    }
}
