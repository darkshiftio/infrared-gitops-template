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
	"net"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
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
	// Backup is the destination of the install's backups, outside the cluster:
	// the Installation's spec.backup.destination, which the operator seeds from
	// the chart's INFRARED_BACKUP. An empty Bucket turns backups off, and with
	// Stores false there is nothing to copy.
	Backup BackupTarget `json:"Backup"`
	// Disabled is the operator's INFRARED_DISABLED_COMPONENTS: the components,
	// by Application name, that the template leaves out.
	Disabled []string `json:"Disabled"`
	// Forge is the forge the org's repos live on: "gitea", or "" for GitHub, as
	// before the field existed. The operator never passes "github".
	Forge string `json:"Forge"`
	// ForgeURL is the forge's root as the cluster reaches it, e.g.
	// http://gitea-http.infrared.svc.cluster.local:3000, without a trailing
	// slash: repos are <ForgeURL>/<owner>/<repo>. Empty for GitHub.
	ForgeURL string `json:"ForgeURL"`
	// Registry is the operator's INFRARED_REGISTRY: the address of the registry
	// inside the cluster, <IPv4>:<port>, e.g. 10.43.0.50:5000, or "" for none.
	// With Stores the template runs Zot there (its Service's pinned ClusterIP
	// and port), and builds push the builder to it.
	Registry string `json:"Registry"`
	// Copies is the rest of the Installation's spec.backup that the template
	// renders: the buckets' mirror (spec.backup.mirror.schedule, and how long
	// what a run replaced or deleted is kept, spec.backup.retention) and the
	// age recipients the backups are encrypted to. With the stores, a backup
	// bucket and Recipients, backups are on: the operator's backup CronJob
	// writes one artifact per backup under <prefix>/backups/, the mirror's run
	// mark names the newest complete one, and the consumers' Postgres roles
	// reach the Infrared namespace for its dump. The template carries the
	// setting in the infrared Application. Each empty field renders today's
	// literal.
	Copies Copies `json:"Copies"`
	// PostgresArchive is Barman's WAL archiving of the platform's Postgres to
	// the backup bucket: Enabled is spec.backup.postgres.archive, which the
	// infrared Application carries, and renders the archive (the Barman Cloud
	// plugin, the Cluster's WAL archiver, the ObjectStore and the base
	// backups) with the stores and a backup bucket; off, the default, renders
	// none of it, since each backup carries a dump of every consumer database.
	// Schedule is the base backup's and Retention the archive's, each empty
	// for today's literal.
	PostgresArchive PostgresArchive `json:"PostgresArchive"`
	// RegistryRetention is the operator's INFRARED_REGISTRY_RETENTION: Zot's
	// garbage collection and retention. Each empty field renders today's
	// literal.
	RegistryRetention RegistryRetention `json:"RegistryRetention"`
	// Restore is the restore in progress, which the operator reads from the
	// ConfigMap infrared/infrared-restore while its phase is ObjectsRestored or
	// Failed, and zero otherwise. With the stores and a backup bucket it waits
	// for the Infrared chart's restore Job to bring Postgres's records back
	// into the empty Postgres (the mark postgres), copies the buckets back and
	// holds what needs them until they are back.
	Restore Restore `json:"Restore"`
	// PostgresServerName is the server name the platform's Postgres archives
	// under, s3://<Backup.Bucket>/<prefix>/postgres/<name>/: it must name an
	// empty prefix and never changes for the life of the install. Empty means
	// postgres, the Cluster's own name, as before the field existed.
	PostgresServerName string `json:"PostgresServerName"`
	// SubstrateRegistry is the operator's INFRARED_SUBSTRATE_REGISTRY: the
	// registry path Agent Substrate's images are pulled and copied from, which
	// holds each image of scripts/substrate-images.json under its own name, by
	// the same tag and digest, e.g.
	// us-central1-docker.pkg.dev/darkshift-preprod/infrared/substrate. Empty
	// means ghcr.io/darkshiftio/substrate, as before the field existed.
	SubstrateRegistry string `json:"SubstrateRegistry"`
	// RegistryToken is the operator's INFRARED_REGISTRY_TOKEN, the Infrared
	// chart's registryToken: the install's pull secret (ImagePullSecret) is an
	// access token for the registry host Registry, of the Google service
	// account GCPServiceAccount or, on AWS, an ECR token of the cluster's role
	// in AWSRegion (AWSRoleARN when the chart names one for IRSA; AWSHostNetwork
	// when its Job reads the node's role on the node's network), which the
	// chart rewrites every 30 minutes, not a lasting credential. The template carries it in the infrared Application,
	// whose imagePullSecrets it leaves empty (the chart names the Secret
	// itself), and copies the pull secret every 5 minutes instead of every
	// hour. The zero value is none, as before the field existed.
	RegistryToken RegistryToken `json:"RegistryToken"`
}

