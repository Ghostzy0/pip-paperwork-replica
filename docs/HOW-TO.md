# How to use Paperwork Replica

Paperwork Replica is an experimental local PDF reader and workspace for Apple silicon Macs running macOS 14 or later.

## Build and open a sample

From the repository root, run `./scripts/build.sh`, then open `build/Paperwork Replica.app`. To run the shared core tests, use `./scripts/test.sh`. The first build helper downloads a checksum-pinned Go toolchain; a separate system Go install is not required. See [README](../README.md) for requirements and current verification limits.

Choose **Open synthetic sample** on the welcome screen to use the bundled three-page example, or choose **Open PDF…** to pick a local file. The app has one active document. The left thumbnail pane can be hidden from the View menu; **Pages** opens a navigation-only overview. Select a page card to return to the reader. Use the search field to find text; result rows navigate to matching pages.

## Make and save changes

Choose a markup tool from the annotation controls, then use it on the page. Supported form fields and annotations can be inspected in the document panel. Page controls provide navigation, rotation, reordering, and deletion where the current document permits them.

Edits are made to a working copy. **Save a copy…** asks for a new destination and refuses to overwrite an existing file. The opened source remains unchanged. Export commands also create new files; choose a new name if the destination already exists.

Recovery is off by default. If enabled from File, the app stores the editable working PDF at `~/Library/Application Support/PaperworkReplica/recovery.pdf`. Recovery data is local and is not encrypted by the app. Turn recovery off or discard its file from the File menu when appropriate.

## Searchable scan copy

**Searchable scan copy…** uses on-device Apple Vision OCR with the app’s fixed English (UK) recognition setting. It produces a flattened searchable copy, so original form fields and annotations are no longer editable in that output. Recognition can make mistakes. Review the result before relying on it.

See [PARITY.md](../PARITY.md) for observed, implemented, and unverified behavior.
