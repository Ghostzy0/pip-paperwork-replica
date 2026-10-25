import Foundation

/// Original standalone product identity and isolated recovery-data namespace.
struct ReplicaIdentity {
    let displayName = "Paperwork Replica"
    let releaseVersion = "0.1.0-alpha.1"

    static func dataDirectory() -> String { "PaperworkReplica" }
}
