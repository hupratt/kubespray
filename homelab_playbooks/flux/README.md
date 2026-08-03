# Flux GitOps for the homelab cluster

This tree is the GitOps replacement for the imperative Ansible playbooks in
`homelab_playbooks/*.yaml`. Instead of running `ansible-playbook` against the
cluster, Flux continuously reconciles the desired state from this directory.

This is a **pilot**: the full scaffold plus a few representative apps are
converted so the patterns are established. The remaining apps follow the same
templates (see [Migration map](#migration-map)).

## Layout

```
flux/
├── clusters/homelab/            # what THIS cluster reconciles
│   ├── flux-system/
│   │   └── gotk-sync.yaml        # GitRepository (source) + root Kustomization
│   ├── infrastructure.yaml       # infra-controllers -> infra-configs (ordered)
│   └── apps.yaml                 # apps (dependsOn infra-configs)
├── infrastructure/
│   ├── controllers/              # operators via Helm (ESO, cert-manager)
│   └── configs/                  # namespaces, ClusterSecretStore (vault-backend)
└── apps/homelab/                 # application HelmReleases / manifests
    ├── kube-prometheus-stack/    # external-Helm-repo pattern (from 00c)
    └── linkwarden/               # git-chart + ExternalSecret + valuesFrom (from 21)
```

Reconciliation order is enforced with `dependsOn` + `wait: true`:

```
flux-system (root)
  └─ infra-controllers   (ESO, cert-manager — CRDs Ready)
       └─ infra-configs  (namespaces, vault-backend ClusterSecretStore)
            └─ apps       (kube-prometheus-stack, linkwarden, …)
```

## One-time bootstrap (Flux is not yet installed)

Two things below are **not** GitOps-managed because they need secrets/tokens
that must not live in Git.

### 1. Vault-side ESO wiring (still Ansible)

The Kubernetes auth method, `eso-policy`, and `eso-role` inside Vault are still
provisioned by `02d-hashicorp-vault.yaml` (it uses the Vault root token). Run
that part once before Flux brings up the `vault-backend` ClusterSecretStore.
Only the ClusterSecretStore *object* moved to Git
(`infrastructure/configs/cluster-secret-store/vault-backend.yaml`).

### 2. Install Flux and point it at this repo

The cluster repo is private (`gitlab.thekor.eu`), so Flux syncs over SSH.

```bash
# Install the Flux CLI, then bootstrap against the private GitLab repo.
export GITLAB_TOKEN=<pat-with-api-scope>   # or use --deploy-key for SSH
flux bootstrap git \
  --url=ssh://git@gitlab.thekor.eu:2022/flux/kubespray.git \
  --branch=homelab \
  --path=homelab_playbooks/flux/clusters/homelab \
  --private-key-file=$HOME/.ssh/id_ed25519_ansible
```

`bootstrap` installs the Flux controllers and creates the `flux-system` secret
referenced by `gotk-sync.yaml`. If you prefer to install controllers manually:

```bash
flux install
flux create secret git flux-system \
  --url=ssh://git@gitlab.thekor.eu:2022/flux/kubespray.git \
  --private-key-file=$HOME/.ssh/id_ed25519_ansible
kubectl apply -k homelab_playbooks/flux/clusters/homelab/flux-system
```

### 3. Per-app git-chart credentials

Apps whose Helm chart is pulled from a private repo need their own SSH secret.
For the linkwarden pilot:

```bash
flux create secret git linkwarden-git-auth \
  --namespace=linkwarden \
  --url=ssh://git@gitlab.thekor.eu/kube/linkwarden.git \
  --private-key-file=$HOME/.ssh/id_ed25519
```

## How the Ansible patterns map to Flux

| Ansible task | Flux equivalent |
| --- | --- |
| `kubernetes.core.k8s` Namespace | plain `Namespace` manifest in `infrastructure/configs/namespaces` |
| `helm repo add` + `helm install` (external repo) | `HelmRepository` + `HelmRelease` (see `kube-prometheus-stack`) |
| `git clone` + `helm install ./chart` (local chart) | `GitRepository` source + `HelmRelease` with `chart.spec.chart: <path>` (see `linkwarden`) |
| `template` values.j2 with Vault secrets → `values_files` | static values inline + `valuesFrom` `targetPath` reading the ESO Secret |
| `ExternalSecret` via `kubernetes.core.k8s` | commit the `ExternalSecret` manifest directly |
| `ConfigMap` via `kubernetes.core.k8s` | commit the `ConfigMap` manifest directly |
| `ClusterSecretStore` deploy | commit once in `infrastructure/configs/cluster-secret-store` |

### Secret handling

No plaintext secrets live in Git. `ExternalSecret` objects are committed as-is;
ESO reconciles them against Vault through the `vault-backend` ClusterSecretStore
and produces the in-cluster `Secret`. Where a Helm chart needed a secret value
inside its values (e.g. linkwarden DB creds), the `HelmRelease` pulls that
scalar from the ESO-managed `Secret` via `valuesFrom` + `targetPath` — the exact
values the `.j2` template used to interpolate.

## Migration map

**All numbered playbooks have been migrated.** The tree now holds ~40 apps, the
backups group, and the infrastructure layers — every `kustomization.yaml` builds
with `kubectl kustomize`. What remains is runtime setup (one-time secrets, Vault
seeding) and a handful of items that can't be represented declaratively.

### Reconciliation model

`infra-controllers` is `wait: true` (a strict CRD gate) and contains **only**
operators installed from public sources, each declaring its own namespace inline:
external-secrets, cert-manager, kyverno, haproxy, cloudnative-pg, volsync,
mariadb-operator. `infra-configs` and `apps` are `wait: false`, so one app that is
missing a one-time git/SSH secret or an un-seeded Vault key cannot block the other
~40 — each reconciles (and self-heals on retry) independently.

MariaDB *instances* were split out of the operator dir into
`apps/homelab/mariadb-instances/` (they need ESO + operator CRDs, both of which are
only guaranteed by the apps layer). Vault was moved to `apps/homelab/vault/` (its
ServiceMonitor needs the Prometheus CRDs that arrive with kube-prometheus-stack).

### Created but intentionally NOT wired

These leaf dirs exist and build, but are left out of their aggregator because they
would block the `wait: true` controllers layer. Wire them once the prerequisite is
resolved:

- `infrastructure/controllers/rook-ceph/` — the CephFilesystem needs the rook
  operator, which is **not** in this tree (`01a`/`01b` clone a private rook repo
  and hand-tune the CephCluster interactively). Publish rook as its own
  GitRepository-backed Kustomization, then add `rook-ceph` to the controllers
  aggregator.
- `infrastructure/controllers/cert-manager-webhook-hetzner/` — the webhook chart
  was `helm install`ed from a local path; the GitRepository source is a
  best-guess placeholder. Verify the chart's git source (+ create the
  `cert-manager-webhook-hetzner-git-auth` SSH secret), then wire it in. Until then
  the `wildcard-thekor` Certificate in `configs/cert-manager-issuers` won't issue.

### One-time setup required before apps go green

- **Per-app git-chart SSH secrets** (private GitLab charts): `linkwarden-git-auth`,
  `vaultwarden-git-auth`, `netbox-git-auth`, `sftpgo-git-auth`, `patchmon-git-auth`,
  `dawarich-git-auth`, plus the matrix signal-bridge repo. Create with
  `flux create secret git <name> --namespace <ns> --url ssh://… --private-key-file …`.
  `dawarich` also points at a **placeholder** repo URL — fix it to the real chart source.
- **Vault KV seeding**: the imperative `vault_kv2_write` steps (root token) that
  populated `kv/<app>` were not migrated. Several ExternalSecrets use **inferred**
  KV keys/properties — verify before relying on them: the matrix bridges
  (`synapse`, `mautrixdiscord`, `pickle_key`), `hetzner-ddns` (`hetzner/ddns_api_token`),
  the DB-backup creds (`postgres-backup`, `mongodb-backup`), and `restic-technitium`.
- **influx values are Ansible-Vault-encrypted** (`charts/influx/influx-values.yml`)
  — `influxdb` currently deploys with chart defaults only. Decrypt, then model the
  secrets as an ExternalSecret + `valuesFrom`.
- **mittwald replicator**: multiple apps annotate secrets with `replicate-to`
  (docker pull secret, mariadb creds). The `kubernetes-replicator` controller that
  honours those annotations is wired in at
  `infrastructure/controllers/kubernetes-replicator/` (migrated from `03a`). Note
  the wildcard-`thekor` TLS secret's `replicate-to` annotation was applied by `03a`
  as a patch to the cert-manager-owned Secret; add it to the `wildcard-thekor`
  Certificate's `secretTemplate.annotations` in `configs/cert-manager-issuers` so
  the fan-out of the TLS cert is declarative too.

### Pre-existing source bugs carried over verbatim (fix at the source)

- `www` — ExternalSecret targets `portfolio-vault-secrets` but the Deployment reads
  `portfolio-backend-env` (names don't match; env won't load).
- `patchmon` — chart expects `patchmon-oidc-secret`; playbook only creates
  `patchmon-server-secret`.
- `frigate` — chart mounts a `frigate-config` ConfigMap; secrets now render the
  config into a Secret, so the chart's mount must be repointed.

### Not GitOps-able (stay imperative / Ansible)

Vault init/unseal/restore (`02b`/`02c`), the postgres restore runbook (`08e`),
`deploy-backup.sh` kubeconfig generation + scp, image builds/pushes to
`registry.thekor.eu`, one-off DB bootstraps and `mongorestore`/`pg_dump` seeding,
and host-side steps (PV backing dirs on `coreos-wk-4`, nodelocaldns/kubelet
patches). These are noted in the per-dir file comments.

### Verify locally

```bash
for d in $(find homelab_playbooks/flux -name kustomization.yaml -printf '%h\n'); do
  kubectl kustomize "$d" >/dev/null && echo "OK $d" || echo "FAIL $d"
done
```
