import PDFKit

public enum SampleDocument {
    /// Packaged builds place `starter.pdf` in the app's Resources directory.
    /// Tests inject the canonical source fixture to exercise this production path.
    public static var resourceURL: URL?

    public static func make() throws -> Workspace {
        let url = resourceURL ?? Bundle.main.resourceURL?.appendingPathComponent("starter.pdf")
        guard let url, FileManager.default.isReadableFile(atPath: url.path) else {
            throw PaperworkError.invalid("The sample document is missing from this installation.")
        }
        guard let document = PDFDocument(url: url) else {
            throw PaperworkError.invalid("The sample document could not be read.")
        }
        return Workspace(document: document)
    }
}
