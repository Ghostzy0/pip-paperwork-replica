# Frequently asked questions

### Is Paperwork Replica the same product as PDF Expert?

No. It is an independent AppKit/PDFKit application that recreates a selected reader and navigation layout. It is not affiliated with Readdle, Apple, or Adobe. See [PARITY.md](../PARITY.md) for the observed scope and gaps.

### Does it upload my PDFs or use an account?

No network service, account, cloud storage, AI service, premium mode, or trial is included. PDF reading and OCR are local. Recovery, if enabled, writes a local working-copy snapshot to `~/Library/Application Support/PaperworkReplica/recovery.pdf`; that file is not encrypted by the app.

### Does it change my original PDF?

Edits are made in a working copy. Save and export actions create new files and refuse to replace existing destinations. Keep your own backups for important documents.

### Can it edit every PDF?

No. Encrypted and signed inputs are treated conservatively as read-only, and only supported form fields and PDF operations are available. Executable and remote actions in PDFs are disabled. The app does not provide redaction, cryptographic signing, text replacement, or vendor services.

### What does OCR do?

It creates a flattened searchable copy using the fixed English (UK) on-device recognition setting. This can reduce editability and recognition can be inaccurate. Inspect the output before use.

### Is the app fully tested on macOS 14 and accessible with VoiceOver?

Not yet. The 24 October 2026 snapshot compiled, passed 36 tests, and produced a locally verified signed package. Native launch, VoiceOver, minimum-window and macOS 14 behavior, and detailed fidelity checks remain unverified.

### Where are licenses and notices?

The app source is MIT-licensed. Third-party notices are included in `Engine/Notices/`; Apple frameworks and system components remain subject to Apple’s terms. See [UPSTREAM.md](../UPSTREAM.md) and [the notices index](../Engine/Notices/README.md).
