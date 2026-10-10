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
		"cloud":               func(d *Data) { d.Cloud = "azure" },
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
	// INFRARED_BACKUP's prefix, when the install sets one.
	if err := bf.Set(`{"bucket": "acme-google-backup", "provider": "gcs"}`); err != nil || b != (BackupTarget{Bucket: "acme-google-backup", Provider: "gcs"}) {
		t.Errorf("-backup with a provider: %v, %+v", err, b)
	}
	if err := bf.Set(`{"bucket": "acme-backups", "prefix": "acme-mgmt"}`); err != nil || b != (BackupTarget{Bucket: "acme-backups", Prefix: "acme-mgmt"}) {
		t.Errorf("-backup with a prefix loaded %+v, %v", b, err)
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

// The copies, Postgres's archive, Zot's retention and a restore load through
// their flags (camelCase keys), refuse an unknown field, and an empty flag is
// the zero value.
func TestCopiesRetentionRestoreFlags(t *testing.T) {
	var c Copies
	cf := jsonFlag[Copies]{&c, "copies"}
	if err := cf.Set(`{"recipients": ["age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p"],
		"mirror": {"schedule": "17 * * * *", "retention": "7d"}}`); err != nil {
		t.Fatal(err)
	}
	if len(c.Recipients) != 1 || c.Mirror != (CopySchedule{Schedule: "17 * * * *", Retention: "7d"}) {
		t.Errorf("-copies loaded %+v", c)
	}
	// The staging copies and Postgres's schedule are gone from Copies.
	for _, bad := range []string{`{"recipient": []}`, `{"mirror": {"when": "x"}}`, `{"objects": {"schedule": "5 * * * *"}}`,
		`{"gitea": {"schedule": "10 * * * *"}}`, `{"postgres": {"schedule": "0 0 3 * * *"}}`, `{} {}`} {
		if err := cf.Set(bad); err == nil {
			t.Errorf("-copies took %s", bad)
		}
	}
	if err := cf.Set(""); err != nil || c.Recipients != nil || c.Mirror != (CopySchedule{}) {
		t.Errorf("-copies '' = %+v, %v; want the zero value", c, err)
	}
	var a PostgresArchive
	af := jsonFlag[PostgresArchive]{&a, "postgres-archive"}
	if err := af.Set(`{"enabled": true, "schedule": "0 30 2 * * *", "retention": "14d"}`); err != nil {
		t.Fatal(err)
	}
	if a != (PostgresArchive{Enabled: true, Schedule: "0 30 2 * * *", Retention: "14d"}) {
		t.Errorf("-postgres-archive loaded %+v", a)
	}
	if err := af.Set(`{"archive": true}`); err == nil {
		t.Error("-postgres-archive took an unknown field")
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
	if err := xf.Set(`{"point": "20261006T010500Z", "artifact": "20261006T010500Z.irbackup", "mirrorRun": "20261006T011700Z"}`); err != nil {
		t.Fatal(err)
	}
	if x != (Restore{Point: "20261006T010500Z", Artifact: "20261006T010500Z.irbackup", MirrorRun: "20261006T011700Z"}) {
		t.Errorf("-restore loaded %+v", x)
	}
	if got := xf.String(); !strings.Contains(got, `"Point":"20261006T010500Z"`) {
		t.Errorf("-restore's String is %s", got)
	}
	// A restore's Postgres no longer comes from an archive.
	if err := xf.Set(`{"point": "20261006T010500Z", "postgres": {"source": "postgres"}}`); err == nil {
		t.Error("-restore took the archive's source")
	}
}

// The new fields load from the operator's Data JSON by their Go names, the
// backup's prefix and credentials among them.
func TestDataFileCopiesFields(t *testing.T) {
	path := filepath.Join(t.TempDir(), "data.json")
	body := `{"clusterName": "c1", "Copies": {"Recipients": ["age1x"], "Mirror": {"Schedule": "17 * * * *"}},
		"Backup": {"Bucket": "acme-backups", "Prefix": "acme-mgmt", "Credentials": {"Secret": "infrared-platform-tokens",
			"AccessKeyIDKey": "backup-access-key-id", "SecretKeyKey": "backup-secret-access-key", "Kind": "accessKey"}},
		"PostgresArchive": {"Enabled": true, "Retention": "7d"},
		"RegistryRetention": {"KeepNewest": 5},
		"Restore": {"Point": "20261006T010500Z", "Artifact": "20261006T010500Z.irbackup", "MirrorRun": "20261006T011700Z"},
		"PostgresServerName": "postgres-20261003T060000Z"}`
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	var d Data
	if err := mergeDataFile(&d, path); err != nil {
		t.Fatal(err)
	}
	if len(d.Copies.Recipients) != 1 || d.Copies.Mirror.Schedule != "17 * * * *" || d.RegistryRetention.KeepNewest != 5 ||
		d.Backup.Prefix != "acme-mgmt" || d.Backup.Credentials.Kind != "accessKey" ||
		d.PostgresArchive != (PostgresArchive{Enabled: true, Retention: "7d"}) ||
		d.Restore != (Restore{Point: "20261006T010500Z", Artifact: "20261006T010500Z.irbackup", MirrorRun: "20261006T011700Z"}) ||
		d.PostgresServerName != "postgres-20261003T060000Z" {
		t.Errorf("loaded Copies %+v, Backup %+v, PostgresArchive %+v, RegistryRetention %+v, Restore %+v, PostgresServerName %q",
			d.Copies, d.Backup, d.PostgresArchive, d.RegistryRetention, d.Restore, d.PostgresServerName)
	}
	for _, old := range []string{`{"Copies": {"Postgres": {"Schedule": "0 0 3 * * *"}}}`, `{"Copies": {"Objects": {}}}`,
		`{"Restore": {"Postgres": {"Source": "postgres"}}}`} {
		if err := os.WriteFile(path, []byte(old), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := mergeDataFile(&Data{}, path); err == nil {
			t.Errorf("a field that is gone loaded: %s", old)
		}
	}
}

func TestValidateCopiesRetentionRestore(t *testing.T) {
	base := Data{ClusterName: "c1", ClusterFlavor: "k3s", GitopsRepoURL: "https://github.com/acme/gitops",
		DefaultBranch: "main", InfraredChartRepo: "ghcr.io/darkshiftio/charts", InfraredChartVersion: "0.1.0",
		InfraredNamespace: "infrared", TemplateVersion: "v0.1.0"}
	const recipient = "age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p"
	stores := func(d *Data) { d.Stores, d.Backup = true, BackupTarget{Bucket: "acme-backups"} }
	for name, mutate := range map[string]func(*Data){
		"every setting": func(d *Data) {
			d.Copies = Copies{Recipients: []string{recipient}, Mirror: CopySchedule{"*/30 * * * *", "10d"}}
			d.PostgresArchive = PostgresArchive{Enabled: true, Schedule: "0 30 2 * * *", Retention: "365d"}
		},
		"retention": func(d *Data) {
			d.RegistryRetention = RegistryRetention{UntaggedAfter: "1h30m", KeepTags: []string{`^v\d+`, "^release-"}, KeepNewest: 1000, GCInterval: "2h", GCDelay: "30m"}
		},
		"server name": func(d *Data) { d.PostgresServerName = "postgres-20261003T060000Z" },
		"prefix":      func(d *Data) { stores(d); d.Backup.Prefix = "acme-mgmt.2" },
		// The operator sends day one's credential explicitly.
		"credentials, explicit": func(d *Data) {
			stores(d)
			d.Backup.Credentials = BackupCredentials{Secret: "infrared-platform-tokens", AccessKeyIDKey: "backup-access-key-id",
				SecretKeyKey: "backup-secret-access-key", Kind: "accessKey"}
		},
		"restore": func(d *Data) {
			stores(d)
			d.Restore = Restore{Point: "20261006T010500Z", Artifact: "20261006T010500Z.irbackup", MirrorRun: "20261006T011700Z"}
		},
		"restore, the artifact under its path": func(d *Data) {
			stores(d)
			d.Restore = Restore{Point: "20261006T010500Z", Artifact: "lke-tmp1/backups/20261006T010500Z.irbackup"}
		},
		"restore, the point alone": func(d *Data) { stores(d); d.Restore = Restore{Point: "20261006T010500Z"} },
		// Google Cloud Storage: no key; the endpoint and the kind may be given or left empty.
		"gcs": func(d *Data) {
			stores(d)
			d.Backup = BackupTarget{Bucket: "acme-google-backup", Provider: "gcs", Endpoint: "https://storage.googleapis.com", Region: "us-central1",
				Prefix: "acme-mgmt", Credentials: BackupCredentials{Kind: "serviceAccount"}}
		},
		"gcs, the provider alone": func(d *Data) { stores(d); d.Backup = BackupTarget{Bucket: "acme-google-backup", Provider: "gcs"} },
		"gcs, the operator's key names along": func(d *Data) {
			stores(d)
			d.Backup = BackupTarget{Bucket: "acme-google-backup", Provider: "gcs", Credentials: BackupCredentials{
				AccessKeyIDKey: "backup-access-key-id", SecretKeyKey: "backup-secret-access-key", Kind: "serviceAccount"}}
		},
		"linode, spelled out": func(d *Data) {
			stores(d)
			d.Backup = BackupTarget{Bucket: "acme-backups", Provider: "linode", Endpoint: "https://us-east-1.linodeobjects.com", Region: "us-east-1",
				Credentials: BackupCredentials{Kind: "accessKey"}}
		},
	} {
		d := base
		mutate(&d)
		if err := validate(d); err != nil {
			t.Errorf("%s: %v", name, err)
		}
	}
	for name, mutate := range map[string]func(*Data){
		"five-field Postgres schedule": func(d *Data) { d.PostgresArchive.Schedule = "0 3 * * *" },
		"six-field mirror schedule":    func(d *Data) { d.Copies.Mirror.Schedule = "0 17 * * * *" },
		"retention in hours":           func(d *Data) { d.Copies.Mirror.Retention = "168h" },
		"retention of 0 days":          func(d *Data) { d.PostgresArchive.Retention = "0d" },
		"an SSH key as recipient":      func(d *Data) { d.Copies.Recipients = []string{"ssh-ed25519 AAAA"} },
		"recipient twice":              func(d *Data) { d.Copies.Recipients = []string{recipient, recipient} },
		"retention in days":            func(d *Data) { d.RegistryRetention.UntaggedAfter = "1d" },
		"a tag pattern that breaks":    func(d *Data) { d.RegistryRetention.KeepTags = []string{"^v[0-9"} },
		"a tag pattern not ASCII":      func(d *Data) { d.RegistryRetention.KeepTags = []string{"^vé"} },
		"keep newest negative":         func(d *Data) { d.RegistryRetention.KeepNewest = -1 },
		"server name upper case":       func(d *Data) { d.PostgresServerName = "Postgres" },
		"server name with a slash":     func(d *Data) { d.PostgresServerName = "postgres/x" },
		"prefix without a bucket":      func(d *Data) { d.Backup.Prefix = "acme" },
		"prefix with a slash":          func(d *Data) { stores(d); d.Backup.Prefix = "acme/mgmt" },
		"prefix upper case":            func(d *Data) { stores(d); d.Backup.Prefix = "Acme" },
		"credentials of another Secret": func(d *Data) {
			stores(d)
			d.Backup.Credentials.Secret = "acme-backup-key"
		},
		"credentials of another kind": func(d *Data) { stores(d); d.Backup.Credentials.Kind = "role" },
		"a key name with a space":     func(d *Data) { stores(d); d.Backup.Credentials.AccessKeyIDKey = "access key" },
		"credentials without a bucket": func(d *Data) {
			d.Backup.Credentials = BackupCredentials{Kind: "accessKey"}
		},
		"restore without stores": func(d *Data) { d.Restore.Point = "20261006T010500Z" },
		"restore point not a stamp": func(d *Data) {
			stores(d)
			d.Restore.Point = "2026-10-06T01:05:00Z"
		},
		"an artifact without a point":  func(d *Data) { stores(d); d.Restore.Artifact = "20261006T010500Z.irbackup" },
		"a mirror run without a point": func(d *Data) { stores(d); d.Restore.MirrorRun = "20261006T011700Z" },
		"another point's artifact": func(d *Data) {
			stores(d)
			d.Restore = Restore{Point: "20261006T010500Z", Artifact: "20261006T000500Z.irbackup"}
		},
		"an artifact of format 1": func(d *Data) {
			stores(d)
			d.Restore = Restore{Point: "20261006T010500Z", Artifact: "20261006T010500Z.tar.gz.age"}
		},
		"a mirror run before the point": func(d *Data) {
			stores(d)
			d.Restore = Restore{Point: "20261006T010500Z", MirrorRun: "20261006T001700Z"}
		},
		"a provider nobody offers": func(d *Data) { stores(d); d.Backup.Provider = "azure" },
		"gcs with a key":           func(d *Data) { stores(d); d.Backup.Provider = "gcs"; d.Backup.Credentials.Kind = "accessKey" },
		"gcs with another endpoint": func(d *Data) {
			stores(d)
			d.Backup.Provider, d.Backup.Endpoint = "gcs", "https://objects.example.com"
		},
		"gcs with the WAL archive": func(d *Data) {
			stores(d)
			d.Backup.Provider, d.PostgresArchive.Enabled = "gcs", true
		},
		"linode with a service account": func(d *Data) {
			stores(d)
			d.Backup.Provider, d.Backup.Credentials.Kind = "linode", "serviceAccount"
		},
		"a service account without gcs": func(d *Data) { stores(d); d.Backup.Credentials.Kind = "serviceAccount" },
	} {
		d := base
		mutate(&d)
		if err := validate(d); err == nil {
			t.Errorf("%s: validated", name)
		}
	}
}

// The registry token and Substrate's registry load from the operator's Data by
// their Go names and from their flags, and validate together: the token needs
// a Google service account, a registry host and the pull secret it writes.
func TestRegistryTokenAndSubstrateRegistry(t *testing.T) {
	path := filepath.Join(t.TempDir(), "data.json")
	body := `{"clusterName": "c1", "imagePullSecret": "registry-token",
		"SubstrateRegistry": "us-central1-docker.pkg.dev/acme/infrared/substrate",
		"RegistryToken": {"GCPServiceAccount": "registry-reader@acme-preprod.iam.gserviceaccount.com", "Registry": "us-central1-docker.pkg.dev"}}`
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	var d Data
	if err := mergeDataFile(&d, path); err != nil {
		t.Fatal(err)
	}
	want := RegistryToken{GCPServiceAccount: "registry-reader@acme-preprod.iam.gserviceaccount.com", Registry: "us-central1-docker.pkg.dev"}
	awsWant := RegistryToken{AWSRegion: "us-east-1", Registry: "123456789012.dkr.ecr.us-east-1.amazonaws.com"}
	if d.SubstrateRegistry != "us-central1-docker.pkg.dev/acme/infrared/substrate" || d.RegistryToken != want {
		t.Errorf("loaded SubstrateRegistry %q, RegistryToken %+v", d.SubstrateRegistry, d.RegistryToken)
	}
	var tok RegistryToken
	tf := jsonFlag[RegistryToken]{&tok, "registry-token"}
	if err := tf.Set(`{"gcpServiceAccount": "registry-reader@acme-preprod.iam.gserviceaccount.com", "registry": "us-central1-docker.pkg.dev"}`); err != nil || tok != want {
		t.Errorf("-registry-token loaded %+v, %v", tok, err)
	}
	var awsTok RegistryToken
	if err := (jsonFlag[RegistryToken]{&awsTok, "registry-token"}).Set(`{"awsRegion": "us-east-1", "registry": "123456789012.dkr.ecr.us-east-1.amazonaws.com"}`); err != nil || awsTok != awsWant {
		t.Errorf("-registry-token loaded the AWS form as %+v, %v", awsTok, err)
	}
	var ec2Tok RegistryToken
	if err := (jsonFlag[RegistryToken]{&ec2Tok, "registry-token"}).Set(`{"awsRegion": "us-east-1", "awsHostNetwork": true, "registry": "123456789012.dkr.ecr.us-east-1.amazonaws.com"}`); err != nil || !ec2Tok.AWSHostNetwork || ec2Tok.AWSRegion != "us-east-1" {
		t.Errorf("-registry-token loaded the EC2 form as %+v, %v", ec2Tok, err)
	}
	if err := tf.Set(`{"serviceAccount": "x"}`); err == nil {
		t.Error("-registry-token took an unknown field")
	}

	base := Data{ClusterName: "c1", ClusterFlavor: "k3s", GitopsRepoURL: "https://github.com/acme/gitops",
		DefaultBranch: "main", InfraredChartRepo: "us-central1-docker.pkg.dev/acme/infrared/charts", InfraredChartVersion: "0.1.0",
		InfraredNamespace: "infrared", TemplateVersion: "v0.1.0"}
	for name, mutate := range map[string]func(*Data){
		"none":               func(*Data) {},
		"substrate registry": func(d *Data) { d.SubstrateRegistry = "us-central1-docker.pkg.dev/acme/infrared/substrate" },
		"a registry with a port": func(d *Data) {
			d.SubstrateRegistry = "registry.example.com:5000/substrate"
		},
		"token":     func(d *Data) { d.ImagePullSecret, d.RegistryToken = "registry-token", want },
		"aws token": func(d *Data) { d.ImagePullSecret, d.RegistryToken = "registry-token", awsWant },
		"aws token with an IRSA role": func(d *Data) {
			d.ImagePullSecret, d.RegistryToken = "registry-token", awsWant
			d.RegistryToken.AWSRoleARN = "arn:aws:iam::123456789012:role/infrared-registry-token"
		},
		"aws token on the node's network": func(d *Data) {
			d.ImagePullSecret, d.RegistryToken = "registry-token", awsWant
			d.RegistryToken.AWSHostNetwork = true
		},
	} {
		d := base
		mutate(&d)
		if err := validate(d); err != nil {
			t.Errorf("%s: %v", name, err)
		}
	}
	for name, mutate := range map[string]func(*Data){
		"substrate registry with a scheme": func(d *Data) { d.SubstrateRegistry = "https://ghcr.io/acme/substrate" },
		"substrate registry with a slash":  func(d *Data) { d.SubstrateRegistry = "ghcr.io/acme/substrate/" },
		"substrate registry with a tag":    func(d *Data) { d.SubstrateRegistry = "ghcr.io/acme/substrate:v1" },
		"substrate registry, a host alone": func(d *Data) { d.SubstrateRegistry = "ghcr.io" },
		"token without a pull secret":      func(d *Data) { d.RegistryToken = want },
		"token without a registry": func(d *Data) {
			d.ImagePullSecret, d.RegistryToken = "registry-token", RegistryToken{GCPServiceAccount: want.GCPServiceAccount}
		},
		"token without a service account": func(d *Data) {
			d.ImagePullSecret, d.RegistryToken = "registry-token", RegistryToken{Registry: want.Registry}
		},
		"token with a registry path": func(d *Data) {
			d.ImagePullSecret, d.RegistryToken = "registry-token", RegistryToken{GCPServiceAccount: want.GCPServiceAccount, Registry: "us-central1-docker.pkg.dev/acme"}
		},
		"aws token with a Google service account too": func(d *Data) {
			d.ImagePullSecret, d.RegistryToken = "registry-token", awsWant
			d.RegistryToken.GCPServiceAccount = want.GCPServiceAccount
		},
		"aws token for Artifact Registry": func(d *Data) {
			d.ImagePullSecret, d.RegistryToken = "registry-token", RegistryToken{AWSRegion: "us-east-1", Registry: want.Registry}
		},
		"aws token for ECR in another region": func(d *Data) {
			d.ImagePullSecret, d.RegistryToken = "registry-token", RegistryToken{AWSRegion: "us-west-2", Registry: awsWant.Registry}
		},
		"aws token without a region": func(d *Data) {
			d.ImagePullSecret, d.RegistryToken = "registry-token", RegistryToken{AWSRoleARN: "arn:aws:iam::123456789012:role/r", Registry: awsWant.Registry}
		},
		"aws token with a user, not a role": func(d *Data) {
			d.ImagePullSecret, d.RegistryToken = "registry-token", awsWant
			d.RegistryToken.AWSRoleARN = "arn:aws:iam::123456789012:user/someone"
		},
		"aws token without a pull secret": func(d *Data) { d.RegistryToken = awsWant },
		"host network without a region": func(d *Data) {
			d.ImagePullSecret, d.RegistryToken = "registry-token", RegistryToken{AWSHostNetwork: true, Registry: awsWant.Registry}
		},
		"Google token with host network": func(d *Data) {
			d.ImagePullSecret, d.RegistryToken = "registry-token", want
			d.RegistryToken.AWSHostNetwork = true
		},
		"token for a user, not a service account": func(d *Data) {
			d.ImagePullSecret, d.RegistryToken = "registry-token", RegistryToken{GCPServiceAccount: "someone@example.com", Registry: want.Registry}
		},
	} {
		d := base
		mutate(&d)
		if err := validate(d); err == nil {
			t.Errorf("%s: validated", name)
		}
	}
}

func TestValidateCloudIdentity(t *testing.T) {
	gsa := "infrared-cloud@acme-preprod.iam.gserviceaccount.com"
	role := "arn:aws:iam::123456789012:role/infrared-cloud"
	for _, tc := range []struct {
		name string
		c    *CloudIdentity
		ok   bool
	}{
		{"none", nil, true},
		{"google", &CloudIdentity{GCPServiceAccount: gsa}, true},
		{"google and web identity", &CloudIdentity{GCPServiceAccount: gsa, AWSWebIdentity: true}, true},
		{"irsa", &CloudIdentity{AWSRoleARN: role}, true},
		{"host network", &CloudIdentity{AWSHostNetwork: true}, true},
		{"empty", &CloudIdentity{}, false},
		{"two aws modes", &CloudIdentity{AWSRoleARN: role, AWSHostNetwork: true}, false},
		{"bad google account", &CloudIdentity{GCPServiceAccount: "nobody@example.com"}, false},
		{"bad role", &CloudIdentity{AWSRoleARN: "arn:aws:iam::1:user/x"}, false},
	} {
		if errs := validateCloudIdentity(tc.c); (len(errs) == 0) != tc.ok {
			t.Errorf("%s: errors %v, want ok=%v", tc.name, errs, tc.ok)
		}
	}
}
