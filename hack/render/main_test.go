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

// The one install's stores fields load from the operator's JSON by their Go
// names, Backup's keys as the operator's INFRARED_BACKUP spells them included.
func TestDataFileStoresFields(t *testing.T) {
	path := filepath.Join(t.TempDir(), "data.json")
	body := `{"clusterName": "c1", "Stores": true,
		"Backup": {"bucket": "acme-backups", "endpoint": "https://us-east-1.linodeobjects.com", "region": "us-east-1"},
		"Disabled": ["infisical"]}`
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	var d Data
	if err := mergeDataFile(&d, path); err != nil {
		t.Fatal(err)
	}
	want := BackupTarget{Bucket: "acme-backups", Endpoint: "https://us-east-1.linodeobjects.com", Region: "us-east-1"}
	if !d.Stores || d.Backup != want || len(d.Disabled) != 1 || d.Disabled[0] != "infisical" {
		t.Errorf("loaded Stores %t, Backup %+v, Disabled %q", d.Stores, d.Backup, d.Disabled)
	}
}

func TestBackupAndDisabledFlags(t *testing.T) {
	var b BackupTarget
	bf := backupFlag{&b}
	if err := bf.Set(`{"bucket": "acme-backups", "region": "us-east-1"}`); err != nil {
		t.Fatal(err)
	}
	if b != (BackupTarget{Bucket: "acme-backups", Region: "us-east-1"}) {
		t.Errorf("-backup loaded %+v", b)
	}
	if err := bf.Set(`{"buckets": "x"}`); err == nil {
		t.Error("-backup took an unknown field")
	}
	if err := bf.Set(""); err != nil || b != (BackupTarget{}) {
		t.Errorf("-backup '' = %+v, %v; want the zero value", b, err)
	}
	var d []string
	df := disabledFlag{&d}
	if err := df.Set(`["infisical", "victoria-metrics-k8s-stack"]`); err != nil || len(d) != 2 {
		t.Errorf("-disabled loaded %q, %v", d, err)
	}
	if err := df.Set(`infisical`); err == nil {
		t.Error("-disabled took a bare name, not a JSON array")
	}
	if err := df.Set(""); err != nil || d != nil {
		t.Errorf("-disabled '' = %q, %v; want none", d, err)
	}
}

func TestValidateStoresFields(t *testing.T) {
	base := Data{ClusterName: "c1", ClusterFlavor: "k3s", GitopsRepoURL: "https://github.com/acme/gitops",
		DefaultBranch: "main", InfraredChartRepo: "ghcr.io/darkshiftio/charts", InfraredChartVersion: "0.1.0",
		InfraredNamespace: "infrared", TemplateVersion: "v0.1.0"}
	for name, mutate := range map[string]func(*Data){
		"nothing": func(d *Data) {},
		"stores":  func(d *Data) { d.Stores = true },
		"backup on Linode": func(d *Data) {
			d.Backup = BackupTarget{Bucket: "acme-backups", Endpoint: "https://us-east-1.linodeobjects.com", Region: "us-east-1"}
		},
		"backup on AWS":     func(d *Data) { d.Backup = BackupTarget{Bucket: "acme.backups", Region: "us-east-1"} },
		"disabled":          func(d *Data) { d.Disabled = []string{"infisical", "victoria-metrics-k8s-stack"} },
		"endpoint, a slash": func(d *Data) { d.Backup = BackupTarget{Bucket: "b-1", Endpoint: "http://seaweedfs.example:8333/"} },
	} {
		d := base
		mutate(&d)
		if err := validate(d); err != nil {
			t.Errorf("%s: %v", name, err)
		}
	}
	for name, mutate := range map[string]func(*Data){
		"required component": func(d *Data) { d.Disabled = []string{"infrared"} },
		"not a name":         func(d *Data) { d.Disabled = []string{"Infisical"} },
		"empty name":         func(d *Data) { d.Disabled = []string{""} },
		"bucket too short":   func(d *Data) { d.Backup = BackupTarget{Bucket: "ab"} },
		"bucket uppercase":   func(d *Data) { d.Backup = BackupTarget{Bucket: "Backups"} },
		"bucket with a path": func(d *Data) { d.Backup = BackupTarget{Bucket: "backups/linode"} },
		"endpoint no scheme": func(d *Data) { d.Backup = BackupTarget{Bucket: "backups", Endpoint: "us-east-1.linodeobjects.com"} },
		"endpoint path":      func(d *Data) { d.Backup = BackupTarget{Bucket: "backups", Endpoint: "https://x.example/bucket"} },
		"region a URL":       func(d *Data) { d.Backup = BackupTarget{Bucket: "backups", Region: "https://x"} },
		"no bucket":          func(d *Data) { d.Backup = BackupTarget{Endpoint: "https://x.example"} },
	} {
		d := base
		mutate(&d)
		if err := validate(d); err == nil {
			t.Errorf("%s: validated", name)
		}
	}
}

