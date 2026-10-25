# Contributing

Contributions should improve the independent local reader while preserving truthful scope, source licensing, and original-file safety.

## Before opening a change

- Read [PARITY.md](../PARITY.md), [UPSTREAM.md](../UPSTREAM.md), and [SECURITY.md](SECURITY.md).
- Keep changes scoped and explain user-visible behavior, limitations, and how you verified them.
- Preserve create-only writes, opt-in recovery, read-only handling for encrypted and signed inputs, and OCR’s flattened-output warning.
- Do not add private reference captures, personal PDFs, credentials, machine-specific paths, vendor artwork/source, or undocumented network behavior.

## Validation

On a supported Apple silicon Mac with macOS 14 or later and Xcode Command Line Tools, run `./scripts/test.sh` and `./scripts/build.sh`. Report the exact commands and results. A passing test suite or build does not establish native GUI behavior, VoiceOver accessibility, minimum-OS behavior, or reference parity; identify any such checks that remain unrun.

Keep upstream and embedded notices intact. The frontend is in `Sources/Paperwork/`; shared core code is pinned in `SHARED-CORE.sha256`. Do not silently fork or modify that common engine as part of a frontend-only change.
