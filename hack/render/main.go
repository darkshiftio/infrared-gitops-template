// Command render renders template/ into a gitops repo tree, implementing
// exactly the contract the Infrared operator implements (see README.md,
// "The rendering contract"):
//
//   - every file under template/ is rendered;
//   - a file ending in .tmpl is a Go text/template with delimiters [[ and ]],
//     executed with Data and missingkey=error, and written without the .tmpl
//     suffix; beyond text/template's builtins only Funcs exist (the operator's
//     exact helper set);
//   - every other file is copied byte for byte;
//   - any path segment exactly equal to __cluster__ becomes Data.ClusterName.
//
// It is stdlib only, so it runs anywhere Go does, with no module download.
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io/fs"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"text/template"
)

// Data is the value every .tmpl file is executed against. encoding/json matches
// field names case-insensitively, so a -data file written with Go names or
// with the operator's camelCase names (clusterName, buildRegistry, ...) loads
// the same.
type Data struct {
	ClusterName          string `json:"ClusterName"`
	ClusterFlavor        string `json:"ClusterFlavor"` // "k3s" | "eks"
	Region               string `json:"Region"`
	OrgName              string `json:"OrgName"`
	GitopsRepoURL        string `json:"GitopsRepoURL"`
	GitopsRepoOwner      string `json:"GitopsRepoOwner"`
	GitopsRepoName       string `json:"GitopsRepoName"`
	DefaultBranch        string `json:"DefaultBranch"`
	TemplateVersion      string `json:"TemplateVersion"`
	InfraredVersion      string `json:"InfraredVersion"`
	InfraredChartRepo    string `json:"InfraredChartRepo"`
	InfraredChartVersion string `json:"InfraredChartVersion"`
	InfraredNamespace    string `json:"InfraredNamespace"`
	ImagePullSecret      string `json:"ImagePullSecret"`
	// BuildRegistry is the registry prefix product images are built into, e.g.
	// 123456789012.dkr.ecr.us-east-1.amazonaws.com/acme; empty leaves the
	// builds component out.
	BuildRegistry string `json:"buildRegistry"`

	// The fields below are the operator's, with JSON names equal to their Go
	// names. The zero value of each renders exactly what the template rendered
	// before it existed.

	// Edge is the Installation's spec.edge: "" or "traefik" (as before), or
	// "gateway", which turns on the edge components (Envoy Gateway, external-dns
	// and Cloudflare's origin issuer). "" means traefik.
	Edge string `json:"Edge"`
	// PlatformDomain is the Installation's spec.previews.domain, "" when unset.
	// In gateway mode zones answer at <zone>.<PlatformDomain>.
	PlatformDomain string `json:"PlatformDomain"`
	// InfraredHost is the host of the Installation's spec.previews.signInURL,
	// "" when unset. In gateway mode it is Infrared's own name.
	InfraredHost string `json:"InfraredHost"`
	// ImageRegistry is the registry of Infrared's own images (the operator's
	// INFRARED_IMAGE_REGISTRY), e.g. ghcr.io/darkshiftio; "" keeps the chart's.
	ImageRegistry string `json:"ImageRegistry"`
	// Images is each component's pin (INFRARED_IMAGES), keyed by operator, api,
	// ui, mcp and runner; empty keeps the chart's.
	Images map[string]ImageRef `json:"Images"`
	// Cloud is "", "aws" or "linode", from the nodes' providerID prefix.
	Cloud string `json:"Cloud"`
	// SubstrateCapable is the operator's preflight result; while it is false the
	// template leaves Substrate out.
	SubstrateCapable bool `json:"SubstrateCapable"`
	// Stores is the operator's INFRARED_STORES: true renders the platform's own
	// stores, CloudNativePG with one Postgres Cluster, and SeaweedFS.
	Stores bool `json:"Stores"`
	// Backup is the operator's INFRARED_BACKUP: the bucket outside the cluster
	// the stores are copied to. An empty Bucket turns backups off, and with
	// Stores false there is nothing to copy.
	Backup BackupTarget `json:"Backup"`
	// Disabled is the operator's INFRARED_DISABLED_COMPONENTS: the components,
	// by Application name, that the template leaves out.
	Disabled []string `json:"Disabled"`
}

