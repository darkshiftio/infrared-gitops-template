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
	// "gateway", which turns on the edge components (Envoy Gateway, and without
	// a TunnelID or PrivateEdge external-dns and Cloudflare's origin issuer).
	// "" means traefik.
	Edge string `json:"Edge"`
	// PlatformDomain is the Installation's spec.previews.domain, "" when unset.
	// In gateway mode zones answer at <zone>.<PlatformDomain>.
	PlatformDomain string `json:"PlatformDomain"`
	// InfraredHost is the host of the Installation's spec.previews.signInURL,
	// "" when unset. In gateway mode it is Infrared's own name.
	InfraredHost string `json:"InfraredHost"`
	// CustomHostnames is spec.previews.customHostnames on a gateway edge:
	// addresses under an org's own domains are Cloudflare for SaaS custom
	// hostnames, whose origin certificates come from Let's Encrypt over
	// HTTP-01 on the listener http-any (Issuer letsencrypt-http, and
	// cert-manager's Gateway API support). false renders as before.
	CustomHostnames bool `json:"CustomHostnames"`
	// ACMEEmail is spec.previews.acmeEmail, Let's Encrypt's contact for those
	// certificates; "" registers without one.
	ACMEEmail string `json:"ACMEEmail"`
	// DomainTokenKey is spec.previews.domainTokenKey on a gateway edge with a
	// platform domain: the key of the Secret infrared-platform-tokens that
	// holds a Cloudflare token for PlatformDomain's zone, which is not
	// InfraredHost's (a hosted plane's tenants' domain, infrared-docs-internal
	// ADR 0063). The edge then gives *.<PlatformDomain> a copy of that token,
	// the OriginIssuer cloudflare-origin-domain and the Certificate
	// edge-domain, the listener https that certificate, and a second
	// external-dns, external-dns-domain; Infrared's own name keeps
	// cloudflare-api-token and the Certificate edge. "" renders as before, and
	// an operator leaves it out of the data.
	DomainTokenKey string `json:"DomainTokenKey,omitempty"`
	// TunnelID is spec.tunnel.id on a gateway edge: the UUID, lower case, of
	// the Cloudflare Tunnel the edge is reached through (infrared-docs-internal
	// ADR 0064). Envoy then binds no node's ports and its Service is a
	// ClusterIP; cloudflared runs beside it (components/edge/tunnel.yaml) with
	// a route for Infrared's name and *.<PlatformDomain>; the edge's
	// certificate comes from a certificate authority inside the cluster
	// (edge-ca); and external-dns, external-dns-domain and Cloudflare's origin
	// issuer are left out, so DomainTokenKey is not read. "" renders as
	// before, and an operator leaves it out of the data.
	TunnelID string `json:"TunnelID,omitempty"`
	// TunnelCredentialsKey is spec.tunnel.credentialsKey, with TunnelID: the
	// key of the Secret infrared-platform-tokens that holds the tunnel's
	// credentials file, which the template copies to cloudflared. "" is the
	// default, cloudflare-tunnel-credentials, and an operator leaves it out of
	// the data without a tunnel.
	TunnelCredentialsKey string `json:"TunnelCredentialsKey,omitempty"`
	// TunnelMode is spec.tunnel.mode beside, with TunnelID: cloudflared runs
	// beside an edge that stays as it renders without a tunnel (the nodes'
	// own ports, Cloudflare's Origin CA, external-dns), so each of the edge's
	// names moves onto the tunnel when its record points there
	// (infrared-docs-internal ADR 0090, workspace TODO 745). cloudflared's
	// routes, the first that matches wins: a Let's Encrypt challenge to
	// Envoy's plain HTTP, InfraredHost and each of TunnelHostnames to Envoy's
	// HTTPS by that name, *.<PlatformDomain> by each request's own, then 404.
	// "" is the tunnel alone, as before: the operator hands mode only as "",
	// and leaves it out of the data.
	TunnelMode string `json:"TunnelMode,omitempty"`
	// TunnelHostnames are spec.tunnel.hostnames, with TunnelID, alone or
	// beside (infrared-docs-internal ADR 0090, workspace TODO 745): the other
	// names a record sends to the tunnel, each served on the edge by a
	// listener of its own that the template does not render (a name a gitops
	// repo outside it serves, a zone's own address, a custom hostname).
	// cloudflared gives each a route to Envoy's HTTPS by that name
	// (originServerName), after InfraredHost's and before *.<PlatformDomain>,
	// and answers 404 for a name listed nowhere. The operator hands them
	// sorted, each once, lower case and without InfraredHost; empty, it
	// leaves them out of the data.
	TunnelHostnames []string `json:"TunnelHostnames,omitempty"`
	// OrgLabels are the Organizations' labels under PlatformDomain, on a
	// gateway edge where the Installation's spec.previews.orgLabels is on
	// (infrared-docs-internal ADR 0097): zone z of the org labelled acme
	// answers at <z>.acme.<PlatformDomain>. The zones' listener and
	// cloudflared's route, both *.<PlatformDomain>, take a name at any depth,
	// but a wildcard certificate covers one label, and cloudflared checks
	// Envoy's certificate against each request's own name (matchSNItoHost):
	// so the certificate that names *.<PlatformDomain> names
	// *.<label>.<PlatformDomain> for each label too. The operator hands them
	// sorted, each once; empty, it leaves them out of the data.
	OrgLabels []string `json:"OrgLabels,omitempty"`
	// TunnelPublish is spec.tunnel.publish with TunnelMode beside: the
	// Gateway edge carries external-dns's target annotation under both
	// prefixes (external-dns.alpha.kubernetes.io/ and external-dns.kubernetes.io/),
	// <TunnelID>.cfargotunnel.com, so the names external-dns publishes from
	// the edge become proxied CNAMEs to the tunnel instead of the nodes'
	// addresses. false renders as before, and an operator leaves it out of
	// the data.
	TunnelPublish bool `json:"TunnelPublish,omitempty"`
	// SignInPrivate is spec.previews.signInPrivate on a gateway edge with an
	// InfraredHost: Infrared's own name is kept off the edge, which renders
	// no listener, route, cloudflared route or certificate name for it, and
	// no edge's proof; the install's own private ingress serves the name
	// (infrared-docs-internal ADR 0090). InfraredHost stays set, and what
	// else renders from it (Grafana's sign-in, the README, the infrared
	// Application) is as before. false renders as before, and an operator
	// leaves it out of the data.
	SignInPrivate bool `json:"SignInPrivate,omitempty"`
	// EdgeProofSecret is the operator's INFRARED_EDGE_PROOF_SECRET (the
	// Infrared chart's api.clientAddressProof.enabled) on a gateway edge with
	// an InfraredHost: the Secret in InfraredNamespace whose key credential
	// Envoy stamps on every request for Infrared's API, as the header
	// X-Infrared-Edge-Proof, so the API believes the client-address header
	// only on a request that came through the edge (workspace TODO 473, F4;
	// infrared-docs-internal ADR 0066 D2). The infrared route then has a first
	// rule for the API's paths with the HTTPRouteFilter infrared-edge-proof,
	// and the ClientTrafficPolicy edge strips any copy a client sent. ""
	// renders as before, and an operator leaves it out of the data.
	EdgeProofSecret string `json:"EdgeProofSecret,omitempty"`
	// PrivateEdge is the Installation's spec.privateEdge on a gateway edge
	// (infrared-docs-internal ADR 0100 D2): the edge serves its names inside
	// the cluster alone, with no Cloudflare Tunnel and no public name. It
	// renders as behind a tunnel without cloudflared: Envoy binds no node's
	// ports and its Service is a ClusterIP, the edge's certificate comes from
	// the certificate authority inside the cluster (edge-ca), and external-dns,
	// external-dns-domain and Cloudflare's origin issuer are left out, so no
	// Cloudflare token is read; the infrared Application carries
	// installation.privateEdge. The operator hands it only on a gateway edge,
	// with no tunnel and no custom hostnames; were a tunnel there all the same,
	// the private edge wins and no cloudflared renders. false renders as
	// before, and an operator leaves it out of the data.
	PrivateEdge bool `json:"PrivateEdge,omitempty"`
	// ImageRegistry is the registry of Infrared's own images (the operator's
	// INFRARED_IMAGE_REGISTRY), e.g. ghcr.io/darkshiftio; "" keeps the chart's.
	ImageRegistry string `json:"ImageRegistry"`
	// Images is each component's pin (INFRARED_IMAGES), keyed by operator, api,
	// ui, mcp and runner; empty keeps the chart's.
	Images map[string]ImageRef `json:"Images"`
	// Cloud is "", "aws", "linode" or "gcp", from the nodes' providerID prefix.
	Cloud string `json:"Cloud"`
	// SubstrateCapable is the operator's preflight result; while it is false the
	// template leaves Substrate out.
	SubstrateCapable bool `json:"SubstrateCapable"`
	// Stores is the operator's INFRARED_STORES: true renders the platform's own
	// stores, CloudNativePG with one Postgres Cluster, and SeaweedFS.
	Stores bool `json:"Stores"`
	// StoresSingleNode is the operator's INFRARED_STORES_SINGLE_NODE, the
	// chart's stores.singleNode: with Stores, SeaweedFS runs on the cluster's
	// one node, one server of each kind, every file written once. False, the
	// default, spreads it over three nodes as before; without Stores it
	// changes nothing.
	StoresSingleNode bool `json:"StoresSingleNode"`
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
	// Telemetry is the Installation's spec.observability.telemetry: the
	// telemetry plane an install without the metrics stack pushes its numbers
	// to (infrared-docs-internal ADR 0044). URL is the remote-write address,
	// hosted's POST /api/v1/telemetry/write; Platform is the label every series
	// carries, <login>-<stack> for a Mac's stack. Both empty renders no
	// telemetry component; with victoria-metrics-k8s-stack on, nothing renders
	// either, since that stack keeps its metrics itself.
	Telemetry Telemetry `json:"Telemetry"`
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
	// registry path Agent Substrate's images are pulled from, which holds each
	// image of scripts/substrate-images.json under its own name, by the same
	// tag and digest, e.g.
	// us-central1-docker.pkg.dev/darkshift-preprod/infrared/substrate. Empty
	// means where upstream publishes them, ghcr.io/agent-substrate/substrate.
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
	// CloudIdentity is the operator's INFRARED_CLOUD_IDENTITY, the Infrared
	// chart's cloudIdentity: what the chart binds the ServiceAccount
	// infrared-cloud to, the one identity Infrared reaches an org's cloud
	// account with (ADR 0033). The template carries it in the infrared
	// Application, so Argo CD's render of the chart keeps it. Nil is none, as
	// before the field existed, and is left out of the data.
	CloudIdentity *CloudIdentity `json:"CloudIdentity,omitempty"`
	// RunningChartVersion is the chart version of the operator that renders,
	// which pins Infrared's images to its own release. The infrared Application
	// carries those pins only while InfraredChartVersion is that version: when
	// the gitops repo pins a newer chart (an upgrade), the pins are left out so
	// Argo CD runs the newer chart's own images, the newer operator among them,
	// which then pins its own. Empty is an operator from before the field, and
	// the pins render as they always did.
	RunningChartVersion string `json:"RunningChartVersion,omitempty"`
	// OIDC is the operator's INFRARED_OIDC, the Infrared chart's oidc.enabled:
	// Infrared is the OpenID Connect provider of the install's own tools
	// (infrared-docs-internal ADR 0053). With GrafanaURL and InfraredHost set
	// too, Grafana signs people in through Infrared. False renders as before
	// the field existed, and an operator leaves it out of the data.
	OIDC bool `json:"OIDC,omitempty"`
	// GrafanaURL is the operator's INFRARED_OIDC_GRAFANA_URL, the Infrared
	// chart's oidc.grafanaURL: Grafana's address in a browser, such as
	// https://grafana.infrared-cp-google.private.darkshift.io, http(s) with no
	// trailing slash. It is Grafana's root_url, and Grafana's redirect URI is
	// <GrafanaURL>/login/generic_oauth. Empty renders as before the field
	// existed.
	GrafanaURL string `json:"GrafanaURL,omitempty"`
	// NetworkPolicies is the operator's INFRARED_NETWORK_POLICIES, the
	// Infrared chart's tenancy.networkPolicies.enabled: every platform
	// namespace gets its ingress NetworkPolicy, Argo CD's own policies admit
	// no org's namespace, and the infrared Application carries the setting
	// (infrared-docs-internal ADR 0066 D1; see "The network fence"). False
	// renders as before the field existed, and an operator leaves it out of
	// the data.
	NetworkPolicies bool `json:"NetworkPolicies,omitempty"`
	// RegistryPulls is the operator's INFRARED_REGISTRY_PULLS, the Infrared
	// chart's tenancy.registryPulls.enabled: zot-base reads for no one without
	// a login, each zone pulls as its org's own registry user (the operator
	// hands it zot-pull), and the infrared Application carries the setting
	// (infrared-docs-internal ADR 0066 D3; see "The registry"). False renders
	// as before the field existed, and an operator leaves it out of the data.
	RegistryPulls bool `json:"RegistryPulls,omitempty"`
	// StoresSecurity is the operator's INFRARED_STORES_SECURITY, the Infrared
	// chart's tenancy.storesSecurity.enabled: SeaweedFS takes no caller it
	// cannot identify (gRPC under mutual TLS from cert-manager, the filer's
	// HTTP and volume writes under signed tokens, the master's HTTP admin
	// off), and the infrared Application carries the setting (ADR 0066 D3; see
	// "The stores' own security"). False renders as before the field existed,
	// and an operator leaves it out of the data.
	StoresSecurity bool `json:"StoresSecurity,omitempty"`
	// TenantPods is the operator's INFRARED_TENANT_PODS, the Infrared chart's
	// tenancy.tenantPods, as one line of JSON ({"enabled": true, "placement":
	// {...}}): a tenant's zone and build pods carry no Kubernetes token, and a
	// zone's pods the install's placement (infrared-docs-internal ADR 0066 D4,
	// D5). The operator does it all; the infrared Application carries the
	// setting. Empty renders as before the field existed, and an operator
	// leaves it out of the data.
	TenantPods string `json:"TenantPods,omitempty"`
	// TenantQuotas is the operator's INFRARED_TENANT_QUOTAS, the Infrared
	// chart's tenancy.quotas, as one line of JSON ({"enabled": true, "zones":
	// {...}, "builds": {...}}): a tenant org's quotas (ADR 0066 D4), which the
	// infrared Application carries. Empty renders as before.
	TenantQuotas string `json:"TenantQuotas,omitempty"`
	// AdmissionPolicies is the operator's INFRARED_ADMISSION_POLICIES, the
	// Infrared chart's tenancy.admissionPolicies.enabled: the operator applies
	// ValidatingAdmissionPolicies on tenants' namespaces (ADR 0066 D6), and the
	// infrared Application carries the setting. False renders as before.
	AdmissionPolicies bool `json:"AdmissionPolicies,omitempty"`
	// DenyLogging is the operator's INFRARED_DENY_LOGGING, the Infrared chart's
	// tenancy.denyLogging.enabled: GKE logs the denies of tenants' namespaces
	// (ADR 0066 D10), and the infrared Application carries the setting. False
	// renders as before.
	DenyLogging bool `json:"DenyLogging,omitempty"`
	// ArgoCDRestrictDefaultProject is the operator's
	// INFRARED_ARGOCD_RESTRICT_DEFAULT_PROJECT, the Infrared chart's
	// tenancy.argoCD.restrictDefaultProject: Argo CD's default project takes
	// the platform org's gitops repo alone (ADR 0066 D10), and the infrared
	// Application carries the setting. False renders as before.
	ArgoCDRestrictDefaultProject bool `json:"ArgoCDRestrictDefaultProject,omitempty"`
	// BuildCaps is the operator's INFRARED_BUILD_CAPS, the Infrared chart's
	// tenancy.buildCaps, as one line of JSON ({"enabled": true,
	// "deadlineMinutes": ..., "minutesPerOrgPerDay": ...}): each tenant
	// build's deadline and its org's build minutes a UTC day (workspace TODO
	// 473). The operator keeps them; the infrared Application carries the
	// setting. Empty renders as before the field existed, and an operator
	// leaves it out of the data.
	BuildCaps string `json:"BuildCaps,omitempty"`
	// TenantStorage is the operator's INFRARED_TENANT_STORAGE, the Infrared
	// chart's tenancy.tenantStorage, as one line of JSON ({"enabled": true,
	// "capGi": ..., "minDiskGi": ...}): the cap on every tenant org's volumes
	// together (workspace TODO 473), which the infrared Application carries.
	// Empty renders as before.
	TenantStorage string `json:"TenantStorage,omitempty"`
	// MetricsStorage is the operator's INFRARED_METRICS_STORAGE, the Infrared
	// chart's operator.metricsStorage: the size of the install's own metrics
	// store, such as 40Gi (infrared-docs-internal ADR 0075, lane H). VMSingle's
	// claim takes it, or on k3s with the stores the emptyDir its data is on
	// (see "The metrics store's size"). Empty is 10Gi, which renders as before
	// the field existed, and an operator leaves it out of the data.
	MetricsStorage string `json:"MetricsStorage,omitempty"`
	// MetricsAuth is the operator's INFRARED_METRICS_AUTH, the Infrared
	// chart's observability.metricsAuth.stage, as the operator hands it over
	// (infrared-docs-internal docs/home-defense.md, step 5; see "The metrics'
	// door"): door, vmauth in front of the metrics store and Alertmanager,
	// with a user for Grafana, which reads through it, and with
	// MetricsAuthIssuer and MetricsAuthAudience one each for Infrared's API
	// and operator, which sign in with their ServiceAccount tokens; enforced,
	// the door and the stack's back doors closed by NetworkPolicy. The chart's
	// clients is door here. Empty renders as before the field existed, and an
	// operator leaves it out of the data.
	MetricsAuth string `json:"MetricsAuth,omitempty"`
	// MetricsAuthIssuer is the cluster's service account token issuer, with
	// MetricsAuth: the issuer the door's users for the API and the operator
	// check a token against, by its discovery document and keys, so it must
	// publish them (GKE's and EKS's do, k3s's does not). Empty renders no
	// such user, and an operator leaves it out of the data.
	MetricsAuthIssuer string `json:"MetricsAuthIssuer,omitempty"`
	// MetricsAuthAudience is the operator's INFRARED_METRICS_TOKEN_AUDIENCE,
	// the chart's observability.metricsAuth.audience, with MetricsAuth: the
	// aud claim those users match, a DNS label such as infrared-metrics.
	MetricsAuthAudience string `json:"MetricsAuthAudience,omitempty"`
	// NodeExporterAuth is the operator's INFRARED_NODE_EXPORTER_AUTH, the
	// chart's observability.nodeExporterAuth.enabled: node-exporter answers
	// only behind kube-rbac-proxy, over TLS on each node's port 9100 and to a
	// token allowed to get its Service's subresource, which vmagent's own is
	// (see "The metrics' door"). False renders as before the field existed,
	// and an operator leaves it out of the data.
	NodeExporterAuth bool `json:"NodeExporterAuth,omitempty"`
	// MediaStore is the operator's INFRARED_MEDIA_STORE, the Infrared chart's
	// summaryvideo.store, where the API keeps its videos and pictures
	// (infrared-docs-internal ADR 0087, D4 and D7): both or objectStore puts
	// them in SeaweedFS's bucket media, which the API alone reads and writes
	// with the S3 identity media; with it the identity storage-reader (List on
	// every bucket, for the storage views), the API's pods through the stores'
	// fence on 8333, and media in the hourly copy and the restore (see "The
	// bucket media"). The infrared Application does not carry it: the
	// install's values file moves the value both ways. Empty, the chart's
	// volume, renders as before the field existed, and an operator leaves it
	// out of the data.
	MediaStore string `json:"MediaStore,omitempty"`
	// StoresOrgLayout is the registry in the stores' org layout
	// (infrared-docs-internal ADR 0087 D2, D3): the Installation's
	// status.storage.layout is org, which the operator sets only once a
	// migration has copied, verified and deleted every repository's files into
	// the layout, never from the chart's stores.orgLayout.enabled. With the
	// stores and the registry, zot-base's S3 driver has no rootdirectory, so
	// Zot's root is the bucket's, and Zot's pods carry an annotation naming it,
	// so a change of root rolls them; the platform's own repositories are
	// platform/images/kpack-builder and platform/images/substrate/<name> (see
	// "The stores' org layout"). False, the default, renders as before the
	// field existed, and an operator leaves it out of the data.
	StoresOrgLayout bool `json:"StoresOrgLayout,omitempty"`
	// RegistryPaused stops Zot while a migration between the layouts copies,
	// verifies and deletes its files, and while its root changes: with the
	// stores and the registry, Zot's Application renders replicaCount 0, and
	// nothing else changes. The operator sets it from the migration's phase in
	// the Installation's status.storage (Pausing, Copying and Rooting). False,
	// the default, renders as before the field existed, and an operator leaves
	// it out of the data.
	RegistryPaused bool `json:"RegistryPaused,omitempty"`
	// StorePaths is the operator's INFRARED_STORES_POLICIES, the Infrared
	// chart's stores.policies.enabled, on an install with the platform's
	// stores (infrared-docs-internal ADR 0087 D10): the template renders the
	// stores' applier, the CronJob stores/seaweedfs-paths, which applies the
	// path rules the operator writes to stores/infrared-store-paths, daily and
	// in each Job the operator starts from it, and carries out the journal of
	// a migration between the stores' layouts (see "The stores' applier").
	// False, the default, renders as before the field existed, and an
	// operator leaves it out of the data.
	StorePaths bool `json:"StorePaths,omitempty"`
	// StoresMigration is the operator's: a migration between the stores'
	// layouts runs (the Installation's status.storage.migration has a phase
	// other than Done), or another move it drives through the journal
	// stores/infrared-store-moves. The migration starts the applier's Jobs
	// from the CronJob stores/seaweedfs-paths by name, so with the stores the
	// CronJob renders even without StorePaths, its own schedule suspended
	// while files move: only the operator's Jobs run then. False, the
	// default, renders as before the field existed, and an operator leaves it
	// out of the data.
	StoresMigration bool `json:"StoresMigration,omitempty"`
	// AgentPool is the operator's from the Infrared chart's runner.actors
	// (INFRARED_AGENT_ACTORS), on: with Agent Substrate, the template renders
	// the WorkerPool agents in ate-workers, where an org's agent steps run as
	// actors (infrared-docs-internal ADR 0089), on the runner placement's
	// nodes (runner.placement), whose taints atelet then tolerates too (see
	// "The agents' WorkerPool"). Nil, the default, renders as before the field
	// existed, and an operator leaves it out of the data.
	AgentPool *AgentPool `json:"AgentPool,omitempty"`
}

