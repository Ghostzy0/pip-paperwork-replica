import AppKit
import PDFKit
import Vision
import CoreText

public enum LocalOCR {
    private static let defaultRecognitionLanguages = ["en-GB"]

    /// Returns the languages supported by the same accurate request used for OCR.
    public static func supportedRecognitionLanguages() throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        do { return try request.supportedRecognitionLanguages() }
        catch { throw PaperworkError.invalid("macOS could not list supported OCR languages. Check Vision support on this Mac and try again.") }
    }

    /// Keeps the historical Core request independent of Vision's advertised language list.
    /// The list is queried lazily because some runtimes accept legacy codes for recognition
    /// while omitting them from `supportedRecognitionLanguages()`.
    static func resolveRecognitionLanguages(_ selection: [String]?, supportedLanguages: () throws -> [String]) throws -> [String] {
        guard let selection else { return defaultRecognitionLanguages }
        return try validateRecognitionLanguages(selection, supportedBy: supportedLanguages())
    }

    /// Validates an ordered selection against the request's runtime language list.
    public static func validateRecognitionLanguages(_ languages: [String], supportedBy supportedLanguages: [String]) throws -> [String] {
        guard !languages.isEmpty else { throw PaperworkError.invalid("Choose at least one supported OCR language.") }
        guard languages.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw PaperworkError.invalid("OCR language codes cannot be empty.")
        }
        let keys = languages.map { $0.lowercased() }
        guard Set(keys).count == keys.count else { throw PaperworkError.invalid("Choose each OCR language once.") }
        let supported = Set(supportedLanguages)
        guard languages.allSatisfy(supported.contains) else { throw PaperworkError.invalid("One or more selected OCR languages are not supported by this Mac.") }

        let chinese = languages.filter { $0.lowercased() == "zh" || $0.lowercased().hasPrefix("zh-") }
        if !chinese.isEmpty {
            let englishOnly = languages.dropFirst().allSatisfy {
                let code = $0.lowercased()
                return code == "en" || code.hasPrefix("en-")
            }
            guard chinese.count == 1, languages.first == chinese[0], languages.count <= 2, englishOnly else {
                throw PaperworkError.invalid("Put one Chinese language first. Chinese can be used alone or with English only.")
            }
        }
        return languages
    }

    /// Rasterises each page. Output is deliberately a separate flattened, searchable PDF.
    public static func searchableCopy(data: Data, cancelled: () -> Bool = { false }, progress: (Int, Int) -> Void = { _, _ in }, recognitionLanguages: [String]? = nil) throws -> PDFDocument {
        // Preserve Core's historical en-GB request exactly. On some Vision runtimes this
        // language still works for recognition but is omitted from supportedRecognitionLanguages().
        // Explicit Plus selections are always checked against the runtime list; there is no fallback.
        let languages = try resolveRecognitionLanguages(recognitionLanguages, supportedLanguages: supportedRecognitionLanguages)
        guard let source = PDFDocument(data: data), source.pageCount > 0, source.pageCount <= 100, !source.isLocked, !source.isEncrypted, source.allowsCopying, !Workspace.containsSignature(source, data: data) else { throw PaperworkError.invalid("OCR supports 1 to 100 unrestricted, unsigned pages at a time. Extract a smaller section first.") }
        guard data.count <= Workspace.maxBytes else { throw PaperworkError.invalid("Extract a smaller section before OCR.") }
        var totalPixels: Double = 0
        for index in 0..<source.pageCount {
            guard let page = source.page(at: index) else { throw PaperworkError.invalid("A page could not be read.") }
            let bounds = page.bounds(for: .mediaBox)
            let pixels = bounds.width * bounds.height * 4
            guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0, bounds.width <= 2400, bounds.height <= 2400, pixels <= 12_000_000 else { throw PaperworkError.invalid("This page is too large for safe OCR. Extract a smaller page first.") }
            totalPixels += pixels
        }
        guard totalPixels <= 160_000_000 else { throw PaperworkError.invalid("This document is too large for one OCR task. Extract a smaller section first.") }
        let buffer = NSMutableData()
        guard let consumer = CGDataConsumer(data: buffer), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw PaperworkError.invalid("A searchable copy could not be started.") }
        for i in 0..<source.pageCount {
            if cancelled() { throw PaperworkError.invalid("OCR stopped. The working copy was kept.") }
            try autoreleasepool { () throws -> Void in
            guard let page = source.page(at: i) else { throw PaperworkError.invalid("A page could not be read.") }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width > 0, bounds.height > 0, bounds.width <= 2400, bounds.height <= 2400 else { throw PaperworkError.invalid("This page is too large for safe OCR.") }
            // PDFPage.thumbnail accounts for rotation. Output normalises rotation into its media size.
            let rotated = page.rotation % 180 != 0
            let size = CGSize(width: rotated ? bounds.height : bounds.width, height: rotated ? bounds.width : bounds.height)
            let image = page.thumbnail(of: NSSize(width: size.width * 2, height: size.height * 2), for: .mediaBox)
            var rect = CGRect(origin: .zero, size: image.size)
            guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { throw PaperworkError.invalid("This page could not be rendered for OCR.") }
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages = languages
            let usesChinese = languages.contains { $0.lowercased() == "zh" || $0.lowercased().hasPrefix("zh-") }
            request.usesLanguageCorrection = !usesChinese
            try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
            if cancelled() { throw PaperworkError.invalid("OCR stopped. The working copy was kept.") }
            context.beginPDFPage([kCGPDFContextMediaBox as String: NSData(bytes: [CGRect(origin: .zero, size: size)], length: MemoryLayout<CGRect>.size)] as CFDictionary)
            context.draw(cg, in: CGRect(origin: .zero, size: size))
            for observation in request.results ?? [] {
                guard let candidate = observation.topCandidates(1).first, !candidate.string.isEmpty else { continue }
                let box = observation.boundingBox
                let font = CTFontCreateWithName("Helvetica" as CFString, max(5, box.height * size.height), nil)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: candidate.string, attributes: [.font: font]))
                let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                context.saveGState(); context.setTextDrawingMode(.invisible)
                context.translateBy(x: box.minX * size.width, y: box.minY * size.height)
                if width > 0 { context.scaleBy(x: box.width * size.width / width, y: 1) }
                context.textPosition = .zero; CTLineDraw(line, context); context.restoreGState()
            }
            context.endPDFPage()
            }
            guard buffer.length <= 128 * 1024 * 1024 else { throw PaperworkError.invalid("The OCR output is too large. Extract a smaller section and try again.") }
            progress(i + 1, source.pageCount)
        }
        context.closePDF()
        guard buffer.length <= 128 * 1024 * 1024 else { throw PaperworkError.invalid("The OCR output is too large. Extract a smaller section and try again.") }
        guard let out = PDFDocument(data: buffer as Data), out.pageCount == source.pageCount else { throw PaperworkError.invalid("The searchable copy could not be verified.") }; return out
    }
}

public final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    public init() {}
    public func cancel() { lock.lock(); value = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