// ImageRef is one component's image pin: Images["api"].Tag and .Digest.
type ImageRef struct {
	Tag    string `json:"Tag"`
	Digest string `json:"Digest"`
}

// BackupTarget is an S3-compatible bucket outside the cluster:
// Backup.Bucket, .Endpoint (empty for AWS S3) and .Region (may be empty).
type BackupTarget struct {
	Bucket   string `json:"Bucket"`
	Endpoint string `json:"Endpoint"`
	Region   string `json:"Region"`
}

// Required are the components the template always renders: Disabled may not
// name them.
var Required = []string{"appprojects", "argocd", "infrared"}

var (
	dnsLabel   = regexp.MustCompile(`^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$`)
	bucketName = regexp.MustCompile(`^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$`)
	regionName = regexp.MustCompile(`^[a-z0-9][a-z0-9-]*$`)
)

// backupFlag reads -backup: a JSON object {"bucket", "endpoint", "region"}, as
// the operator's INFRARED_BACKUP carries it.
type backupFlag struct{ b *BackupTarget }

func (f backupFlag) String() string {
	if f.b == nil || *f.b == (BackupTarget{}) {
		return ""
	}
	b, _ := json.Marshal(*f.b)
	return string(b)
}

func (f backupFlag) Set(s string) error {
	var b BackupTarget
	if strings.TrimSpace(s) != "" {
		dec := json.NewDecoder(strings.NewReader(s))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&b); err != nil {
			return fmt.Errorf("-backup: %w", err)
		}
	}
	*f.b = b
	return nil
}

// disabledFlag reads -disabled: a JSON array of component names, as the
// operator's INFRARED_DISABLED_COMPONENTS carries it.
type disabledFlag struct{ d *[]string }

func (f disabledFlag) String() string {
	if f.d == nil || len(*f.d) == 0 {
		return ""
	}
	b, _ := json.Marshal(*f.d)
	return string(b)
}

func (f disabledFlag) Set(s string) error {
	var d []string
	if strings.TrimSpace(s) != "" {
		if err := json.Unmarshal([]byte(s), &d); err != nil {
			return fmt.Errorf("-disabled: %w", err)
		}
	}
	*f.d = d
	return nil
}

// Edges and Clouds are the values Edge and Cloud may take.
var (
	Edges  = []string{"", "traefik", "gateway"}
	Clouds = []string{"", "aws", "linode"}
)

// imagesFlag reads -images: a JSON object of component to {"tag", "digest"},
// as the operator's INFRARED_IMAGES carries it.
type imagesFlag struct{ m *map[string]ImageRef }

func (f imagesFlag) String() string {
	if f.m == nil || len(*f.m) == 0 {
		return ""
	}
	b, _ := json.Marshal(*f.m)
	return string(b)
}

func (f imagesFlag) Set(s string) error {
	m := map[string]ImageRef{}
	if strings.TrimSpace(s) != "" {
		dec := json.NewDecoder(strings.NewReader(s))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&m); err != nil {
			return fmt.Errorf("-images: %w", err)
		}
	}
	*f.m = m
	return nil
}

// Funcs are the helpers templates may use beyond text/template's builtins.
// They mirror the operator's set (infrared-operator internal/gitopstemplate)
// exactly, arguments included: the needle comes first, so
// [[ if contains ".dkr.ecr." .BuildRegistry ]] reads naturally.
var Funcs = template.FuncMap{
	"lower":      strings.ToLower,
	"upper":      strings.ToUpper,
	"trimPrefix": func(prefix, s string) string { return strings.TrimPrefix(s, prefix) },
	"trimSuffix": func(suffix, s string) string { return strings.TrimSuffix(s, suffix) },
	"replace":    func(old, repl, s string) string { return strings.ReplaceAll(s, old, repl) },
	"contains":   func(sub, s string) bool { return strings.Contains(s, sub) },
	"hasPrefix":  func(prefix, s string) bool { return strings.HasPrefix(s, prefix) },
	"hasSuffix":  func(suffix, s string) bool { return strings.HasSuffix(s, suffix) },
	"quote":      func(s string) string { return fmt.Sprintf("%q", s) },
	"default": func(def, v string) string {
		if v == "" {
			return def
		}
		return v
	},
}

