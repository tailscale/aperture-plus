import CryptoKit
import Foundation

public struct ApplianceArtifacts: Sendable, Equatable {
    public struct Manifest: Decodable, Sendable, Equatable {
        public let schemaVersion: Int
        public let architecture: String
        public let operatingSystem: String
        public let thundersnapRevision: String
        public let artifacts: [String: Artifact]
    }

    public struct Artifact: Decodable, Sendable, Equatable {
        public let sha256: String
        public let size: UInt64
    }

    public let kernel: URL
    public let initramfs: URL
    public let manifest: Manifest

    public static func locate(in roots: [URL]) throws -> ApplianceArtifacts {
        for root in roots {
            let kernel = root.appending(path: "Image")
            let initramfs = root.appending(path: "initramfs.cpio")
            let manifestURL = root.appending(path: "manifest.json")
            guard FileManager.default.fileExists(atPath: kernel.path),
                  FileManager.default.fileExists(atPath: initramfs.path),
                  let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
                  manifest.schemaVersion == 1,
                  manifest.architecture == "arm64",
                  manifest.operatingSystem == "linux" else { continue }
            try verify(kernel, named: "Image", manifest: manifest)
            try verify(initramfs, named: "initramfs.cpio", manifest: manifest)
            return ApplianceArtifacts(kernel: kernel, initramfs: initramfs, manifest: manifest)
        }
        throw ApplianceError.notFound(roots)
    }

    public static func defaultRoots(bundle: Bundle = .main,
                                    environment: [String: String] = ProcessInfo.processInfo.environment,
                                    currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) -> [URL] {
        var roots: [URL] = []
        if let path = environment["APERTURE_THUNDERBOOT_ARTIFACTS"] {
            roots.append(URL(fileURLWithPath: path))
        }
        if let manifest = bundle.url(forResource: "manifest", withExtension: "json") {
            roots.append(manifest.deletingLastPathComponent())
        }
        roots.append(currentDirectory.appending(path: "build/Thunderboot", directoryHint: .isDirectory))
        roots.append(currentDirectory.appending(path: "../thundersnap/thunderboot-out", directoryHint: .isDirectory))
        return roots
    }

    private static func verify(_ url: URL, named name: String, manifest: Manifest) throws {
        guard let expected = manifest.artifacts[name] else {
            throw ApplianceError.missingManifestEntry(name)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.uint64Value == expected.size else {
            throw ApplianceError.sizeMismatch(name)
        }
        let digest = SHA256.hash(data: try Data(contentsOf: url))
            .map { String(format: "%02x", $0) }.joined()
        guard digest == expected.sha256 else { throw ApplianceError.hashMismatch(name) }
    }
}

public enum ApplianceError: LocalizedError, Equatable {
    case notFound([URL])
    case missingManifestEntry(String)
    case sizeMismatch(String)
    case hashMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .notFound: return "No verified ARM64 Thunderboot appliance was found."
        case .missingManifestEntry(let name): return "Manifest is missing \(name)."
        case .sizeMismatch(let name): return "Artifact size mismatch for \(name)."
        case .hashMismatch(let name): return "Artifact SHA-256 mismatch for \(name)."
        }
    }
}
