struct CallToneRelease: Decodable {
    let tag_name: String
    let draft: Bool
    let prerelease: Bool

    func updateVersion(after installedVersion: String) -> String? {
        let tag = tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name
        guard !draft, !prerelease, let latest = Self.components(tag),
              let installed = Self.components(installedVersion),
              installed.lexicographicallyPrecedes(latest) else { return nil }
        return tag
    }

    private static func components(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        var numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        numbers += Array(repeating: 0, count: 3 - parts.count)
        return numbers
    }
}