const (
	tmplSuffix     = ".tmpl"
	clusterSegment = "__cluster__"
)

func main() {
	var (
		d        Data
		src      string
		out      string
		dataFile string
	)
	flag.StringVar(&src, "template", "template", "template directory to render")
	flag.StringVar(&out, "out", "out", "output directory (created; must be empty or absent)")
	flag.StringVar(&dataFile, "data", "", "optional JSON file of Data; flags given explicitly override it")
	flag.StringVar(&d.ClusterName, "cluster", "demo", "ClusterName")
	flag.StringVar(&d.ClusterFlavor, "flavor", "k3s", `ClusterFlavor: "k3s" or "eks"`)
	flag.StringVar(&d.Region, "region", "us-east-1", "Region")
	flag.StringVar(&d.OrgName, "org", "demo-org", "OrgName")
	flag.StringVar(&d.GitopsRepoOwner, "repo-owner", "demo-org", "GitopsRepoOwner")
	flag.StringVar(&d.GitopsRepoName, "repo-name", "gitops", "GitopsRepoName")
	flag.StringVar(&d.GitopsRepoURL, "repo-url", "", "GitopsRepoURL (default https://github.com/<repo-owner>/<repo-name>.git)")
	flag.StringVar(&d.DefaultBranch, "branch", "main", "DefaultBranch")
	flag.StringVar(&d.TemplateVersion, "template-version", "v0.1.0", "TemplateVersion")
	flag.StringVar(&d.InfraredVersion, "infrared-version", "v0.1.0", "InfraredVersion")
	flag.StringVar(&d.InfraredChartRepo, "chart-repo", "ghcr.io/darkshiftio/charts", "InfraredChartRepo (no oci:// prefix)")
	flag.StringVar(&d.InfraredChartVersion, "chart-version", "0.1.0", "InfraredChartVersion")
	flag.StringVar(&d.InfraredNamespace, "namespace", "infrared", "InfraredNamespace")
	flag.StringVar(&d.ImagePullSecret, "pull-secret", "", "ImagePullSecret (empty for none)")
	flag.StringVar(&d.BuildRegistry, "build-registry", os.Getenv("INFRARED_BUILD_REGISTRY"),
		"BuildRegistry, the registry prefix product images are built into (default $INFRARED_BUILD_REGISTRY; empty leaves builds out)")
	flag.StringVar(&d.Edge, "edge", "", `Edge: "", "traefik" (both as before) or "gateway" (Envoy Gateway, external-dns, origin issuer)`)
	flag.StringVar(&d.PlatformDomain, "platform-domain", "", "PlatformDomain: zones answer at <zone>.<domain> in gateway mode (empty for none)")
	flag.StringVar(&d.InfraredHost, "infrared-host", "", "InfraredHost: Infrared's own name in gateway mode, the sign-in URL's host (empty for none)")
	flag.StringVar(&d.ImageRegistry, "image-registry", "", "ImageRegistry: the registry of Infrared's images, e.g. ghcr.io/darkshiftio (empty keeps the chart's)")
	flag.Var(imagesFlag{&d.Images}, "images", `Images, as JSON: {"api": {"tag": "v1.2.3", "digest": "sha256:..."}, ...} (empty keeps the chart's)`)
	flag.StringVar(&d.Cloud, "cloud", "", `Cloud: "", "aws" or "linode"`)
	flag.BoolVar(&d.SubstrateCapable, "substrate-capable", false, "SubstrateCapable: the preflight's result")
	flag.BoolVar(&d.Stores, "stores", false, "Stores: the platform's own Postgres and SeaweedFS")
	flag.Var(backupFlag{&d.Backup}, "backup", `Backup, as JSON: {"bucket": "...", "endpoint": "https://...", "region": "..."} (empty: no backups)`)
	flag.Var(disabledFlag{&d.Disabled}, "disabled", `Disabled, as a JSON array of component names: ["infisical"] (empty: none)`)
	flag.Parse()

	if dataFile != "" {
		if err := mergeDataFile(&d, dataFile); err != nil {
			fatal(err)
		}
	}
	if d.GitopsRepoURL == "" {
		d.GitopsRepoURL = fmt.Sprintf("https://github.com/%s/%s.git", d.GitopsRepoOwner, d.GitopsRepoName)
	}
	if err := validate(d); err != nil {
		fatal(err)
	}
	n, err := Render(src, out, d)
	if err != nil {
		fatal(err)
	}
	fmt.Printf("rendered %d files from %s into %s (cluster %s, flavor %s, build registry %q, edge %q, stores %t, backup bucket %q, disabled %q)\n",
		n, src, out, d.ClusterName, d.ClusterFlavor, d.BuildRegistry, d.Edge, d.Stores, d.Backup.Bucket, d.Disabled)
}

