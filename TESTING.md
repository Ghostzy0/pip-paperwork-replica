# Verification and open gates

## Source and package identity

The runtime source at public `dc8e52c4fa8c3f108e50ba98338dc60f5724c87c` passed [hosted macOS 14 CI](https://github.com/Ghostzy0/pip-paperwork-replica/actions/runs/40173407848): ten shared-core source pins, 36 tests with zero failures, and production build. The tested local canvas package was compiled from an audited development snapshot whose exported runtime inputs match that public source. Its executable SHA-256 is `c7787a90c1f02085df4247c6bd102bf371a077afd6d2ddadab78831df854f62a`. Strict local ad-hoc signature and packaged resources/notices passed; Developer ID and notarisation are not provided.

## Native observations — 25 October 2026

On macOS 27.0.1, this exact package opened the same authored three-page PDF used to reproduce the earlier overview defect. All three previews and full Page 1/2/3 labels were visible. Selecting Page 3 opened the correct reader page; returning to overview preserved current-page details.

An authored 26-page document exercised the first 1–24 batch, horizontal scrolling from the first cards to the last, the next 25–26 batch, and Page 26 reader navigation. Returning to overview reset the first batch while retaining the current page in document details. All eight retained JPEG/AX pairs were independently inspected by the parent reviewer. Actual screenshots are 2560×1736 pixels; native-point window dimensions were not measured. Source PDF hashes stayed unchanged, the app quit normally, and its executable process was absent afterward.

The previous flipped-stack package remained a rejected layout fix: it clipped labels and showed only two of three main previews. Earlier reader/page-2/search evidence belongs to that earlier executable and does not silently qualify the new package.

On the same c778 package, a bounded native I/O slice edited the synthetic Project contact to `FINAL25 Sample`, saved a separate copy, reopened it, and retained the edited value across three pages. Opening an owned 46-byte invalid PDF showed a read error; dismissing it left the edited current copy intact. Canceling the native file picker also left the current copy active. On a separate authored three-page fixture, Page 2 showed `BRAVO SECOND PAGE`; searching `BRAVO` returned one result on Page 2. The original input hash stayed unchanged. Ten retained JPEG captures were independently reviewed; no account/personal content or GPS metadata was observed. The picker contents were not retained.

A single resize attempt did not visibly reduce the window; its screenshot remained 2560×1736 pixels. Native-point size and minimum-window behavior are not established. A 213-row, app-process-only sampler reported maxima of 44.1% estimated CPU and 232,048 KiB RSS during mixed I/O. These are sampled maxima, not true peak, idle, energy or latency measurements; the helper process was excluded.

## Open limits

Field edit/save/reopen, invalid-input handling, picker cancellation, and the Page 2/BRAVO search regression now pass on the current package. Keyboard-only, VoiceOver, minimum-window and macOS 14 GUI checks remain unverified. The resize attempt did not establish a smaller window.

Premium reference annotation/save/OCR workflows were unavailable through the authorised free reference path; no trial was activated. Bookmarks, Outline, Annotation Summary, multiple document tabs and page-grouped search differ from the reference. Core unit/CI evidence is not native GUI or full PDF compatibility acceptance. See [PARITY.md](PARITY.md) and the repository issues for the remaining scope.
