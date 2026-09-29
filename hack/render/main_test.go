package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestOutputPath(t *testing.T) {
	cases := map[string]string{
		"registry/clusters/__cluster__/registry.yaml.tmpl": "registry/clusters/demo/registry.yaml",
		"components/argocd/install.yaml":                   "components/argocd/install.yaml",
		"a/__cluster__x/b.tmpl":                            "a/__cluster__x/b",
	}
	for in, want := range cases {
		if got := OutputPath(in, "demo"); got != want {
			t.Errorf("OutputPath(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestRender(t *testing.T) {
	src := t.TempDir()
	out := filepath.Join(t.TempDir(), "out")
	write := func(rel, s string) {
		p := filepath.Join(src, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(s), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("x/__cluster__/a.yaml.tmpl", "name: [[ .ClusterName ]]\nhelm: {{ .Values.x }}\n")
	write("x/verbatim.yaml", "raw: [[ .ClusterName ]]\n")
	d := Data{ClusterName: "c1", ClusterFlavor: "k3s"}
	n, err := Render(src, out, d)
	if err != nil || n != 2 {
		t.Fatalf("Render = %d, %v", n, err)
	}
	a, _ := os.ReadFile(filepath.Join(out, "x/c1/a.yaml"))
	if string(a) != "name: c1\nhelm: {{ .Values.x }}\n" {
		t.Errorf("rendered a.yaml = %q", a)
	}
	v, _ := os.ReadFile(filepath.Join(out, "x/verbatim.yaml"))
	if !strings.Contains(string(v), "[[ .ClusterName ]]") {
		t.Errorf("verbatim file was rendered: %q", v)
	}
}

func TestMissingKeyErrors(t *testing.T) {
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "a.tmpl"), []byte("[[ .NoSuchField ]]"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Render(src, filepath.Join(t.TempDir(), "out"), Data{}); err == nil {
		t.Fatal("expected an error for an unknown field")
	}
}