// mergeDataFile loads a JSON Data file, then re-applies every flag the user set
// explicitly, so flags win.
func mergeDataFile(d *Data, path string) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	set := map[string]bool{}
	flag.Visit(func(f *flag.Flag) { set[f.Name] = true })
	explicit := *d
	var fromFile Data
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&fromFile); err != nil {
		return fmt.Errorf("%s: %w", path, err)
	}
	*d = fromFile
	overrides := map[string]func(){
		"cluster":           func() { d.ClusterName = explicit.ClusterName },
		"flavor":            func() { d.ClusterFlavor = explicit.ClusterFlavor },
		"region":            func() { d.Region = explicit.Region },
		"org":               func() { d.OrgName = explicit.OrgName },
		"repo-owner":        func() { d.GitopsRepoOwner = explicit.GitopsRepoOwner },
		"repo-name":         func() { d.GitopsRepoName = explicit.GitopsRepoName },
		"repo-url":          func() { d.GitopsRepoURL = explicit.GitopsRepoURL },
		"branch":            func() { d.DefaultBranch = explicit.DefaultBranch },
		"template-version":  func() { d.TemplateVersion = explicit.TemplateVersion },
		"infrared-version":  func() { d.InfraredVersion = explicit.InfraredVersion },
		"chart-repo":        func() { d.InfraredChartRepo = explicit.InfraredChartRepo },
		"chart-version":     func() { d.InfraredChartVersion = explicit.InfraredChartVersion },
		"namespace":         func() { d.InfraredNamespace = explicit.InfraredNamespace },
		"pull-secret":       func() { d.ImagePullSecret = explicit.ImagePullSecret },
		"build-registry":    func() { d.BuildRegistry = explicit.BuildRegistry },
		"edge":              func() { d.Edge = explicit.Edge },
		"platform-domain":   func() { d.PlatformDomain = explicit.PlatformDomain },
		"infrared-host":     func() { d.InfraredHost = explicit.InfraredHost },
		"image-registry":    func() { d.ImageRegistry = explicit.ImageRegistry },
		"images":            func() { d.Images = explicit.Images },
		"cloud":             func() { d.Cloud = explicit.Cloud },
		"substrate-capable": func() { d.SubstrateCapable = explicit.SubstrateCapable },
		"stores":            func() { d.Stores = explicit.Stores },
		"backup":            func() { d.Backup = explicit.Backup },
		"disabled":          func() { d.Disabled = explicit.Disabled },
	}
	for name, apply := range overrides {
		if set[name] {
			apply()
		}
	}
	return nil
}

