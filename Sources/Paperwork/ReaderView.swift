import AppKit
import PDFKit
import PaperworkCore

final class ReaderView: PDFView {
    var workspace: Workspace?
    var editField: ((PDFPage, PDFAnnotation) -> Void)?
    var noteAt: ((PDFPage, NSPoint) -> Void)?
    var inkDone: ((PDFPage, [NSPoint]) -> Void)?
    var tool = "select"
    var interactionEnabled = true
    private var stroke: [NSPoint] = []
    private weak var strokePage: PDFPage?
    override func mouseDown(with event: NSEvent) {
        guard interactionEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: false) else { super.mouseDown(with: event); return }
        let pagePoint = convert(point, to: page)
        if tool == "note" { noteAt?(page, pagePoint); return }
        if tool == "ink" { strokePage = page; stroke = [pagePoint]; return }
        if let annotation = page.annotation(at: pagePoint), annotation.type == "Widget" {
            editField?(page, annotation); return
        }
        // Never execute embedded link actions automatically. Internal destinations remain available via thumbnails.
        if let annotation = page.annotation(at: pagePoint), annotation.type == "Link" { NSSound.beep(); return }
        super.mouseDown(with: event)
    }
    override func mouseDragged(with event: NSEvent) {
        if tool == "ink", let p = strokePage { stroke.append(convert(convert(event.locationInWindow, from: nil), to: p)); needsDisplay = true; return }
        super.mouseDragged(with: event)
    }
    override func mouseUp(with event: NSEvent) {
        if tool == "ink", let p = strokePage { stroke.append(convert(convert(event.locationInWindow, from: nil), to: p)); inkDone?(p, stroke); stroke = []; strokePage = nil; needsDisplay = true; return }
        super.mouseUp(with: event)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let p = strokePage, stroke.count > 1 {
            let path = NSBezierPath(); path.lineWidth = 2; NSColor.systemBlue.setStroke()
            path.move(to: convert(stroke[0], from: p)); for point in stroke.dropFirst() { path.line(to: convert(point, from: p)) }; path.stroke()
        }
    }
    override func perform(_ action: PDFAction) {
        // PDF-contained scripts, launch actions, remote files and URLs are inert in this local workspace.
        if let go = action as? PDFActionGoTo { self.go(to: go.destination) }
    }
}
