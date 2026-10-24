import Foundation
import PDFKit

public enum Recovery {
    public static func store(_ workspace: Workspace, at url: URL) throws {
        guard workspace.editable else { throw PaperworkError.invalid("Recovery is available for editable PDFs only.") }
        if let source = workspace.sourceURL {
            let target = url.resolvingSymlinksInPath().standardizedFileURL
            guard target != source, !Workspace.sameFile(source, target) else {
                throw PaperworkError.invalid("Recovery must use a separate app-owned file. The original was preserved.")
            }
        }
        let bytes = try workspace.data()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try bytes.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public static func restore(at url: URL) throws -> Workspace {
        let ws = try Workspace.load(url)
        guard ws.editable else { throw PaperworkError.invalid("This recovery file is not editable. Open a separate PDF instead.") }
        let restored = Workspace(document: ws.document)
        restored.markRecovered()
        return restored
    }
    public static func discard(at url: URL) throws { if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } }
}
