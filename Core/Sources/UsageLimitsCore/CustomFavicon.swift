import Foundation

/// 首页 `<link rel="…icon…">` 候选。
public struct FaviconCandidate: Equatable, Sendable {
    public var href: String
    public var type: String?
    public var sizes: String?
    public var rel: String

    public init(href: String, type: String? = nil, sizes: String? = nil, rel: String) {
        self.href = href
        self.type = type
        self.sizes = sizes
        self.rel = rel
    }
}

/// 从用量 URL 的 origin 首页解析 favicon，不打用户填的 usage 路径。
public enum CustomFaviconParser {
    public static let maxHTMLBytes = 512 * 1024
    public static let preferredSize = 64
    public static let preferredSizeRange = 32...128
    public static let homepageTimeout: TimeInterval = 8
    public static let maxLogoBytes = 256 * 1024

    /// `https://host/v1/usage` → `https://host/`
    public static func homepageURL(from usageURL: URL) -> URL? {
        guard usageURL.scheme?.lowercased() == "https",
              let host = usageURL.host, !host.isEmpty
        else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = usageURL.port
        components.path = "/"
        return components.url
    }

    public static func pickBestHref(html: String, baseURL: URL) -> URL? {
        pickBestHref(candidates: parseLinkIcons(html: html), baseURL: baseURL)
    }

    public static func pickBestHref(candidates: [FaviconCandidate], baseURL: URL) -> URL? {
        let icons = candidates.filter { $0.rel.lowercased().contains("icon") && !$0.href.isEmpty }
        guard !icons.isEmpty else { return nil }
        let bestKind = icons.map(kind).min() ?? .unknown
        let sameKind = icons.filter { kind($0) == bestKind }
        let chosen: FaviconCandidate
        if bestKind == .png {
            chosen = pickBySize(sameKind)
        } else {
            chosen = sameKind[0]
        }
        return resolve(href: chosen.href, base: baseURL)
    }

    public static func parseLinkIcons(html: String) -> [FaviconCandidate] {
        let clipped: String
        if html.utf8.count > maxHTMLBytes {
            clipped = String(html.prefix(maxHTMLBytes))
        } else {
            clipped = html
        }
        var result: [FaviconCandidate] = []
        let pattern = #"(?i)<link\b[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = clipped as NSString
        let matches = regex.matches(in: clipped, range: NSRange(location: 0, length: ns.length))
        for match in matches {
            let tag = ns.substring(with: match.range)
            let attrs = attributes(in: tag)
            let rel = attrs["rel"] ?? ""
            guard rel.lowercased().contains("icon") else { continue }
            guard let href = attrs["href"], !href.isEmpty else { continue }
            result.append(FaviconCandidate(
                href: href,
                type: attrs["type"],
                sizes: attrs["sizes"],
                rel: rel
            ))
        }
        return result
    }

    public static func resolve(href: String, base: URL) -> URL? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let absolute = URL(string: trimmed), absolute.scheme != nil {
            guard absolute.scheme?.lowercased() == "https" else { return nil }
            return absolute
        }
        return URL(string: trimmed, relativeTo: base)?.absoluteURL
    }

    public static func looksLikeImage(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= maxLogoBytes * 2 else { return false }
        if data.count >= 4 {
            let b = [UInt8](data.prefix(12))
            if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return true }
            if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return true }
            if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return true }
            if b[0] == 0x00, b[1] == 0x00, b[2] == 0x01, b[3] == 0x00 { return true }
            if b.count >= 12, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
               b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return true }
        }
        if let text = String(data: data.prefix(256), encoding: .utf8) {
            let head = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if head.hasPrefix("<svg") { return true }
            if head.hasPrefix("<?xml"), head.contains("<svg") { return true }
        }
        return false
    }

    public static func suggestedExtension(for data: Data) -> String {
        let b = [UInt8](data.prefix(12))
        if b.count >= 4, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "png" }
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "jpg" }
        if b.count >= 4, b[0] == 0x00, b[1] == 0x00, b[2] == 0x01, b[3] == 0x00 { return "ico" }
        if b.count >= 12, b[0] == 0x52, b[8] == 0x57 { return "webp" }
        if let text = String(data: data.prefix(64), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           text.contains("<svg") {
            return "svg"
        }
        return "png"
    }

    public static func representativeSize(_ sizes: String?) -> Int? {
        guard let sizes else { return nil }
        let lower = sizes.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.isEmpty || lower == "any" { return nil }
        let pairs = lower.split(whereSeparator: { $0.isWhitespace || $0 == "," })
        var edges: [Int] = []
        for pair in pairs {
            let parts = pair.split(separator: "x")
            guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]),
                  width > 0, height > 0
            else { continue }
            edges.append(max(width, height))
        }
        guard !edges.isEmpty else { return nil }
        return edges.min(by: { abs($0 - preferredSize) < abs($1 - preferredSize) })
    }

    private enum Kind: Int, Comparable {
        case svg = 0
        case png = 1
        case ico = 2
        case jpeg = 3
        case webp = 4
        case unknown = 5

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private static func kind(_ candidate: FaviconCandidate) -> Kind {
        let mime = candidate.type?.split(separator: ";").first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let ext = hrefExtension(candidate.href)
        if mime == "image/svg+xml" || ext == "svg" { return .svg }
        if mime == "image/png" || (mime == nil && ext == "png") { return .png }
        if mime == "image/x-icon" || mime == "image/vnd.microsoft.icon" || mime == "image/ico"
            || (mime == nil && ext == "ico") {
            return .ico
        }
        if mime == "image/jpeg" || mime == "image/jpg"
            || (mime == nil && (ext == "jpg" || ext == "jpeg")) {
            return .jpeg
        }
        if mime == "image/webp" || (mime == nil && ext == "webp") { return .webp }
        if mime == nil {
            if ext == "svg" { return .svg }
            if ext == "png" { return .png }
            if ext == "ico" { return .ico }
        }
        return .unknown
    }

    private static func hrefExtension(_ href: String) -> String {
        let path = href.split(separator: "?").first.map(String.init) ?? href
        guard let dot = path.lastIndex(of: "."), dot < path.endIndex else { return "" }
        return path[path.index(after: dot)...].lowercased()
            .split(separator: "#").first.map(String.init) ?? ""
    }

    private static func pickBySize(_ list: [FaviconCandidate]) -> FaviconCandidate {
        func size(_ candidate: FaviconCandidate) -> Int {
            representativeSize(candidate.sizes) ?? preferredSize
        }
        let inRange = list.filter { preferredSizeRange.contains(size($0)) }
        let pool = inRange.isEmpty ? list : inRange
        return pool.min(by: { abs(size($0) - preferredSize) < abs(size($1) - preferredSize) }) ?? list[0]
    }

    private static func attributes(in tag: String) -> [String: String] {
        var result: [String: String] = [:]
        let pattern = #"(?i)([a-z_:][\w:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let ns = tag as NSString
        for match in regex.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1)).lowercased()
            let value: String
            if match.range(at: 2).location != NSNotFound {
                value = ns.substring(with: match.range(at: 2))
            } else if match.range(at: 3).location != NSNotFound {
                value = ns.substring(with: match.range(at: 3))
            } else {
                value = ns.substring(with: match.range(at: 4))
            }
            result[name] = value
        }
        return result
    }
}
