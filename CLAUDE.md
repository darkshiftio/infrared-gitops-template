# infrared-gitops-template

Part of Infrared (github.com/darkshiftio). This repo is the template the
Infrared operator renders into a customer's gitops repo when it bootstraps a
management cluster. `README.md` is the contract; read it before changing
anything under `template/`.

- Vocabulary, exactly: management cluster, workload cluster, cluster template,
  gitops repo, registry (`registry/clusters/<cluster>/`), app-of-apps,
  Application, AppProject, sync wave, Synced/Healthy, gitops catalog, zone,
  promotion, pin (`tag@sha256`), AgentRole/AgentWorkflow/AgentWorkflowRun.
  Never hub, spoke, persona or pipeline.
- The rendering contract (delimiters `[[ ]]`, `.tmpl` stripped, `__cluster__`
  path segments, the Data fields) is shared with the operator. Changing it is a
  change to both repos, in step. `hack/render` must keep implementing it
  exactly; templates use only text/template builtins plus the operator's
  small helper set (contains, hasPrefix, hasSuffix, quote, ...; listed in
  README.md), never sprig.
- `components/argocd`, `components/kpack` and `components/infisical` are
  verbatim (no `.tmpl`): the operator kustomize-builds `components/argocd`
  directly. Re-vendor upstream with `scripts/vendor-*.sh`, never by hand.
- Every Application carries `app.kubernetes.io/part-of: infrared-gitops`, a
  sync wave, `SkipDryRunOnMissingResource=true` and the standard retry block.
  `scripts/verify.sh` enforces it.
- Pin every upstream chart and manifest to an explicit version.
- `make verify` before every PR. Never apply from CI; this repo holds no
  credentials. AWS work uses the `darkshift` profile only.
- Commits: conventional commits. No AI attribution lines in commits or PRs.