// Templates test Disabled with builtins only, as the components do: a range
// that sets a variable declared outside it. missingkey=error does not apply to
// a nil slice, so the zero value renders.
func TestDisabledIdiom(t *testing.T) {
	src := t.TempDir()
	tpl := `[[- $on := true ]][[ range .Disabled ]][[ if eq . "infisical" ]][[ $on = false ]][[ end ]][[ end ]]` +
		`[[ if $on ]]on[[ else ]]off[[ end ]]`
	if err := os.WriteFile(filepath.Join(src, "a.tmpl"), []byte(tpl), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		disabled []string
		want     string
	}{
		{nil, "on"},
		{[]string{"kpack"}, "on"},
		{[]string{"kpack", "infisical"}, "off"},
	} {
		out := filepath.Join(t.TempDir(), "out")
		if _, err := Render(src, out, Data{ClusterName: "c1", Disabled: c.disabled}); err != nil {
			t.Fatal(err)
		}
		got, _ := os.ReadFile(filepath.Join(out, "a"))
		if string(got) != c.want {
			t.Errorf("Disabled %q rendered %q, want %q", c.disabled, got, c.want)
		}
	}
}

// The forge fields load from the operator's JSON by their Go names. Gitea needs
// its URL, and GitHub, the empty Forge, has none.
func TestForgeFields(t *testing.T) {
	path := filepath.Join(t.TempDir(), "data.json")
	body := `{"clusterName": "c1", "Forge": "gitea", "ForgeURL": "http://gitea-http.infrared.svc.cluster.local:3000"}`
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	var d Data
	if err := mergeDataFile(&d, path); err != nil {
		t.Fatal(err)
	}
	if d.Forge != "gitea" || d.ForgeURL != "http://gitea-http.infrared.svc.cluster.local:3000" {
		t.Errorf("loaded Forge %q, ForgeURL %q", d.Forge, d.ForgeURL)
	}
	base := Data{ClusterName: "c1", ClusterFlavor: "k3s", GitopsRepoURL: "https://github.com/acme/gitops",
		DefaultBranch: "main", InfraredChartRepo: "ghcr.io/darkshiftio/charts", InfraredChartVersion: "0.1.0",
		InfraredNamespace: "infrared", TemplateVersion: "v0.1.0"}
	for _, c := range []struct{ forge, url string }{
		{"", ""},
		{"gitea", "http://gitea-http.infrared.svc.cluster.local:3000"},
		{"gitea", "https://git.example.com/gitea"},
	} {
		d := base
		d.Forge, d.ForgeURL = c.forge, c.url
		if err := validate(d); err != nil {
			t.Errorf("Forge %q, ForgeURL %q: %v", c.forge, c.url, err)
		}
	}
	for _, c := range []struct{ forge, url string }{
		{"github", ""},
		{"Gitea", "http://gitea-http:3000"},
		{"gitea", ""},
		{"gitea", "http://gitea-http:3000/"},
		{"gitea", "gitea-http:3000"},
		{"gitea", "http://user:secret@gitea-http:3000"},
		{"gitea", "http://gitea-http:3000?x=1"},
		{"", "http://gitea-http:3000"},
	} {
		d := base
		d.Forge, d.ForgeURL = c.forge, c.url
		if err := validate(d); err == nil {
			t.Errorf("Forge %q, ForgeURL %q: validated", c.forge, c.url)
		}
	}
}

