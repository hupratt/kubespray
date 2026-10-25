# Kubernetes node drain/uncordon shutdown hook

Files:
- `k8s-drain.sh` — cordons, taints (`homelab.io/shutting-down=true:NoSchedule`),
  and drains the node. Called by the shutdown-watcher below.
- `k8s-shutdown-watcher.sh` — holds a systemd shutdown inhibitor lock and
  waits for the `PrepareForShutdown` D-Bus signal; when it fires, runs
  `k8s-drain.sh` *before* releasing the lock, so the drain genuinely
  finishes before the OS starts tearing down containers.
- `k8s-uncordon.sh` — waits for the API server, removes the taint, uncordons.
  Called on boot by `k8s-node-uncordon.service`.
- `k8s-node-drain.service` — wraps the watcher in `systemd-inhibit`.
- `k8s-node-uncordon.service` — runs the uncordon script on boot.
- `90-k8s-drain-logind.conf` — raises `InhibitDelayMaxSec` so logind
  actually waits long enough for the drain to finish.
- `rbac.yaml` — a ServiceAccount + ClusterRole scoped to just what
  cordon/taint/drain/uncordon needs (not cluster-admin).

## Why not a plain ExecStop hook

An earlier version of this used `Before=shutdown.target` +
`ExecStop=` on a no-op unit. That's a common pattern, but it turned out
to be insufficient here: each container runs in its own transient systemd
scope (`cri-containerd-<id>.scope`), and those get swept into the general
shutdown-transaction fan-out as soon as it starts — regardless of
`kubelet.service`'s own stop ordering, since there's no way to declare
`Before=`/`After=` against container scopes that don't exist until
runtime. In testing, the API server was already unreachable ~20s before
`kubelet.service` even began stopping. `Before=shutdown.target` only
guarantees *our* unit finishes before that target is reached — it does
nothing to stop everything else from racing to their death in parallel.

The inhibitor-lock approach avoids this entirely: holding a `delay`-type
shutdown inhibitor makes `systemd-logind` pause the *whole* shutdown
transition — before any container teardown begins — until we release it.

## Why a separate ServiceAccount/kubeconfig

These scripts run from systemd directly on the host, not from a Pod, so
there's no projected ServiceAccount token available the way there would be
inside the cluster. You need a standing kubeconfig on each node with a token
tied to the restricted `node-drain-agent` ClusterRole above — not your admin
kubeconfig.

## One-time cluster setup

```bash
kubectl apply -f rbac.yaml

# Long-lived token (1 year here; adjust as you like). Requires k8s 1.24+.
TOKEN=$(kubectl -n kube-system create token node-drain-agent --duration=8760h)

# Cluster CA + API server URL, taken from your existing kubeconfig/cluster.
CA_DATA=$(kubectl config view --raw --minify --flatten \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
SERVER=$(kubectl config view --raw --minify --flatten \
  -o jsonpath='{.clusters[0].cluster.server}')

cat > drain-kubeconfig <<EOF
apiVersion: v1
kind: Config
clusters:
- name: default
  cluster:
    certificate-authority-data: ${CA_DATA}
    server: ${SERVER}
contexts:
- name: default
  context:
    cluster: default
    user: node-drain-agent
current-context: default
users:
- name: node-drain-agent
  user:
    token: ${TOKEN}
EOF
```

Copy the resulting `drain-kubeconfig` to `/etc/kubernetes/drain-kubeconfig`
on **every worker node** (mode `0600`, owned by root). Since the token has a
fixed expiry, note a reminder to rotate it (re-run the `create token` step
and redistribute) before it lapses — there's no controller auto-renewing it.

## Per-node install (Fedora CoreOS)

`/usr` is read-only on CoreOS, so put the scripts under `/opt` (which is a
writable symlink to `/var/opt`) or `/var/home/core/bin` — not `/usr/local/bin`
as literally written in the unit files if your image doesn't allow writes
there. Adjust the `ExecStart=`/`ExecStop=` paths in the two `.service` files
to match wherever you actually put the scripts.

```bash
./oneoff.sh
```

`busctl` (used by the watcher to catch the D-Bus signal) ships with
systemd itself, so no extra package should be needed on CoreOS.

