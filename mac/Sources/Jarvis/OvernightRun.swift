import Foundation

/// The index sends the first five fields. Opening a run adds its report and manifest.
struct OvernightRun: Decodable, Identifiable {
    let id: String
    let title: String
    let status: String
    let createdAt: String
    let updatedAt: String
    var request: String?
    var markdown: String?
    var error: String?
    var sources: [Source]?
    var files: [File]?
    var fromJobList = false

    enum CodingKeys: String, CodingKey {
        case id, title, status, createdAt, updatedAt, request, markdown, error, sources, files
    }

    struct Source: Decodable, Hashable {
        let label: String
        let url: String
    }

    struct File: Decodable, Hashable, Identifiable {
        let id: String
        let label: String
        let path: String
        var name: String { (path as NSString).lastPathComponent }
        var isMarkdown: Bool { ["md", "markdown"].contains((name as NSString).pathExtension.lowercased()) }
    }

    var name: String { title.isEmpty ? (request?.prefix(90)).map(String.init) ?? id : title }
    var statusLabel: String {
        switch status {
        case "done": return "Completed"
        case "error": return "Failed"
        case "needs-input": return "Needs input"
        default: return status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func legacy(_ job: JarvisJob) -> Self {
        var seen = Set<URL>()
        let text = job.result ?? ""
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        let links: [Source] = (detector?.matches(in: text, range: range) ?? []).compactMap { match in
            guard let url = match.url, Self.webLink(url.absoluteString) != nil,
                  seen.insert(url).inserted else { return nil }
            return Source(label: url.absoluteString, url: url.absoluteString)
        }
        return Self(id: job.id, title: job.title, status: job.state.rawValue,
                    createdAt: job.createdAt, updatedAt: job.updatedAt,
                    request: job.text, markdown: job.result, error: job.error,
                    sources: links, files: [], fromJobList: true)
    }

    static func webLink(_ href: String) -> URL? {
        guard let url = URL(string: href), let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 200 && id.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }

    /// Resolve a reference within this run's declared files, never against a Mac path.
    func linkedFile(_ href: String, from current: File?) -> File? {
        guard let parts = URLComponents(string: href), parts.scheme == nil, parts.host == nil,
              !parts.path.isEmpty, !parts.path.hasPrefix("/"), !parts.path.contains("\\") else { return nil }
        var path = current?.path.split(separator: "/").dropLast().map(String.init) ?? []
        for part in parts.path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..":
                guard !path.isEmpty else { return nil }
                path.removeLast()
            default: path.append(String(part))
            }
        }
        return files?.first { $0.path == path.joined(separator: "/") }
    }
}

struct OvernightRunPage: Decodable {
    var runs: [OvernightRun]
    var nextCursor: String?
    var legacy = false

    enum CodingKeys: String, CodingKey { case runs, nextCursor }
}
