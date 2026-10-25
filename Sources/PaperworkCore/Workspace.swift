import AppKit
import PDFKit
import CryptoKit

public enum PaperworkError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

public enum AnnotationKind: String, CaseIterable { case highlight, underline, strikeOut, text, ink }

public final class Workspace {
    public private(set) var document: PDFDocument
    public private(set) var sourceURL: URL?
    public private(set) var sourceDigest: String?
    public private(set) var dirty = false
    public private(set) var revision = 0
    public private(set) var encryptedInput = false
    public private(set) var signedInput = false
    private var editedButtonNames = Set<String>()
    private var mutationBefore: Data?
    private var formTemplate: Data?
    private var undoStack: [Data] = []
    private var redoStack: [Data] = []
    private let snapshotBudget = 96 * 1024 * 1024
    public static let maxBytes = 180 * 1024 * 1024
    public static let maxPages = 2000

    public init(document: PDFDocument = PDFDocument()) {
        self.document = document
        encryptedInput = document.isEncrypted
        signedInput = Self.containsSignature(document, data: nil)
    }
    static func containsSignature(_ pdf: PDFDocument, data: Data?) -> Bool {
        if let data, data.range(of: Data("/ByteRange".utf8)) != nil { return true }
        return (0..<pdf.pageCount).contains { i in pdf.page(at: i)?.annotations.contains { $0.widgetFieldType == .signature } ?? false }
    }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var editable: Bool { !document.isLocked && !encryptedInput && !signedInput && document.pageCount > 0 && document.allowsDocumentChanges && document.allowsCommenting && document.allowsDocumentAssembly && document.allowsFormFieldEntry }
    public var readOnlyReason: String? {
        if document.isLocked { return "This PDF is locked. Unlock it to read it." }
        if encryptedInput { return "Encrypted PDFs are read-only here. The password is never stored." }
        if signedInput { return "Signed PDFs are read-only here to preserve their signatures." }
        if !editable && document.pageCount > 0 { return "This PDF restricts changes. You can read it here." }
        return nil
    }
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func load(_ url: URL, password: String? = nil) throws -> Workspace {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= maxBytes else { throw PaperworkError.invalid("Choose a PDF smaller than 180 MB.") }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let pdf = PDFDocument(data: data) else { throw PaperworkError.invalid("This file could not be read as a PDF. Try a different copy.") }
        let encrypted = pdf.isEncrypted
        if pdf.isLocked, let password { _ = pdf.unlock(withPassword: password) }
        guard pdf.isLocked || (pdf.pageCount > 0 && pdf.pageCount <= maxPages) else { throw PaperworkError.invalid("Choose a PDF with 1 to 2,000 pages.") }
        let workspace = Workspace(document: pdf)
        workspace.sourceURL = url.resolvingSymlinksInPath().standardizedFileURL
        workspace.sourceDigest = digest(data)
        workspace.encryptedInput = encrypted
        // Conservative detection: never rewrite a PDF whose byte-level signature markers are present.
        workspace.signedInput = containsSignature(pdf, data: data)
        return workspace
    }
    func markRecovered() { dirty = true }
    public func unlock(_ password: String) throws {
        guard document.unlock(withPassword: password), document.pageCount > 0, document.pageCount <= Self.maxPages else { throw PaperworkError.invalid("That password did not unlock a supported PDF. Try again.") }
    }
    public func data() throws -> Data {
        guard let bytes = document.dataRepresentation(), !bytes.isEmpty else { throw PaperworkError.invalid("The PDF could not be prepared. Keep your working copy and try again.") }
        return try canonical(bytes, document: document)
    }
    private func canonical(_ bytes: Data, document pdf: PDFDocument, flatten: Bool = false, template: Data? = nil) throws -> Data {
        var edits: [String: String] = [:]
        if formTemplate != nil && !flatten {
            for index in 0..<pdf.pageCount { for annotation in pdf.page(at: index)?.annotations ?? [] where annotation.type == "Widget" && annotation.widgetFieldType == .button && editedButtonNames.contains(annotation.fieldName ?? "") {
                guard let name = annotation.fieldName, !name.isEmpty else { throw PaperworkError.invalid("This form has an unnamed button field. Use a simpler PDF form.") }
                if edits[name] == nil { edits[name] = "Off" }
                if annotation.buttonWidgetState == .onState { edits[name] = annotation.buttonWidgetStateString }
            } }
        }
        return try CanonicalPDF.normalise(bytes, template: template ?? formTemplate, edits: edits, flatten: flatten)
    }
    public func page(_ index: Int) throws -> PDFPage {
        guard index >= 0, index < document.pageCount, let p = document.page(at: index) else { throw PaperworkError.invalid("Choose a page in this PDF.") }; return p
    }
    public func change(_ body: () throws -> Void) throws {
        guard editable else { throw PaperworkError.invalid(readOnlyReason ?? "Open an editable PDF first.") }
        guard mutationBefore == nil else { throw PaperworkError.invalid("Finish the current document change first.") }
        let before = try data()
        mutationBefore = before
        defer { mutationBefore = nil }
        guard before.count <= snapshotBudget else { throw PaperworkError.invalid("This working copy is too large for safe undo. Extract a smaller section first.") }
        do { try body() } catch { document = PDFDocument(data: before)!; throw error }
        undoStack.append(before)
        while undoStack.reduce(0, { $0 + $1.count }) > snapshotBudget { undoStack.removeFirst() }
        if undoStack.count > 20 { undoStack.removeFirst() }
        redoStack.removeAll(); dirty = true; revision += 1
    }
    public func undo() throws {
        guard let previous = undoStack.last, let restored = PDFDocument(data: previous) else { return }
        redoStack.append(try data()); undoStack.removeLast(); document = restored; dirty = true; revision += 1
    }
    public func redo() throws {
        guard let next = redoStack.last, let restored = PDFDocument(data: next) else { return }
        undoStack.append(try data()); redoStack.removeLast(); document = restored; dirty = true; revision += 1
    }
    public func rotate(_ index: Int) throws { try change { let p = try page(index); p.rotation = (p.rotation + 90) % 360 } }
    public func move(_ index: Int, by offset: Int) throws {
        let target = index + offset
        guard target >= 0, target < document.pageCount else { throw PaperworkError.invalid("The page is already at that end of the PDF.") }
        try change { let p = try page(index); document.removePage(at: index); document.insert(p, at: target) }
    }
    public func delete(_ index: Int) throws {
        guard document.pageCount > 1 else { throw PaperworkError.invalid("Keep at least one page in the PDF.") }
        try change { _ = try page(index); document.removePage(at: index) }
    }
    public func insert(_ other: Workspace, after index: Int) throws {
        guard other.editable, document.pageCount + other.document.pageCount <= Self.maxPages else { throw PaperworkError.invalid("Insert an unrestricted PDF within the 2,000-page limit.") }
        let copies = try (0..<other.document.pageCount).map { i -> PDFPage in
            guard let p = other.document.page(at: i)?.copy() as? PDFPage else { throw PaperworkError.invalid("An imported page could not be copied.") }; return p
        }
        try change { _ = try page(index); for (n, p) in copies.enumerated() { document.insert(p, at: index + 1 + n) } }
    }
    public func annotate(_ kind: AnnotationKind, page index: Int, bounds: NSRect, text: String = "", points: [NSPoint] = []) throws {
        try change {
            let p = try page(index)
            let area = bounds.intersection(p.bounds(for: .cropBox))
            guard !area.isEmpty else { throw PaperworkError.invalid("Select an area inside the page.") }
            let subtype: PDFAnnotationSubtype
            switch kind { case .highlight: subtype = .highlight; case .underline: subtype = .underline; case .strikeOut: subtype = .strikeOut; case .text: subtype = .text; case .ink: subtype = .ink }
            let a = PDFAnnotation(bounds: area, forType: subtype, withProperties: nil)
            a.contents = text; a.userName = "Paperwork"
            a.color = kind == .highlight ? NSColor.systemYellow.withAlphaComponent(0.45) : (kind == .text ? .systemOrange : .systemBlue)
            if kind == .ink {
                guard points.count >= 2 else { throw PaperworkError.invalid("Draw a line inside one page.") }
                let path = NSBezierPath(); path.move(to: NSPoint(x: points[0].x - area.minX, y: points[0].y - area.minY))
                for point in points.dropFirst() { path.line(to: NSPoint(x: point.x - area.minX, y: point.y - area.minY)) }
                a.add(path); let border = PDFBorder(); border.lineWidth = 2; a.border = border
            }
            p.addAnnotation(a)
        }
    }
    public func markSelection(_ selection: PDFSelection, kind: AnnotationKind) throws {
        guard [.highlight, .underline, .strikeOut].contains(kind) else { return }
        let lines = selection.selectionsByLine()
        try change {
            guard !lines.isEmpty else { throw PaperworkError.invalid("Select some text first.") }
            for line in lines { for p in line.pages {
                let rect = line.bounds(for: p)
                guard !rect.isEmpty else { continue }
                let subtype: PDFAnnotationSubtype = kind == .highlight ? .highlight : (kind == .underline ? .underline : .strikeOut)
                guard let origin = p.document else { throw PaperworkError.invalid("The selected page is no longer available. Select the text again.") }
                let target = try page(origin.index(for: p))
                let a = PDFAnnotation(bounds: rect, forType: subtype, withProperties: nil)
                a.color = kind == .highlight ? NSColor.systemYellow.withAlphaComponent(0.45) : .systemBlue
                a.contents = line.string; target.addAnnotation(a)
            } }
        }
    }
    public func removeAnnotation(page index: Int, annotation indexInPage: Int) throws {
        try change { let p = try page(index); guard p.annotations.indices.contains(indexInPage), p.annotations[indexInPage].type != "Widget" else { throw PaperworkError.invalid("Choose an annotation, rather than a form field.") }; p.removeAnnotation(p.annotations[indexInPage]) }
    }
    public func fill(page index: Int, annotation annotationIndex: Int, value: String) throws {
        try change {
            let p = try page(index)
            guard p.annotations.indices.contains(annotationIndex) else { throw PaperworkError.invalid("That form field could not be found.") }
            let a = p.annotations[annotationIndex]
            guard a.type == "Widget", !a.isReadOnly else { throw PaperworkError.invalid("This form field is read-only.") }
            switch a.widgetFieldType {
            case .text:
                guard !a.isPasswordField else { throw PaperworkError.invalid("Password form fields are not stored here.") }
                guard a.maximumLength == 0 || value.count <= a.maximumLength else { throw PaperworkError.invalid("This value is longer than the form field allows.") }
                a.widgetStringValue = value
            case .button:
                guard a.widgetControlType == .checkBoxControl || a.widgetControlType == .radioButtonControl else { throw PaperworkError.invalid("Form action buttons are disabled.") }
                guard a.widgetControlType != .radioButtonControl || !a.radiosInUnison else { throw PaperworkError.invalid("Radio groups that select in unison are not supported here.") }
                if a.widgetControlType == .radioButtonControl, value == "Off", a.buttonWidgetState == .onState, !a.allowsToggleToOff { throw PaperworkError.invalid("This form requires a radio selection. Choose another option instead.") }
                let on = a.buttonWidgetStateString
                guard value == "Off" || value == on else { throw PaperworkError.invalid("Choose an available form state.") }
                guard let name = a.fieldName, !name.isEmpty else { throw PaperworkError.invalid("This form button has no field name. Use a simpler PDF form.") }
                formTemplate = mutationBefore
                editedButtonNames.insert(name)
                if a.widgetControlType == .radioButtonControl, value != "Off", let name = a.fieldName {
                    for pageIndex in 0..<document.pageCount { for peer in document.page(at: pageIndex)?.annotations ?? [] where peer.fieldName == name && peer.widgetFieldType == .button { peer.buttonWidgetState = .offState } }
                }
                a.buttonWidgetState = value == "Off" ? .offState : .onState
            case .choice:
                let choices = a.choices ?? []; let values = a.values ?? choices
                guard let choice = choices.firstIndex(of: value), values.indices.contains(choice) else { throw PaperworkError.invalid("Choose one of the form's listed values.") }
                a.widgetStringValue = values[choice]
            default: throw PaperworkError.invalid("This form field type is not supported here.")
            }
        }
    }
    public static func range(_ expression: String, count: Int) throws -> [Int] {
        guard count > 0 else { throw PaperworkError.invalid("Open a PDF first.") }
        var result: [Int] = []
        for part in expression.split(separator: ",", omittingEmptySubsequences: false) {
            let ends = part.trimmingCharacters(in: .whitespaces).split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(ends.count), let first = Int(ends[0]), first >= 1, first <= count else { throw PaperworkError.invalid("Use page numbers such as 1-3, 5.") }
            let last: Int
            if ends.count == 2 { guard let n = Int(ends[1]), n >= first, n <= count else { throw PaperworkError.invalid("The page range is outside this PDF.") }; last = n } else { last = first }
            for n in first...last { if !result.contains(n - 1) { result.append(n - 1) } }
        }
        return result
    }
    public func extract(_ indices: [Int]) throws -> PDFDocument {
        guard !document.isLocked, !encryptedInput, !signedInput, document.allowsCopying, !indices.isEmpty else { throw PaperworkError.invalid("Extraction needs an unrestricted, unsigned PDF and at least one page.") }
        let out = PDFDocument()
        for index in indices { guard let p = try page(index).copy() as? PDFPage else { throw PaperworkError.invalid("A page could not be copied.") }; out.insert(p, at: out.pageCount) }
        return out
    }
    // Create-only exports. Existing destinations are never replaced; expectedDigest is retained
    // for source compatibility but never grants overwrite authority.
    public func saveCopy(to destination: URL, document output: PDFDocument? = nil, expectedDigest: String? = nil, options: [PDFDocumentWriteOption: Any] = [:]) throws {
        guard !document.isLocked, !encryptedInput, !signedInput, document.allowsCopying else { throw PaperworkError.invalid("Saving needs an unrestricted, unsigned PDF.") }
        guard destination.pathExtension.lowercased() == "pdf" else { throw PaperworkError.invalid("Use a .pdf filename.") }
        let target = destination.standardizedFileURL.resolvingSymlinksInPath()
        if let source = sourceURL {
            guard target != source, !Self.sameFile(source, target) else { throw PaperworkError.invalid("Choose a new filename. Paperwork preserves the opened original.") }
        }
        // A first PDFKit page-copy serialization can omit AcroForm roots. Keep an
        // explicit full-document template so the parser can reconstruct only retained widgets.
        let fallbackTemplate = output != nil && options[.burnInAnnotationsOption] as? Bool != true ? try data() : nil
        let pdf = output ?? document
        guard let bytes = pdf.dataRepresentation(options: options), let check = PDFDocument(data: bytes), check.pageCount == pdf.pageCount, !check.isLocked else { throw PaperworkError.invalid("The saved copy could not be verified. Keep the working copy and try again.") }
        let normalised = try canonical(bytes, document: check, flatten: options[.burnInAnnotationsOption] as? Bool == true, template: fallbackTemplate)
        guard let verified = PDFDocument(data: normalised), verified.pageCount == pdf.pageCount else { throw PaperworkError.invalid("The final page count could not be verified. Keep the working copy.") }
        try Self.writeNew(normalised, to: target)
        if output == nil && options.isEmpty { dirty = false }
    }
    public static func writeNew(_ bytes: Data, to target: URL) throws {
        let fm = FileManager.default
        let temp = target.deletingLastPathComponent().appendingPathComponent(".paperwork-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temp) }
        let descriptor = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw PaperworkError.invalid("A private temporary file could not be created. Check folder permissions.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do { try handle.write(contentsOf: bytes); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        // A hard link creates a new directory entry atomically and refuses any existing path.
        guard link(temp.path, target.path) == 0 else { throw PaperworkError.invalid("The destination exists, changed or is not writable. Choose a new filename.") }
    }
    static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let a = try? FileManager.default.attributesOfItem(atPath: lhs.path), let b = try? FileManager.default.attributesOfItem(atPath: rhs.path) else { return false }
        return (a[.systemFileNumber] as? NSNumber) == (b[.systemFileNumber] as? NSNumber) && (a[.systemNumber] as? NSNumber) == (b[.systemNumber] as? NSNumber)
    }
}
