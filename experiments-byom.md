# Embedding Container Images in CAA — BYOM Validation

End-to-end validation of the embedded container image approach using the local
CAA **BYOM** (Bring Your Own Machine) setup on a kind cluster.  This proves the
adapted changes (guest-components `reference_db` patch + CAA podvm embedded
image support) work on the latest release bases (guest-components v0.21.0,
cloud-api-adaptor v0.22.0).

> **Why BYOM?**  In BYOM the peer pod "VM" is a Docker container, so we can
> `docker exec` into it and inspect the CDH journal, mounts, and network state
> directly — much simpler than the libvirt/qcow2 route used in
> [experiments-caa.md](experiments-caa.md).

---

## What was validated

| Component | Change | Source branch |
|---|---|---|
| guest-components | `reference_db` in image-rs `MetaStore` so CDH can serve pre-embedded images without registry contact | `image-cache-reference-db-v0.21.0` |
| cloud-api-adaptor | `image-embedded` podvm build + `kata-image-cache` boot service | `feature/embedded-image-cache-v0.22.0` |

The validation used a **containerized** form of the embedded podvm (BYOM pool
VMs are containers).  The cache layout, boot service, and bind-mount logic are
identical to the mkosi/qcow2 path in the PR branches.

---

## Test setup (BYOM on kind)

### 1. Cluster

- kind cluster `peer-pods` with Calico CNI
- Worker node labeled for CAA and kata-remote
- `discard_unpacked_layers = false` so peer pod images stay unpacked on the node

### 2. Patched CDH binaries (built from the adapted GC branch)

Built from `image-cache-reference-db-v0.21.0` (gnu libc, since the pool VM is
Ubuntu):

```
confidential-data-hub  v0.21.0-04214c4e
resource providers:    KBS, SEV
kms plugins:           ALIYUN
```

- `confidential-data-hub` — the daemon (with `reference_db` support)
- `cdh-oneshot` — the one-shot CLI used to pre-pull the image at build time
  (built with `ONE_SHOT=true`, which renames the output; save the daemon first)

### 3. Embedded podvm-byom container image

Built from `podvm-byom-e2e-image-amd64:latest` plus:

| Path in image | Content |
|---|---|
| `/usr/local/bin/confidential-data-hub` | patched CDH daemon (`v0.21.0-04214c4e`) |
| `/usr/lib/kata-cache/layers/` | pre-pulled nginx layer directories (0..6) |
| `/usr/lib/kata-cache/meta_store.json` | image-rs reference database with `reference_db` |
| `/usr/local/bin/kata-image-cache-setup` | boot script: copies meta_store.json + bind-mounts layers |
| `/usr/lib/systemd/system/kata-image-cache.service` | one-shot service (enabled) |
| drop-ins for CDH + kata-agent | soft `Wants=`/`After=` the cache service |

The pre-pull ran inside the Docker build via `cdh-oneshot pull-image`
(`--security=insecure --network=host`), exactly like the mkosi Dockerfile.

`meta_store.json` contains both the tag and digest forms in `reference_db`:

```json
"reference_db": {
  "docker.io/library/nginx:latest": "sha256:878c3373...",
  "docker.io/library/nginx@sha256:1eeaa05a...": "sha256:878c3373..."
}
```

### 4. Pool VMs

Three pool containers (`podvm-byom-1..3`) running the embedded image on the
`kind` network, with the BYOM SSH key installed:

```
podvm-byom-1: 172.18.0.4
podvm-byom-2: 172.18.0.5
podvm-byom-3: 172.18.0.6
```

### 5. CAA deployment

CAA v0.22.0 helm chart deployed with the BYOM provider:

```
CLOUD_PROVIDER=byom make deploy
```

- kata-deploy subchart installed the `kata-remote` shim into containerd
  (`/opt/kata/containerd/config.d/kata-deploy.toml`)
- Webhook adds `kata.peerpods.io/vm: 1` + node affinity to kata-remote pods
- Worker node labeled `katacontainers.io/kata-runtime=true`
- BYOM pool IPs set to `172.18.0.4,172.18.0.5,172.18.0.6`

### 6. Test image

`docker.io/library/nginx:latest` (66 MB) — cached on the node so kubelet's
`IfNotPresent` skips the node-side pull; the only variable is CDH inside the VM.

---

## Validation cases

### Case A — embedded image, registry OPEN → PASS