`kubectl` must be on `PATH` for root at boot/shutdown time (both scripts
no-op cleanly if it's missing, but obviously won't do anything useful). On a
Kubespray-built CoreOS worker `kubectl` usually isn't installed by default —
grab a static binary matching your cluster's minor version and drop it in
`/opt/bin/kubectl` (also on the writable `/opt` path) if it's not already
present.

## How the shutdown hook actually fires

`k8s-node-drain.service` runs `systemd-inhibit --what=shutdown --mode=delay
... k8s-shutdown-watcher.sh` for the whole uptime of the node. Holding that
lock means logind will pause (not skip) any `systemctl poweroff`/`reboot`/
normal shutdown for up to `InhibitDelayMaxSec` while the lock is held. The
watcher blocks on the `PrepareForShutdown` D-Bus signal; when logind
broadcasts it, the watcher runs the drain script synchronously, then exits
— releasing the lock and letting the shutdown actually proceed. This won't
fire on a hard power loss or `kill -9`, only a controlled shutdown/reboot
that goes through logind (which `systemctl reboot`/`poweroff` do by default).

## logind's InhibitDelayMaxSec — two gotchas

`InhibitDelayMaxSec` caps how long *any* inhibitor (ours or kubelet's own)
can delay a shutdown. Two things to know:

1. **Kubespray templates its own drop-in** at
   `/etc/systemd/logind.conf.d/99-kubelet.conf`, matching whatever
   `shutdownGracePeriod` was set to at provisioning time. This is a
   **static file** — the running kubelet process does not rewrite it on
   restart, so editing `/var/lib/kubelet/config.yaml` by hand (as we did
   to raise the grace period) does **not** update it. It'll silently
   drift out of sync with the live config unless you edit it too.
2. Because `99-kubelet.conf` sorts after a plain `90-...conf`, our own
   drop-in needs a name that sorts after it regardless of numeric
   prefix — hence `zz-k8s-drain-logind.conf` (any letter prefix beats
   any digit prefix in a plain alphabetical sort).

Install ours and confirm it's the one actually in effect:

```bash
install -o root -g root -m 0644 -D zz-k8s-drain-logind.conf \
  /etc/systemd/logind.conf.d/zz-k8s-drain-logind.conf
systemctl restart systemd-logind
busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
  org.freedesktop.login1.Manager InhibitDelayMaxUSec
# should read 200000000
```

Whatever you set kubelet's `shutdownGracePeriod` to, keep this value
comfortably above it (currently 180s → 200s here), or logind will force
the shutdown through before kubelet's own critical-pod-protection window
even finishes.

## Kubelet already owns its own shutdown inhibitor — don't fight it

```yaml
shutdownGracePeriod: 150s
shutdownGracePeriodCriticalPods: 20s
```

Static pods (including the API server) are treated as critical and held
alive until the *final* `shutdownGracePeriodCriticalPods` window, so this
gives our watcher roughly `150s - 20s = 130s` of a still-live API server
to run the drain — `k8s-drain.sh`'s default `DRAIN_TIMEOUT=90s` leaves
comfortable margin under that.

Note kubelet's own graceful-shutdown pod termination and our
`kubectl drain` are still two independent, uncoordinated mechanisms
reacting to the same signal — kubelet will start gracefully terminating
non-critical pods on its own timeline regardless of our drain. That's
fine for the goal here (nothing gets hard-killed instantly), but don't
expect our drain to be the *only* thing terminating pods during shutdown.

## Testing

```bash
# Confirm the drain fires:
systemctl reboot
# then on another node, watch:
kubectl get node <node> -w
kubectl describe node <node> | grep -A2 Taints

# Confirm uncordon/taint-removal on boot: after it comes back, taint
# should be gone and node schedulable again within ~WAIT_RETRIES*5s.

# After the fact, check both logs from the *previous* boot:
journalctl -t k8s-shutdown-watcher -b -1 --no-pager
journalctl -t k8s-drain -b -1 --no-pager
```

If the watcher's log shows the "Shutdown requested..." line but
`k8s-drain` still says API-unreachable, the inhibitor isn't actually being
respected — double check `systemctl restart systemd-logind` was run after
installing the logind drop-in, and that `loginctl show-manager` reports
`InhibitDelayMaxSec` at the new value (not the default 5s).

Tunable via environment overrides in the unit files (`Environment=`) or by
exporting before invocation: `NODE_NAME`, `KUBECONFIG`, `DRAIN_TIMEOUT`,
`TAINT_KEY`, `WAIT_RETRIES`.