// AgentPool is the WorkerPool agents: Workers warm workers, each sized for one
// step's actor (CPU and Memory its limits, RequestCPU and RequestMemory what
// it asks for), on the nodes NodeSelector picks, with Tolerations. MaxWorkers
// above 0 makes it elastic: the operator sets its replicas between MinWorkers
// and MaxWorkers, Workers is its size only until the operator first does, and
// the template leaves the replicas to it (see "The agents' WorkerPool"). Both
// are left out of the data at 0, which renders as before they existed.
type AgentPool struct {
	Workers       int32             `json:"Workers"`
	MinWorkers    int32             `json:"MinWorkers,omitempty"`
	MaxWorkers    int32             `json:"MaxWorkers,omitempty"`
	CPU           string            `json:"CPU"`
	Memory        string            `json:"Memory"`
	RequestCPU    string            `json:"RequestCPU"`
	RequestMemory string            `json:"RequestMemory"`
	NodeSelector  map[string]string `json:"NodeSelector,omitempty"`
	Tolerations   []Toleration      `json:"Tolerations,omitempty"`
}

// Toleration is a taint a pod tolerates, as Kubernetes spells one.
type Toleration struct {
	Key      string `json:"Key,omitempty"`
	Operator string `json:"Operator,omitempty"`
	Value    string `json:"Value,omitempty"`
	Effect   string `json:"Effect,omitempty"`
}

