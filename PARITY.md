# Recreation parity and evidence

## Observed reference

The private primary-reference session observed PDF Expert 3.13.4 build 1177 with an authored three-page synthetic PDF on macOS 27.0.1. Captures established the dark reader chrome, compact top command rows, left thumbnail navigation, page overview, and right-side search result navigation. Highlight selection surfaced a sign-in gate before an annotation was created. Private screenshots/AX are intentionally excluded from this public source export.

## This implementation

The recreated source composes AppKit/PDFKit with the shared Paperwork Core. The reader, optional page-thumbnail sidebar, paged navigation-only overview, and paginated local search navigation are implemented. Result rows include a page number, per-page match count and selected-text snippet. Core-supported operations retain their original behavior and limits. The replica does not include vendor branding, upsell, trial/account flow, or services.

## Unverified and remaining

The 24 October 2026 source snapshot compiled, passed 36 tests, and produced a strict-signature local package. The packaged app has not yet been launched. Same-input comparison, VoiceOver/minimum-window/macOS 14 checks, and native feature acceptance remain unverified. Native geometry was not measured. Text selection markup creation, export/save, forms, OCR, dark/light appearance comparison and multi-document behavior remain unverified against the reference. The implementation intentionally has one active document and no fake multi-tab affordance. It does not yet provide the observed sidebar panes for Bookmarks, Outline, or Annotation Summary; only Thumbnails is implemented. Search results are shown as paged individual matches with page/count context, not the reference page-group hierarchy. The overview is navigation-only; page operations remain disabled while it is shown. Differences should be added here only with reproducible build identity and private evidence index references.
