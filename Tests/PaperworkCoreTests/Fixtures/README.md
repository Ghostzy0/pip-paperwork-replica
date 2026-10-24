# Synthetic R1 PDF corpus

Original test inputs generated for this repository. No customer data, credentials, external app media or genuine signatures.

- `three-pages.pdf`: labelled text and distinct order markers.
- `form.pdf`: canonical AcroForm `/Fields` tree, text widget `customer`, starting `/V` = `Before`, populated normal appearance.
- `controls.pdf`: checkbox `consent`, shared-field radios `delivery`, display/export choices `region`, constrained `short`, password `secret`, and read-only `fixed`.
- `encrypted.pdf`: AES-256 encrypted three-page fixture; test-only user password `paperwork-test`, owner password `synthetic-owner`. These strings are public synthetic fixture values.
- `signature-field.pdf`: unsigned signature widget, for conservative read-only detection only.
- `signature-marker.pdf`: synthetic comment containing `/ByteRange`, for conservative byte-marker detection only.

`generate.py` regenerates the corpus with reportlab and pypdf. Encryption uses randomness, so regenerated encrypted bytes are not a golden hash. Tests compare semantic values and preserve exact per-test input bytes. `verify_outputs.py OUTPUT_DIRECTORY` checks the native saved outputs with pypdf, including the canonical field tree rather than only widget rendering.

Swift tests find these source-adjacent fixtures via `#filePath`; run `bash scripts/test.sh` within the app checkout to build the pinned helper before native tests. Set `PAPERWORK_ENGINE` only when intentionally testing another helper executable. Generated native outputs are copied only when `PAPERWORK_AUDIT_OUTPUT` is set, and should remain outside tracked sources.

## Canonical production starter

`generate_starter.py` regenerates `Sources/PaperworkCore/Resources/starter.pdf` using **ReportLab4.4.9** (`python3 -m pip install reportlab==4.4.9` in an isolated development environment). The generator uses invariant metadata and Base-14 Helvetica/Helvetica-Bold without embedding a font file. On the reviewed host, two runs matched SHA-256 `95ed366af6f7a053e540a13b11b8b5ba13373507af4b6a5c20b76368af1fd6ea`; cross-version byte identity is not promised. Independent parser used pypdf6.10.0. ReportLab/pypdf are fixture-development tools only; the checked-in asset and runtime app build require neither.

The actual app reads its packaged Resources/starter.pdf. Tests inject the SAME canonical source asset into the production loader, then perform the first untouched highlight/form/rotate/save/reopen sequence; missing asset is a tested error. Do not replace this with a test-only generated document or waive host-specific failures. Optional Popup companions are validated against the Text annotation while counting the five logical markup kinds.