// CloudIdentity is the chart's cloudIdentity: a Google service account bound
// by Workload Identity, and at most one way to an AWS principal: an IRSA role,
// the node's role on the node's network, or a projected token for
// AssumeRoleWithWebIdentity.
type CloudIdentity struct {
	GCPServiceAccount string `json:"GCPServiceAccount,omitempty"`
	AWSRoleARN        string `json:"AWSRoleARN,omitempty"`
	AWSHostNetwork    bool   `json:"AWSHostNetwork,omitempty"`
	AWSWebIdentity    bool   `json:"AWSWebIdentity,omitempty"`
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

// Telemetry is where an install without the metrics stack sends its numbers,
// and the platform label they carry (ADR 0044).
type Telemetry struct {
	URL      string `json:"URL"`
	Platform string `json:"Platform"`
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
	// Default is true when the pin is the chart version's own default
	// (INFRARED_IMAGES "default"): handed only so a component that needs it
	// runs, never written into the infrared Application, so a chart upgrade
	// moves it with the chart.
	Default bool `json:"Default,omitempty"`
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
// namesFlag reads a flag that takes a JSON array of names, such as
// -tunnel-hostnames; empty is none.
type namesFlag struct {
	d    *[]string
	name string
}

func (f namesFlag) String() string {
	if f.d == nil || len(*f.d) == 0 {
		return ""
	}
	b, _ := json.Marshal(*f.d)
	return string(b)
}

func (f namesFlag) Set(s string) error {
	var d []string
	if strings.TrimSpace(s) != "" {
		if err := json.Unmarshal([]byte(s), &d); err != nil {
			return fmt.Errorf("-%s: %w", f.name, err)
		}
	}
	*f.d = d
	return nil
}

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

// Edges, Clouds, Forges and MediaStores are the values Edge, Cloud, Forge
// and MediaStore may take.
var (
	Edges       = []string{"", "traefik", "gateway"}
	Clouds      = []string{"", "aws", "linode", "gcp"}
	Forges      = []string{"", "gitea"}
	MediaStores = []string{"", "both", "objectStore"}
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
	flag.StringVar(&d.DomainTokenKey, "domain-token-key", "",
		"DomainTokenKey: the key of infrared-platform-tokens with a Cloudflare token for the platform domain's own zone; needs -edge gateway and -platform-domain (empty: one token for both)")
	flag.StringVar(&d.TunnelID, "tunnel-id", "",
		"TunnelID: the UUID, lower case, of the Cloudflare Tunnel the edge is reached through; needs -edge gateway (empty: the edge on the nodes' own ports)")
	flag.StringVar(&d.TunnelCredentialsKey, "tunnel-credentials-key", defaultTunnelCredentialsKey,
		"TunnelCredentialsKey: the key of infrared-platform-tokens with the tunnel's credentials file, with -tunnel-id")
	flag.StringVar(&d.TunnelMode, "tunnel-mode", "",
		`TunnelMode: "beside", cloudflared beside the edge on the nodes' own ports, with -tunnel-id (empty: the tunnel alone)`)
	flag.BoolVar(&d.TunnelPublish, "tunnel-publish", false,
		"TunnelPublish: external-dns publishes the edge's names to the tunnel; needs -tunnel-mode beside")
	flag.Var(namesFlag{&d.TunnelHostnames, "tunnel-hostnames"}, "tunnel-hostnames",
		`TunnelHostnames, as a JSON array: ["support.example.com"], the other names that reach the edge through the tunnel, each by its own route; needs -tunnel-id (empty: none)`)
	flag.Var(namesFlag{&d.OrgLabels, "org-labels"}, "org-labels",
		`OrgLabels, as a JSON array: ["acme"], the orgs' labels under the platform domain, each a wildcard name on the zones' certificate; needs -edge gateway and -platform-domain (empty: none)`)
	flag.BoolVar(&d.SignInPrivate, "sign-in-private", false,
		"SignInPrivate: Infrared's own name kept off the edge; needs -edge gateway, -platform-domain and -infrared-host")
	flag.StringVar(&d.EdgeProofSecret, "edge-proof-secret", "",
		"EdgeProofSecret: the Secret in -namespace whose key credential the edge stamps on requests for Infrared's API (INFRARED_EDGE_PROOF_SECRET); needs -edge gateway and -infrared-host (empty: no stamp)")
	flag.BoolVar(&d.PrivateEdge, "private-edge", false,
		"PrivateEdge: the edge inside the cluster alone, on its own certificate authority, with no tunnel and no public name; needs -edge gateway, never with -tunnel-id")
	flag.StringVar(&d.ImageRegistry, "image-registry", "", "ImageRegistry: the registry of Infrared's images, e.g. ghcr.io/darkshiftio (empty keeps the chart's)")
	flag.Var(imagesFlag{&d.Images}, "images", `Images, as JSON: {"api": {"tag": "v1.2.3", "digest": "sha256:..."}, ...} (empty keeps the chart's)`)
	flag.StringVar(&d.Cloud, "cloud", "", `Cloud: "", "aws", "linode" or "gcp"`)
	flag.BoolVar(&d.SubstrateCapable, "substrate-capable", false, "SubstrateCapable: the preflight's result")
	flag.BoolVar(&d.Stores, "stores", false, "Stores: the platform's own Postgres and SeaweedFS")
	flag.BoolVar(&d.StoresSingleNode, "stores-single-node", false, "StoresSingleNode: with Stores, SeaweedFS on the cluster's one node, every file once")
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
		"SubstrateRegistry: the registry path Substrate's images come from (empty: ghcr.io/agent-substrate/substrate)")
	flag.Var(jsonFlag[RegistryToken]{&d.RegistryToken, "registry-token"}, "registry-token",
		`RegistryToken, as JSON: {"gcpServiceAccount": "...@<project>.iam.gserviceaccount.com", "registry": "us-central1-docker.pkg.dev"}, or {"awsRegion": "us-east-1", "awsRoleArn": "" (optional), "awsHostNetwork": false (optional), "registry": "<account>.dkr.ecr.us-east-1.amazonaws.com"} (empty: none)`)
	flag.StringVar(&d.RunningChartVersion, "running-chart-version", "", "RunningChartVersion: the rendering operator's chart version; image pins render only when it equals InfraredChartVersion (empty: always, as before)")
	flag.Var(jsonFlag[*AgentPool]{&d.AgentPool, "agent-pool"}, "agent-pool",
		`AgentPool, as the operator renders it from runner.actors: {"Workers": 4, "MinWorkers": 0 and "MaxWorkers": 10 (optional: elastic), "CPU": "2500m", "Memory": "9Gi", "RequestCPU": "625m", "RequestMemory": "2304Mi", "NodeSelector": {...} (optional), "Tolerations": [{"Key", "Operator", "Value", "Effect"}] (optional)} (empty: none)`)
	flag.Var(jsonFlag[*CloudIdentity]{&d.CloudIdentity, "cloud-identity"}, "cloud-identity",
		`CloudIdentity, as INFRARED_CLOUD_IDENTITY maps to it: {"gcpServiceAccount": "...@<project>.iam.gserviceaccount.com" (optional), and at most one of "awsRoleArn", "awsHostNetwork": true, "awsWebIdentity": true} (empty: none)`)
	flag.BoolVar(&d.OIDC, "oidc", false, "OIDC: Infrared is the OpenID Connect provider of the install's own tools (INFRARED_OIDC); with -grafana-url and -infrared-host, Grafana signs people in through it")
	flag.StringVar(&d.GrafanaURL, "grafana-url", "", "GrafanaURL: Grafana's address in a browser, http(s) with no trailing slash (INFRARED_OIDC_GRAFANA_URL; empty for none)")
	flag.BoolVar(&d.NetworkPolicies, "network-policies", false, "NetworkPolicies: every platform namespace's ingress NetworkPolicy, the network fence (INFRARED_NETWORK_POLICIES)")
	flag.BoolVar(&d.RegistryPulls, "registry-pulls", false, "RegistryPulls: the registry reads for no one without a login, and each zone pulls as its org (INFRARED_REGISTRY_PULLS)")
	flag.BoolVar(&d.StoresSecurity, "stores-security", false, "StoresSecurity: SeaweedFS under its own security, mutual TLS and signed tokens (INFRARED_STORES_SECURITY)")
	flag.StringVar(&d.TenantPods, "tenant-pods", "", `TenantPods: the chart's tenancy.tenantPods as one line of JSON, {"enabled":true,"placement":{...}} (INFRARED_TENANT_PODS; empty for none)`)
	flag.StringVar(&d.TenantQuotas, "tenant-quotas", "", `TenantQuotas: the chart's tenancy.quotas as one line of JSON, {"enabled":true,"zones":{...},"builds":{...}} (INFRARED_TENANT_QUOTAS; empty for none)`)
	flag.BoolVar(&d.AdmissionPolicies, "admission-policies", false, "AdmissionPolicies: the operator's admission policies on tenants' namespaces (INFRARED_ADMISSION_POLICIES)")
	flag.BoolVar(&d.DenyLogging, "deny-logging", false, "DenyLogging: GKE logs the denies of tenants' namespaces (INFRARED_DENY_LOGGING)")
	flag.BoolVar(&d.ArgoCDRestrictDefaultProject, "argocd-restrict-default-project", false, "ArgoCDRestrictDefaultProject: Argo CD's default project takes the platform's root alone (INFRARED_ARGOCD_RESTRICT_DEFAULT_PROJECT)")
	flag.StringVar(&d.BuildCaps, "build-caps", "", `BuildCaps: the chart's tenancy.buildCaps as one line of JSON, {"enabled":true,"deadlineMinutes":20,"minutesPerOrgPerDay":60} (INFRARED_BUILD_CAPS; empty for none)`)
	flag.StringVar(&d.TenantStorage, "tenant-storage", "", `TenantStorage: the chart's tenancy.tenantStorage as one line of JSON, {"enabled":true,"capGi":400,"minDiskGi":10} (INFRARED_TENANT_STORAGE; empty for none)`)
	flag.StringVar(&d.MetricsStorage, "metrics-storage", "",
		"MetricsStorage: the size of the install's metrics store, VMSingle's claim or on k3s with the stores its emptyDir, e.g. 40Gi (INFRARED_METRICS_STORAGE; empty: 10Gi)")
	flag.StringVar(&d.MetricsAuth, "metrics-auth", "",
		`MetricsAuth: "" (as before), "door" or "enforced": vmauth in front of the metrics store and Alertmanager, and at enforced the stack's back doors closed (INFRARED_METRICS_AUTH; the chart's clients is door)`)
	flag.StringVar(&d.MetricsAuthIssuer, "metrics-auth-issuer", "",
		"MetricsAuthIssuer: with -metrics-auth, the cluster's service account issuer, https, which the door checks the API's and the operator's tokens against (empty: no user for them)")
	flag.StringVar(&d.MetricsAuthAudience, "metrics-auth-audience", "",
		"MetricsAuthAudience: with -metrics-auth, the audience of the API's and the operator's tokens, a DNS label such as infrared-metrics (INFRARED_METRICS_TOKEN_AUDIENCE)")
	flag.BoolVar(&d.NodeExporterAuth, "node-exporter-auth", false,
		"NodeExporterAuth: node-exporter behind kube-rbac-proxy, which vmagent scrapes with its own token (INFRARED_NODE_EXPORTER_AUTH)")
	flag.StringVar(&d.MediaStore, "media-store", "",
		`MediaStore: "" (the chart's volume, as before), "both" or "objectStore": the API's videos and pictures in SeaweedFS's bucket media (INFRARED_MEDIA_STORE)`)
	flag.BoolVar(&d.StoresOrgLayout, "stores-org-layout", false,
		"StoresOrgLayout: the registry in the stores' org layout, Zot at the bucket's root and the platform's repositories under platform/images/ (the Installation's status.storage.layout org)")
	flag.BoolVar(&d.RegistryPaused, "registry-paused", false,
		"RegistryPaused: Zot stopped, no replica, while a migration between the stores' layouts moves its files")
	flag.BoolVar(&d.StorePaths, "store-paths", false,
		"StorePaths: the stores' applier of the path rules, the CronJob stores/seaweedfs-paths (INFRARED_STORES_POLICIES)")
	flag.BoolVar(&d.StoresMigration, "stores-migration", false,
		"StoresMigration: a migration between the stores' layouts runs, which needs the applier's CronJob, its schedule suspended")
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
	fmt.Printf("rendered %d files from %s into %s (cluster %s, flavor %s, build registry %q, edge %q, tunnel %q, private edge %t, stores %t, backup bucket %q, disabled %q, forge %q, registry %q, substrate capable %t, recipients %d, restore point %q)\n",
		n, src, out, d.ClusterName, d.ClusterFlavor, d.BuildRegistry, d.Edge, d.TunnelID, d.PrivateEdge, d.Stores, d.Backup.Bucket, d.Disabled, d.Forge, d.Registry, d.SubstrateCapable,
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
		"cluster":                func() { d.ClusterName = explicit.ClusterName },
		"flavor":                 func() { d.ClusterFlavor = explicit.ClusterFlavor },
		"region":                 func() { d.Region = explicit.Region },
		"org":                    func() { d.OrgName = explicit.OrgName },
		"repo-owner":             func() { d.GitopsRepoOwner = explicit.GitopsRepoOwner },
		"repo-name":              func() { d.GitopsRepoName = explicit.GitopsRepoName },
		"repo-url":               func() { d.GitopsRepoURL = explicit.GitopsRepoURL },
		"branch":                 func() { d.DefaultBranch = explicit.DefaultBranch },
		"template-version":       func() { d.TemplateVersion = explicit.TemplateVersion },
		"infrared-version":       func() { d.InfraredVersion = explicit.InfraredVersion },
		"chart-repo":             func() { d.InfraredChartRepo = explicit.InfraredChartRepo },
		"chart-version":          func() { d.InfraredChartVersion = explicit.InfraredChartVersion },
		"namespace":              func() { d.InfraredNamespace = explicit.InfraredNamespace },
		"pull-secret":            func() { d.ImagePullSecret = explicit.ImagePullSecret },
		"build-registry":         func() { d.BuildRegistry = explicit.BuildRegistry },
		"edge":                   func() { d.Edge = explicit.Edge },
		"platform-domain":        func() { d.PlatformDomain = explicit.PlatformDomain },
		"infrared-host":          func() { d.InfraredHost = explicit.InfraredHost },
		"domain-token-key":       func() { d.DomainTokenKey = explicit.DomainTokenKey },
		"tunnel-id":              func() { d.TunnelID = explicit.TunnelID },
		"tunnel-credentials-key": func() { d.TunnelCredentialsKey = explicit.TunnelCredentialsKey },
		"tunnel-mode":            func() { d.TunnelMode = explicit.TunnelMode },
		"tunnel-publish":         func() { d.TunnelPublish = explicit.TunnelPublish },
		"tunnel-hostnames":       func() { d.TunnelHostnames = explicit.TunnelHostnames },
		"org-labels":             func() { d.OrgLabels = explicit.OrgLabels },
		"sign-in-private":        func() { d.SignInPrivate = explicit.SignInPrivate },
		"edge-proof-secret":      func() { d.EdgeProofSecret = explicit.EdgeProofSecret },
		"private-edge":           func() { d.PrivateEdge = explicit.PrivateEdge },
		"image-registry":         func() { d.ImageRegistry = explicit.ImageRegistry },
		"images":                 func() { d.Images = explicit.Images },
		"cloud":                  func() { d.Cloud = explicit.Cloud },
		"substrate-capable":      func() { d.SubstrateCapable = explicit.SubstrateCapable },
		"stores":                 func() { d.Stores = explicit.Stores },
		"stores-single-node":     func() { d.StoresSingleNode = explicit.StoresSingleNode },
		"backup":                 func() { d.Backup = explicit.Backup },
		"disabled":               func() { d.Disabled = explicit.Disabled },
		"forge":                  func() { d.Forge = explicit.Forge },
		"forge-url":              func() { d.ForgeURL = explicit.ForgeURL },
		"registry":               func() { d.Registry = explicit.Registry },
		"copies":                 func() { d.Copies = explicit.Copies },
		"postgres-archive":       func() { d.PostgresArchive = explicit.PostgresArchive },
		"registry-retention":     func() { d.RegistryRetention = explicit.RegistryRetention },
		"restore":                func() { d.Restore = explicit.Restore },
		"postgres-server-name":   func() { d.PostgresServerName = explicit.PostgresServerName },
		"substrate-registry":     func() { d.SubstrateRegistry = explicit.SubstrateRegistry },
		"registry-token":         func() { d.RegistryToken = explicit.RegistryToken },
		"cloud-identity":         func() { d.CloudIdentity = explicit.CloudIdentity },
		"agent-pool":             func() { d.AgentPool = explicit.AgentPool },
		"running-chart-version":  func() { d.RunningChartVersion = explicit.RunningChartVersion },
		"oidc":                   func() { d.OIDC = explicit.OIDC },
		"grafana-url":            func() { d.GrafanaURL = explicit.GrafanaURL },
		"registry-pulls":         func() { d.RegistryPulls = explicit.RegistryPulls },
		"stores-security":        func() { d.StoresSecurity = explicit.StoresSecurity },
		"tenant-pods":            func() { d.TenantPods = explicit.TenantPods },
		"tenant-quotas":          func() { d.TenantQuotas = explicit.TenantQuotas },
		"admission-policies":     func() { d.AdmissionPolicies = explicit.AdmissionPolicies },
		"deny-logging":           func() { d.DenyLogging = explicit.DenyLogging },
		"argocd-restrict-default-project": func() {
			d.ArgoCDRestrictDefaultProject = explicit.ArgoCDRestrictDefaultProject
		},
		"build-caps":        func() { d.BuildCaps = explicit.BuildCaps },
		"tenant-storage":    func() { d.TenantStorage = explicit.TenantStorage },
		"metrics-storage":   func() { d.MetricsStorage = explicit.MetricsStorage },
		"media-store":       func() { d.MediaStore = explicit.MediaStore },
		"stores-org-layout": func() { d.StoresOrgLayout = explicit.StoresOrgLayout },
		"registry-paused":   func() { d.RegistryPaused = explicit.RegistryPaused },
		"store-paths":       func() { d.StorePaths = explicit.StorePaths },
		"stores-migration":  func() { d.StoresMigration = explicit.StoresMigration },
		"metrics-auth": func() {
			d.MetricsAuth = explicit.MetricsAuth
		},
		"metrics-auth-issuer": func() {
			d.MetricsAuthIssuer = explicit.MetricsAuthIssuer
		},
		"metrics-auth-audience": func() {
			d.MetricsAuthAudience = explicit.MetricsAuthAudience
		},
		"node-exporter-auth": func() {
			d.NodeExporterAuth = explicit.NodeExporterAuth
		},
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
	if d.CustomHostnames && d.Edge != "gateway" {
		errs = append(errs, errors.New("CustomHostnames needs Edge gateway: custom hostnames are served through the Gateway behind Cloudflare"))
	}
	if d.ACMEEmail != "" && (strings.ContainsAny(d.ACMEEmail, " \t\"") || strings.Count(d.ACMEEmail, "@") != 1) {
		errs = append(errs, fmt.Errorf("ACMEEmail must be one email address, got %q", d.ACMEEmail))
	}
	errs = append(errs, validateDomainTokenKey(d)...)
	errs = append(errs, validateTunnel(d)...)
	errs = append(errs, validateSignInPrivate(d)...)
	errs = append(errs, validateOrgLabels(d)...)
	errs = append(errs, validateEdgeProof(d)...)
	errs = append(errs, validatePrivateEdge(d)...)
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
	errs = append(errs, validateCloudIdentity(d.CloudIdentity)...)
	errs = append(errs, validateAgentPool(d.AgentPool)...)
	if err := validateGrafanaURL(d.GrafanaURL); err != nil {
		errs = append(errs, err)
	}
	errs = append(errs, validateTenancyCarry("TenantPods", d.TenantPods, "placement"),
		validateTenancyCarry("TenantQuotas", d.TenantQuotas, "zones", "builds"),
		validateTenancyCarry("BuildCaps", d.BuildCaps, "deadlineMinutes", "minutesPerOrgPerDay"),
		validateTenancyCarry("TenantStorage", d.TenantStorage, "capGi", "minDiskGi"))
	if d.MetricsStorage != "" && !metricsSize.MatchString(d.MetricsStorage) {
		errs = append(errs, fmt.Errorf("MetricsStorage must be the metrics store's size, a whole number above zero of Mi, Gi or Ti (or a larger binary unit), e.g. 40Gi, got %q", d.MetricsStorage))
	}
	if !slices.Contains(MediaStores, d.MediaStore) {
		errs = append(errs, fmt.Errorf("MediaStore must be one of %q (the chart's summaryvideo.store; its volume is empty here), got %q", MediaStores, d.MediaStore))
	}
	errs = append(errs, validateMetricsAuth(d)...)
	return errors.Join(errs...)
}

// MetricsAuths are the values of MetricsAuth the operator hands over: none,
// the door, and the door with the stack's back doors closed. The chart's
// clients is door here.
var MetricsAuths = []string{"", "door", "enforced"}

// audience is a ServiceAccount token's audience as the operator takes it, a
// DNS label: the door's match on the aud claim is a regular expression in
// vmauth, so nothing else may be read as one.
var audience = regexp.MustCompile(`^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$`)

// validateMetricsAuth refuses what the operator never hands over: a stage
// other than door or enforced, an issuer that is no https URL of a host
// without a query or fragment, an audience that is no DNS label, and either
// of them without the door.
func validateMetricsAuth(d Data) []error {
	var errs []error
	if !slices.Contains(MetricsAuths, d.MetricsAuth) {
		errs = append(errs, fmt.Errorf("MetricsAuth must be one of %q (the operator hands the chart's clients over as door), got %q", MetricsAuths, d.MetricsAuth))
	}
	if d.MetricsAuth == "" && (d.MetricsAuthIssuer != "" || d.MetricsAuthAudience != "") {
		errs = append(errs, errors.New("MetricsAuthIssuer and MetricsAuthAudience need MetricsAuth: without the door nothing reads them"))
	}
	if i := d.MetricsAuthIssuer; i != "" {
		if u, err := url.Parse(i); err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" ||
			strings.ContainsAny(i, " \t\"'") {
			errs = append(errs, fmt.Errorf("MetricsAuthIssuer must be the cluster's service account issuer, an https URL with no query or fragment, got %q", i))
		}
	}
	if a := d.MetricsAuthAudience; a != "" && !audience.MatchString(a) {
		errs = append(errs, fmt.Errorf("MetricsAuthAudience must be a token audience of lower-case letters, digits and hyphens, such as infrared-metrics, got %q", a))
	}
	return errs
}

// quantity is a Kubernetes resource quantity as the operator writes one: a
// whole or decimal number, with or without a unit.
var quantity = regexp.MustCompile(`^[0-9]+(\.[0-9]+)?(m|k|M|G|T|Ki|Mi|Gi|Ti)?$`)

// labelKey and labelValue are a Kubernetes label's key and value.
var (
	labelKey   = regexp.MustCompile(`^([a-z0-9]([-a-z0-9.]*[a-z0-9])?/)?[A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?$`)
	labelValue = regexp.MustCompile(`^([A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?)?$`)
)

// validateAgentPool checks the agents' WorkerPool: 1 to 64 workers, or, with
// the pool elastic, a floor and a ceiling of 0 to 64 and the workers between
// them; each size a quantity, a node selector of labels, and tolerations as
// Kubernetes takes them.
func validateAgentPool(p *AgentPool) []error {
	if p == nil {
		return nil
	}
	var errs []error
	switch {
	case p.MaxWorkers == 0 && p.MinWorkers != 0:
		errs = append(errs, fmt.Errorf("AgentPool.MinWorkers needs MaxWorkers, the elastic pool's ceiling, got %d", p.MinWorkers))
	case p.MaxWorkers == 0 && (p.Workers < 1 || p.Workers > 64):
		errs = append(errs, fmt.Errorf("AgentPool.Workers must be 1 to 64, got %d", p.Workers))
	case p.MaxWorkers < 0 || p.MaxWorkers > 64 || p.MinWorkers < 0 || p.MinWorkers > p.MaxWorkers:
		errs = append(errs, fmt.Errorf("AgentPool.MinWorkers and MaxWorkers must be 0 <= MinWorkers <= MaxWorkers <= 64, got %d and %d",
			p.MinWorkers, p.MaxWorkers))
	case p.MaxWorkers > 0 && (p.Workers < p.MinWorkers || p.Workers > p.MaxWorkers):
		errs = append(errs, fmt.Errorf("AgentPool.Workers of an elastic pool must be %d to %d, its floor to its ceiling, got %d",
			p.MinWorkers, p.MaxWorkers, p.Workers))
	}
	for name, v := range map[string]string{"CPU": p.CPU, "Memory": p.Memory, "RequestCPU": p.RequestCPU, "RequestMemory": p.RequestMemory} {
		if !quantity.MatchString(v) {
			errs = append(errs, fmt.Errorf("AgentPool.%s must be a resource quantity, e.g. 2500m or 9Gi, got %q", name, v))
		}
	}
	for k, v := range p.NodeSelector {
		if !labelKey.MatchString(k) || !labelValue.MatchString(v) {
			errs = append(errs, fmt.Errorf("AgentPool.NodeSelector must hold labels, got %q: %q", k, v))
		}
	}
	for _, t := range p.Tolerations {
		switch {
		case t.Key != "" && !labelKey.MatchString(t.Key), !labelValue.MatchString(t.Value):
			errs = append(errs, fmt.Errorf("AgentPool.Tolerations: a key and a value as a label's, got %q and %q", t.Key, t.Value))
		case !slices.Contains([]string{"", "Equal", "Exists"}, t.Operator):
			errs = append(errs, fmt.Errorf("AgentPool.Tolerations: an operator Equal or Exists, got %q", t.Operator))
		case !slices.Contains([]string{"", "NoSchedule", "PreferNoSchedule", "NoExecute"}, t.Effect):
			errs = append(errs, fmt.Errorf("AgentPool.Tolerations: an effect NoSchedule, PreferNoSchedule or NoExecute, got %q", t.Effect))
		case t.Key == "" && t.Operator == "Equal":
			errs = append(errs, errors.New("AgentPool.Tolerations: a toleration without a key tolerates every taint, with operator Exists"))
		}
	}
	return errs
}

// validateTenancyCarry checks one of the tenancy's settings the infrared
// Application carries as a line of JSON (TenantPods, TenantQuotas): empty, or
// one JSON object on one line with "enabled": true and only the keys the
// chart's block takes, so it lands in the Application's values as the chart
// reads it.
func validateTenancyCarry(name, v string, keys ...string) error {
	if v == "" {
		return nil
	}
	var m map[string]json.RawMessage
	if strings.ContainsAny(v, "\n\r") || json.Unmarshal([]byte(v), &m) != nil || string(m["enabled"]) != "true" {
		return fmt.Errorf(`%s must be one line of JSON, {"enabled":true, ...}, as the operator carries it, got %q`, name, v)
	}
	for k := range m {
		if k != "enabled" && !slices.Contains(keys, k) {
			return fmt.Errorf("%s takes enabled and %s alone, got %q", name, strings.Join(keys, ", "), k)
		}
	}
	return nil
}

// validateDomainTokenKey checks DomainTokenKey: empty, or a key of a Secret,
// and only on a gateway edge with a platform domain, the one edge that splits
// its certificates and DNS records by Cloudflare zone.
func validateDomainTokenKey(d Data) []error {
	if d.DomainTokenKey == "" {
		return nil
	}
	var errs []error
	if !secretKey.MatchString(d.DomainTokenKey) || d.DomainTokenKey == "." || strings.HasPrefix(d.DomainTokenKey, "..") {
		errs = append(errs, fmt.Errorf("DomainTokenKey must be a Secret's key: letters, digits, '-', '_' and '.', at most 253, not . or .., got %q", d.DomainTokenKey))
	}
	if d.Edge != "gateway" || d.PlatformDomain == "" {
		errs = append(errs, errors.New("DomainTokenKey needs Edge gateway and a PlatformDomain: only the Gateway edge serves the platform domain on a token of its own"))
	}
	return errs
}

// defaultTunnelCredentialsKey is the key of infrared-platform-tokens that
// holds the tunnel's credentials file when TunnelCredentialsKey names none:
// the key the Infrared chart's platformTokens.cloudflareTunnelCredentials
// writes, and the Installation's default.
const defaultTunnelCredentialsKey = "cloudflare-tunnel-credentials"

// maxTunnelHostnames is the most names spec.tunnel.hostnames takes.
const maxTunnelHostnames = 100

// tunnelBeside is the one TunnelMode the operator hands: the tunnel beside
// the nodes' own ports (ADR 0090); mode only arrives as "".
const tunnelBeside = "beside"

// validateTunnel checks the Cloudflare Tunnel: none, or a tunnel's UUID in
// lower case, as the Installation takes it, on a gateway edge, the one edge
// it fronts, with its credentials key a key of a Secret. A credentials key
// other than the default needs the tunnel it is for. TunnelMode is beside,
// with a tunnel, or empty, and TunnelPublish needs it beside (ADR 0090).
func validateTunnel(d Data) []error {
	var errs []error
	switch d.TunnelMode {
	case "":
	case tunnelBeside:
		if d.TunnelID == "" {
			errs = append(errs, errors.New("TunnelMode beside needs a TunnelID: it runs that tunnel beside the nodes' own ports"))
		}
	default:
		errs = append(errs, fmt.Errorf("TunnelMode must be beside or empty, the tunnel alone (the operator hands mode only as empty), got %q", d.TunnelMode))
	}
	if d.TunnelPublish && d.TunnelMode != tunnelBeside {
		errs = append(errs, errors.New("TunnelPublish needs TunnelMode beside: only beside the nodes' own ports does external-dns publish the edge's names"))
	}
	if d.TunnelID == "" {
		if d.TunnelCredentialsKey != "" && d.TunnelCredentialsKey != defaultTunnelCredentialsKey {
			errs = append(errs, errors.New("TunnelCredentialsKey needs a TunnelID: it names the credentials of the tunnel the edge is reached through"))
		}
		if len(d.TunnelHostnames) > 0 {
			errs = append(errs, errors.New("TunnelHostnames needs a TunnelID: they are the names that reach the edge through that tunnel"))
		}
		return errs
	}
	errs = append(errs, validateTunnelHostnames(d)...)
	if !tunnelID.MatchString(d.TunnelID) {
		errs = append(errs, fmt.Errorf("TunnelID must be a Cloudflare Tunnel's UUID, lower case, e.g. 6ff42ae2-765d-4adf-8112-31c55c1551ef, got %q", d.TunnelID))
	}
	if d.Edge != "gateway" {
		errs = append(errs, errors.New("TunnelID needs Edge gateway: the tunnel fronts the Gateway edge alone"))
	}
	if k := d.TunnelCredentialsKey; k != "" && (!secretKey.MatchString(k) || k == "." || strings.HasPrefix(k, "..")) {
		errs = append(errs, fmt.Errorf("TunnelCredentialsKey must be a Secret's key: letters, digits, '-', '_' and '.', at most 253, not . or .., got %q", k))
	}
	return errs
}

// validateTunnelHostnames checks TunnelHostnames as the operator hands them
// (ADR 0090): at most maxTunnelHostnames, each a DNS name of two labels or
// more, lower case, with no wildcard, at most 253 characters, listed once,
// and never InfraredHost, whose route is the template's own and which
// SignInPrivate keeps off the edge.
func validateTunnelHostnames(d Data) []error {
	var errs []error
	if len(d.TunnelHostnames) > maxTunnelHostnames {
		errs = append(errs, fmt.Errorf("TunnelHostnames lists %d names, at most %d", len(d.TunnelHostnames), maxTunnelHostnames))
	}
	seen := map[string]bool{}
	for _, h := range d.TunnelHostnames {
		switch {
		case len(h) > 253 || !hostname.MatchString(h):
			errs = append(errs, fmt.Errorf("TunnelHostnames: %q must be a DNS name, lower case, with no wildcard, e.g. support.example.com", h))
		case seen[h]:
			errs = append(errs, fmt.Errorf("TunnelHostnames: %q is listed twice", h))
		case h == d.InfraredHost:
			errs = append(errs, fmt.Errorf("TunnelHostnames: %q is InfraredHost, whose route is the template's own (the operator never lists it)", h))
		}
		seen[h] = true
	}
	return errs
}

// maxOrgLabelLength is the most characters an org's label takes, as the
// Organization's spec.addressLabel does.
const maxOrgLabelLength = 32

// validateOrgLabels checks OrgLabels as the operator hands them (ADR 0097):
// only on a gateway edge with a PlatformDomain, the one edge whose
// certificate names the domain's wildcard, each a DNS label, lower case, of
// 3 to maxOrgLabelLength characters, listed once.
func validateOrgLabels(d Data) []error {
	var errs []error
	if len(d.OrgLabels) > 0 && (d.Edge != "gateway" || d.PlatformDomain == "") {
		errs = append(errs, errors.New("OrgLabels needs Edge gateway and a PlatformDomain: they are names under that domain on the edge's certificate"))
	}
	seen := map[string]bool{}
	for _, l := range d.OrgLabels {
		switch {
		case len(l) < 3 || len(l) > maxOrgLabelLength || !orgLabel.MatchString(l):
			errs = append(errs, fmt.Errorf("OrgLabels: %q must be a DNS label, lower case, of 3 to %d characters, e.g. acme", l, maxOrgLabelLength))
		case seen[l]:
			errs = append(errs, fmt.Errorf("OrgLabels: %q is listed twice", l))
		}
		seen[l] = true
	}
	return errs
}

// validateSignInPrivate checks SignInPrivate: only on a gateway edge with an
// InfraredHost, the one edge that serves the name, and a PlatformDomain,
// which the Installation's previews always carry with it (ADR 0090).
func validateSignInPrivate(d Data) []error {
	if !d.SignInPrivate {
		return nil
	}
	if d.Edge != "gateway" || d.InfraredHost == "" || d.PlatformDomain == "" {
		return []error{errors.New("SignInPrivate needs Edge gateway, an InfraredHost and a PlatformDomain: only the Gateway edge serves Infrared's own name")}
	}
	return nil
}

// validateEdgeProof checks EdgeProofSecret: empty, or a Secret's name, and
// only on a gateway edge with an InfraredHost it serves (no SignInPrivate),
// the one edge whose route for Infrared stamps the proof, as the operator
// hands it.
func validateEdgeProof(d Data) []error {
	if d.EdgeProofSecret == "" {
		return nil
	}
	var errs []error
	if len(d.EdgeProofSecret) > 253 || !dnsSubdomain.MatchString(d.EdgeProofSecret) {
		errs = append(errs, fmt.Errorf("EdgeProofSecret must be a Secret's name: lowercase letters, digits, '-' and '.', at most 253, got %q", d.EdgeProofSecret))
	}
	if d.Edge != "gateway" || d.InfraredHost == "" {
		errs = append(errs, errors.New("EdgeProofSecret needs Edge gateway and an InfraredHost: only the Gateway edge's route for Infrared stamps the proof"))
	}
	if d.SignInPrivate {
		errs = append(errs, errors.New("EdgeProofSecret takes no SignInPrivate: with Infrared's own name off the edge, no route of Infrared's stamps the proof"))
	}
	return errs
}

// validatePrivateEdge checks PrivateEdge (infrared-docs-internal ADR 0100):
// only on a gateway edge, the one edge it keeps inside the cluster, and never
// beside what reaches an edge from outside, which the operator leaves out of
// its data with it: a Cloudflare Tunnel (TunnelID, and so its mode, publish
// and hostnames, which need one) and custom hostnames, which Cloudflare's
// proxy serves.
func validatePrivateEdge(d Data) []error {
	if !d.PrivateEdge {
		return nil
	}
	var errs []error
	if d.Edge != "gateway" {
		errs = append(errs, errors.New("PrivateEdge needs Edge gateway: it keeps the Gateway edge inside the cluster"))
	}
	if d.TunnelID != "" {
		errs = append(errs, errors.New("PrivateEdge takes no TunnelID: the private edge has no tunnel, and the operator leaves the tunnel out of its data with it"))
	}
	if d.CustomHostnames {
		errs = append(errs, errors.New("PrivateEdge takes no CustomHostnames: a custom hostname reaches the edge through Cloudflare's proxy, which nothing does on a private edge"))
	}
	return errs
}

// validateGrafanaURL checks GrafanaURL: empty, or Grafana's address in a
// browser, http(s) and a host with no trailing slash, user, query or fragment,
// as the operator hands it over. Grafana's root_url is it with a slash, and its
// redirect URI <GrafanaURL>/login/generic_oauth, which infrared-api matches
// exactly.
func validateGrafanaURL(grafanaURL string) error {
	if grafanaURL == "" {
		return nil
	}
	u, err := url.Parse(grafanaURL)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" || u.User != nil ||
		strings.HasSuffix(grafanaURL, "/") || strings.ContainsAny(grafanaURL, "?# \t\"'") {
		return fmt.Errorf("GrafanaURL must be Grafana's address in a browser, http(s) and a host with no trailing slash, user, query or fragment, got %q", grafanaURL)
	}
	return nil
}

// validateCloudIdentity checks the cloud identity: none, or a Google service
// account, at most one AWS mode, or both, and nothing empty.
func validateCloudIdentity(c *CloudIdentity) []error {
	if c == nil {
		return nil
	}
	var errs []error
	if *c == (CloudIdentity{}) {
		errs = append(errs, errors.New("CloudIdentity names no Google service account and no AWS mode: leave it out instead"))
	}
	if c.GCPServiceAccount != "" && !gcpServiceAccount.MatchString(c.GCPServiceAccount) {
		errs = append(errs, fmt.Errorf("CloudIdentity.GCPServiceAccount must be a Google service account, <name>@<project>.iam.gserviceaccount.com, got %q", c.GCPServiceAccount))
	}
	if c.AWSRoleARN != "" && !awsRoleARN.MatchString(c.AWSRoleARN) {
		errs = append(errs, fmt.Errorf("CloudIdentity.AWSRoleARN must be an IAM role, arn:aws:iam::<account>:role/<name>, got %q", c.AWSRoleARN))
	}
	modes := 0
	for _, on := range []bool{c.AWSRoleARN != "", c.AWSHostNetwork, c.AWSWebIdentity} {
		if on {
			modes++
		}
	}
	if modes > 1 {
		errs = append(errs, errors.New("CloudIdentity names more than one AWS mode (AWSRoleARN, AWSHostNetwork, AWSWebIdentity): one at most"))
	}
	return errs
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
	// hostname is a name of TunnelHostnames: a DNS name of two labels or
	// more, lower case, with no wildcard (the CRD's pattern for
	// spec.tunnel.hostnames).
	hostname = regexp.MustCompile(`^([a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\.)+[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$`)
	// orgLabel is a label of OrgLabels: one DNS label, lower case (the CRD's
	// pattern for an Organization's spec.addressLabel).
	orgLabel = regexp.MustCompile(`^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`)
	// tunnelID is a Cloudflare Tunnel's UUID, lower case.
	tunnelID = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
	// dnsSubdomain is an object's name, such as a Secret's: DNS labels joined
	// by dots (at most 253 characters, checked apart).
	dnsSubdomain = regexp.MustCompile(`^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$`)
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
	// metricsSize is the metrics store's size as the operator hands it: the
	// canonical form of a whole number above zero of Mi, Gi or Ti, which may
	// name a larger binary unit (1024Ti is 1Pi).
	metricsSize = regexp.MustCompile(`^[1-9][0-9]*(Mi|Gi|Ti|Pi|Ei)$`)
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