// RegistryToken is the chart's registryToken: the Google service account
// whose access token is the pull secret, or the AWS region (and optional IRSA
// role) whose ECR token is, and the registry host it is for. Registry is set
// whenever a token is.
type RegistryToken struct {
	GCPServiceAccount string `json:"GCPServiceAccount"`
	AWSRegion         string `json:"AWSRegion,omitempty"`
	AWSRoleARN        string `json:"AWSRoleARN,omitempty"`
	// AWSHostNetwork: the chart's token Job runs on the node's network, to
	// reach an EC2 node's role where the instance metadata answers one hop.
	AWSHostNetwork bool   `json:"AWSHostNetwork,omitempty"`
	Registry       string `json:"Registry"`
}

// Copies is spec.backup's mirror and recipients: Copies.Mirror is the
// buckets' hourly mirror (five cron fields), its Retention whole days, such
// as 7d; Recipients are age X25519 recipients (age1...).
type Copies struct {
	Mirror     CopySchedule `json:"Mirror"`
	Recipients []string     `json:"Recipients"`
}

// CopySchedule is one schedule and retention; empty keeps the default.
type CopySchedule struct {
	Schedule  string `json:"Schedule"`
	Retention string `json:"Retention"`
}

// PostgresArchive is Barman's archive of the platform's Postgres: Enabled is
// spec.backup.postgres.archive, which turns it on (off by default); Schedule
// the base backup's (six cron fields, seconds first) and Retention the
// archive's (whole days), each empty for the default, 0 0 3 * * * and 7d.
type PostgresArchive struct {
	Enabled   bool   `json:"Enabled"`
	Schedule  string `json:"Schedule"`
	Retention string `json:"Retention"`
}

// RegistryRetention is INFRARED_REGISTRY_RETENTION: Zot deletes an untagged
// image UntaggedAfter it was untagged, keeps every tag matching KeepTags and
// each repository's KeepNewest newest tags, and collects garbage every
// GCInterval, GCDelay after a blob was last used. Zero keeps the default: 24h,
// ["^v[0-9]"], 10, 1h and 1h.
type RegistryRetention struct {
	UntaggedAfter string   `json:"UntaggedAfter"`
	KeepTags      []string `json:"KeepTags"`
	KeepNewest    int      `json:"KeepNewest"`
	GCInterval    string   `json:"GCInterval"`
	GCDelay       string   `json:"GCDelay"`
}

// Restore is a restore in progress: Point is the stamp of the backup restored
// (e.g. 20261006T010500Z), Artifact its object under <prefix>/backups/
// (<Point>.irbackup), and MirrorRun the mirror run whose current/ the buckets
// come back from, a stamp too.
type Restore struct {
	Point     string `json:"Point"`
	Artifact  string `json:"Artifact"`
	MirrorRun string `json:"MirrorRun"`
}

// ImageRef is one component's image pin: Images["api"].Tag and .Digest.
type ImageRef struct {
	Tag    string `json:"Tag"`
	Digest string `json:"Digest"`
}

// BackupTarget is a bucket outside the cluster: Backup.Bucket, .Provider
// (empty, linode or s3: an S3-compatible bucket, as before the field existed;
// gcs: Google Cloud Storage), .Endpoint (empty for AWS S3), .Region (may be
// empty), .Prefix, the path everything is kept under (empty: the install's
// name, ClusterName), and .Credentials, where its key is, or that there is
// none.
type BackupTarget struct {
	Bucket      string            `json:"Bucket"`
	Provider    string            `json:"Provider"`
	Endpoint    string            `json:"Endpoint"`
	Region      string            `json:"Region"`
	Prefix      string            `json:"Prefix"`
	Credentials BackupCredentials `json:"Credentials"`
}

