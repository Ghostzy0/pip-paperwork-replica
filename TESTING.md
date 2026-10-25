# Verification and open gates

## Source and package identity

The runtime source at public `dc8e52c4fa8c3f108e50ba98338dc60f5724c87c` passed [hosted macOS 14 CI](https://github.com/Ghostzy0/pip-paperwork-replica/actions/runs/40173407848): ten shared-core source pins, 36 tests with zero failures, and production build. The tested local canvas package was compiled from an audited development snapshot whose exported runtime inputs match that public source. Its executable SHA-256 is `c7787a90c1f02085df4247c6bd102bf371a077afd6d2ddadab78831df854f62a`. Strict local ad-hoc signature and packaged resources/notices passed; Developer ID and notarisation are not provided.

## Native observations — 25 October 2026

On macOS 27.0.1, this exact package opened the same authored three-page PDF used to reproduce the earlier overview defect. All three previews and full Page 1/2/3 labels were visible. Selecting Page 3 opened the correct reader page; returning to overview preserved current-page details.

An authored 26-page document exercised the first 1–24 batch, horizontal scrolling from the first cards to the last, the next 25–26 batch, and Page 26 reader navigation. Returning to overview reset the first batch while retaining the current page in document details. All eight retained JPEG/AX pairs were independently inspected by the parent reviewer. Actual screenshots are 2560×1736 pixels; native-point window dimensions were not measured. Source PDF hashes stayed unchanged, the app quit normally, and its executable process was absent afterward.

The previous flipped-stack package remained a rejected layout fix: it clipped labels and showed only two of three main previews. Earlier reader/page-2/search evidence belongs to that earlier executable and does not silently qualify the new package.

## Open limits

The current package's field edit/save/reopen, invalid-input/chooser cancellation, smaller-window, keyboard-only, VoiceOver and minimum-OS GUI checks remain unrun. A finite final native I/O slice is queued; this page will record only what it actually establishes.

Premium reference annotation/save/OCR workflows were unavailable through the authorised free reference path; no trial was activated. Bookmarks, Outline, Annotation Summary, multiple document tabs and page-grouped search differ from the reference. Core unit/CI evidence is not native GUI or full PDF compatibility acceptance. See [PARITY.md](PARITY.md) and the repository issues for the remaining scope.
