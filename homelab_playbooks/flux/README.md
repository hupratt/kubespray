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

## Validate locally

```bash
# every leaf + aggregate kustomization must build:
for d in $(find homelab_playbooks/flux -name kustomization.yaml -printf '%h\n'); do
  kubectl kustomize "$d" >/dev/null && echo "OK $d" || echo "FAIL $d"
done
```

## Migration map

Converted in this pilot:

- [x] `00a-ns.yaml` → `infrastructure/configs/namespaces`
- [x] `02d` (ESO install + ClusterSecretStore) → `infrastructure/controllers/external-secrets` + `infrastructure/configs/cluster-secret-store`
- [x] `03a` (cert-manager controller only) → `infrastructure/controllers/cert-manager`
- [x] `00c-prometheus.yaml` → `apps/homelab/kube-prometheus-stack`
- [x] `21-linkwarden.yaml` → `apps/homelab/linkwarden`

Not yet migrated (follow the same patterns above):

- **cert-manager extras** — the `cert-manager-webhook-hetzner` chart,
  `ClusterIssuer`, and wildcard `Certificate` from `03a` (the webhook chart was
  installed from a local path `/home/hugo/...`; needs a GitRepository/HelmRepo
  source before it can be GitOps-managed).
- **Storage / rook-ceph** — `01a`/`01b`, `46-slow-storage.yaml`.
- **Databases/operators** — cloudnative-pg (`08*`), mariadb-operator (`09`).
- **Remaining apps** — the rest of the numbered playbooks (harbor, netbox,
  authentik, paperless, immich, matrix, sftpgo, vaultwarden, …). Each becomes an
  `apps/homelab/<name>/` dir: `HelmRepository`-or-`GitRepository` + `HelmRelease`
  + `ExternalSecret` (+ any `ConfigMap`), added to `apps/homelab/kustomization.yaml`.
- **Backups / CronJobs** — the `13-backupuser`, `15-*`, `16-*`, `34-backup-etcd`,
  `39–45 restic-*` playbooks become committed `CronJob`/RBAC manifests, ideally
  under a new `apps/homelab/backups/` group.

Once you're happy with the pilot, the remaining apps are mechanical and a good
fit for a parallel fan-out — say the word and I'll convert them in batches.
