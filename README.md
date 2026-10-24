# Paperwork Replica

An original, local-first macOS PDF workspace that recreates selected reader and page-navigation workflows observed in PDF Expert 3.13.4. It is an independent project and is not affiliated with Readdle, Apple, or Adobe.

The native AppKit interface provides a single open document, continuous PDF reading, left-side page thumbnails, page overview with direct navigation, text search results with page navigation, supported local markup and form operations, and create-only Save a Copy workflows. It uses Apple PDFKit plus the shared Paperwork Core implementation. The opened source PDF is preserved; edits are made in a working copy. A single-document workspace is deliberate: this build does not claim to reproduce multi-tab document management.

## Build

Requirements: Apple silicon Mac, macOS 14 or later, and Xcode Command Line Tools. The first helper build downloads the exact Go toolchain after verifying its checksum; no system Go installation is needed. From the exported repository root:

```sh
./scripts/build.sh
./scripts/test.sh
```

Build output is `build/Paperwork Replica.app`. The 24 October 2026 source snapshot compiled, passed 36 tests, and produced a strict-signature local package. It has not yet had a native launch, VoiceOver, minimum-window, minimum-OS, or same-input fidelity acceptance; those remain open. This is experimental source, not a claim of release readiness.

## Guides

- [How to use Paperwork Replica](docs/HOW-TO.md)
- [Frequently asked questions](docs/FAQ.md)
- [AI setup prompt](docs/AI-SETUP.md)
- [Security and privacy](docs/SECURITY.md)
- [Contributing](docs/CONTRIBUTING.md)

## Privacy and limits

Documents are processed locally. No account, cloud service, trial, premium mode, AI service, cryptographic signing, redaction, text replacement, or vendor integration is included. Encrypted and signed PDFs remain read-only under the shared core policy. Save operations refuse to replace existing files. OCR creates flattened searchable copies and can make recognition errors. Supported form fields only; executable and remote PDF actions remain disabled.

See [PARITY.md](PARITY.md) for evidence boundaries, [docs/REFERENCE-WORKFLOW.md](docs/REFERENCE-WORKFLOW.md) for the required reference/evidence workflow, and [Engine/Notices/README.md](Engine/Notices/README.md) for third-party notices. Private reference captures and machine-specific paths are never part of this export.
