# Changelog

## 0.1.0-alpha.1 — experimental qualification

Original single-document macOS reader recreation using the shared Paperwork Core. Includes thumbnails, local search navigation, supported markup/forms and create-only Save a Copy. No vendor branding, private media or vendor services are included.

The overview now uses an explicit flipped scroll document with bounded 24-page batches, complete preview/label extents and horizontal overflow. The earlier plain/stack candidates' clipping was reproduced, corrected, independently reviewed and retested on the same authored three-page fixture. A 26-page fixture also passed scrolling, next-batch and reader-return checks.

The source passed 36 tests and hosted macOS 14 production build. Native and release boundaries are recorded in [TESTING.md](TESTING.md); no stable, full-fidelity, VoiceOver, minimum-OS GUI or notarisation claim is made.
