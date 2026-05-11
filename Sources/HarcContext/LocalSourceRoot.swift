import CryptoKit
import Darwin
import Foundation

public enum LocalSourceRootKind: String, Sendable, Codable, Equatable, CaseIterable {
    case folder
    case repository
}

public struct LocalSourceRoot: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var path: String
    public var displayName: String
    public var kind: LocalSourceRootKind
    public var readOnly: Bool
    public var includeGlobs: [String]
    public var excludeGlobs: [String]
    public var lastScannedAt: Date?

    public init(
        id: String = UUID().uuidString,
        path: String,
        displayName: String? = nil,
        kind: LocalSourceRootKind? = nil,
        readOnly: Bool = true,
        includeGlobs: [String] = [],
        excludeGlobs: [String] = LocalSourceScanner.defaultExcludeGlobs,
        lastScannedAt: Date? = nil
    ) {
        self.id = id
        self.path = path
        let url = URL(fileURLWithPath: path, isDirectory: true)
        self.displayName = displayName ?? url.lastPathComponent
        self.kind = kind ?? (FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) ? .repository : .folder)
        self.readOnly = readOnly
        self.includeGlobs = includeGlobs
        self.excludeGlobs = excludeGlobs
        self.lastScannedAt = lastScannedAt
    }
}

public enum LocalSourceDocumentKind: String, Sendable, Codable, Equatable {
    case markdown
    case plainText
    case sourceCode
    case json
    case yaml
    case transcriptSidecar
}

public struct SourceProvenance: Sendable, Codable, Equatable {
    public var rootID: String
    public var rootPath: String
    public var relativePath: String
    public var absolutePath: String
    public var lineStart: Int?
    public var lineEnd: Int?
    public var contentHash: String
    public var documentKind: LocalSourceDocumentKind
    public var scannedAt: Date

    public var citationPath: String {
        if let lineStart {
            return "\(absolutePath):\(lineStart)"
        }
        return absolutePath
    }
}

public struct ScannedSourceDocument: Sendable, Codable, Equatable, Identifiable {
    public var id: String { "\(provenance.rootID):\(provenance.relativePath)" }
    public var title: String
    public var text: String
    public var provenance: SourceProvenance
}

public enum LocalSourceScannerError: Error, Equatable, Sendable {
    case rootMissing(String)
    case rootIsNotDirectory(String)
}

public enum LocalSourceScanner {
    public static let defaultExcludeGlobs = [
        ".git/**",
        "DerivedData/**",
        ".build/**",
        "build/**",
        "node_modules/**",
        ".next/**",
        "dist/**",
        "*.xcworkspace/**",
        "*.xcodeproj/**",
    ]

    private static let supportedExtensions: [String: LocalSourceDocumentKind] = [
        "md": .markdown,
        "markdown": .markdown,
        "txt": .plainText,
        "swift": .sourceCode,
        "m": .sourceCode,
        "mm": .sourceCode,
        "h": .sourceCode,
        "js": .sourceCode,
        "jsx": .sourceCode,
        "ts": .sourceCode,
        "tsx": .sourceCode,
        "py": .sourceCode,
        "rb": .sourceCode,
        "go": .sourceCode,
        "rs": .sourceCode,
        "java": .sourceCode,
        "kt": .sourceCode,
        "c": .sourceCode,
        "cc": .sourceCode,
        "cpp": .sourceCode,
        "json": .json,
        "jsonl": .transcriptSidecar,
        "yaml": .yaml,
        "yml": .yaml,
    ]

    public static func scan(root: LocalSourceRoot, scannedAt: Date = Date()) throws -> [ScannedSourceDocument] {
        let rootURL = URL(fileURLWithPath: root.path, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
            throw LocalSourceScannerError.rootMissing(rootURL.path)
        }
        guard isDirectory.boolValue else {
            throw LocalSourceScannerError.rootIsNotDirectory(rootURL.path)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var documents: [ScannedSourceDocument] = []
        for case let url as URL in enumerator {
            let standardized = url.standardizedFileURL
            let relativePath = Self.relativePath(for: standardized, rootURL: rootURL)

            if shouldSkipDirectory(relativePath: relativePath, root: root, url: standardized) {
                enumerator.skipDescendants()
                continue
            }

            guard try standardized.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                  let kind = supportedExtensions[standardized.pathExtension.lowercased()],
                  isIncluded(relativePath: relativePath, root: root)
            else {
                continue
            }

            guard let text = try? String(contentsOf: standardized, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                continue
            }

            documents.append(ScannedSourceDocument(
                title: standardized.deletingPathExtension().lastPathComponent,
                text: text,
                provenance: SourceProvenance(
                    rootID: root.id,
                    rootPath: rootURL.path,
                    relativePath: relativePath,
                    absolutePath: standardized.path,
                    lineStart: 1,
                    lineEnd: text.split(separator: "\n", omittingEmptySubsequences: false).count,
                    contentHash: sha256(text),
                    documentKind: kind,
                    scannedAt: scannedAt
                )
            ))
        }

        return documents.sorted { $0.provenance.relativePath < $1.provenance.relativePath }
    }

    private static func shouldSkipDirectory(relativePath: String, root: LocalSourceRoot, url: URL) -> Bool {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return false
        }
        return root.excludeGlobs.contains { matches(glob: $0, path: relativePath + "/") || matches(glob: $0, path: relativePath) }
    }

    private static func isIncluded(relativePath: String, root: LocalSourceRoot) -> Bool {
        let excluded = root.excludeGlobs.contains { matches(glob: $0, path: relativePath) }
        guard !excluded else { return false }
        guard !root.includeGlobs.isEmpty else { return true }
        return root.includeGlobs.contains { matches(glob: $0, path: relativePath) }
    }

    private static func matches(glob: String, path: String) -> Bool {
        fnmatch(glob, path, FNM_PATHNAME) == 0 || fnmatch(glob, URL(fileURLWithPath: path).lastPathComponent, 0) == 0
    }

    private static func relativePath(for url: URL, rootURL: URL) -> String {
        let path = url.path
        let root = rootURL.path
        guard path.hasPrefix(root + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(root.count + 1))
    }

    private static func sha256(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
