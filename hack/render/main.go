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
	"os"
	"path/filepath"
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
	fmt.Printf("rendered %d files from %s into %s (cluster %s, flavor %s, build registry %q)\n", n, src, out, d.ClusterName, d.ClusterFlavor, d.BuildRegistry)
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
		"cluster":          func() { d.ClusterName = explicit.ClusterName },
		"flavor":           func() { d.ClusterFlavor = explicit.ClusterFlavor },
		"region":           func() { d.Region = explicit.Region },
		"org":              func() { d.OrgName = explicit.OrgName },
		"repo-owner":       func() { d.GitopsRepoOwner = explicit.GitopsRepoOwner },
		"repo-name":        func() { d.GitopsRepoName = explicit.GitopsRepoName },
		"repo-url":         func() { d.GitopsRepoURL = explicit.GitopsRepoURL },
		"branch":           func() { d.DefaultBranch = explicit.DefaultBranch },
		"template-version": func() { d.TemplateVersion = explicit.TemplateVersion },
		"infrared-version": func() { d.InfraredVersion = explicit.InfraredVersion },
		"chart-repo":       func() { d.InfraredChartRepo = explicit.InfraredChartRepo },
		"chart-version":    func() { d.InfraredChartVersion = explicit.InfraredChartVersion },
		"namespace":        func() { d.InfraredNamespace = explicit.InfraredNamespace },
		"pull-secret":      func() { d.ImagePullSecret = explicit.ImagePullSecret },
		"build-registry":   func() { d.BuildRegistry = explicit.BuildRegistry },
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
	return errors.Join(errs...)
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