func validate(d Data) error {
	var errs []error
	if d.ClusterFlavor != "k3s" && d.ClusterFlavor != "eks" {
		errs = append(errs, fmt.Errorf("ClusterFlavor must be k3s or eks, got %q", d.ClusterFlavor))
	}
	for name, v := range map[string]string{
		"ClusterName": d.ClusterName, "GitopsRepoURL": d.GitopsRepoURL, "DefaultBranch": d.DefaultBranch,
		"InfraredChartRepo": d.InfraredChartRepo, "InfraredChartVersion": d.InfraredChartVersion,
		"InfraredNamespace": d.InfraredNamespace, "TemplateVersion": d.TemplateVersion,
	} {
		if v == "" {
			errs = append(errs, fmt.Errorf("%s must not be empty", name))
		}
	}
	if strings.HasPrefix(d.InfraredChartRepo, "oci://") {
		errs = append(errs, errors.New("InfraredChartRepo must not carry oci:// (Argo CD OCI helm repos take the bare host/path)"))
	}
	if !slices.Contains(Edges, d.Edge) {
		errs = append(errs, fmt.Errorf("Edge must be one of %q, got %q", Edges, d.Edge))
	}
	if !slices.Contains(Clouds, d.Cloud) {
		errs = append(errs, fmt.Errorf("Cloud must be one of %q, got %q", Clouds, d.Cloud))
	}
	for name, v := range map[string]string{"PlatformDomain": d.PlatformDomain, "InfraredHost": d.InfraredHost} {
		if strings.ContainsAny(v, "/: *") || strings.HasPrefix(v, ".") || strings.HasSuffix(v, ".") {
			errs = append(errs, fmt.Errorf("%s must be a bare DNS name, got %q", name, v))
		}
	}
	for _, name := range d.Disabled {
		switch {
		case !dnsLabel.MatchString(name):
			errs = append(errs, fmt.Errorf("Disabled names components by their Application name, got %q", name))
		case slices.Contains(Required, name):
			errs = append(errs, fmt.Errorf("Disabled cannot name %q: the template always renders %q", name, Required))
		}
	}
	errs = append(errs, validateBackup(d.Backup)...)
	return errors.Join(errs...)
}

// validateBackup checks the shape of each Backup field that is set; an empty
// Bucket turns backups off, so the other two need one.
func validateBackup(b BackupTarget) []error {
	var errs []error
	if b.Bucket == "" {
		if b.Endpoint != "" || b.Region != "" {
			errs = append(errs, errors.New("Backup.Endpoint and Backup.Region need a Backup.Bucket"))
		}
		return errs
	}
	if !bucketName.MatchString(b.Bucket) || strings.Contains(b.Bucket, "..") {
		errs = append(errs, fmt.Errorf("Backup.Bucket must be an S3 bucket name, got %q", b.Bucket))
	}
	if b.Endpoint != "" {
		u, err := url.Parse(b.Endpoint)
		if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" ||
			strings.TrimSuffix(u.Path, "/") != "" || u.RawQuery != "" || u.Fragment != "" || u.User != nil {
			errs = append(errs, fmt.Errorf("Backup.Endpoint must be an http(s) URL with a host and nothing after it, got %q", b.Endpoint))
		}
	}
	if b.Region != "" && !regionName.MatchString(b.Region) {
		errs = append(errs, fmt.Errorf("Backup.Region must be a region name such as us-east-1, got %q", b.Region))
	}
	return errs
}

// OutputPath maps a slash-separated path relative to template/ to its output
// path: each segment equal to __cluster__ becomes the cluster name, and a
// trailing .tmpl is stripped.
func OutputPath(rel, cluster string) string {
	segs := strings.Split(rel, "/")
	for i, s := range segs {
		if s == clusterSegment {
			segs[i] = cluster
		}
	}
	return strings.TrimSuffix(strings.Join(segs, "/"), tmplSuffix)
}

// Render renders every file under src into out and returns how many files it
// wrote.
func Render(src, out string, d Data) (int, error) {
	if entries, err := os.ReadDir(out); err == nil && len(entries) > 0 {
		return 0, fmt.Errorf("output directory %s is not empty", out)
	}
	count := 0
	err := filepath.WalkDir(src, func(path string, e fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if e.IsDir() {
			return nil
		}
		if !e.Type().IsRegular() {
			return fmt.Errorf("%s: only regular files are allowed in the template", path)
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		rel = filepath.ToSlash(rel)
		info, err := e.Info()
		if err != nil {
			return err
		}
		content, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if strings.HasSuffix(rel, tmplSuffix) {
			t, err := template.New(rel).Delims("[[", "]]").Funcs(Funcs).Option("missingkey=error").Parse(string(content))
			if err != nil {
				return err
			}
			var buf bytes.Buffer
			if err := t.Execute(&buf, d); err != nil {
				return err
			}
			content = buf.Bytes()
		}
		dst := filepath.Join(out, filepath.FromSlash(OutputPath(rel, d.ClusterName)))
		if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(dst, content, info.Mode().Perm()); err != nil {
			return err
		}
		count++
		return nil
	})
	return count, err
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "render:", err)
	os.Exit(1)
}
