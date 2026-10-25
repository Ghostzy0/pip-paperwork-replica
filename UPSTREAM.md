# Provenance and notices

Paperwork Replica is an independent AppKit/PDFKit application. It uses the shared, locally executed Paperwork Core implementation without copying or modifying that core; the exact source inputs are pinned in `SHARED-CORE.sha256` and exported byte-for-byte. This standalone repository contains no character branding or motion-engine code.

The Swift app and original neutral icon are licensed under MIT; see `LICENSE`. The canonical PDF helper is built from pdfcpu v0.16.1 and pinned Go modules. Runtime and embedded notices are preserved in `Engine/Notices/`. Apple AppKit, PDFKit, Vision and system fonts remain governed by their platform terms. No vendor source, vendor artwork, or proprietary reference media is included.