// Registry loads from the operator's JSON by its Go name, and is a private
// IPv4 address and a port: the address Zot's Service is pinned to, which builds
// name the registry by.
func TestRegistryField(t *testing.T) {
	path := filepath.Join(t.TempDir(), "data.json")
	if err := os.WriteFile(path, []byte(`{"clusterName": "c1", "Registry": "10.43.0.50:5000"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	var d Data
	if err := mergeDataFile(&d, path); err != nil {
		t.Fatal(err)
	}
	if d.Registry != "10.43.0.50:5000" {
		t.Errorf("loaded Registry %q", d.Registry)
	}
	base := Data{ClusterName: "c1", ClusterFlavor: "k3s", GitopsRepoURL: "https://github.com/acme/gitops",
		DefaultBranch: "main", InfraredChartRepo: "ghcr.io/darkshiftio/charts", InfraredChartVersion: "0.1.0",
		InfraredNamespace: "infrared", TemplateVersion: "v0.1.0"}
	for _, r := range []string{"", "10.43.0.50:5000", "172.20.0.10:80", "192.168.1.10:65535"} {
		d := base
		d.Registry = r
		if err := validate(d); err != nil {
			t.Errorf("Registry %q: %v", r, err)
		}
	}
	for _, r := range []string{
		"registry.infrared.internal:5000", // a name: builds would speak HTTPS to it
		"10.43.0.50",                      // no port
		"8.8.8.8:5000",                    // not a private address
		"10.43.0.50:0",
		"10.43.0.50:65536",
		"10.43.0.50:05000",
		"10.43.0.50:http",
		"http://10.43.0.50:5000",
		"10.43.0.50:5000/platform",
		"[::ffff:10.43.0.50]:5000",
		"[fd00::50]:5000",
	} {
		d := base
		d.Registry = r
		if err := validate(d); err == nil {
			t.Errorf("Registry %q: validated", r)
		}
	}
}

// The zot Application splits Registry into its Service's ClusterIP and port
// with builtins only: a range over the address's length finds the colon.
func TestRegistrySplitIdiom(t *testing.T) {
	src := t.TempDir()
	tpl := `[[- $ip := .Registry ]][[ $port := "" ]]` +
		`[[ range $i := len .Registry ]][[ if hasPrefix ":" (slice $.Registry $i) ]]` +
		`[[ $ip = slice $.Registry 0 $i ]][[ $port = trimPrefix ":" (slice $.Registry $i) ]][[ end ]][[ end ]]` +
		`[[ $ip ]] [[ $port ]]`
	if err := os.WriteFile(filepath.Join(src, "a.tmpl"), []byte(tpl), 0o644); err != nil {
		t.Fatal(err)
	}
	for registry, want := range map[string]string{
		"10.43.0.50:5000":  "10.43.0.50 5000",
		"192.168.1.10:80":  "192.168.1.10 80",
		"172.20.0.10:8080": "172.20.0.10 8080",
		"":                 " ",
	} {
		out := filepath.Join(t.TempDir(), "out")
		if _, err := Render(src, out, Data{ClusterName: "c1", Registry: registry}); err != nil {
			t.Fatal(err)
		}
		got, _ := os.ReadFile(filepath.Join(out, "a"))
		if string(got) != want {
			t.Errorf("Registry %q rendered %q, want %q", registry, got, want)
		}
	}
}

// The copies, Zot's retention and a restore load from the operator's
// environment's JSON (camelCase keys) through their flags, refuse an unknown
// field, and an empty flag is the zero value.
func TestCopiesRetentionRestoreFlags(t *testing.T) {
	var c Copies
	cf := jsonFlag[Copies]{&c, "copies"}
	if err := cf.Set(`{"recipients": ["age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p"],
		"postgres": {"schedule": "0 0 3 * * *", "retention": "7d"}, "gitea": {"schedule": "10 * * * *"}}`); err != nil {
		t.Fatal(err)
	}
	if len(c.Recipients) != 1 || c.Postgres != (CopySchedule{Schedule: "0 0 3 * * *", Retention: "7d"}) ||
		c.Gitea.Schedule != "10 * * * *" || c.Mirror != (CopySchedule{}) {
		t.Errorf("-copies loaded %+v", c)
	}
	for _, bad := range []string{`{"recipient": []}`, `{"postgres": {"when": "x"}}`, `{} {}`} {
		if err := cf.Set(bad); err == nil {
			t.Errorf("-copies took %s", bad)
		}
	}
	if err := cf.Set(""); err != nil || c.Recipients != nil || c.Postgres != (CopySchedule{}) {
		t.Errorf("-copies '' = %+v, %v; want the zero value", c, err)
	}
	var r RegistryRetention
	rf := jsonFlag[RegistryRetention]{&r, "registry-retention"}
	if err := rf.Set(`{"untaggedAfter": "48h", "keepTags": ["^v[0-9]", "^release-"], "keepNewest": 20}`); err != nil {
		t.Fatal(err)
	}
	if r.UntaggedAfter != "48h" || len(r.KeepTags) != 2 || r.KeepNewest != 20 || r.GCInterval != "" {
		t.Errorf("-registry-retention loaded %+v", r)
	}
	if err := rf.Set(`{"keepNewest": "20"}`); err == nil {
		t.Error("-registry-retention took a number as a string")
	}
	var x Restore
	xf := jsonFlag[Restore]{&x, "restore"}
	if err := xf.Set(`{"point": "20261003T050500Z", "postgres": {"source": "postgres", "targetTime": "2026-10-03T05:17:00Z"}}`); err != nil {
		t.Fatal(err)
	}
	if x != (Restore{Point: "20261003T050500Z", Postgres: RestorePostgres{Source: "postgres", TargetTime: "2026-10-03T05:17:00Z"}}) {
		t.Errorf("-restore loaded %+v", x)
	}
	if got := xf.String(); !strings.Contains(got, `"Point":"20261003T050500Z"`) {
		t.Errorf("-restore's String is %s", got)
	}
}

// The new fields load from the operator's Data JSON by their Go names.
func TestDataFileCopiesFields(t *testing.T) {
	path := filepath.Join(t.TempDir(), "data.json")
	body := `{"clusterName": "c1", "Copies": {"Recipients": ["age1x"], "Mirror": {"Schedule": "17 * * * *"}},
		"RegistryRetention": {"KeepNewest": 5}, "Restore": {"Point": "20261003T050500Z"},
		"PostgresServerName": "postgres-20261003T060000Z"}`
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	var d Data
	if err := mergeDataFile(&d, path); err != nil {
		t.Fatal(err)
	}
	if len(d.Copies.Recipients) != 1 || d.Copies.Mirror.Schedule != "17 * * * *" || d.RegistryRetention.KeepNewest != 5 ||
		d.Restore.Point != "20261003T050500Z" || d.PostgresServerName != "postgres-20261003T060000Z" {
		t.Errorf("loaded Copies %+v, RegistryRetention %+v, Restore %+v, PostgresServerName %q",
			d.Copies, d.RegistryRetention, d.Restore, d.PostgresServerName)
	}
}

func TestValidateCopiesRetentionRestore(t *testing.T) {
	base := Data{ClusterName: "c1", ClusterFlavor: "k3s", GitopsRepoURL: "https://github.com/acme/gitops",
		DefaultBranch: "main", InfraredChartRepo: "ghcr.io/darkshiftio/charts", InfraredChartVersion: "0.1.0",
		InfraredNamespace: "infrared", TemplateVersion: "v0.1.0"}
	const recipient = "age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p"
	stores := func(d *Data) { d.Stores, d.Backup = true, BackupTarget{Bucket: "acme-backups"} }
	for name, mutate := range map[string]func(*Data){
		"every copy": func(d *Data) {
			d.Copies = Copies{Recipients: []string{recipient}, Postgres: CopySchedule{"0 30 2 * * *", "14d"},
				Mirror: CopySchedule{"*/30 * * * *", "10d"}, Objects: CopySchedule{"5 * * * MON-FRI", "9d"}, Gitea: CopySchedule{"10 * * * *", "365d"}}
		},
		"retention": func(d *Data) {
			d.RegistryRetention = RegistryRetention{UntaggedAfter: "1h30m", KeepTags: []string{`^v\d+`, "^release-"}, KeepNewest: 1000, GCInterval: "2h", GCDelay: "30m"}
		},
		"server name": func(d *Data) { d.PostgresServerName = "postgres-20261003T060000Z" },
		"restore": func(d *Data) {
			stores(d)
			d.PostgresServerName = "postgres-20261004T101500Z"
			d.Restore = Restore{Point: "20261003T050500Z", Postgres: RestorePostgres{Source: "postgres", TargetTime: "2026-10-03T05:17:00Z"}}
		},
		"restore, no archive": func(d *Data) { stores(d); d.Restore = Restore{Point: "20261003T050500Z"} },
	} {
		d := base
		mutate(&d)
		if err := validate(d); err != nil {
			t.Errorf("%s: %v", name, err)
		}
	}
	for name, mutate := range map[string]func(*Data){
		"five-field Postgres schedule": func(d *Data) { d.Copies.Postgres.Schedule = "0 3 * * *" },
		"six-field mirror schedule":    func(d *Data) { d.Copies.Mirror.Schedule = "0 17 * * * *" },
		"retention in hours":           func(d *Data) { d.Copies.Objects.Retention = "168h" },
		"retention of 0 days":          func(d *Data) { d.Copies.Gitea.Retention = "0d" },
		"an SSH key as recipient":      func(d *Data) { d.Copies.Recipients = []string{"ssh-ed25519 AAAA"} },
		"recipient twice":              func(d *Data) { d.Copies.Recipients = []string{recipient, recipient} },
		"retention in days":            func(d *Data) { d.RegistryRetention.UntaggedAfter = "1d" },
		"a tag pattern that breaks":    func(d *Data) { d.RegistryRetention.KeepTags = []string{"^v[0-9"} },
		"a tag pattern not ASCII":      func(d *Data) { d.RegistryRetention.KeepTags = []string{"^vé"} },
		"keep newest negative":         func(d *Data) { d.RegistryRetention.KeepNewest = -1 },
		"server name upper case":       func(d *Data) { d.PostgresServerName = "Postgres" },
		"server name with a slash":     func(d *Data) { d.PostgresServerName = "postgres/x" },
		"restore without stores":       func(d *Data) { d.Restore.Point = "20261003T050500Z" },
		"restore point not a stamp": func(d *Data) {
			stores(d)
			d.Restore.Point = "2026-10-03T05:05:00Z"
		},
		"restore source, no new name": func(d *Data) {
			stores(d)
			d.Restore = Restore{Point: "20261003T050500Z", Postgres: RestorePostgres{Source: "postgres"}}
		},
		"restore into its own source": func(d *Data) {
			stores(d)
			d.PostgresServerName = "postgres"
			d.Restore = Restore{Point: "20261003T050500Z", Postgres: RestorePostgres{Source: "postgres"}}
		},
		"target time not UTC": func(d *Data) {
			stores(d)
			d.PostgresServerName = "postgres-20261004T101500Z"
			d.Restore = Restore{Point: "20261003T050500Z", Postgres: RestorePostgres{Source: "postgres", TargetTime: "2026-10-03T05:17:00+02:00"}}
		},
		"target time, no source": func(d *Data) {
			stores(d)
			d.Restore = Restore{Point: "20261003T050500Z", Postgres: RestorePostgres{TargetTime: "2026-10-03T05:17:00Z"}}
		},
		"postgres without a point": func(d *Data) { stores(d); d.Restore.Postgres.Source = "postgres" },
	} {
		d := base
		mutate(&d)
		if err := validate(d); err == nil {
			t.Errorf("%s: validated", name)
		}
	}
}
