# Security and privacy

Paperwork Replica is an experimental local application. It has no account, cloud, telemetry, or vendor-service integration. PDFKit and the bundled canonical-PDF helper process files on the Mac. PDF-provided executable and remote actions are disabled.

The app uses a working copy and refuses to overwrite existing files when saving or exporting. Encrypted and signed PDFs remain read-only under the shared core policy. These safeguards reduce accidental changes but do not replace backups or a security audit.

Local recovery is optional and disabled by default. When enabled, a working PDF snapshot is stored at `~/Library/Application Support/PaperworkReplica/recovery.pdf` and is not encrypted by the app. OCR makes a flattened output copy. Avoid using sensitive files until the app’s behavior and security have been independently reviewed.

To report a vulnerability, use the repository’s private vulnerability-reporting mechanism if available. Otherwise, contact the maintainers privately before sharing details publicly. Do not attach real documents, passwords, recovery files, crash dumps, or other sensitive data to an issue. Security response and supported-version commitments are not yet established.

Third-party components and notices are listed in [UPSTREAM.md](../UPSTREAM.md) and `Engine/Notices/`.