// BackupCredentials is where the backup bucket's key is: the Secret in the
// Infrared namespace, its two keys, and the credential's Kind. Each empty
// field is today's: infrared-platform-tokens, backup-access-key-id,
// backup-secret-access-key, accessKey. Day one reads that Secret alone, which
// the store infrared-platform reads, and an access key alone. With Provider
// gcs the Kind is serviceAccount, or empty for the same: no key at all; the
// Secret and its keys are not read, and the bucket is written and read by the
// cluster's own identities (Workload Identity).
type BackupCredentials struct {
	Secret         string `json:"Secret"`
	AccessKeyIDKey string `json:"AccessKeyIDKey"`
	SecretKeyKey   string `json:"SecretKeyKey"`
	Kind           string `json:"Kind"`
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
// the operator's INFRARED_BACKUP carries it, with "provider", "prefix" and
// "credentials" when they are set.
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

// Edges, Clouds and Forges are the values Edge, Cloud and Forge may take.
var (
	Edges  = []string{"", "traefik", "gateway"}
	Clouds = []string{"", "aws", "linode"}
	Forges = []string{"", "gitea"}
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

// jsonFlag reads a flag's JSON into a value, refusing unknown fields: -copies
// and -postgres-archive as the Data carries them, -registry-retention as the
// operator's INFRARED_REGISTRY_RETENTION does, and -restore as the restore's
// Data. Field names match case-insensitively, so camelCase keys load. An empty
// value is the zero value.
type jsonFlag[T any] struct {
	v    *T
	name string
}

func (f jsonFlag[T]) String() string {
	if f.v == nil {
		return ""
	}
	var zero T
	b, _ := json.Marshal(*f.v)
	if z, _ := json.Marshal(zero); string(b) == string(z) {
		return ""
	}
	return string(b)
}

func (f jsonFlag[T]) Set(s string) error {
	var v T
	if strings.TrimSpace(s) != "" {
		dec := json.NewDecoder(strings.NewReader(s))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&v); err != nil {
			return fmt.Errorf("-%s: %w", f.name, err)
		}
		if dec.More() {
			return fmt.Errorf("-%s: more than one JSON value", f.name)
		}
	}
	*f.v = v
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
	flag.StringVar(&d.InfraredChartRepo, "chart-repo", "us-central1-docker.pkg.dev/darkshift-preprod/infrared/charts", "InfraredChartRepo (no oci:// prefix)")
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
	flag.Var(backupFlag{&d.Backup}, "backup", `Backup, as JSON: {"bucket": "...", "endpoint": "https://...", "region": "...", "prefix": "...", "provider": "gcs"} (empty: no backups)`)
	flag.Var(disabledFlag{&d.Disabled}, "disabled", `Disabled, as a JSON array of component names: ["infisical"] (empty: none)`)
	flag.StringVar(&d.Forge, "forge", "", `Forge: "" (GitHub, as before) or "gitea"`)
	flag.StringVar(&d.ForgeURL, "forge-url", "", "ForgeURL: the forge's root as the cluster reaches it, no trailing slash (Gitea only)")
	flag.StringVar(&d.Registry, "registry", "", "Registry: the address of the registry inside the cluster, <IPv4>:<port> (empty for none)")
	flag.Var(jsonFlag[Copies]{&d.Copies, "copies"}, "copies",
		`Copies: {"recipients": ["age1..."], "mirror": {"schedule": "17 * * * *", "retention": "7d"}} (empty: today's)`)
	flag.Var(jsonFlag[PostgresArchive]{&d.PostgresArchive, "postgres-archive"}, "postgres-archive",
		`PostgresArchive: {"enabled": true, "schedule": "0 0 3 * * *", "retention": "7d"} (empty: today's)`)
	flag.Var(jsonFlag[RegistryRetention]{&d.RegistryRetention, "registry-retention"}, "registry-retention",
		`RegistryRetention, as INFRARED_REGISTRY_RETENTION: {"untaggedAfter": "24h", "keepTags": ["^v[0-9]"], "keepNewest": 10, "gcInterval": "1h", "gcDelay": "1h"} (empty: today's)`)
	flag.Var(jsonFlag[Restore]{&d.Restore, "restore"}, "restore",
		`Restore: {"point": "20261006T010500Z", "artifact": "20261006T010500Z.irbackup", "mirrorRun": "20261006T011700Z"} (empty: no restore)`)
	flag.StringVar(&d.PostgresServerName, "postgres-server-name", "", "PostgresServerName: the server name Postgres archives under (empty: postgres)")
	flag.StringVar(&d.SubstrateRegistry, "substrate-registry", "",
		"SubstrateRegistry: the registry path Substrate's images come from (empty: ghcr.io/darkshiftio/substrate)")
	flag.Var(jsonFlag[RegistryToken]{&d.RegistryToken, "registry-token"}, "registry-token",
		`RegistryToken, as JSON: {"gcpServiceAccount": "...@<project>.iam.gserviceaccount.com", "registry": "us-central1-docker.pkg.dev"}, or {"awsRegion": "us-east-1", "awsRoleArn": "" (optional), "awsHostNetwork": false (optional), "registry": "<account>.dkr.ecr.us-east-1.amazonaws.com"} (empty: none)`)
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
	fmt.Printf("rendered %d files from %s into %s (cluster %s, flavor %s, build registry %q, edge %q, stores %t, backup bucket %q, disabled %q, forge %q, registry %q, substrate capable %t, recipients %d, restore point %q)\n",
		n, src, out, d.ClusterName, d.ClusterFlavor, d.BuildRegistry, d.Edge, d.Stores, d.Backup.Bucket, d.Disabled, d.Forge, d.Registry, d.SubstrateCapable,
		len(d.Copies.Recipients), d.Restore.Point)
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
		"cluster":              func() { d.ClusterName = explicit.ClusterName },
		"flavor":               func() { d.ClusterFlavor = explicit.ClusterFlavor },
		"region":               func() { d.Region = explicit.Region },
		"org":                  func() { d.OrgName = explicit.OrgName },
		"repo-owner":           func() { d.GitopsRepoOwner = explicit.GitopsRepoOwner },
		"repo-name":            func() { d.GitopsRepoName = explicit.GitopsRepoName },
		"repo-url":             func() { d.GitopsRepoURL = explicit.GitopsRepoURL },
		"branch":               func() { d.DefaultBranch = explicit.DefaultBranch },
		"template-version":     func() { d.TemplateVersion = explicit.TemplateVersion },
		"infrared-version":     func() { d.InfraredVersion = explicit.InfraredVersion },
		"chart-repo":           func() { d.InfraredChartRepo = explicit.InfraredChartRepo },
		"chart-version":        func() { d.InfraredChartVersion = explicit.InfraredChartVersion },
		"namespace":            func() { d.InfraredNamespace = explicit.InfraredNamespace },
		"pull-secret":          func() { d.ImagePullSecret = explicit.ImagePullSecret },
		"build-registry":       func() { d.BuildRegistry = explicit.BuildRegistry },
		"edge":                 func() { d.Edge = explicit.Edge },
		"platform-domain":      func() { d.PlatformDomain = explicit.PlatformDomain },
		"infrared-host":        func() { d.InfraredHost = explicit.InfraredHost },
		"image-registry":       func() { d.ImageRegistry = explicit.ImageRegistry },
		"images":               func() { d.Images = explicit.Images },
		"cloud":                func() { d.Cloud = explicit.Cloud },
		"substrate-capable":    func() { d.SubstrateCapable = explicit.SubstrateCapable },
		"stores":               func() { d.Stores = explicit.Stores },
		"backup":               func() { d.Backup = explicit.Backup },
		"disabled":             func() { d.Disabled = explicit.Disabled },
		"forge":                func() { d.Forge = explicit.Forge },
		"forge-url":            func() { d.ForgeURL = explicit.ForgeURL },
		"registry":             func() { d.Registry = explicit.Registry },
		"copies":               func() { d.Copies = explicit.Copies },
		"postgres-archive":     func() { d.PostgresArchive = explicit.PostgresArchive },
		"registry-retention":   func() { d.RegistryRetention = explicit.RegistryRetention },
		"restore":              func() { d.Restore = explicit.Restore },
		"postgres-server-name": func() { d.PostgresServerName = explicit.PostgresServerName },
		"substrate-registry":   func() { d.SubstrateRegistry = explicit.SubstrateRegistry },
		"registry-token":       func() { d.RegistryToken = explicit.RegistryToken },
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
	if d.Backup.Provider == backupProviderGCS && d.PostgresArchive.Enabled {
		errs = append(errs, errors.New("PostgresArchive.Enabled takes no Backup.Provider gcs: Barman's archive writes through the S3 API with a key, which Google Cloud Storage is not given here"))
	}
	errs = append(errs, validateForge(d.Forge, d.ForgeURL)...)
	if err := validateRegistry(d.Registry); err != nil {
		errs = append(errs, err)
	}
	errs = append(errs, validateCopies(d.Copies)...)
	errs = append(errs, validatePostgresArchive(d.PostgresArchive)...)
	errs = append(errs, validateRegistryRetention(d.RegistryRetention)...)
	errs = append(errs, validateRestore(d)...)
	if d.PostgresServerName != "" && !serverName.MatchString(d.PostgresServerName) {
		errs = append(errs, fmt.Errorf("PostgresServerName must be 1 to 63 letters, digits, dots, underscores and hyphens, starting with a lowercase letter, got %q", d.PostgresServerName))
	}
	if d.SubstrateRegistry != "" && !registryPath.MatchString(d.SubstrateRegistry) {
		errs = append(errs, fmt.Errorf("SubstrateRegistry must be a registry host and path, no scheme, tag or trailing slash, e.g. us-central1-docker.pkg.dev/acme/infrared/substrate, got %q", d.SubstrateRegistry))
	}
	errs = append(errs, validateRegistryToken(d.RegistryToken, d.ImagePullSecret)...)
	return errors.Join(errs...)
}

// validateRegistryToken checks the registry token: none, or either a Google
// service account or an AWS region (with an optional IRSA role) and a registry
// host together, with the pull secret it writes. On AWS the host is ECR's in
// that region.
func validateRegistryToken(t RegistryToken, pullSecret string) []error {
	if t == (RegistryToken{}) {
		return nil
	}
	var errs []error
	switch {
	case t.GCPServiceAccount != "" && (t.AWSRegion != "" || t.AWSRoleARN != "" || t.AWSHostNetwork):
		errs = append(errs, errors.New("RegistryToken names a Google service account and an AWS region, role or host network: one or the other"))
	case t.AWSRegion != "" || t.AWSRoleARN != "" || t.AWSHostNetwork:
		if !awsRegion.MatchString(t.AWSRegion) {
			errs = append(errs, fmt.Errorf("RegistryToken.AWSRegion must be an AWS region, e.g. us-east-1, got %q", t.AWSRegion))
		} else if !ecrHost.MatchString(t.Registry) || !strings.HasSuffix(t.Registry, ".dkr.ecr."+t.AWSRegion+".amazonaws.com") {
			errs = append(errs, fmt.Errorf("RegistryToken.Registry must be ECR's host in %s, <account>.dkr.ecr.%s.amazonaws.com, got %q", t.AWSRegion, t.AWSRegion, t.Registry))
		}
		if t.AWSRoleARN != "" && !awsRoleARN.MatchString(t.AWSRoleARN) {
			errs = append(errs, fmt.Errorf("RegistryToken.AWSRoleARN must be empty or an IAM role, arn:aws:iam::<account>:role/<name>, got %q", t.AWSRoleARN))
		}
	default:
		if !gcpServiceAccount.MatchString(t.GCPServiceAccount) {
			errs = append(errs, fmt.Errorf("RegistryToken.GCPServiceAccount must be a Google service account, <name>@<project>.iam.gserviceaccount.com, got %q", t.GCPServiceAccount))
		}
		if !registryHost.MatchString(t.Registry) {
			errs = append(errs, fmt.Errorf("RegistryToken.Registry must be a registry host, no scheme or path, e.g. us-central1-docker.pkg.dev, got %q", t.Registry))
		}
	}
	if pullSecret == "" {
		errs = append(errs, errors.New("RegistryToken needs ImagePullSecret, the Secret the token is written to"))
	}
	return errs
}

var (
	// cronField is one field of a cron schedule: digits, names, * / , ? and -.
	cronField = `[0-9A-Za-z*/,?-]+`
	// cron5 is a CronJob's schedule; cron6 CloudNativePG's, seconds first.
	cron5 = regexp.MustCompile(`^` + cronField + `( ` + cronField + `){4}$`)
	cron6 = regexp.MustCompile(`^` + cronField + `( ` + cronField + `){5}$`)
	// retentionDays is how long a copy is kept: whole days, such as 7d.
	retentionDays = regexp.MustCompile(`^[1-9][0-9]{0,2}d$`)
	// ageRecipient is an age X25519 recipient: age1 and 58 bech32 characters.
	ageRecipient = regexp.MustCompile(`^age1[02-9ac-hj-np-z]{58}$`)
	// duration is a Go duration in whole hours, minutes or seconds, such as 1h30m.
	duration = regexp.MustCompile(`^([0-9]+(h|m|s))+$`)
	// printable is printable ASCII, which the templates quote as JSON safely.
	printable = regexp.MustCompile(`^[ -~]{1,200}$`)
	// stamp is a backup's or a mirror run's name: its UTC time,
	// YYYYMMDDTHHMMSSZ.
	stamp = regexp.MustCompile(`^[0-9]{8}T[0-9]{6}Z$`)
	// artifact is a backup's object: its stamp and .irbackup, alone or under
	// its path.
	artifact = regexp.MustCompile(`^([a-z0-9][a-z0-9._-]{0,62}/backups/)?[0-9]{8}T[0-9]{6}Z\.irbackup$`)
	// serverName is a Postgres archive's server name, such as postgres or
	// postgres-20261003T060000Z.
	serverName = regexp.MustCompile(`^[a-z][A-Za-z0-9._-]{0,62}$`)
	// backupPrefix is the path a destination keeps an install's backups
	// under, as spec.backup.destination.prefix allows it.
	backupPrefix = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,62}$`)
	// secretKey is a key of a Secret's data.
	secretKey = regexp.MustCompile(`^[-._a-zA-Z0-9]{1,253}$`)
	// registryHost is a registry's DNS name, with a port or without.
	registryHost = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+(:[0-9]{1,5})?$`)
	// registryPath is a registry host and a repository path under it.
	registryPath = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+(:[0-9]{1,5})?(/[a-z0-9]+([._-][a-z0-9]+)*)+$`)
	// awsRegion is an AWS region, such as us-east-1 or us-gov-west-1.
	awsRegion = regexp.MustCompile(`^[a-z]{2}(-gov|-iso[a-z]?)?-[a-z]+-[0-9]$`)
	// ecrHost is a private ECR registry's host.
	ecrHost = regexp.MustCompile(`^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com$`)
	// awsRoleARN is an IAM role's ARN.
	awsRoleARN = regexp.MustCompile(`^arn:aws(-us-gov|-cn)?:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]{1,512}$`)
	// gcpServiceAccount is a Google service account's email.
	gcpServiceAccount = regexp.MustCompile(`^[a-z][a-z0-9-]{4,28}[a-z0-9]@[a-z][a-z0-9-]{4,28}[a-z0-9]\.iam\.gserviceaccount\.com$`)
)

// The backup bucket's key, as day one reads it: from this Secret alone, and
// an access key alone; with Provider gcs, no key: the credential's kind is
// serviceAccount, and the endpoint, when given, is Google Cloud Storage's.
const (
	backupSecret             = "infrared-platform-tokens"
	backupKind               = "accessKey"
	backupKindServiceAccount = "serviceAccount"
	backupProviderGCS        = "gcs"
	backupEndpointGCS        = "https://storage.googleapis.com"
)

// BackupProviders are the values Backup.Provider takes: empty, linode and s3
// are S3-compatible buckets with a key, as before the field existed; gcs is
// Google Cloud Storage, written and read by the cluster's own identities.
var BackupProviders = []string{"", "linode", "s3", backupProviderGCS}

// validateCopies checks the mirror's schedule and retention when they are
// set, and the recipients.
func validateCopies(c Copies) []error {
	var errs []error
	if c.Mirror.Schedule != "" && !cron5.MatchString(c.Mirror.Schedule) {
		errs = append(errs, fmt.Errorf("Copies.Mirror.Schedule must be 5 cron fields, got %q", c.Mirror.Schedule))
	}
	if c.Mirror.Retention != "" && !retentionDays.MatchString(c.Mirror.Retention) {
		errs = append(errs, fmt.Errorf("Copies.Mirror.Retention must be whole days, such as 7d, got %q", c.Mirror.Retention))
	}
	seen := map[string]bool{}
	for _, r := range c.Recipients {
		switch {
		case !ageRecipient.MatchString(r):
			errs = append(errs, fmt.Errorf("Copies.Recipients must be age X25519 recipients (age1...), got %q", r))
		case seen[r]:
			errs = append(errs, fmt.Errorf("Copies.Recipients lists %s twice", r))
		}
		seen[r] = true
	}
	return errs
}

// validatePostgresArchive checks the base backup's schedule and the archive's
// retention when they are set.
func validatePostgresArchive(a PostgresArchive) []error {
	var errs []error
	if a.Schedule != "" && !cron6.MatchString(a.Schedule) {
		errs = append(errs, fmt.Errorf("PostgresArchive.Schedule must be 6 cron fields, seconds first, got %q", a.Schedule))
	}
	if a.Retention != "" && !retentionDays.MatchString(a.Retention) {
		errs = append(errs, fmt.Errorf("PostgresArchive.Retention must be whole days, such as 7d, got %q", a.Retention))
	}
	return errs
}

// validateRegistryRetention checks each of Zot's retention settings that is set.
func validateRegistryRetention(r RegistryRetention) []error {
	var errs []error
	for name, v := range map[string]string{"UntaggedAfter": r.UntaggedAfter, "GCInterval": r.GCInterval, "GCDelay": r.GCDelay} {
		if v != "" && !duration.MatchString(v) {
			errs = append(errs, fmt.Errorf("RegistryRetention.%s must be a duration such as 24h or 1h30m, got %q", name, v))
		}
	}
	if len(r.KeepTags) > 20 {
		errs = append(errs, fmt.Errorf("RegistryRetention.KeepTags holds %d patterns, at most 20", len(r.KeepTags)))
	}
	for _, p := range r.KeepTags {
		if !printable.MatchString(p) {
			errs = append(errs, fmt.Errorf("RegistryRetention.KeepTags must be printable ASCII, got %q", p))
		} else if _, err := regexp.Compile(p); err != nil {
			errs = append(errs, fmt.Errorf("RegistryRetention.KeepTags %q is not a regular expression: %w", p, err))
		}
	}
	if r.KeepNewest < 0 || r.KeepNewest > 1000 {
		errs = append(errs, fmt.Errorf("RegistryRetention.KeepNewest must be 1 to 1000, or 0 for the default, got %d", r.KeepNewest))
	}
	return errs
}

// validateRestore checks a restore: a point, with the stores and a backup
// bucket to restore them from; the artifact and the mirror run, when set, are
// that point's.
func validateRestore(d Data) []error {
	r := d.Restore
	if r.Point == "" {
		if r != (Restore{}) {
			return []error{errors.New("Restore.Artifact and Restore.MirrorRun need a Restore.Point")}
		}
		return nil
	}
	var errs []error
	if !stamp.MatchString(r.Point) {
		errs = append(errs, fmt.Errorf("Restore.Point must be a backup's stamp, YYYYMMDDTHHMMSSZ, got %q", r.Point))
	}
	if !d.Stores || d.Backup.Bucket == "" {
		errs = append(errs, errors.New("Restore needs the stores and a backup bucket to restore them from"))
	}
	if r.Artifact != "" && (!artifact.MatchString(r.Artifact) || !strings.HasSuffix(r.Artifact, r.Point+".irbackup")) {
		errs = append(errs, fmt.Errorf("Restore.Artifact must be the point's object, %s.irbackup, got %q", r.Point, r.Artifact))
	}
	if r.MirrorRun != "" && (!stamp.MatchString(r.MirrorRun) || r.MirrorRun < r.Point) {
		errs = append(errs, fmt.Errorf("Restore.MirrorRun must be the stamp of a mirror run at or after the point %s, got %q", r.Point, r.MirrorRun))
	}
	return errs
}

// validateRegistry checks Registry: empty, or <IPv4>:<port> with a private
// address. The template pins Zot's Service to that address and port, and
// builds name the registry by it: their tools speak plain HTTP only to a
// private address (go-containerregistry's fallback), never to a name.
func validateRegistry(registry string) error {
	if registry == "" {
		return nil
	}
	host, port, err := net.SplitHostPort(registry)
	ip := net.ParseIP(host)
	n, perr := strconv.Atoi(port)
	if err != nil || strings.Contains(host, ":") || ip == nil || ip.To4() == nil || !ip.IsPrivate() ||
		perr != nil || n < 1 || n > 65535 || port != strconv.Itoa(n) {
		return fmt.Errorf("Registry must be a private IPv4 address and a port, e.g. 10.43.0.50:5000, got %q", registry)
	}
	return nil
}

// validateForge checks Forge and ForgeURL together: Gitea needs its URL, and
// GitHub ("") has none.
func validateForge(forge, forgeURL string) []error {
	if !slices.Contains(Forges, forge) {
		return []error{fmt.Errorf("Forge must be one of %q, got %q", Forges, forge)}
	}
	if forge == "" {
		if forgeURL != "" {
			return []error{errors.New("ForgeURL needs a Forge: GitHub (\"\") has none")}
		}
		return nil
	}
	u, err := url.Parse(forgeURL)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" ||
		strings.HasSuffix(forgeURL, "/") || u.RawQuery != "" || u.Fragment != "" || u.User != nil {
		return []error{fmt.Errorf("ForgeURL must be the forge's http(s) root without a trailing slash, got %q", forgeURL)}
	}
	return nil
}

// validateBackup checks the shape of each Backup field that is set; an empty
// Bucket turns backups off, so the others need one.
func validateBackup(b BackupTarget) []error {
	var errs []error
	if b.Bucket == "" {
		if b.Endpoint != "" || b.Region != "" || b.Prefix != "" || b.Credentials != (BackupCredentials{}) {
			errs = append(errs, errors.New("Backup.Endpoint, Backup.Region, Backup.Prefix and Backup.Credentials need a Backup.Bucket"))
		}
		return errs
	}
	if b.Prefix != "" && !backupPrefix.MatchString(b.Prefix) {
		errs = append(errs, fmt.Errorf("Backup.Prefix must be 1 to 63 lowercase letters, digits, dots, underscores and hyphens, starting with a letter or digit, got %q", b.Prefix))
	}
	if !slices.Contains(BackupProviders, b.Provider) {
		errs = append(errs, fmt.Errorf("Backup.Provider must be one of %q, got %q", BackupProviders, b.Provider))
	}
	c := b.Credentials
	if c.Secret != "" && c.Secret != backupSecret {
		errs = append(errs, fmt.Errorf("Backup.Credentials.Secret must be %s, the one Secret the store infrared-platform reads, got %q", backupSecret, c.Secret))
	}
	switch {
	case b.Provider == backupProviderGCS && c.Kind != "" && c.Kind != backupKindServiceAccount:
		errs = append(errs, fmt.Errorf("Backup.Credentials.Kind must be %s with Backup.Provider gcs (the cluster's own identities, no key), got %q", backupKindServiceAccount, c.Kind))
	case b.Provider != backupProviderGCS && c.Kind != "" && c.Kind != backupKind:
		errs = append(errs, fmt.Errorf("Backup.Credentials.Kind must be %s, the one kind of credential day one reads, got %q", backupKind, c.Kind))
	}
	if b.Provider == backupProviderGCS && b.Endpoint != "" && b.Endpoint != backupEndpointGCS {
		errs = append(errs, fmt.Errorf("Backup.Endpoint must be %s or empty with Backup.Provider gcs, got %q", backupEndpointGCS, b.Endpoint))
	}
	for name, v := range map[string]string{"AccessKeyIDKey": c.AccessKeyIDKey, "SecretKeyKey": c.SecretKeyKey} {
		if v != "" && !secretKey.MatchString(v) {
			errs = append(errs, fmt.Errorf("Backup.Credentials.%s must be a Secret's key: letters, digits, '-', '_' and '.', got %q", name, v))
		}
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
