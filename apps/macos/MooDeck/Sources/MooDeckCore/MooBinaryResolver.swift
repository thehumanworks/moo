import Foundation

public enum MooBinaryResolver {
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL? = Bundle.main.bundleURL,
        fileManager: FileManager = .default
    ) -> URL? {
        if let explicit = nonEmpty(environment["MOO_BIN"]) {
            return URL(fileURLWithPath: explicit)
        }

        var candidates: [URL] = []

        if let root = nonEmpty(environment["MOO_APP_REPO_ROOT"]) {
            candidates.append(URL(fileURLWithPath: root).appendingPathComponent("zig-out/bin/moo"))
        }

        if let bundleURL {
            candidates.append(contentsOf: bundleDerivedCandidates(bundleURL: bundleURL))
        }

        if let pwd = nonEmpty(environment["PWD"]) {
            candidates.append(URL(fileURLWithPath: pwd).appendingPathComponent("zig-out/bin/moo"))
        }

        if let home = nonEmpty(environment["HOME"]) {
            candidates.append(URL(fileURLWithPath: home).appendingPathComponent(".local/bin/moo"))
        }

        if let pathHit = pathCandidate(environment["PATH"], fileManager: fileManager) {
            candidates.append(pathHit)
        }

        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private static func bundleDerivedCandidates(bundleURL: URL) -> [URL] {
        var urls: [URL] = []
        let bundleParent = bundleURL.deletingLastPathComponent()

        // dist/MooDeck.app -> repo root -> zig-out/bin/moo
        urls.append(bundleParent.deletingLastPathComponent().appendingPathComponent("zig-out/bin/moo"))

        // SwiftPM debug executable path -> repo root, when launched without bundling.
        let pathComponents = bundleURL.pathComponents
        if let buildIndex = pathComponents.lastIndex(of: ".build"), buildIndex > 0 {
            let repoRoot = URL(fileURLWithPath: pathComponents[0..<buildIndex].joined(separator: "/"))
            urls.append(repoRoot.appendingPathComponent("../../../zig-out/bin/moo").standardizedFileURL)
        }

        return urls
    }

    private static func pathCandidate(_ path: String?, fileManager: FileManager) -> URL? {
        guard let path = nonEmpty(path) else { return nil }

        for rawDirectory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(rawDirectory)).appendingPathComponent("moo")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
