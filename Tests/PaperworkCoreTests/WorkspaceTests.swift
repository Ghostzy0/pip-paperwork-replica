import XCTest
import AppKit
import PDFKit
@testable import PaperworkCore

final class WorkspaceTests: XCTestCase {
    var directory: URL!
    let fm = FileManager.default
    var fixtures: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures") }

    override func setUpWithError() throws {
        let appRoot = fixtures.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helperPath = ProcessInfo.processInfo.environment["PAPERWORK_ENGINE"] ?? appRoot.appendingPathComponent("Engine/build/canonical-pdf").path
        CanonicalPDF.helperURL = URL(fileURLWithPath: helperPath)
        SampleDocument.resourceURL = appRoot.appendingPathComponent("Sources/PaperworkCore/Resources/starter.pdf")
        guard fm.isExecutableFile(atPath: helperPath) else { throw PaperworkError.invalid("Build the canonical PDF helper first, or set PAPERWORK_ENGINE to its executable.") }
        directory = fm.temporaryDirectory.appendingPathComponent("paperwork-r1-\(UUID().uuidString)")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        SampleDocument.resourceURL = nil
        if let directory { try fm.removeItem(at: directory) }
    }
    func input(_ name: String = "three-pages.pdf") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try fm.copyItem(at: fixtures.appendingPathComponent(name), to: url)
        return url
    }
    func workspace(_ name: String = "three-pages.pdf") throws -> Workspace { try Workspace.load(input(name)) }
    func labels(_ document: PDFDocument) -> [String] {
        (0..<document.pageCount).map { document.page(at: $0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    }
    func output(_ url: URL, name: String) throws {
        if let path = ProcessInfo.processInfo.environment["PAPERWORK_AUDIT_OUTPUT"] {
            let destination = URL(fileURLWithPath: path)
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            let target = destination.appendingPathComponent(name)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: url, to: target)
        }
    }

    func assertCanonicalButtonNames(at url: URL, expected: [String: String], file: StaticString = #filePath, line: UInt = #line) throws {
        let provider = try XCTUnwrap(CGDataProvider(url: url as CFURL), file: file, line: line)
        let pdf = try XCTUnwrap(CGPDFDocument(provider), file: file, line: line)
        let catalog = try XCTUnwrap(pdf.catalog, file: file, line: line)
        var form: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(catalog, "AcroForm", &form), file: file, line: line)
        let fieldTree = try XCTUnwrap(form, file: file, line: line)
        var fields: CGPDFArrayRef?
        XCTAssertTrue(CGPDFDictionaryGetArray(fieldTree, "Fields", &fields), file: file, line: line)
        let array = try XCTUnwrap(fields, file: file, line: line)
        var seen: Set<String> = []
        for index in 0..<CGPDFArrayGetCount(array) {
            var field: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(array, index, &field), let field else { continue }
            var rawName: CGPDFStringRef?
            guard CGPDFDictionaryGetString(field, "T", &rawName), let rawName,
                  let bytes = CGPDFStringGetBytePtr(rawName),
                  let name = String(bytes: UnsafeBufferPointer(start: bytes, count: CGPDFStringGetLength(rawName)), encoding: .utf8),
                  let expectedValue = expected[name] else { continue }
            seen.insert(name)
            var value: UnsafePointer<CChar>?
            XCTAssertTrue(CGPDFDictionaryGetName(field, "V", &value), "Canonical \(name) /V must be a PDF Name, not a string", file: file, line: line)
            if let value { XCTAssertEqual(String(cString: value), expectedValue, file: file, line: line) }
        }
        XCTAssertEqual(seen, Set(expected.keys), file: file, line: line)
        withExtendedLifetime(pdf) {}
    }
    func testMissingCanonicalWriterFailsWithoutChangingSourceOrHistory() throws {
        let ws = try workspace(), original = try Data(contentsOf: ws.sourceURL!)
        let configured = CanonicalPDF.helperURL
        CanonicalPDF.helperURL = nil
        defer { CanonicalPDF.helperURL = configured }
        XCTAssertThrowsError(try ws.rotate(0))
        XCTAssertThrowsError(try ws.saveCopy(to: directory.appendingPathComponent("unsafe.pdf")))
        XCTAssertEqual(try Data(contentsOf: ws.sourceURL!), original)
        XCTAssertEqual(try ws.page(0).rotation, 0)
        XCTAssertFalse(ws.dirty); XCTAssertFalse(ws.canUndo)
        XCTAssertFalse(fm.fileExists(atPath: directory.appendingPathComponent("unsafe.pdf").path))
    }
    func testActualStarterSampleWorkflowAndWriterDiagnostics() throws {
        // Capture from a separate fresh instance. Serializing the workflow instance for
        // diagnostics can change PDFKit's internal field tree and mask first-use defects.
        let diagnostic = try SampleDocument.make()
        let raw = directory.appendingPathComponent("starter-raw-first.pdf")
        try XCTUnwrap(diagnostic.document.dataRepresentation()).write(to: raw)
        try output(raw, name: "starter-raw-first.pdf")
        let request = directory.appendingPathComponent("starter-request.json")
        try Data("{\"version\":1,\"edits\":{},\"flatten\":false}".utf8).write(to: request)
        let helperOutput = directory.appendingPathComponent("starter-helper.pdf")
        let errorPipe = Pipe(), child = Process()
        child.executableURL = CanonicalPDF.helperURL
        child.arguments = [raw.path, helperOutput.path, request.path]
        child.standardInput = FileHandle.nullDevice; child.standardOutput = FileHandle.nullDevice; child.standardError = errorPipe
        try child.run()
        let diagnostics = errorPipe.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        let stderr = String(data: diagnostics, encoding: .utf8) ?? "non-UTF8 stderr"
        print("Actual starter canonical writer exit \(child.terminationStatus): \(stderr)")
        if let path = ProcessInfo.processInfo.environment["PAPERWORK_AUDIT_OUTPUT"] {
            try diagnostics.write(to: URL(fileURLWithPath: path).appendingPathComponent("starter-helper-stderr.txt"))
        }
        XCTAssertEqual(child.terminationStatus, 0, "Starter raw PDF must be supported by the packaged writer: \(stderr)")

        let ws = try SampleDocument.make()
        func stage(_ name: String, _ body: () throws -> Void) throws {
            do { try body() } catch { throw PaperworkError.invalid("Actual starter stage \(name): \(error.localizedDescription)") }
        }
        XCTAssertEqual(ws.document.pageCount, 3)
        let selection = try XCTUnwrap(ws.document.findString("Select this sentence", withOptions: []).first)
        try stage("highlight") { try ws.markSelection(selection, kind: .highlight) }
        let field = try XCTUnwrap(try ws.page(0).annotations.firstIndex(where: { $0.fieldName == "Project contact" }))
        try stage("fill") { try ws.fill(page: 0, annotation: field, value: "Morgan Sample 84") }
        try stage("rotate") { try ws.rotate(0) }
        let saved = directory.appendingPathComponent("starter-edited.pdf")
        try stage("save") { try ws.saveCopy(to: saved) }
        let reopened = try Workspace.load(saved)
        XCTAssertEqual(reopened.document.pageCount, 3)
        XCTAssertEqual(try reopened.page(0).rotation, 90)
        XCTAssertEqual(try reopened.page(0).annotations.first(where: { $0.fieldName == "Project contact" })?.widgetStringValue, "Morgan Sample 84")
        XCTAssertTrue(try reopened.page(0).annotations.contains(where: { $0.type == "Highlight" }))
        XCTAssertFalse(reopened.document.findString("Select this sentence", withOptions: []).isEmpty)
        try output(saved, name: "starter-edited.pdf")
    }
    func testLoadAndSaveCopyPreserveOriginalAndPermissions() throws {
        let source = try input(), bytes = try Data(contentsOf: source), ws = try Workspace.load(source)
        try ws.rotate(0)
        let destination = directory.appendingPathComponent("new.pdf")
        try ws.saveCopy(to: destination)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(ws.sourceDigest, Workspace.digest(bytes))
        XCTAssertFalse(ws.dirty)
        let reopened = try Workspace.load(destination)
        XCTAssertEqual(reopened.document.pageCount, 3)
        XCTAssertEqual(try reopened.page(0).rotation, 90)
        XCTAssertEqual((try fm.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testAnnotationKindsPersistAndRemoveIsUndoable() throws {
        let ws = try workspace()
        for (i, kind) in AnnotationKind.allCases.enumerated() {
            let y = CGFloat(250 + i * 25)
            try ws.annotate(kind, page: 0, bounds: NSRect(x: 40, y: y, width: 250, height: 20), text: "synthetic \(kind.rawValue)", points: [NSPoint(x: 45, y: y + 4), NSPoint(x: 210, y: y + 12)])
        }
        let url = directory.appendingPathComponent("annotations.pdf")
        try ws.saveCopy(to: url)
        let reopened = try Workspace.load(url), annotations = try reopened.page(0).annotations
        let logicalAnnotations = annotations.filter { $0.type != "Popup" }
        let textAnnotation = try XCTUnwrap(logicalAnnotations.first(where: { $0.type == "Text" }))
        let popups = annotations.filter { $0.type == "Popup" }
        XCTAssertEqual(logicalAnnotations.count, 5)
        XCTAssertLessThanOrEqual(popups.count, 1, "A text annotation may have one ancillary popup")
        if let popup = textAnnotation.popup {
            XCTAssertEqual(popup.type, "Popup")
            XCTAssertEqual(popups.count, 1)
            XCTAssertTrue(popups.contains(where: { $0 === popup }), "The ancillary popup must belong to the Text annotation")
        } else {
            XCTAssertTrue(popups.isEmpty, "A popup cannot appear without its parent Text annotation")
        }
        XCTAssertEqual(Set(logicalAnnotations.compactMap(\.type)), Set(["Highlight", "Underline", "StrikeOut", "Text", "Ink"]))
        XCTAssertEqual(Set(logicalAnnotations.compactMap(\.contents)), Set(AnnotationKind.allCases.map { "synthetic \($0.rawValue)" }))
        XCTAssertEqual(logicalAnnotations.first(where: { $0.type == "Ink" })?.paths?.count, 1)
        let removableIndex = try XCTUnwrap(annotations.firstIndex(where: { $0.type != "Popup" }))
        try reopened.removeAnnotation(page: 0, annotation: removableIndex)
        XCTAssertEqual(try reopened.page(0).annotations.filter { $0.type != "Popup" }.count, 4)
        try reopened.undo()
        XCTAssertEqual(try reopened.page(0).annotations.filter { $0.type != "Popup" }.count, 5)
        try output(url, name: "annotations.pdf")
    }
    func testMissingStarterResourceFailsClearly() throws {
        let configured = SampleDocument.resourceURL
        SampleDocument.resourceURL = directory.appendingPathComponent("missing-starter.pdf")
        defer { SampleDocument.resourceURL = configured }
        XCTAssertThrowsError(try SampleDocument.make()) { error in
            XCTAssertTrue(error.localizedDescription.contains("sample document is missing"))
        }
    }
    func testSelectedTextMarkupsPersist() throws {
        let ws = try workspace()
        for kind in [AnnotationKind.highlight, .underline, .strikeOut] {
            let selection = try XCTUnwrap(ws.document.findString("FIRST", withOptions: []).first)
            try ws.markSelection(selection, kind: kind)
        }
        let reopened = try XCTUnwrap(PDFDocument(data: ws.data()))
        let annotations = try XCTUnwrap(reopened.page(at: 0)).annotations
        XCTAssertEqual(Set(annotations.compactMap(\.type)), Set(["Highlight", "Underline", "StrikeOut"]))
        XCTAssertTrue(annotations.allSatisfy { $0.contents?.contains("FIRST") == true })
    }
    func testUndoHistoryIsBoundedAndInvalidSaveDoesNotDiscardEdits() throws {
        let ws = try workspace()
        for _ in 0..<21 { try ws.rotate(0) }
        var undos = 0
        while ws.canUndo { try ws.undo(); undos += 1 }
        XCTAssertEqual(undos, 20)
        XCTAssertEqual(try ws.page(0).rotation, 90)
        XCTAssertThrowsError(try ws.saveCopy(to: directory.appendingPathComponent("wrong.txt")))
        XCTAssertThrowsError(try ws.saveCopy(to: directory.appendingPathComponent("missing/copy.pdf")))
        XCTAssertTrue(ws.dirty)
        XCTAssertThrowsError(try ws.extract([]))
    }
    func testCanonicalTextFormPersistenceAndUndo() throws {
        let ws = try workspace("form.pdf")
        let annotation = try XCTUnwrap(try ws.page(0).annotations.firstIndex(where: { $0.fieldName == "customer" }))
        XCTAssertEqual(try ws.page(0).annotations[annotation].widgetStringValue, "Before")
        try ws.fill(page: 0, annotation: annotation, value: "Morgan Synthetic 42")
        try ws.undo()
        XCTAssertEqual(try ws.page(0).annotations[annotation].widgetStringValue, "Before")
        try ws.redo()
        let url = directory.appendingPathComponent("form-filled.pdf")
        try ws.saveCopy(to: url)
        let reopened = try Workspace.load(url)
        XCTAssertEqual(try reopened.page(0).annotations.first(where: { $0.fieldName == "customer" })?.widgetStringValue, "Morgan Synthetic 42")
        try output(url, name: "form-filled.pdf")
    }
    func testCheckboxRadioAndExportChoicePersistCanonically() throws {
        let ws = try workspace("controls.pdf")
        let unchanged = directory.appendingPathComponent("controls-unmodified.pdf")
        try ws.saveCopy(to: unchanged)
        try output(unchanged, name: "controls-unmodified.pdf")
        func field(_ name: String) throws -> Int { try XCTUnwrap(try ws.page(0).annotations.firstIndex(where: { $0.fieldName == name })) }
        let consent = try field("consent")
        let on = try XCTUnwrap(try ws.page(0).annotations[consent].buttonWidgetStateString)
        try ws.fill(page: 0, annotation: consent, value: on)
        let radios = try ws.page(0).annotations.enumerated().filter { $0.element.fieldName == "delivery" }
        XCTAssertEqual(radios.count, 2)
        let express = try XCTUnwrap(radios.first(where: { $0.element.buttonWidgetStateString == "express" }))
        try ws.fill(page: 0, annotation: express.offset, value: "express")
        XCTAssertEqual(try ws.page(0).annotations.filter { $0.fieldName == "delivery" && $0.buttonWidgetState == .onState }.count, 1)
        try ws.fill(page: 0, annotation: field("region"), value: "France")
        let url = directory.appendingPathComponent("controls-filled.pdf")
        try ws.saveCopy(to: url)
        let reopened = try Workspace.load(url), annotations = try reopened.page(0).annotations
        XCTAssertEqual(annotations[consent].buttonWidgetState, .onState)
        XCTAssertEqual(annotations.filter { $0.fieldName == "delivery" && $0.buttonWidgetState == .onState }.count, 1)
        XCTAssertEqual(annotations.first(where: { $0.fieldName == "region" })?.widgetStringValue, "France")
        try output(url, name: "controls-filled.pdf")
        // This parser distinguishes PDF Names from visual/widget strings. PDFKit reopen alone
        // can mask stale /AS and invalid canonical /V, so require both representations.
        try assertCanonicalButtonNames(at: url, expected: ["consent": "Yes", "delivery": "express"])
        try ws.fill(page: 0, annotation: consent, value: "Off")
        XCTAssertEqual(try ws.page(0).annotations[consent].buttonWidgetState, .offState)
        try ws.undo(); XCTAssertEqual(try ws.page(0).annotations[consent].buttonWidgetState, .onState)
    }
    func testEditedFormsSurviveInsertMoveExtractionAndUndo() throws {
        let ws = try workspace("controls.pdf")
        func stage(_ name: String, _ body: () throws -> Void) throws {
            do { try body() } catch { throw PaperworkError.invalid("Form structural stage \(name): \(error.localizedDescription)") }
        }
        let consent = try XCTUnwrap(try ws.page(0).annotations.firstIndex(where: { $0.fieldName == "consent" }))
        try stage("fill") { try ws.fill(page: 0, annotation: consent, value: "Yes") }
        let textPages = try workspace()
        try stage("insert") { try ws.insert(textPages, after: 0) }
        try stage("move") { try ws.move(0, by: 3) }
        let full = directory.appendingPathComponent("moved-forms.pdf")
        try stage("full-save") { try ws.saveCopy(to: full) }
        XCTAssertEqual(try Workspace.load(full).document.pageCount, 4)
        try assertCanonicalButtonNames(at: full, expected: ["consent": "Yes", "delivery": "standard"])
        try output(full, name: "structural-moved-forms.pdf")
        let extract = try ws.extract([3])
        let extracted = directory.appendingPathComponent("extracted-forms.pdf")
        try stage("extract-save") { try ws.saveCopy(to: extracted, document: extract) }
        XCTAssertEqual(try Workspace.load(extracted).document.pageCount, 1)
        try assertCanonicalButtonNames(at: extracted, expected: ["consent": "Yes", "delivery": "standard"])
        try output(extracted, name: "structural-extracted-forms.pdf")
        try ws.undo()
        XCTAssertNotNil(try ws.page(0).annotations.first(where: { $0.fieldName == "consent" }))
        try ws.undo()
        XCTAssertEqual(ws.document.pageCount, 1)
        let undo = directory.appendingPathComponent("undo-forms.pdf")
        try stage("undo-save") { try ws.saveCopy(to: undo) }
        try assertCanonicalButtonNames(at: undo, expected: ["consent": "Yes", "delivery": "standard"])
        try output(undo, name: "structural-undo-forms.pdf")
        try ws.undo()
        let initial = directory.appendingPathComponent("initial-forms.pdf")
        try stage("initial-save") { try ws.saveCopy(to: initial) }
        try assertCanonicalButtonNames(at: initial, expected: ["consent": "Off", "delivery": "standard"])
        try output(initial, name: "structural-initial-forms.pdf")
    }
    func testFormConstraintsRejectInvalidValuesWithoutMutation() throws {
        let ws = try workspace("controls.pdf")
        func field(_ name: String) throws -> Int { try XCTUnwrap(try ws.page(0).annotations.firstIndex(where: { $0.fieldName == name })) }
        XCTAssertThrowsError(try ws.fill(page: 0, annotation: field("short"), value: "123456"))
        XCTAssertThrowsError(try ws.fill(page: 0, annotation: field("secret"), value: "should not persist"))
        XCTAssertThrowsError(try ws.fill(page: 0, annotation: field("fixed"), value: "changed"))
        XCTAssertThrowsError(try ws.fill(page: 0, annotation: field("consent"), value: "unavailable"))
        XCTAssertThrowsError(try ws.fill(page: 0, annotation: field("region"), value: "Atlantis"))
        let selectedRadio = try XCTUnwrap(try ws.page(0).annotations.firstIndex(where: { $0.fieldName == "delivery" && $0.buttonWidgetState == .onState }))
        XCTAssertThrowsError(try ws.fill(page: 0, annotation: selectedRadio, value: "Off"), "NoToggleToOff radio must keep its required selection")
        XCTAssertFalse(ws.dirty); XCTAssertFalse(ws.canUndo)
        XCTAssertEqual(try ws.page(0).annotations[try field("short")].widgetStringValue, "12345")
        XCTAssertEqual(try ws.page(0).annotations[try field("fixed")].widgetStringValue, "Immutable")
    }
    func testOptimisedAndFlattenedCopiesKeepWorkingEditsAndOriginal() throws {
        let ws = try workspace("form.pdf"), original = try Data(contentsOf: ws.sourceURL!)
        let field = try XCTUnwrap(try ws.page(0).annotations.firstIndex(where: { $0.fieldName == "customer" }))
        try ws.fill(page: 0, annotation: field, value: "Morgan Synthetic 42")
        try ws.annotate(.highlight, page: 0, bounds: NSRect(x: 35, y: 445, width: 300, height: 20))
        let optimized = directory.appendingPathComponent("form-optimized.pdf")
        try ws.saveCopy(to: optimized, options: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true])
        XCTAssertTrue(ws.dirty, "A separate optimised export must not mark the editable working copy as saved")
        XCTAssertEqual(try Workspace.load(optimized).page(0).annotations.first(where: { $0.fieldName == "customer" })?.widgetStringValue, "Morgan Synthetic 42")
        let flattened = directory.appendingPathComponent("form-flattened.pdf")
        try ws.saveCopy(to: flattened, options: [.burnInAnnotationsOption: true])
        XCTAssertTrue(ws.dirty)
        XCTAssertTrue(try Workspace.load(flattened).page(0).annotations.isEmpty, "Flattened output must not retain interactive annotations or fields")
        XCTAssertEqual(try Data(contentsOf: ws.sourceURL!), original)
        XCTAssertTrue(try ws.page(0).annotations.contains(where: { $0.type == "Widget" }), "Editable original working copy is kept")
        try output(optimized, name: "form-optimized.pdf")
        try output(flattened, name: "form-flattened.pdf")
    }
    func testStructuralEditsUndoRedoAndSourceIsolation() throws {
        let ws = try workspace(), original = labels(ws.document)
        try ws.move(0, by: 2)
        XCTAssertEqual(labels(ws.document), [original[1], original[2], original[0]])
        try ws.delete(1)
        XCTAssertEqual(labels(ws.document), [original[1], original[0]])
        try ws.undo(); XCTAssertEqual(labels(ws.document), [original[1], original[2], original[0]])
        try ws.undo(); XCTAssertEqual(labels(ws.document), original)
        try ws.redo(); XCTAssertEqual(labels(ws.document), [original[1], original[2], original[0]])
        try ws.rotate(0); XCTAssertFalse(ws.canRedo)
        XCTAssertEqual(try Workspace.load(ws.sourceURL!).document.pageCount, 3)
        XCTAssertEqual(labels(try Workspace.load(ws.sourceURL!).document), original)
    }
    func testInsertCopiesPagesAndExtractKeepsRequestedOrder() throws {
        let ws = try workspace(), other = Workspace(document: try XCTUnwrap(PDFDocument(data: try Data(contentsOf: fixtures.appendingPathComponent("three-pages.pdf")))))
        let expected = labels(ws.document)
        try ws.insert(other, after: 0)
        XCTAssertEqual(labels(ws.document), [expected[0]] + expected + [expected[1], expected[2]])
        try other.rotate(0)
        XCTAssertEqual(try ws.page(1).rotation, 0, "Inserted page must not share mutable identity with import")
        XCTAssertEqual(labels(try ws.extract([5, 0, 3])), [expected[2], expected[0], expected[2]])
    }
    func testFailureRollsBackDocumentAndUndoHistory() throws {
        enum Failure: Error { case deliberate }
        let ws = try workspace(), before = labels(ws.document)
        XCTAssertThrowsError(try ws.change { ws.document.removePage(at: 0); throw Failure.deliberate })
        XCTAssertEqual(labels(ws.document), before)
        XCTAssertFalse(ws.dirty); XCTAssertFalse(ws.canUndo); XCTAssertEqual(ws.revision, 0)
        try ws.rotate(0)
        XCTAssertThrowsError(try ws.change { ws.document.removePage(at: 0); throw Failure.deliberate })
        XCTAssertEqual(ws.revision, 1); XCTAssertTrue(ws.canUndo)
        try ws.undo(); XCTAssertEqual(try ws.page(0).rotation, 0)
    }
    func testInvalidPageAndAnnotationOperationsDoNotMutate() throws {
        let ws = try workspace(), before = labels(ws.document)
        for index in [-1, 3, Int.max] {
            XCTAssertThrowsError(try ws.rotate(index))
            XCTAssertThrowsError(try ws.delete(index))
            XCTAssertThrowsError(try ws.extract([index]))
        }
        XCTAssertThrowsError(try ws.annotate(.text, page: 0, bounds: NSRect(x: 1000, y: 1000, width: 10, height: 10)))
        XCTAssertThrowsError(try ws.annotate(.ink, page: 0, bounds: NSRect(x: 40, y: 40, width: 20, height: 20), points: []))
        XCTAssertThrowsError(try ws.fill(page: 0, annotation: 0, value: "invalid"))
        XCTAssertEqual(labels(ws.document), before); XCTAssertFalse(ws.canUndo); XCTAssertFalse(ws.dirty)
    }
    func testDeleteLastPageRejected() throws {
        let ws = try workspace(); try ws.delete(2); try ws.delete(1)
        XCTAssertThrowsError(try ws.delete(0)); XCTAssertEqual(ws.document.pageCount, 1)
    }
    func testRangeParserRejectsMalformedAndPreservesOrder() throws {
        XCTAssertEqual(try Workspace.range("3, 1-2, 2", count: 3), [2, 0, 1])
        for text in ["", ",", "1,", "0", "-1", "4", "2-1", "1-4", "1--2", "cat", "1.5", "1-2-3"] {
            XCTAssertThrowsError(try Workspace.range(text, count: 3), text)
        }
    }
    func testSourceAliasesAndHardlinksCannotBeSaveDestinations() throws {
        let source = try input(), before = try Data(contentsOf: source), ws = try Workspace.load(source)
        let symlink = directory.appendingPathComponent("symlink.pdf"), hardlink = directory.appendingPathComponent("hardlink.pdf")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: source)
        try fm.linkItem(at: source, to: hardlink)
        for url in [source, symlink, hardlink] {
            XCTAssertThrowsError(try ws.saveCopy(to: url, expectedDigest: Workspace.digest(before)))
        }
        XCTAssertEqual(try Data(contentsOf: source), before)
    }
    func testExistingDestinationIsAlwaysPreservedEvenWithMatchingDigest() throws {
        let ws = try workspace(); try ws.rotate(0)
        let destination = directory.appendingPathComponent("existing.pdf"), prior = Data("keep existing destination".utf8)
        try prior.write(to: destination)
        XCTAssertThrowsError(try ws.saveCopy(to: destination))
        XCTAssertThrowsError(try ws.saveCopy(to: destination, expectedDigest: Workspace.digest(Data("stale".utf8))))
        XCTAssertEqual(try Data(contentsOf: destination), prior); XCTAssertTrue(ws.dirty)
        XCTAssertThrowsError(try ws.saveCopy(to: destination, expectedDigest: Workspace.digest(prior)))
        XCTAssertEqual(try Data(contentsOf: destination), prior)
        XCTAssertTrue(ws.dirty)
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasPrefix(".paperwork-") })
    }
    func testSeparateExtractExportDoesNotClearUnsavedEdits() throws {
        let ws = try workspace(); try ws.rotate(0)
        try ws.saveCopy(to: directory.appendingPathComponent("extract.pdf"), document: ws.extract([1]))
        XCTAssertTrue(ws.dirty)
    }
    func testMalformedEmptyAndOversizedInputRejection() throws {
        for (name, bytes) in [("empty.pdf", Data()), ("garbage.pdf", Data("This is not a PDF".utf8))] {
            let url = directory.appendingPathComponent(name); try bytes.write(to: url)
            XCTAssertThrowsError(try Workspace.load(url))
        }
        let url = directory.appendingPathComponent("large.pdf")
        XCTAssertTrue(fm.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url); try handle.truncate(atOffset: UInt64(Workspace.maxBytes + 1)); try handle.close()
        XCTAssertThrowsError(try Workspace.load(url))
    }
    func testEncryptedInputRemainsReadOnlyAfterUnlock() throws {
        let ws = try workspace("encrypted.pdf")
        XCTAssertTrue(ws.document.isLocked); XCTAssertTrue(ws.encryptedInput); XCTAssertFalse(ws.editable)
        XCTAssertThrowsError(try ws.unlock("wrong password")); XCTAssertTrue(ws.document.isLocked)
        try ws.unlock("paperwork-test")
        XCTAssertFalse(ws.document.isLocked); XCTAssertEqual(ws.document.pageCount, 3); XCTAssertFalse(ws.editable)
        XCTAssertThrowsError(try ws.rotate(0)); XCTAssertThrowsError(try ws.extract([0]))
        XCTAssertThrowsError(try ws.saveCopy(to: directory.appendingPathComponent("unencrypted.pdf")))
        let target = try workspace()
        XCTAssertThrowsError(try target.insert(ws, after: 0)); XCTAssertEqual(target.document.pageCount, 3)
    }
    func testSignatureDetectionIsReadOnlyForMarkerAndField() throws {
        for name in ["signature-marker.pdf", "signature-field.pdf"] {
            let ws = try workspace(name)
            XCTAssertTrue(ws.signedInput, name); XCTAssertFalse(ws.editable)
            XCTAssertThrowsError(try ws.rotate(0))
            XCTAssertThrowsError(try ws.extract([0]))
            XCTAssertThrowsError(try ws.saveCopy(to: directory.appendingPathComponent("unsigned-\(name)")))
        }
    }
    func testRecoveryRoundTripPermissionsAndDiscard() throws {
        let ws = try workspace(); try ws.rotate(1)
        let url = directory.appendingPathComponent("private/recovery.pdf")
        try Recovery.store(ws, at: url)
        XCTAssertEqual((try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try fm.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let recovered = try Recovery.restore(at: url)
        XCTAssertEqual(try recovered.page(1).rotation, 90)
        XCTAssertTrue(recovered.dirty, "Restored-only work must trigger the unsaved close warning")
        XCTAssertNil(recovered.sourceURL, "Recovery is app-owned, not a protected original")
        XCTAssertThrowsError(try recovered.saveCopy(to: url))
        try recovered.rotate(0)
        try Recovery.store(recovered, at: url)
        XCTAssertEqual(try Recovery.restore(at: url).page(0).rotation, 90)
        try Recovery.discard(at: url); try Recovery.discard(at: url)
        XCTAssertFalse(fm.fileExists(atPath: url.path))
    }
    func testRecoveryCannotOverwriteOpenedOriginal() throws {
        let source = try input(), original = try Data(contentsOf: source), ws = try Workspace.load(source)
        try ws.rotate(0)
        let symlink = directory.appendingPathComponent("recovery-symlink.pdf")
        let hardlink = directory.appendingPathComponent("recovery-hardlink.pdf")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: source)
        try fm.linkItem(at: source, to: hardlink)
        for target in [source, symlink, hardlink] {
            XCTAssertThrowsError(try Recovery.store(ws, at: target), "Recovery must preserve original-input guarantee")
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
    func testOCRImmediateCancellationAndBoundsGuard() throws {
        let bytes = try Data(contentsOf: fixtures.appendingPathComponent("three-pages.pdf"))
        var progress = 0
        XCTAssertThrowsError(try LocalOCR.searchableCopy(data: bytes, cancelled: { true }, progress: { _, _ in progress += 1 }))
        XCTAssertEqual(progress, 0)
        XCTAssertThrowsError(try LocalOCR.searchableCopy(data: Data("invalid".utf8)))
    }
    func testOCRRecognitionLanguagesAreOrderedUniqueAndCompatible() throws {
        let supported = ["en-GB", "en-US", "fr-FR", "zh-Hans", "zh-Hant"]
        XCTAssertEqual(try LocalOCR.validateRecognitionLanguages(["fr-FR", "en-GB"], supportedBy: supported), ["fr-FR", "en-GB"])
        XCTAssertEqual(try LocalOCR.validateRecognitionLanguages(["zh-Hant", "en-GB"], supportedBy: supported), ["zh-Hant", "en-GB"])
        XCTAssertEqual(try LocalOCR.validateRecognitionLanguages(["zh-Hans"], supportedBy: supported), ["zh-Hans"])
        XCTAssertThrowsError(try LocalOCR.validateRecognitionLanguages([], supportedBy: supported), "At least one language is required")
        XCTAssertThrowsError(try LocalOCR.validateRecognitionLanguages(["  "], supportedBy: supported), "Blank language codes are invalid")
        XCTAssertThrowsError(try LocalOCR.validateRecognitionLanguages(["en-GB", "en-GB"], supportedBy: supported), "Selections must be unique")
        XCTAssertThrowsError(try LocalOCR.validateRecognitionLanguages(["de-DE"], supportedBy: supported), "Unsupported languages are rejected")
        XCTAssertThrowsError(try LocalOCR.validateRecognitionLanguages(["en-GB", "zh-Hant"], supportedBy: supported), "Chinese must be first")
        XCTAssertThrowsError(try LocalOCR.validateRecognitionLanguages(["zh-Hant", "fr-FR"], supportedBy: supported), "Chinese may only be paired with English")
        XCTAssertThrowsError(try LocalOCR.validateRecognitionLanguages(["zh-Hant", "zh-Hans"], supportedBy: supported), "Two Chinese variants are incompatible")
    }
    func testOCRCoreDefaultDoesNotDependOnVisionAdvertisedLanguages() throws {
        var queriedVision = false
        let coreLanguages = try LocalOCR.resolveRecognitionLanguages(nil) {
            queriedVision = true
            return ["en-US", "fr-FR"] // This Vision runtime omits legacy en-GB.
        }
        XCTAssertEqual(coreLanguages, ["en-GB"])
        XCTAssertFalse(queriedVision, "Core must preserve its accepted historical request without listing languages")

        XCTAssertThrowsError(try LocalOCR.resolveRecognitionLanguages(["en-GB"], supportedLanguages: {
            queriedVision = true
            return ["en-US", "fr-FR"]
        }), "Explicit Plus selections must still be validated against this runtime")
        XCTAssertTrue(queriedVision)
    }
    func testOCRRejectsUnsupportedLanguageBeforeParsingOrReportingProgress() throws {
        let unavailable = "paperwork-unavailable-\(UUID().uuidString)"
        var progress = 0
        XCTAssertThrowsError(try LocalOCR.searchableCopy(data: Data("invalid PDF".utf8), progress: { _, _ in progress += 1 }, recognitionLanguages: [unavailable])) { error in
            XCTAssertTrue(error.localizedDescription.contains("not supported"), error.localizedDescription)
        }
        XCTAssertEqual(progress, 0)
    }
    func testOCRCancellationAfterFirstPageReturnsNoPartialDocument() throws {
        let bytes = try Data(contentsOf: fixtures.appendingPathComponent("three-pages.pdf"))
        let flag = CancellationFlag()
        var completed: [Int] = []
        var output: PDFDocument?
        XCTAssertThrowsError(try output = LocalOCR.searchableCopy(data: bytes, cancelled: { flag.isCancelled }, progress: { current, total in
            XCTAssertEqual(total, 3); completed.append(current); flag.cancel()
        }))
        XCTAssertNil(output, "Cancellation must not return a partial searchable copy")
        XCTAssertEqual(completed, [1])
    }
    func testOCRRejectsOversizedPageWithoutCallingProgress() throws {
        let pdf = PDFDocument(), page = PDFPage()
        page.setBounds(NSRect(x: 0, y: 0, width: 2500, height: 500), for: .mediaBox)
        pdf.insert(page, at: 0)
        var calls = 0
        XCTAssertThrowsError(try LocalOCR.searchableCopy(data: XCTUnwrap(pdf.dataRepresentation()), progress: { _, _ in calls += 1 }))
        XCTAssertEqual(calls, 0)
    }
    func testOCRRejectsProtectedInputsBeforeProcessing() throws {
        for name in ["encrypted.pdf", "signature-field.pdf", "signature-marker.pdf"] {
            let bytes = try Data(contentsOf: fixtures.appendingPathComponent(name))
            var progress = 0
            XCTAssertThrowsError(try LocalOCR.searchableCopy(data: bytes, progress: { _, _ in progress += 1 }), name)
            XCTAssertEqual(progress, 0)
        }
    }
    func testOCRRejectsPerPageAndAggregatePixelBudgetsBeforeProcessing() throws {
        for (count, size) in [(1, CGFloat(1800)), (14, CGFloat(1700))] {
            let pdf = PDFDocument()
            for index in 0..<count {
                let page = PDFPage(); page.setBounds(NSRect(x: 0, y: 0, width: size, height: size), for: .mediaBox)
                pdf.insert(page, at: index)
            }
            var progress = 0
            XCTAssertThrowsError(try LocalOCR.searchableCopy(data: XCTUnwrap(pdf.dataRepresentation()), progress: { _, _ in progress += 1 }))
            XCTAssertEqual(progress, 0)
        }
    }
    func testSearchableOCRContainsRecognisedTextAndPreservesBounds() throws {
        let image = NSImage(size: NSSize(width: 800, height: 1000))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 800, height: 1000).fill()
        NSAttributedString(string: "PAPERWORK SYNTHETIC 731", attributes: [.font: NSFont.systemFont(ofSize: 38), .foregroundColor: NSColor.black]).draw(at: NSPoint(x: 50, y: 800))
        image.unlockFocus()
        let scan = PDFDocument(); scan.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        let before = try XCTUnwrap(scan.dataRepresentation())
        XCTAssertTrue(scan.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        var progress: [Int] = []
        let recognised = try LocalOCR.searchableCopy(data: before, progress: { current, total in XCTAssertEqual(total, 1); progress.append(current) })
        XCTAssertEqual(progress, [1]); XCTAssertEqual(recognised.pageCount, 1)
        XCTAssertTrue((recognised.string ?? "").contains("SYNTHETIC"), recognised.string ?? "no recognised text")
        XCTAssertEqual(recognised.page(at: 0)?.bounds(for: .mediaBox).size, scan.page(at: 0)?.bounds(for: .mediaBox).size)
        let url = directory.appendingPathComponent("ocr-searchable.pdf")
        try XCTUnwrap(recognised.dataRepresentation()).write(to: url)
        XCTAssertTrue((PDFDocument(url: url)?.string ?? "").contains("SYNTHETIC"))
        try output(url, name: "ocr-searchable.pdf")
    }
    func testSearchableFrenchOCRContainsRecognisedTextWhenSupported() throws {
        let supported = try LocalOCR.supportedRecognitionLanguages()
        guard supported.contains("fr-FR") else { throw XCTSkip("French OCR is not supported by this macOS Vision request.") }

        let image = NSImage(size: NSSize(width: 800, height: 1000))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 800, height: 1000).fill()
        NSAttributedString(string: "BONJOUR FRANCAIS 731", attributes: [.font: NSFont.systemFont(ofSize: 38), .foregroundColor: NSColor.black]).draw(at: NSPoint(x: 50, y: 800))
        image.unlockFocus()
        let scan = PDFDocument(); scan.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        let recognised = try LocalOCR.searchableCopy(data: XCTUnwrap(scan.dataRepresentation()), recognitionLanguages: ["fr-FR"])
        XCTAssertTrue((recognised.string ?? "").contains("BONJOUR"), recognised.string ?? "no recognised text")
    }
}
