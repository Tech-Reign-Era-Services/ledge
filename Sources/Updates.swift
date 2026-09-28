import Foundation

// Updates from the app itself: the newest release on GitHub, and whether it's newer than this one. What GitHub says
// is checked here before anything is downloaded; Updater.swift fetches it, checks the download and opens the
// installer. Foundation only (tested in tests/).

struct Release: Equatable {
    var version: String // "1.3.1"
    var pkg: URL // the installer, on github.com
    var sha256: String // its digest, as GitHub gives it: the download must match
    var size: Int
    var page: URL // the release's page, for its notes
}

enum Updates {
    static let repo = "Tech-Reign-Era-Services/ledge"
    static let latestURL = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    static let maxSize = 20_000_000 // Ledge is under 1 MB: anything much bigger isn't Ledge
    static let checkEvery = 24 * 60 * 60.0 // automatic checks: once a day at most

    /// GitHub's answer for the latest release, if it's a proper one: a vX.Y.Z tag, and a Ledge-X.Y.Z.pkg in this
    /// repository's own downloads, with a SHA-256 digest to check it against.
    static func parse(_ data: Data) -> Release? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              o["draft"] as? Bool != true, o["prerelease"] as? Bool != true,
              let tag = o["tag_name"] as? String, tag.hasPrefix("v"), case let version = String(tag.dropFirst()), numbers(version) != nil,
              let assets = o["assets"] as? [[String: Any]],
              let asset = assets.first(where: { $0["name"] as? String == "Ledge-\(version).pkg" }),
              let link = asset["browser_download_url"] as? String, let pkg = URL(string: link),
              pkg.scheme == "https", pkg.host == "github.com", pkg.path.hasPrefix("/\(repo)/releases/download/"),
              let size = asset["size"] as? Int, size > 0, size <= maxSize,
              let digest = asset["digest"] as? String, digest.hasPrefix("sha256:") else { return nil }
        let sha = String(digest.dropFirst(7)).lowercased()
        guard sha.count == 64, sha.allSatisfy(\.isHexDigit) else { return nil }
        let page = (o["html_url"] as? String).flatMap(URL.init(string:)).flatMap { $0.host == "github.com" ? $0 : nil }
            ?? URL(string: "https://github.com/\(repo)/releases/tag/\(tag)")!
        return Release(version: version, pkg: pkg, sha256: sha, size: size, page: page)
    }

    /// Is `a` a later version than `b`? "1.10.0" is later than "1.9.2". Anything that isn't a version never is.
    static func isNewer(_ a: String, than b: String) -> Bool {
        guard var x = numbers(a), var y = numbers(b) else { return false }
        while x.count < y.count { x.append(0) }
        while y.count < x.count { y.append(0) }
        for (p, q) in zip(x, y) where p != q { return p > q }
        return false
    }

    /// Time for an automatic check? At most once a day.
    static func due(lastCheck: Double, now: Double) -> Bool { now - lastCheck >= checkEvery || now < lastCheck }

    private static func numbers(_ v: String) -> [Int]? {
        let parts = v.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        let n = parts.compactMap { $0.count <= 6 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) ? Int($0) : nil }
        return n.count == parts.count ? n : nil
    }
}
