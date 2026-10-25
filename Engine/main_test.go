// SPDX-License-Identifier: MIT
package main

import (
	"github.com/pdfcpu/pdfcpu/pkg/pdfcpu/model"
	"github.com/pdfcpu/pdfcpu/pkg/pdfcpu/types"
	"os"
	"path/filepath"
	"testing"
)

func TestCreateOnlyPrivateOutput(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "output.pdf")
	if err := writeNew(path, []byte("first")); err != nil {
		t.Fatal(err)
	}
	if err := writeNew(path, []byte("replacement")); err == nil {
		t.Fatal("replaced existing output")
	}
	data, _ := os.ReadFile(path)
	if string(data) != "first" {
		t.Fatal("output modified")
	}
	st, _ := os.Stat(path)
	if st.Mode().Perm() != 0600 {
		t.Fatal("output not private")
	}
	entries, _ := os.ReadDir(root)
	if len(entries) != 1 {
		t.Fatal("temporary output left behind")
	}
}
func TestRejectUncleanAndOversizedPaths(t *testing.T) {
	if _, e := readRegular("relative.pdf", 100); e == nil {
		t.Fatal("accepted relative path")
	}
	path := filepath.Join(t.TempDir(), "input.pdf")
	os.WriteFile(path, []byte("large"), 0600)
	if _, e := readRegular(path, 2); e == nil {
		t.Fatal("accepted oversized input")
	}
	if _, e := readRegular(filepath.Dir(path), 100); e == nil {
		t.Fatal("accepted directory")
	}
}
func TestRejectInvalidRequestBeforeOutput(t *testing.T) {
	root := t.TempDir()
	in := filepath.Join(root, "input.pdf")
	out := filepath.Join(root, "output.pdf")
	req := filepath.Join(root, "request.json")
	os.WriteFile(in, []byte("invalid pdf"), 0600)
	for _, s := range []string{`{"version":2,"edits":{}}`, `{"version":1,"edits":{},"unknown":true}`, `{"version":1,"edits":{}} {}`} {
		os.WriteFile(req, []byte(s), 0600)
		if e := run([]string{in, out, req}); e == nil {
			t.Fatal("invalid request accepted")
		}
		if _, e := os.Lstat(out); !os.IsNotExist(e) {
			t.Fatal("output produced")
		}
	}
}

func TestRejectDynamicOrphanMetadata(t *testing.T) {
	// Exercise the form-level boundary before any graph cloning or output mutation.
	for _, key := range []string{"CO", "XFA", "AA", "A"} {
		form := types.Dict{key: types.Boolean(true)}
		if e := staticOrphanTemplate(nil, form); e == nil {
			t.Fatal("accepted dynamic form", key)
		}
	}
}

