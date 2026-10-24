"""Independent PDF parser checks on synthetic native output. Usage: python verify_outputs.py DIRECTORY."""
from pathlib import Path
import json
import re
import sys
from pypdf import PdfReader
from pypdf.generic import NameObject

root = Path(sys.argv[1])
results = {}
def check(name, body):
    try:
        body()
        results[name] = {'passed': True}
    except Exception as error:
        results[name] = {'passed': False, 'error': str(error)}

def text_form():
    reader = PdfReader(root / 'form-filled.pdf')
    fields = reader.get_fields() or {}
    assert 'customer' in fields, f'Canonical AcroForm missing customer: {fields}'
    assert fields['customer'].get('/V') == 'Morgan Synthetic 42', fields['customer']
    widgets = []
    for page in reader.pages:
        for ref in page.get('/Annots', []):
            annotation = ref.get_object()
            if annotation.get('/Subtype') != '/Widget': continue
            parent = annotation.get('/Parent'); parent = parent.get_object() if parent else annotation
            assert annotation.get('/V', parent.get('/V')) == 'Morgan Synthetic 42', annotation
            assert annotation.get('/AP', {}).get('/N'), 'Updated widget has no normal appearance'
            widgets.append(annotation)
    assert len(widgets) == 1

def button_and_choice_fields():
    reader = PdfReader(root / 'controls-filled.pdf')
    fields = reader.get_fields()
    for name, expected in [('consent', '/Yes'), ('delivery', '/express')]:
        value = fields[name]['/V']
        assert isinstance(value, NameObject) and value == expected, f'{name} canonical /V {value!r} ({type(value).__name__}), expected PDF Name {expected}'
    assert fields['region']['/V'] == 'FR', fields['region']
    assert fields['short']['/V'] == '12345'
    assert fields['secret'].get('/V', '') == ''
    assert fields['fixed']['/V'] == 'Immutable'
    radio_states = []
    for page in reader.pages:
        for ref in page.get('/Annots', []):
            widget = ref.get_object(); parent = widget.get('/Parent'); parent = parent.get_object() if parent else widget
            if parent.get('/T') == 'delivery': radio_states.append(widget.get('/AS'))
            if parent.get('/T') == 'consent': assert widget.get('/AS') == '/Yes', widget
    assert sorted(radio_states) == ['/Off', '/express'], radio_states

def annotations():
    annotations = PdfReader(root / 'annotations.pdf').pages[0]['/Annots']
    assert {a.get_object()['/Subtype'] for a in annotations} == {'/Highlight','/Underline','/StrikeOut','/Text','/Ink'}

def searchable_ocr():
    reader = PdfReader(root / 'ocr-searchable.pdf')
    assert 'SYNTHETIC' in ''.join(page.extract_text() or '' for page in reader.pages)
    assert not any(a.get_object().get('/Subtype') == '/Widget' for page in reader.pages for a in page.get('/Annots', []))

def exported_modes():
    optimized = PdfReader(root / 'form-optimized.pdf')
    assert optimized.get_fields()['customer']['/V'] == 'Morgan Synthetic 42'
    flattened = PdfReader(root / 'form-flattened.pdf')
    assert not flattened.get_fields(), 'Flattened output retains canonical form fields'
    assert '/AcroForm' not in flattened.trailer['/Root'], 'Flattened output retains AcroForm tree'
    assert not any(page.get('/Annots') for page in flattened.pages), 'Flattened output retains annotations'

def structural_form_fields():
    expected = {'consent', 'delivery', 'region', 'short', 'secret', 'fixed'}
    for filename, count, consent in [('structural-moved-forms.pdf', 4, '/Yes'), ('structural-extracted-forms.pdf', 1, '/Yes'), ('structural-undo-forms.pdf', 1, '/Yes'), ('structural-initial-forms.pdf', 1, '/Off')]:
        reader = PdfReader(root / filename)
        assert len(reader.pages) == count, filename
        fields = reader.get_fields() or {}
        assert set(fields) == expected, f'{filename} canonical fields {set(fields)}, expected all {expected}'
        assert fields['consent']['/V'] == consent, filename
        assert fields['delivery']['/V'] == '/standard', filename
        assert fields['region']['/V'] == 'GB', filename
        assert fields['short']['/V'] == '12345', filename
        assert fields['fixed']['/V'] == 'Immutable', filename

def actual_starter_sample():
    reader = PdfReader(root / 'starter-edited.pdf')
    assert len(reader.pages) == 3
    assert reader.pages[0].get('/Rotate') == 90
    fields = reader.get_fields() or {}
    assert fields['Project contact']['/V'] == 'Morgan Sample 84', fields
    assert any(ref.get_object().get('/Subtype') == '/Highlight' for ref in reader.pages[0].get('/Annots', []))
    assert 'Select this sentence' in (reader.pages[0].extract_text() or '')

def stream_lengths():
    # Corpus uses ordinary xref tables. Inspect serialized stream dictionaries, since a
    # recovering reader can hide a missing mandatory /Length. Not a generic PDF validator.
    errors = []
    for filename in ['form-filled.pdf', 'controls-filled.pdf', 'annotations.pdf', 'ocr-searchable.pdf', 'form-optimized.pdf', 'form-flattened.pdf', 'starter-edited.pdf']:
        data = (root / filename).read_bytes()
        reader = PdfReader(root / filename)
        for generation, entries in reader.xref.items():
            for number, offset in entries.items():
                if not number or offset >= len(data): continue
                end = data.find(b'endobj', offset)
                if end < 0: continue
                match = re.search(rb'\bstream\r?\n', data[offset:end])
                if not match: continue
                header = data[offset:offset + match.start()]
                if not re.search(rb'/Length\b', header):
                    errors.append(f'{filename} object {number} {generation} stream missing /Length')
    assert not errors, '; '.join(errors)

for name, body in [('canonical_text_form', text_form), ('canonical_buttons_choice_constraints', button_and_choice_fields), ('annotation_kinds', annotations), ('searchable_flattened_ocr', searchable_ocr), ('export_modes', exported_modes), ('structural_form_fields', structural_form_fields), ('actual_starter_sample', actual_starter_sample), ('mandatory_stream_lengths', stream_lengths)]:
    check(name, body)
print(json.dumps(results, indent=2))
raise SystemExit(0 if all(result['passed'] for result in results.values()) else 1)
