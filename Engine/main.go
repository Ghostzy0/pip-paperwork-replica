// Copyright 2026 Pip Paperwork contributors. SPDX-License-Identifier: MIT
// canonical-pdf normalizes PDF serialization and restores original button appearances.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"runtime/debug"
	"strconv"
	"strings"
	"time"

	"github.com/pdfcpu/pdfcpu/pkg/api"
	"github.com/pdfcpu/pdfcpu/pkg/pdfcpu/model"
	"github.com/pdfcpu/pdfcpu/pkg/pdfcpu/types"
)

const maxPDF = 180 * 1024 * 1024
const maxRequest = 1024 * 1024
const deadline = 30 * time.Second

type request struct {
	Version  int               `json:"version"`
	Edits    map[string]string `json:"edits"`
	Original string            `json:"original,omitempty"`
	Flatten  bool              `json:"flatten,omitempty"`
}
type field struct {
	dict    types.Dict
	widgets []types.Dict
	flags   int
	kind    string
}

func main() {
	debug.SetMemoryLimit(512 * 1024 * 1024)
	// The process deadline is authoritative even if a parser stalls outside a cancellation check.
	timer := time.AfterFunc(deadline, func() { fmt.Fprintln(os.Stderr, "canonical-pdf: deadline exceeded"); os.Exit(124) })
	defer timer.Stop()
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "canonical-pdf:", err)
		os.Exit(1)
	}
}
func readRegular(path string, max int64) ([]byte, error) {
	if !filepath.IsAbs(path) || filepath.Clean(path) != path {
		return nil, errors.New("paths must be clean and absolute")
	}
	// Open first and inspect that descriptor, avoiding stat/open replacement races.
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if !st.Mode().IsRegular() || st.Size() <= 0 || st.Size() > max {
		return nil, errors.New("input is not a regular file within the size limit")
	}
	b, err := io.ReadAll(io.LimitReader(f, max+1))
	if err != nil {
		return nil, err
	}
	if int64(len(b)) > max {
		return nil, errors.New("input exceeds size limit")
	}
	return b, nil
}
func configuration() *model.Configuration {
	conf := model.NewDefaultConfiguration()
	conf.ValidationMode = model.ValidationRelaxed
	conf.Optimize = false
	conf.OptimizeBeforeWriting = false
	conf.WriteObjectStream = false
	conf.WriteXRefStream = false
	return conf
}
func readPDF(c context.Context, b []byte) (*model.Context, error) {
	ctx, err := api.ReadContext(c, bytes.NewReader(b), configuration())
	if err != nil {
		return nil, err
	}
	if ctx.Encrypt != nil {
		return nil, errors.New("encrypted PDFs are read-only")
	}
	// Detect parsed signatures, including fields not currently visible on a page.
	for _, entry := range ctx.Table {
		if entry == nil || entry.Free {
			continue
		}
		if d, ok := entry.Object.(types.Dict); ok {
			for _, key := range []string{"Type", "FT"} {
				if d[key] == nil {
					continue
				}
				value, e := resolvedName(ctx, d[key])
				if e != nil {
					return nil, e
				}
				if value == "Sig" {
					return nil, errors.New("signed PDFs are read-only")
				}
			}
			if d["ByteRange"] != nil {
				return nil, errors.New("signed PDFs are read-only")
			}
		}
	}
	return ctx, nil
}
func run(args []string) error {
	if len(args) != 3 {
		return errors.New("usage: canonical-pdf INPUT.pdf OUTPUT.pdf REQUEST.json")
	}
	api.DisableConfigDir()
	raw, err := readRegular(args[2], maxRequest)
	if err != nil {
		return fmt.Errorf("request: %w", err)
	}
	var req request
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err = dec.Decode(&req); err != nil {
		return err
	}
	var extra any
	if dec.Decode(&extra) != io.EOF {
		return errors.New("request must contain exactly one JSON object")
	}
	if req.Version != 1 || req.Edits == nil || len(req.Edits) > 10000 {
		return errors.New("unsupported request version or edits")
	}
	if !filepath.IsAbs(args[1]) || filepath.Clean(args[1]) != args[1] || strings.ToLower(filepath.Ext(args[1])) != ".pdf" {
		return errors.New("output must be a clean absolute .pdf path")
	}
	if _, err = os.Lstat(args[1]); !os.IsNotExist(err) {
		return errors.New("output already exists or cannot be inspected")
	}
	input, err := readRegular(args[0], maxPDF)
	if err != nil {
		return err
	}
	c, cancel := context.WithTimeout(context.Background(), deadline)
	defer cancel()
	ctx, err := readPDF(c, input)
	if err != nil {
		return fmt.Errorf("parse input: %w", err)
	}
	var original *model.Context
	if req.Original != "" {
		b, e := readRegular(req.Original, maxPDF)
		if e != nil {
			return e
		}
		original, e = readPDF(c, b)
		if e != nil {
			return fmt.Errorf("parse original: %w", e)
		}
	}
	if req.Flatten {
		widgets, e := pageWidgets(c, ctx)
		if e != nil {
			return e
		}
		if len(widgets) > 0 {
			return errors.New("flattened output still contains widgets")
		}
		if len(req.Edits) != 0 {
			return errors.New("flatten request must have no button edits")
		}
		root, e := ctx.Catalog()
		if e != nil {
			return e
		}
		delete(root, "AcroForm")
	} else if err = restoreOrphanFields(c, ctx, original); err != nil {
		return err
	}
	if err = repairButtons(ctx, original, req.Edits); err != nil {
		return err
	}
	if err = api.ValidateContext(c, ctx); err != nil {
		return fmt.Errorf("validate repaired PDF: %w", err)
	}
	var out bytes.Buffer
	if err = api.WriteContext(c, ctx, &out); err != nil {
		return fmt.Errorf("serialize: %w", err)
	}
	if out.Len() > maxPDF {
		return errors.New("output exceeds size limit")
	}
	check, err := readPDF(c, out.Bytes())
	if err != nil {
		return fmt.Errorf("reparse: %w", err)
	}
	if err = api.ValidateContext(c, check); err != nil {
		return fmt.Errorf("validate output: %w", err)
	}
	if check.PageCount != ctx.PageCount {
		return errors.New("page count changed")
	}
	if err = verifyButtons(check, req.Edits); err != nil {
		return err
	}
	if err = c.Err(); err != nil {
		return err
	}
	return writeNew(args[1], out.Bytes())
}
func writeNew(path string, b []byte) error {
	// Same-directory private temporary + create-only hard link commits without replacing any path.
	f, err := os.CreateTemp(filepath.Dir(path), ".paperwork-canonical-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	defer f.Close()
	if err = f.Chmod(0600); err != nil {
		return err
	}
	if _, err = f.Write(b); err != nil {
		return err
	}
	if err = f.Sync(); err != nil {
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	return os.Link(f.Name(), path)
}
func allFields(ctx *model.Context) (map[string]field, error) {
	root, err := ctx.Catalog()
	if err != nil {
		return nil, err
	}
	result := map[string]field{}
	if root["AcroForm"] == nil {
		return result, nil
	}
	form, err := ctx.DereferenceDict(root["AcroForm"])
	if err != nil {
		return nil, err
	}
	if form["XFA"] != nil {
		return nil, errors.New("XFA forms are unsupported")
	}
	roots, err := ctx.DereferenceArray(form["Fields"])
	if err != nil {
		return nil, err
	}
	visited := map[int]bool{}
	count := 0
	var walk func(types.Object, string, string, int, int) error
	walk = func(o types.Object, prefix, ft string, flags, depth int) error {
		count++
		if depth > 50 || count > 100000 {
			return errors.New("form tree exceeds limit")
		}
		if ref, ok := o.(types.IndirectRef); ok {
			id := ref.ObjectNumber.Value()
			if visited[id] {
				return errors.New("cyclic or shared form field tree")
			}
			visited[id] = true
		}
		d, e := ctx.DereferenceDict(o)
		if e != nil {
			return e
		}
		if d == nil {
			return errors.New("null form field")
		}
		name := prefix
		if d["T"] != nil {
			s, e := ctx.DereferenceText(d["T"])
			if e != nil {
				return e
			}
			if prefix != "" {
				name += "."
			}
			name += s
		}
		ft, flags, e = fieldPolicy(ctx, d, ft, flags)
		if e != nil {
			return e
		}
		kids, e := ctx.DereferenceArray(d["Kids"])
		if e != nil {
			return e
		}
		var widgets []types.Dict
		var children []types.Object
		if d.NameEntry("Subtype") != nil && *d.NameEntry("Subtype") == "Widget" {
			widgets = append(widgets, d)
		}
		for _, k := range kids {
			kd, e := ctx.DereferenceDict(k)
			if e != nil {
				return e
			}
			if kd == nil {
				return errors.New("null field child")
			}
			if kd["T"] == nil && kd.NameEntry("Subtype") != nil && *kd.NameEntry("Subtype") == "Widget" {
				widgets = append(widgets, kd)
			} else {
				children = append(children, k)
			}
		}
		if ft != "" && len(widgets) > 0 {
			if name == "" {
				return errors.New("unnamed button field")
			}
			if _, exists := result[name]; exists {
				return errors.New("duplicate full button field name")
			}
			result[name] = field{d, widgets, flags, ft}
		}
		for _, k := range children {
			if e = walk(k, name, ft, flags, depth+1); e != nil {
				return e
			}
		}
		return nil
	}
	for _, r := range roots {
		if err = walk(r, "", "", 0, 0); err != nil {
			return nil, err
		}
	}
	return result, nil
}
func normal(ctx *model.Context, w types.Dict) (types.Dict, error) {
	ap, e := ctx.DereferenceDict(w["AP"])
	if e != nil {
		return nil, e
	}
	if ap == nil {
		return nil, errors.New("missing appearance")
	}
	obj, e := ctx.Dereference(ap["N"])
	if e != nil {
		return nil, e
	}
	d, ok := obj.(types.Dict)
	if !ok || len(d) == 0 {
		return nil, errors.New("normal appearance is not a state dictionary")
	}
	if d["Off"] == nil {
		return nil, errors.New("missing Off appearance")
	}
	for _, o := range d {
		sd, _, e := ctx.DereferenceStreamDict(o)
		if e != nil || sd == nil {
			return nil, errors.New("appearance state is not a stream")
		}
	}
	return d, nil
}
func rect(ctx *model.Context, w types.Dict) (string, error) {
	a, e := ctx.DereferenceArray(w["Rect"])
	if e != nil || len(a) != 4 {
		return "", errors.New("invalid widget rectangle")
	}
	var s []string
	for _, v := range a {
		n, e := ctx.DereferenceNumber(v)
		if e != nil {
			return "", e
		}
		s = append(s, fmt.Sprintf("%.6f", n))
	}
	return strings.Join(s, ","), nil
}

// Clone an appearance's complete object graph into the destination xref. References
// are remapped; never copy a foreign reference or alter the original context.
func cloneObject(dst, src *model.Context, o types.Object, memo map[types.IndirectRef]types.IndirectRef, depth int) (types.Object, error) {
	if depth > 100 {
		return nil, errors.New("appearance object graph exceeds limit")
	}
	if ref, ok := o.(types.IndirectRef); ok {
		if v, found := memo[ref]; found {
			return v, nil
		}
		value, e := src.Dereference(ref)
		if e != nil {
			return nil, e
		}
		nr, e := dst.IndRefForNewObject(types.Integer(0))
		if e != nil {
			return nil, e
		}
		memo[ref] = *nr
		v, e := cloneObject(dst, src, value, memo, depth+1)
		if e != nil {
			return nil, e
		}
		dst.Table[nr.ObjectNumber.Value()].Object = v
		return *nr, nil
	}
	switch v := o.(type) {
	case types.Dict:
		d := types.NewDict()
		for k, x := range v {
			cp, e := cloneObject(dst, src, x, memo, depth+1)
			if e != nil {
				return nil, e
			}
			d[k] = cp
		}
		return d, nil
	case types.Array:
		a := make(types.Array, len(v))
		for i, x := range v {
			cp, e := cloneObject(dst, src, x, memo, depth+1)
			if e != nil {
				return nil, e
			}
			a[i] = cp
		}
		return a, nil
	case types.StreamDict:
		cp := v.Clone().(types.StreamDict)
		d, e := cloneObject(dst, src, v.Dict, memo, depth+1)
		if e != nil {
			return nil, e
		}
		cp.Dict = d.(types.Dict)
		return cp, nil
	default:
		if o == nil {
			return nil, nil
		}
		return o.Clone(), nil
	}
}
func repairButtons(ctx, original *model.Context, edits map[string]string) error {
	fs, e := fields(ctx)
	if e != nil {
		return e
	}
	var source map[string]field
	if original != nil {
		source, e = fields(original)
		if e != nil {
			return e
		}
	}
	for name, value := range edits {
		f, ok := fs[name]
		if !ok {
			return fmt.Errorf("unknown button field %q", name)
		}
		if value == "" || strings.HasPrefix(value, "/") || len(value) > 1024 {
			return errors.New("button value must be a nonempty PDF state name without leading slash")
		}
		if f.flags&1 != 0 || f.flags&(1<<16) != 0 || f.flags&(1<<25) != 0 {
			return errors.New("read-only, pushbutton, and unison fields cannot be edited")
		}
		radio := f.flags&(1<<15) != 0
		matches := 0
		for _, w := range f.widgets {
			n, err := normal(ctx, w)
			// Restore exact original normal appearances for all widgets in an edited field.
			if original != nil {
				sf, ok := source[name]
				if !ok {
					return errors.New("original button field missing")
				}
				key, err := rect(ctx, w)
				if err != nil {
					return err
				}
				var candidate types.Dict
				count := 0
				for _, sw := range sf.widgets {
					r, err := rect(original, sw)
					if err != nil {
						return err
					}
					if r == key {
						candidate = sw
						count++
					}
				}
				if count != 1 {
					return errors.New("original widget match is missing or ambiguous")
				}
				on, err := normal(original, candidate)
				if err != nil {
					return fmt.Errorf("original appearance: %w", err)
				}
				obj, err := cloneObject(ctx, original, on, map[types.IndirectRef]types.IndirectRef{}, 0)
				if err != nil {
					return err
				}
				n = obj.(types.Dict)
				ap := types.NewDict()
				ap["N"] = n
				w["AP"] = ap
			} else if err != nil {
				return errors.New("damaged button appearances require original PDF")
			}
			state := "Off"
			if value != "Off" && n[value] != nil {
				state = value
				matches++
			}
			w["AS"] = types.Name(state)
			// Child widgets inherit canonical field /V. A stale widget value can override it.
			if w["T"] == nil {
				delete(w, "V")
			}
		}
		if value != "Off" && matches == 0 {
			return errors.New("requested state is absent from original appearances")
		}
		if radio && matches > 1 {
			return errors.New("ambiguous radio option")
		}
		if radio && value == "Off" && f.flags&(1<<14) != 0 {
			return errors.New("radio requires a selection")
		}
		f.dict["V"] = types.Name(value)
	}
	return verifyButtons(ctx, edits)
}
func verifyButtons(ctx *model.Context, edits map[string]string) error {
	fs, e := fields(ctx)
	if e != nil {
		return e
	}
	// Refuse to publish corrupted buttons omitted by an incomplete caller request.
	// Pushbuttons have no selectable state and are left unchanged.
	for _, f := range fs {
		if f.flags&(1<<16) != 0 {
			continue
		}
		value := "Off"
		if raw := f.dict["V"]; raw != nil {
			v, ok := raw.(types.Name)
			if !ok {
				return errors.New("unrepaired button value must be a PDF Name")
			}
			value = string(v)
		}
		selected := 0
		for _, w := range f.widgets {
			n, err := normal(ctx, w)
			if err != nil {
				return err
			}
			actual, ok := w["AS"].(types.Name)
			if !ok || n[string(actual)] == nil {
				return errors.New("unrepaired button has invalid appearance state")
			}
			expected := "Off"
			if value != "Off" && n[value] != nil {
				expected = value
				selected++
			}
			if string(actual) != expected {
				return errors.New("unrepaired button appearance is stale")
			}
			if w["T"] == nil && w["V"] != nil {
				v, ok := w["V"].(types.Name)
				if !ok || string(v) != value {
					return errors.New("unrepaired child widget shadows field value")
				}
			}
		}
		if value != "Off" && selected == 0 {
			return errors.New("unrepaired field state is absent from appearances")
		}
		if f.flags&(1<<15) != 0 && f.flags&(1<<25) == 0 && selected > 1 {
			return errors.New("ambiguous radio state")
		}
	}

	for name, value := range edits {
		f, ok := fs[name]
		if !ok {
			return errors.New("button field lost")
		}
		v, ok := f.dict["V"].(types.Name)
		if !ok || string(v) != value {
			return errors.New("canonical button value differs")
		}
		selected := 0
		for _, w := range f.widgets {
			n, e := normal(ctx, w)
			if e != nil {
				return e
			}
			s, ok := w["AS"].(types.Name)
			if !ok || n[string(s)] == nil {
				return errors.New("invalid button appearance state")
			}
			want := "Off"
			if value != "Off" && n[value] != nil {
				want = value
				selected++
			}
			if string(s) != want {
				return errors.New("stale button appearance state")
			}
			if w["T"] == nil && w["V"] != nil {
				return errors.New("child widget shadows field value")
			}
		}
		if value != "Off" && selected == 0 {
			return errors.New("button state lost")
		}
	}
	return nil
}

// Only selectable buttons participate in canonical state checks.
func fields(ctx *model.Context) (map[string]field, error) {
	all, e := allFields(ctx)
	if e != nil {
		return nil, e
	}
	buttons := map[string]field{}
	for name, f := range all {
		if f.kind == "Btn" {
			buttons[name] = f
		}
	}
	return buttons, nil
}

type retainedWidget struct {
	ref  types.Object
	dict types.Dict
}

func pageWidgets(c context.Context, ctx *model.Context) ([]retainedWidget, error) {
	if err := ctx.EnsurePageCount(); err != nil {
		return nil, err
	}
	if ctx.PageCount < 1 || ctx.PageCount > 2000 {
		return nil, errors.New("page count outside limit")
	}
	var widgets []retainedWidget
	for i := 1; i <= ctx.PageCount; i++ {
		page, _, _, e := ctx.PageDict(c, i, false)
		if e != nil {
			return nil, e
		}
		annots, e := ctx.DereferenceArray(page["Annots"])
		if e != nil {
			return nil, e
		}
		for _, a := range annots {
			d, e := ctx.DereferenceDict(a)
			if e != nil {
				return nil, e
			}
			if d != nil && d.NameEntry("Subtype") != nil && *d.NameEntry("Subtype") == "Widget" {
				if _, ok := a.(types.IndirectRef); !ok {
					return nil, errors.New("direct page widgets are unsupported")
				}
				widgets = append(widgets, retainedWidget{a, d})
				if len(widgets) > 100000 {
					return nil, errors.New("too many widgets")
				}
			}
		}
	}
	return widgets, nil
}
func widgetName(ctx *model.Context, w types.Dict) (string, error) {
	var pieces []string
	for depth := 0; depth < 50; depth++ {
		if w["T"] != nil {
			s, e := ctx.DereferenceText(w["T"])
			if e != nil {
				return "", e
			}
			pieces = append([]string{s}, pieces...)
		}
		if w["Parent"] == nil {
			return strings.Join(pieces, "."), nil
		}
		d, e := ctx.DereferenceDict(w["Parent"])
		if e != nil || d == nil {
			return "", errors.New("invalid widget parent")
		}
		w = d
	}
	return "", errors.New("widget parent chain exceeds limit")
}

// PDFKit page extraction can discard AcroForm and turn radio Kids into separate
// named widgets. Rebuild only against an explicit, unambiguous template. Retain
// the actual page annotation references; never import original pages or widgets.
func restoreOrphanFields(c context.Context, ctx, original *model.Context) error {
	root, e := ctx.Catalog()
	if e != nil {
		return e
	}
	if root["AcroForm"] != nil {
		return nil
	}
	widgets, e := pageWidgets(c, ctx)
	if e != nil {
		return e
	}
	if len(widgets) == 0 {
		return nil
	}
	if original == nil {
		return attachStandaloneText(ctx, root, widgets)
	}
	templates, e := allFields(original)
	if e != nil {
		return e
	}
	groups := map[string][]retainedWidget{}
	seen := map[string]bool{}
	for _, w := range widgets {
		name, e := widgetName(ctx, w.dict)
		if e != nil {
			return e
		}
		if name == "" || strings.Contains(name, ".") {
			return errors.New("unnamed or hierarchical orphan fields are unsupported")
		}
		source, ok := templates[name]
		if !ok {
			return errors.New("orphan field missing from original template")
		}
		key, e := rect(ctx, w.dict)
		if e != nil {
			return e
		}
		unique := name + ":" + key
		if seen[unique] {
			return errors.New("duplicate orphan widget location")
		}
		seen[unique] = true
		matches := 0
		for _, ow := range source.widgets {
			r, e := rect(original, ow)
			if e != nil {
				return e
			}
			if r == key {
				matches++
			}
		}
		if matches != 1 {
			return errors.New("orphan widget template match is ambiguous")
		}
		groups[name] = append(groups[name], w)
	}
	originalRoot, e := original.Catalog()
	if e != nil {
		return e
	}
	originalForm, e := original.DereferenceDict(originalRoot["AcroForm"])
	if e != nil || originalForm == nil {
		return errors.New("original form metadata unavailable")
	}
	if err := staticOrphanTemplate(original, originalForm); err != nil {
		return err
	}
	form := types.NewDict()
	memo := map[types.IndirectRef]types.IndirectRef{}
	for _, key := range []string{"DA", "DR", "Q"} {
		if originalForm[key] != nil {
			v, e := cloneObject(ctx, original, originalForm[key], memo, 0)
			if e != nil {
				return e
			}
			form[key] = v
		}
	}
	var roots types.Array
	for name, group := range groups {
		source := templates[name]
		d := types.NewDict()
		for _, key := range []string{"FT", "Ff", "T", "TU", "TM", "DV", "DA", "DR", "Q", "MaxLen", "Opt", "TI", "DS", "RV"} {
			if source.dict[key] != nil {
				v, e := cloneObject(ctx, original, source.dict[key], memo, 0)
				if e != nil {
					return e
				}
				d[key] = v
			}
		}
		d["FT"] = types.Name(source.kind)
		d["Ff"] = types.Integer(source.flags)
		// The template supplies constraints/style; current values come only from retained widgets.
		if source.kind == "Btn" {
			selected := "Off"
			for _, w := range group {
				if a, ok := w.dict["AS"].(types.Name); ok && string(a) != "Off" {
					if selected != "Off" && selected != string(a) {
						return errors.New("orphan button selection is ambiguous")
					}
					selected = string(a)
				}
			}
			d["V"] = types.Name(selected)
		} else {
			if len(group) > 1 {
				return errors.New("multiple nonbutton orphan widgets are unsupported")
			}
			d["V"] = group[0].dict["V"]
		}
		parent, e := ctx.IndRefForNewObject(d)
		if e != nil {
			return e
		}
		roots = append(roots, *parent)
		var kids types.Array
		for _, w := range group {
			kids = append(kids, w.ref)
			w.dict["Parent"] = *parent
			for _, key := range []string{"T", "TU", "TM", "V", "DV", "FT", "Ff", "DA", "DR", "Q", "MaxLen", "Opt", "I", "TI", "DS", "RV"} {
				delete(w.dict, key)
			}
		}
		d["Kids"] = kids
	}
	form["Fields"] = roots
	form["NeedAppearances"] = types.Boolean(false)
	ref, e := ctx.IndRefForNewObject(form)
	if e != nil {
		return e
	}
	root["AcroForm"] = *ref
	return nil
}

// Dynamic field behavior cannot be reconstructed safely from PDFKit's detached
// widgets. Reject it instead of silently dropping actions/calculation/rich text.
func staticOrphanTemplate(ctx *model.Context, form types.Dict) error {
	for _, key := range []string{"CO", "XFA", "AA", "A"} {
		if form[key] != nil {
			return errors.New("orphan calculation, action, or XFA forms are unsupported")
		}
	}
	roots, e := ctx.DereferenceArray(form["Fields"])
	if e != nil {
		return e
	}
	visited := map[types.IndirectRef]bool{}
	count := 0
	var visit func(types.Object, string, int, int) error
	visit = func(o types.Object, inheritedFT string, inheritedFlags, depth int) error {
		count++
		if depth > 50 || count > 100000 {
			return errors.New("original field tree exceeds limit")
		}
		if r, ok := o.(types.IndirectRef); ok {
			if visited[r] {
				return errors.New("cyclic original field tree")
			}
			visited[r] = true
		}
		d, e := ctx.DereferenceDict(o)
		if e != nil {
			return e
		}
		if d == nil {
			return errors.New("null original field")
		}
		for _, key := range []string{"AA", "A", "RV", "DS"} {
			if d[key] != nil {
				return errors.New("orphan action or rich-text fields are unsupported")
			}
		}
		inheritedFT, inheritedFlags, e = fieldPolicy(ctx, d, inheritedFT, inheritedFlags)
		if e != nil {
			return e
		}
		if inheritedFT == "Tx" && inheritedFlags&(1<<25) != 0 {
			return errors.New("orphan rich-text fields are unsupported")
		}
		kids, e := ctx.DereferenceArray(d["Kids"])
		if e != nil {
			return e
		}
		for _, k := range kids {
			if e = visit(k, inheritedFT, inheritedFlags, depth+1); e != nil {
				return e
			}
		}
		return nil
	}
	for _, r := range roots {
		if e = visit(r, "", 0, 0); e != nil {
			return e
		}
	}
	return nil
}

// Policy entries are inheritable and may legally be indirect objects. Never
// substitute permissive defaults merely because an entry is not direct.
func resolvedName(ctx *model.Context, o types.Object) (string, error) {
	value, e := ctx.Dereference(o)
	if e != nil {
		return "", e
	}
	name, ok := value.(types.Name)
	if !ok {
		return "", errors.New("policy name has an unsupported type")
	}
	return string(name), nil
}
func fieldPolicy(ctx *model.Context, d types.Dict, ft string, flags int) (string, int, error) {
	if d["FT"] != nil {
		value, e := resolvedName(ctx, d["FT"])
		if e != nil {
			return "", 0, e
		}
		ft = value
	}
	if d["Ff"] != nil {
		value, e := ctx.Dereference(d["Ff"])
		if e != nil {
			return "", 0, e
		}
		n, ok := value.(types.Integer)
		if !ok || int(n) < 0 || int64(n) > 2147483647 {
			return "", 0, errors.New("field flags have an unsupported type or range")
		}
		flags = int(n)
	}
	return ft, flags, nil
}

// The bundled native starter exposes one self-contained programmatic text
// widget, but PDFKit omits AcroForm and writes DA as a Name. Attach only this
// unambiguous shape, retaining its actual value, annotation and appearance.
func attachStandaloneText(ctx *model.Context, root types.Dict, widgets []retainedWidget) error {
	if len(widgets) != 1 {
		return errors.New("orphan widget groups require an original form template")
	}
	w := widgets[0].dict
	if w["Parent"] != nil || w["Kids"] != nil {
		return errors.New("orphan field hierarchy requires an original template")
	}
	name, e := widgetName(ctx, w)
	if e != nil {
		return e
	}
	if name == "" || strings.Contains(name, ".") {
		return errors.New("orphan field name is unsupported")
	}
	kind, _, e := fieldPolicy(ctx, w, "", 0)
	if e != nil {
		return e
	}
	if kind != "Tx" {
		return errors.New("orphan controls require an original form template")
	}
	form := types.Dict{"Fields": types.Array{widgets[0].ref}}
	if e = staticOrphanTemplate(ctx, form); e != nil {
		return e
	}
	if w["V"] != nil {
		if _, e = ctx.DereferenceText(w["V"]); e != nil {
			return e
		}
	}
	ap, e := ctx.DereferenceDict(w["AP"])
	if e != nil || ap == nil {
		return errors.New("orphan text appearance is missing")
	}
	normal, _, e := ctx.DereferenceStreamDict(ap["N"])
	if e != nil || normal == nil {
		return errors.New("orphan text normal appearance is unsupported")
	}
	resources, e := ctx.DereferenceDict(normal.Dict["Resources"])
	if e != nil || resources == nil {
		return errors.New("orphan text appearance resources are missing")
	}
	fonts, e := ctx.DereferenceDict(resources["Font"])
	if e != nil || len(fonts) != 1 {
		return errors.New("orphan text font is ambiguous")
	}
	var fontName string
	var font types.Object
	for name, value := range fonts {
		fontName = name
		font = value
	}
	raw, e := ctx.Dereference(w["DA"])
	if e != nil {
		return e
	}
	var da string
	wasName := false
	if n, ok := raw.(types.Name); ok {
		da = string(n)
		wasName = true
		// Actual native starter bytes use #2320: the ordinary PDF parser
		// correctly leaves one literal #20 layer. Decode that known malformed
		// Apple system-font DA encoding once more, never arbitrary PDF names.
		if strings.HasPrefix(da, ".AppleSystemUIFont#20") {
			da, e = types.DecodeName(da)
			if e != nil {
				return e
			}
		}
	} else {
		da, e = ctx.DereferenceText(raw)
		if e != nil {
			return e
		}
	}
	tokens := strings.Fields(da)
	if len(tokens) != 5 || tokens[2] != "Tf" || tokens[4] != "g" {
		return errors.New("orphan text default appearance is unsupported")
	}
	logicalFont := strings.TrimPrefix(tokens[0], "/")
	if logicalFont != fontName && !(wasName && logicalFont == ".AppleSystemUIFont") {
		return errors.New("orphan text default font cannot be resolved")
	}
	size, e := strconv.ParseFloat(tokens[1], 64)
	if e != nil || math.IsNaN(size) || math.IsInf(size, 0) || size < 0 || size > 1000 {
		return errors.New("orphan text font size is unsupported")
	}
	gray, e := strconv.ParseFloat(tokens[3], 64)
	if e != nil || math.IsNaN(gray) || math.IsInf(gray, 0) || gray < 0 || gray > 1 {
		return errors.New("orphan text color is unsupported")
	}
	// A fresh resource alias references the exact existing font object. No font,
	// appearance stream, page content or field value is substituted.
	alias := "PaperworkFieldFont"
	canonicalDA := types.StringLiteral("/" + alias + " " + tokens[1] + " Tf " + tokens[3] + " g")
	form["DR"] = types.Dict{"Font": types.Dict{alias: font}}
	form["DA"] = canonicalDA
	form["NeedAppearances"] = types.Boolean(false)
	w["DA"] = canonicalDA
	root["AcroForm"] = form
	return nil
}
