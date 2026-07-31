import Foundation

/// Snapshot fingerprints pinned by the project. Adding a new entry means the
/// importer has been validated against a fresh upload of the source.
public enum SourceFingerprint {
    public static let knownFingerprints: [String: String] = [
        SupportedModelSource.repoID: SupportedModelSource.sourceIndexSHA256,
        "mlx-community/gemma-4-26b-a4b-it-4bit": "bf198c9f5ea6462addca1966e5dd669c407537a876e82cf06db9084c5c850b13",
    ]

    /// Returns the recognised model ID for a given index.json SHA-256, or nil.
    public static func modelID(forIndexSha256 sha256Hex: String) -> String? {
        for (id, sha) in knownFingerprints where sha == sha256Hex { return id }
        return nil
    }
}
