import Foundation
import PDFKit
import Darwin

/// The bundled, pinned parser normalises PDFKit output and restores canonical button fields.
public enum CanonicalPDF {
    public static var helperURL: URL?
    public static func normalise(_ bytes: Data, template: Data? = nil, edits: [String: String] = [:], flatten: Bool = false) throws -> Data {
        guard let helperURL, FileManager.default.isExecutableFile(atPath: helperURL.path) else { throw PaperworkError.invalid("The PDF writer is missing. Rebuild the complete app using the setup guide.") }
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("paperwork-writer-" + UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: folder) }
        let input = folder.appendingPathComponent("input.pdf"), output = folder.appendingPathComponent("output.pdf"), request = folder.appendingPathComponent("request.json")
        try Workspace.writeNew(bytes, to: input)
        var settings: [String: Any] = ["version": 1, "edits": edits, "flatten": flatten]
        if let template { let url = folder.appendingPathComponent("original.pdf"); try Workspace.writeNew(template, to: url); settings["original"] = url.path }
        try Workspace.writeNew(JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]), to: request)
        let child = Process(); child.executableURL = helperURL; child.arguments = [input.path, output.path, request.path]
        child.standardInput = FileHandle.nullDevice; child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        child.terminationHandler = { _ in finished.signal() }
        try child.run()
        if finished.wait(timeout: .now() + 30) == .timedOut {
            if child.isRunning { child.terminate() }
            if finished.wait(timeout: .now() + 2) == .timedOut, child.isRunning { kill(child.processIdentifier, SIGKILL); _ = finished.wait(timeout: .now() + 2) }
            throw PaperworkError.invalid("The PDF writer took too long. Extract a smaller section and try again.")
        }
        guard child.terminationStatus == 0, let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= Workspace.maxBytes else { throw PaperworkError.invalid("This PDF could not be saved safely. Keep your working copy and try a simpler document.") }
        let result = try Data(contentsOf: output)
        guard let parsed = PDFDocument(data: result), !parsed.isLocked else { throw PaperworkError.invalid("The PDF writer output could not be reopened. Keep your working copy.") }
        return result
    }
}