// Regression for R3: inherited Ff on an unnamed parent must still reject a
// text widget whose FT appears only on the child, before metadata is dropped.
func TestRejectInheritedRichTextOrphanMetadata(t *testing.T) {
	ctx := &model.Context{XRefTable: &model.XRefTable{}}
	widget := types.Dict{"FT": types.Name("Tx"), "T": types.StringLiteral("notes"), "Subtype": types.Name("Widget")}
	parent := types.Dict{"Ff": types.Integer(1 << 25), "Kids": types.Array{widget}}
	form := types.Dict{"Fields": types.Array{parent}}
	if err := staticOrphanTemplate(ctx, form); err == nil {
		t.Fatal("inherited rich text accepted")
	}
	parent["Ff"] = types.Integer(1 | 2)
	if err := staticOrphanTemplate(ctx, form); err != nil {
		t.Fatal("static inherited flags rejected:", err)
	}
	ctx.RootDict = types.Dict{"AcroForm": form}
	fields, err := allFields(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if fields["notes"].kind != "Tx" || fields["notes"].flags != 3 {
		t.Fatal("inherited constraints not resolved")
	}
}

func TestResolveIndirectAndInheritedFieldPolicy(t *testing.T) {
	flags := types.IndirectRef{ObjectNumber: types.Integer(3), GenerationNumber: types.Integer(0)}
	kind := types.IndirectRef{ObjectNumber: types.Integer(4), GenerationNumber: types.Integer(0)}
	ctx := &model.Context{XRefTable: &model.XRefTable{Table: map[int]*model.XRefTableEntry{3: model.NewXRefTableEntryGen0(types.Integer(1)), 4: model.NewXRefTableEntryGen0(types.Name("Btn"))}}}
	d := types.Dict{"Ff": flags, "FT": kind}
	ft, ff, e := fieldPolicy(ctx, d, "", 0)
	if e != nil || ft != "Btn" || ff != 1 {
		t.Fatal("indirect read-only policy lost", ft, ff, e)
	}
	widget := types.Dict{"T": types.StringLiteral("consent"), "Subtype": types.Name("Widget")}
	parent := types.Dict{"Ff": flags, "FT": kind, "Kids": types.Array{widget}}
	ctx.RootDict = types.Dict{"AcroForm": types.Dict{"Fields": types.Array{parent}}}
	fs, e := allFields(ctx)
	if e != nil || fs["consent"].flags != 1 || fs["consent"].kind != "Btn" {
		t.Fatal("inherited indirect policy lost", fs, e)
	}
	widget["V"] = types.Name("Off")
	if err := repairButtons(ctx, nil, map[string]string{"consent": "Yes"}); err == nil {
		t.Fatal("indirect read-only field accepted an edit")
	}
	if widget["V"] != types.Name("Off") {
		t.Fatal("rejected edit mutated value")
	}
	ctx.Table[3] = model.NewXRefTableEntryGen0(types.Integer(1 << 25))
	ctx.Table[4] = model.NewXRefTableEntryGen0(types.Name("Tx"))
	if err := staticOrphanTemplate(ctx, ctx.RootDict["AcroForm"].(types.Dict)); err == nil {
		t.Fatal("indirect inherited rich text accepted")
	}
	ctx.Table[3] = model.NewXRefTableEntryGen0(types.StringLiteral("1"))
	if _, _, e = fieldPolicy(ctx, d, "", 0); e == nil {
		t.Fatal("invalid flags silently accepted")
	}
}

func TestAttachNativeStandaloneTextWithoutChangingAppearance(t *testing.T) {
	ctx := &model.Context{XRefTable: &model.XRefTable{}}
	font := types.Dict{"Type": types.Name("Font"), "Subtype": types.Name("Type1"), "BaseFont": types.Name("Helvetica")}
	normal := types.StreamDict{Dict: types.Dict{"Type": types.Name("XObject"), "Subtype": types.Name("Form"), "Resources": types.Dict{"Font": types.Dict{"TT1": font}}}, Content: []byte("original appearance")}
	widget := types.Dict{"T": types.StringLiteral("Project contact"), "FT": types.Name("Tx"), "Subtype": types.Name("Widget"), "V": types.StringLiteral("Sample person"), "DA": types.Name(".AppleSystemUIFont 14 Tf 0 g"), "AP": types.Dict{"N": normal}}
	ref := types.IndirectRef{ObjectNumber: types.Integer(3), GenerationNumber: types.Integer(0)}
	// The page annotation reference must point to the fixture's actual widget,
	// just as it does in a parsed PDF xref table.
	ctx.Table = map[int]*model.XRefTableEntry{3: model.NewXRefTableEntryGen0(widget)}
	root := types.NewDict()
	if err := attachStandaloneText(ctx, root, []retainedWidget{{ref, widget}}); err != nil {
		t.Fatal(err)
	}
	form := root["AcroForm"].(types.Dict)
	if form["Fields"].(types.Array)[0] != ref {
		t.Fatal("original widget identity lost")
	}
	if widget["V"] != types.StringLiteral("Sample person") {
		t.Fatal("field value changed")
	}
	if widget["DA"] != types.StringLiteral("/PaperworkFieldFont 14 Tf 0 g") {
		t.Fatal("default appearance not canonical")
	}
	after := widget["AP"].(types.Dict)["N"].(types.StreamDict)
	if string(after.Content) != "original appearance" {
		t.Fatal("normal appearance changed")
	}
	if got := form["DR"].(types.Dict)["Font"].(types.Dict)["PaperworkFieldFont"].(types.Dict)["BaseFont"]; got != types.Name("Helvetica") {
		t.Fatal("font substituted")
	}
	// Exact native bytes contain #2320, parsed to literal #20: preserve that
	// observed second-layer encoding in the regression rather than a guess.
	widget["DA"] = types.Name(".AppleSystemUIFont#2014#20Tf#200#20g")
	if err := attachStandaloneText(ctx, types.NewDict(), []retainedWidget{{ref, widget}}); err != nil {
		t.Fatal("actual native encoded DA rejected:", err)
	}
	widget["Ff"] = types.Integer(1 << 25)
	if err := attachStandaloneText(ctx, types.NewDict(), []retainedWidget{{ref, widget}}); err == nil {
		t.Fatal("rich text orphan accepted")
	}
	delete(widget, "Ff")
	widget["Parent"] = ref
	if err := attachStandaloneText(ctx, types.NewDict(), []retainedWidget{{ref, widget}}); err == nil {
		t.Fatal("orphan hierarchy accepted without template")
	}
}
