# Canonical PDF helper

Original MIT helper; parsing/writing uses Apache-2.0 **pdfcpu v0.16.1** and exact Go **1.26.0**. Source revisions are fixed by `go.mod` + `go.sum`; `build.sh` verifies the official darwin/arm64 Go archive SHA-256 before extraction. No Python or system Go is required by the packaged app. Go and module downloads happen only at build time.

Run `Engine/build.sh` from any directory. Output: `Engine/build/canonical-pdf`. Only source/lockfiles/notices are committed; `build/` and app `.build-tools/` toolchain/module caches stay ignored. A public export's clean build must retain this directory, lockfiles and Notices; the app packager embeds the executable at `Contents/Resources/canonical-pdf` and includes Notices.

## Process contract

```text
canonical-pdf /absolute/input.pdf /absolute/new-output.pdf /absolute/request.json
```

```json
{"version":1,"edits":{"consent":"Yes","delivery":"express"},"original":"/absolute/pre-button-edit.pdf","flatten":false}
```

State names omit the leading `/`. Empty `edits` normalizes a PDF without modifying button values. `original` is optional when canonical fields and button normal appearances are intact, and required to repair PDFKit-flattened button appearances or extracted widget groups. The parent supplies private temporary snapshots of the current document and pre-button-edit template; it must never use the user's opened original as the output path. A complete final field-state map is preferable to replaying click events. Only names present in the current canonical field tree may appear in `edits`.

The helper reads bounded regular input/request/template files, rejects encrypted/signed/XFA documents, parses objects with pdfcpu (no PDF regex replacement), repairs button `/V` as Names, sets widget `/AS`, removes stale child `/V` overrides, and clones exact original `/AP/N` normal-state graphs with remapped indirect references. Original matching requires a unique full field name + widget rectangle. PDFKit extraction that omitted the entire AcroForm can be repaired only with an explicit template: uniquely match retained page widgets, rebuild canonical fields and radio parent/Kids links, copy original DA/DR and constraints, and retain current text/choice values. Absent template widgets are omitted; original pages are never imported. Hierarchical orphan names, repeated nonbutton orphan widgets, calculation order, action and rich-text templates currently reject. Ambiguous or unsupported fields fail closed. Pushbuttons/read-only/unison fields cannot be edited. Required radio selections cannot be cleared. Unknown option names are rejected.

Explicit `flatten:true` requires no button edits and no page Widgets, then removes the hidden AcroForm tree. Ordinary normalization preserves canonical hidden fields. The caller must request flattening only after successfully painting annotations/forms into page content.

The bundled starter exposes a separately measured PDFKit defect: one programmatic text widget has no AcroForm, and its default appearance is a Name rather than a string. For exactly one self-contained static text widget, the helper can attach the existing widget without a template. It requires a simple font/gray default appearance and exactly one font in the existing normal appearance. The corrected literal default appearance binds a fresh resource alias to that exact font object. It preserves current value, appearance and annotation identity. Groups, missing/ambiguous resources, actions, rich text and hierarchy still require a supported template or fail closed.

Field policy reads resolve legal indirect values and inherited `FT`/`Ff`; invalid types/ranges reject. Reconstructed fields retain resolved inherited constraints. Rich-text rejection follows policy through unnamed ancestors, including indirect flags. Signature type checks also resolve indirect Names.

It validates, serializes, reparses and validates again before writing. Every saved button is checked, including buttons omitted from the request; an incomplete request cannot silently export known corrupt button values/appearances. Rewrite normalizes stream dictionaries such as PDFKit font streams with missing `/Length`. Page content and other form values are preserved through pdfcpu's object writer; this is a normalizing full rewrite, not byte preservation or signature validation.

Output is create-only: a private mode-0600 temporary is synchronized, then hard-linked to the new destination atomically. Any existing output path, alias or symlink prevents publication. The process has a hard **30 second** deadline (exit 124), cooperative context cancellation, 180 MiB input/output limits, 1 MiB request limit, bounded form/object traversal and a 512 MiB soft Go memory target. The parent also enforces its process timeout. The memory target is not a hard operating-system resource cap. A process killed after creating its private output temporary may leave that temporary; the parent owns temporary-directory cleanup.

`api.DisableConfigDir()` executes before constructing configuration; runtime does not load/write a user's pdfcpu fonts/configuration. Runtime code makes no network requests, spawns no commands and requires no account. Upstream packages contain optional networking features that this entry point does not call; no OS network-sandbox claim is made.

## Verification

With the pinned toolchain/cache environment from `build.sh`, run `go test -p 2 ./...` with build-tool dependencies cached. Tests cover create-only/0600 output, temporary cleanup, input bounds/type/path checks and malformed request rejection. Earlier independent pypdf/Poppler checks used historical malformed development outputs; that internal verifier and its non-distributed inputs are excluded from this public source. The public native suite remains reproducible through `scripts/test.sh`; it does not recreate every historical diagnostic. Native PDFKit reopen, packaged bridge, broader vendor corpus, real user workflow, malicious-PDF stress and OS-version acceptance remain separate app checks.

The source matching policy can reject duplicate field names or identical rectangles in a shared field. The parent must show that failure and preserve the working document. Appearance repair does not invent option names or replace the original control style with a visual approximation.

## Notices

See `Notices/README.md` for library, transitive, Go, embedded Roboto and Adobe core-font metrics notices. No fonts/reference screenshots are copied into the app UI by this helper.