```yaml
# test-embedded.yaml
apiVersion: v1
kind: Pod
metadata:
  name: embedded-image-test
spec:
  runtimeClassName: kata-remote
  containers:
  - name: test
    image: docker.io/library/nginx:latest
    imagePullPolicy: IfNotPresent
    args: ["sleep", "3600"]
    resources:
      requests: { memory: "2Gi" }
      limits:   { memory: "2Gi" }
  restartPolicy: Never
```

Pod reached `Running`; pool VM `172.18.0.6` allocated.

### Case B — embedded image, registry BLOCKED → PASS ✅

Registry blocked **inside the pool VMs** (iptables DROP on every docker.io IP):

```bash
IPS=$(getent ahosts registry-1.docker.io | awk '{print $1}' | sort -u | grep -v ":")
for ip in $IPS; do
  iptables -I OUTPUT  -d "$ip" -j DROP
  iptables -I FORWARD -d "$ip" -j DROP
done
```

Verified unreachable before running the pod.

**Result: pod Running, Ready in 10 s** — with the registry completely blocked.

```
NAME                  READY   STATUS    RESTARTS   AGE   IP               NODE               NOMINATED NODE
embedded-image-test   1/1     Running   0          16s   192.168.107.73   peer-pods-worker   <none>
```

### Case C — NOT-embedded image, registry BLOCKED → FAIL (control) ❌

Same block, same cluster, different image (`docker.io/library/redis:latest`,
not in the embedded cache):

```
Warning  Failed  Error: failed to create containerd task:
  [CDH] [ERROR]: Image Pull error: Failed to pull image
  docker.io/library/redis:latest ... failed to pull image manifest:
  Not authorized: url https://index.docker.io/v2/library/redis/manifests/latest
```

---

## Summary table

| Case | Image in embedded cache | Registry blocked | Result |
|---|---|---|---|
| A | nginx — yes | no | **PASS** (Running) |
| B | nginx — yes | **yes** | **PASS** (Running, 10 s) |
| C | redis — no | **yes** | **FAIL** (CDH pull blocked) |

Cases B and C together are conclusive: with the registry unreachable, the
embedded image still runs and a non-embedded image fails.  The only way CDH
could serve nginx is the local embedded cache.

---

## Proof inside the pool VM

Collected via `docker exec` into the allocated pool VM:

### 1. CDH journal — the cache hit

```
INFO image_rs::builder: Existing metadata found. Using previous ones.
INFO image_rs::image: Image docker.io/library/nginx:latest found in local cache, creating bundle
```

`found in local cache, creating bundle` is emitted by the `reference_db` fast
path added in the guest-components patch — image-rs created the bundle directly
from the local layer store, with no registry round-trip.

### 2. Boot cache service

```
kata-image-cache.service - Kata Peer Pod Image Cache Setup
     Active: active (exited) since ...
    Process: 64 ExecStart=/usr/local/bin/kata-image-cache-setup (code=exited, status=0/SUCCESS)
kata-image-cache-setup[64]: kata-image-cache: bound layer 0
kata-image-cache-setup[64]: kata-image-cache: bound layer 1
kata-image-cache-setup[64]: kata-image-cache: bound layer 2
...
```

### 3. Layer store = bind-mounted embedded layers

`findmnt` shows each CDH layer path backed by the embedded cache:

```
/run/kata-containers/image/layers/0   overlay[/usr/lib/kata-cache/layers/0]   overlay ro
/run/kata-containers/image/layers/1   overlay[/usr/lib/kata-cache/layers/1]   overlay ro
/run/kata-containers/image/layers/2   overlay[/usr/lib/kata-cache/layers/2]   overlay ro
```

### 4. meta_store.json present in the CDH work dir

```
-rw-r--r-- 1 root root 13653 ... /run/kata-containers/image/meta_store.json
```

---

## What this proves

1. The **guest-components `reference_db` patch** works on v0.21.0 — CDH hits the
   local cache on the first `PullImage` call and skips the registry.
2. The **CAA embedded image support** works on v0.22.0 — the podvm carries the
   cache and the boot service populates the CDH layer store before CDH/agent
   start.
3. **No registry contact is made** when the embedded cache is present — proven
   by the in-VM registry block combined with the redis control failure.

---

## Test artifacts

| Artifact | Location |
|---|---|
| Embedded podvm-byom image | `podvm-byom-embedded:test` (local docker) |
| Patched CDH daemon | built from `image-cache-reference-db-v0.21.0` |
| Patched cdh-oneshot | built from `image-cache-reference-db-v0.21.0` |
| Test pod yaml | `test-embedded.yaml` |

---

## Cleanup / restore

- Unblocked registry in pool VMs (iptables rules removed)
- Test/control pods deleted
- Node `/etc/hosts` docker.io entries removed