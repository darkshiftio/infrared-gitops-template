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

// The operator's JSON names the older fields in camelCase and the newer ones by
// their Go names; both load, and an unknown field is an error.
func TestDataFileNewFields(t *testing.T) {
	path := filepath.Join(t.TempDir(), "data.json")
	body := `{"clusterName": "c1", "buildRegistry": "", "Edge": "gateway", "PlatformDomain": "preprod.example.com",
		"InfraredHost": "infrared.preprod.example.com", "ImageRegistry": "ghcr.io/acme",
		"Images": {"api": {"tag": "v1.2.3", "digest": "sha256:01"}}, "Cloud": "linode", "SubstrateCapable": true}`
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	var d Data
	if err := mergeDataFile(&d, path); err != nil {
		t.Fatal(err)
	}
	want := Data{ClusterName: "c1", Edge: "gateway", PlatformDomain: "preprod.example.com",
		InfraredHost: "infrared.preprod.example.com", ImageRegistry: "ghcr.io/acme",
		Images: map[string]ImageRef{"api": {Tag: "v1.2.3", Digest: "sha256:01"}}, Cloud: "linode", SubstrateCapable: true}
	if d.ClusterName != want.ClusterName || d.Edge != want.Edge || d.PlatformDomain != want.PlatformDomain ||
		d.InfraredHost != want.InfraredHost || d.ImageRegistry != want.ImageRegistry || d.Cloud != want.Cloud ||
		d.SubstrateCapable != want.SubstrateCapable || d.Images["api"] != want.Images["api"] {
		t.Errorf("loaded %+v, want %+v", d, want)
	}
	if err := os.WriteFile(path, []byte(`{"Edges": "gateway"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := mergeDataFile(&Data{}, path); err == nil {
		t.Error("an unknown field loaded without an error")
	}
}

// Images is read with index, which a missing key or a nil map leaves at the
// zero ImageRef rather than failing the render (missingkey=error).
func TestImagesIndex(t *testing.T) {
	src := t.TempDir()
	tpl := `[[ with index .Images "api" ]][[ if or .Tag .Digest ]]api [[ .Tag ]]@[[ .Digest ]][[ else ]]none[[ end ]][[ end ]]`
	if err := os.WriteFile(filepath.Join(src, "a.tmpl"), []byte(tpl), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		images map[string]ImageRef
		want   string
	}{
		{nil, "none"},
		{map[string]ImageRef{"ui": {Tag: "v1"}}, "none"},
		{map[string]ImageRef{"api": {Tag: "v1", Digest: "sha256:01"}}, "api v1@sha256:01"},
	} {
		out := filepath.Join(t.TempDir(), "out")
		if _, err := Render(src, out, Data{ClusterName: "c1", Images: c.images}); err != nil {
			t.Fatal(err)
		}
		got, _ := os.ReadFile(filepath.Join(out, "a"))
		if string(got) != c.want {
			t.Errorf("Images %v rendered %q, want %q", c.images, got, c.want)
		}
	}
}

func TestImagesFlag(t *testing.T) {
	var m map[string]ImageRef
	f := imagesFlag{&m}
	if err := f.Set(`{"mcp": {"tag": "v2", "digest": "sha256:02"}}`); err != nil {
		t.Fatal(err)
	}
	if m["mcp"] != (ImageRef{Tag: "v2", Digest: "sha256:02"}) {
		t.Errorf("-images loaded %v", m)
	}
	if err := f.Set(`{"mcp": {"tags": "v2"}}`); err == nil {
		t.Error("-images took an unknown field")
	}
	if err := f.Set(""); err != nil || len(m) != 0 {
		t.Errorf("-images '' = %v, %v; want empty", m, err)
	}
}

func TestValidateNewFields(t *testing.T) {
	base := Data{ClusterName: "c1", ClusterFlavor: "k3s", GitopsRepoURL: "https://github.com/acme/gitops",
		DefaultBranch: "main", InfraredChartRepo: "ghcr.io/darkshiftio/charts", InfraredChartVersion: "0.1.0",
		InfraredNamespace: "infrared", TemplateVersion: "v0.1.0"}
	for _, edge := range Edges {
		for _, cloud := range Clouds {
			d := base
			d.Edge, d.Cloud = edge, cloud
			if err := validate(d); err != nil {
				t.Errorf("Edge %q, Cloud %q: %v", edge, cloud, err)
			}
		}
	}
	for name, mutate := range map[string]func(*Data){
		"edge":                func(d *Data) { d.Edge = "Gateway" },
		"cloud":               func(d *Data) { d.Cloud = "gcp" },
		"domain with scheme":  func(d *Data) { d.PlatformDomain = "https://preprod.example.com" },
		"wildcard domain":     func(d *Data) { d.PlatformDomain = "*.preprod.example.com" },
		"host with a port":    func(d *Data) { d.InfraredHost = "infrared.example.com:8443" },
		"host with a dot end": func(d *Data) { d.InfraredHost = "infrared.example.com." },
	} {
		d := base
		mutate(&d)
		if err := validate(d); err == nil {
			t.Errorf("%s: validated", name)
		}
	}
}

func TestBuildRegistryHelpers(t *testing.T) {
	src := t.TempDir()
	tpl := `[[ if .BuildRegistry ]]registry: [[ .BuildRegistry | quote ]]` +
		`[[ if contains ".dkr.ecr." .BuildRegistry ]] ecr[[ end ]]` +
		`[[ if hasSuffix "/acme" .BuildRegistry ]] org[[ end ]][[ else ]]no builds[[ end ]]`
	if err := os.WriteFile(filepath.Join(src, "a.tmpl"), []byte(tpl), 0o644); err != nil {
		t.Fatal(err)
	}
	for reg, want := range map[string]string{
		"123456789012.dkr.ecr.us-east-1.amazonaws.com/acme": `registry: "123456789012.dkr.ecr.us-east-1.amazonaws.com/acme" ecr org`,
		"ghcr.io/acme": `registry: "ghcr.io/acme" org`,
		"":             "no builds",
	} {
		out := filepath.Join(t.TempDir(), "out")
		if _, err := Render(src, out, Data{ClusterName: "c1", BuildRegistry: reg}); err != nil {
			t.Fatal(err)
		}
		got, _ := os.ReadFile(filepath.Join(out, "a"))
		if string(got) != want {
			t.Errorf("BuildRegistry %q rendered %q, want %q", reg, got, want)
		}
	}
}
