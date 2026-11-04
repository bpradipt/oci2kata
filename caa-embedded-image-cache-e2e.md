# Embedded Image Cache in CAA Peer Pods — BYOM E2E Run

End-to-end validation of the image-rs embedded image cache (`reference_db`
feature) on the **cloud-api-adaptor (CAA) kata-remote** path, using the
**BYOM** provider where each peer pod "VM" is a privileged Docker container on
the kind network.

This is the CAA counterpart of the composable QEMU/Kata work in
[composable-embedded-cache.md](composable-embedded-cache.md). For CAA the cache
stays baked into the pod VM image (the mkosi-embedded style path); the new
image-rs feature itself is identical.

The run proves four things:

1. A pod whose image is in the embedded cache starts with **all guest egress
   to `:443` blocked** — i.e. it never contacts a registry.
2. The **same pod with `enable_embedded_image_cache = false` fails** when
   egress is blocked, because it tries to pull from `index.docker.io`.
3. With egress allowed, the config-off case **pulls from the network** and
   succeeds — much slower than the cache case.
4. **Signature verification works fully offline** against the cached image:
   correct key → `Running`; wrong key → rejected by the `signedBy` policy.

---

## Environment

| Component | Version / commit |
|---|---|
| Host | Omarchy, kernel `7.2.8-9-omarchy`, Docker `29.9.2` |
| kind | `v0.30.0` |
| Kubernetes | `v1.35.1` (kind node image `kindest/node:v1.35.1`) |
| containerd (worker) | `2.2.1` |
| Kata (host, kata-deploy) | `4.2.0` (shim `4.2.0`, commit `c7351e79`) |
| Kata agent (guest, from BYOM base image) | `3.31.0` |
| CAA | `24b09231` (`main`), image built locally |
| CDH (guest) | `v0.21.0-109d08d1` (dev build from `image-rs-embedded-cache-main`) |
| image-rs | commit `109d08d1` |
| Provider | BYOM (peer pod VM = privileged container on the `kind` Docker network) |

The pod VM is a container, so the guest CDH journal, mounts and network state
can be inspected directly with `docker exec`.

---

## 1. Clean slate

Before starting:

```console
$ docker ps -a --format '{{.Names}}' | wc -l
0
$ docker images -q | wc -l
0
$ kind get clusters
(no output)
$ kubectl config current-context
error: current-context is not set
```

All images (base podvm, test images, CAA) were then pulled/built fresh.

---

## 2. Build the patched CDH and `cdh-oneshot`

Both binaries are built from the same guest-components tree
(`image-rs-embedded-cache-main`, image-rs commit `109d08d1`) so the daemon
serving the cache and the one-shot tool populating it behave identically.

```console
# daemon (ttrpc)
$ make -C confidential-data-hub LIBC=gnu ENABLE_KBS=true KMS_PROVIDER=aliyun RPC=ttrpc
$ cp ../target/x86_64-unknown-linux-gnu/release/confidential-data-hub cdh-daemon-gnu
# one-shot
$ make -C confidential-data-hub LIBC=gnu ENABLE_KBS=true KMS_PROVIDER=aliyun ONE_SHOT=true
$ cp ../target/x86_64-unknown-linux-gnu/release/confidential-data-hub cdh-oneshot-gnu
```

Resulting sizes: daemon `34.9 MB`, one-shot `34.1 MB`.

The base BYOM image ships stock CDH (`strings … | grep -c reference_db` → `0`),
so the patched binary is what makes the cache work.

---

## 3. Populate the cache and build the pod VM image

### 3.1 Pre-pull with `cdh-oneshot`

Inside a privileged Ubuntu container (network available, build only):

```console
$ cdh-oneshot --config /tmp/cdh-build.toml pull-image \
    --image-url docker.io/library/nginx:latest \
    --bundle-path /tmp/bundle-nginx
image digest: sha256:8e0328743c8e52ead9fac9c198d0893d63cd38e41b1d9ea629e092a8ac229a93

$ cdh-oneshot --config /tmp/cdh-build.toml pull-image \
    --image-url quay.io/kata-containers/confidential-containers:signed \
    --bundle-path /tmp/bundle-signed
image digest: sha256:febcf61cd6e1ac9628f6ac14fa40836d16f3c6ddef3b303ff0321606e55ddd0b
```

The resulting `reference_db` (readable from the guest at runtime):

```json
{
  "quay.io/kata-containers/confidential-containers@sha256:febcf61c…": "sha256:16ea53ea…",
  "docker.io/library/nginx@sha256:8e032874…": "sha256:1ebe58b0…",
  "quay.io/kata-containers/confidential-containers:signed": "sha256:16ea53ea…",
  "docker.io/library/nginx:latest": "sha256:1ebe58b0…"
}
```

The build config sets the same work directory the daemon uses
(`/run/kata-containers/image`), so the produced `layers/` + `meta_store.json`
are directly consumable:

```toml
[image]
work_dir = "/run/kata-containers/image"
enable_embedded_image_cache = true
image_security_policy_uri = "file:///etc/image-policy.json"
sigstore_config_uri = "file:///etc/sigstore-config.yaml"
```

### 3.2 Image contents

```console
$ du -sh layers meta_store.json
170M    layers          # 8 layer directories (nginx + signed image)
16K     meta_store.json
```

Signature data is baked in as local files, so verification needs no network:

* `/etc/image-policy.json` — `signedBy` GPG rule for
  `quay.io/kata-containers/confidential-containers`
* `/etc/containers/pubkey.asc` — the trusted public key
* `/etc/containers/quay_verification/signatures/` — the signatures
* `/etc/sigstore-config.yaml` — points sigstore at the local signature dir

### 3.3 Pod VM Dockerfile

The embedded pod VM is the published BYOM image plus the patched CDH, the
cache, the signature material and a boot-time setup unit:

```dockerfile
FROM quay.io/confidential-containers/podvm-byom-e2e-image-amd64:latest

# Patched CDH (reference_db + enable_embedded_image_cache + signature verification)
COPY cdh-daemon-gnu /usr/local/bin/confidential-data-hub

# Embedded image cache (pre-pulled layers + reference_db metadata)
COPY layers/ /usr/lib/kata-cache/layers/
COPY meta_store.json /usr/lib/kata-cache/meta_store.json

# Signature verification infrastructure
COPY etc/containers/quay_verification/signatures/ /etc/containers/quay_verification/signatures/
COPY etc/containers/pubkey.asc /etc/containers/pubkey.asc
COPY etc/image-policy.json /etc/image-policy.json
COPY etc/sigstore-config.yaml /etc/sigstore-config.yaml

# Boot-time cache setup service
COPY kata-image-cache-setup /usr/local/bin/kata-image-cache-setup
COPY kata-image-cache.service /usr/lib/systemd/system/kata-image-cache.service
COPY 10-image-cache-cdh.conf /usr/lib/systemd/system/confidential-data-hub.service.d/10-image-cache.conf
COPY 10-image-cache-agent.conf /usr/lib/systemd/system/kata-agent.service.d/10-image-cache.conf
RUN chmod +x /usr/local/bin/kata-image-cache-setup && systemctl enable kata-image-cache.service
```

### 3.4 Boot-time setup

`kata-image-cache.service` runs before `confidential-data-hub` and
`kata-agent`, copies `meta_store.json` into the image-rs work dir, and
bind-mounts every cached layer read-only over a writable tmpfs layer store.
Measured on the three pool VMs: **82 ms, 88 ms, 101 ms**.

Verified inside a pool VM:

```console
$ findmnt -no TARGET,SOURCE,OPTIONS /run/kata-containers/image/layers/0
/run/kata-containers/image/layers/0 overlay[/usr/lib/kata-cache/layers/0] ro,relatime
$ ls /run/kata-containers/image/layers
0 1 2 3 4 5 6 7
$ stat -c '%s' /run/kata-containers/image/meta_store.json
15689
```

(The `overlay[...]` source is the container rootfs; the relevant part is that
each target is a `ro` bind whose source is `/usr/lib/kata-cache/layers/N`.)

### 3.5 Image sizes

| Image | Size |
|---|---|
| `podvm-byom-e2e-image-amd64:latest` (base) | `581 MB` |
| `podvm-byom-embedded:test` | `873 MB` |
| cache contents baked in | `170 MB` layers + `16 KB` metadata |

Base image digest:
`sha256:35bfc0135b4118ddf40e0d2c72bd7051d1bb03caec68994b6969ece142397c36`

---

## 4. Cluster and CAA deployment

```console
# kind cluster (Calico, no default CNI)
$ kind create cluster --name peer-pods --config kind-config.yaml
$ kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
$ kubectl label node peer-pods-worker katacontainers.io/kata-runtime=true
$ kubectl label node peer-pods-worker node.kubernetes.io/worker=

# three BYOM "VMs" (privileged containers on the kind network)
$ for i in 1 2 3; do
    docker run -d --name podvm-byom-$i --network kind --privileged podvm-byom-embedded:test
  done
# → 172.18.0.4, .5, .6

# CAA via Helm (kata-deploy 4.2.0 pinned, local CAA image)
$ helm install peerpods install/charts/peerpods \
    -f install/charts/peerpods/providers/byom.yaml \
    -f byom-secrets.yaml -f byom-overrides.yaml \
    --set webhook.enabled=true --set resourceCtrl.enabled=true \
    --set kata-deploy.image.reference=quay.io/kata-containers/kata-deploy \
    --set kata-deploy.image.tag=4.2.0 \
    -n confidential-containers-system --create-namespace
```

Pool IPs are passed through `providerConfigs.byom.VM_POOL_IPS`. SSH keys for
the peerpod user are injected with `authorized_keys` in each container.

### Two environment fixes required by the stack

These are unrelated to the cache feature but are needed for kata-remote guest
pull on this stack; both are worth documenting upstream:

1. **kata-deploy must match the guest agent.** The published BYOM image
   contains kata-agent `3.31.0`, which expects the shim to pass
   `driver_options=["image_guest_pull={…}"]`. The floating
   `kata-deploy-ci:kata-containers-latest` image (built from 4.2 main after
   commit `f66d7fda4`) no longer sends it, and pod creation fails with
   `missing Image information for ImagePull volume`. Pinning kata-deploy to
   `4.2.0` fixes the protocol mismatch.

2. **`discard_unpacked_layers` must be disabled.** Kind sets it to `true`; the
   nydus snapshotter then cannot find the layer blobs when the kata-remote
   runtime unpacks the image:

   ```console
   $ docker exec peer-pods-worker sed -i \
       's/  discard_unpacked_layers = true/  discard_unpacked_layers = false/' \
       /etc/containerd/config.toml
   $ docker exec peer-pods-worker systemctl restart containerd
   ```

   This is exactly the failure documented in
   `docs/troubleshooting/nydus-snapshotter.md` upstream.

### Initdata

The pod initdata must contain **both** `aa.toml` and `cdh.toml`; without
`aa.toml` the attestation-agent (and therefore CDH → kata-agent → forwarder)
never starts and the pod stays in `ContainerCreating`.

Cache-on case:

```toml
version = "0.1.0"
algorithm = "sha384"
[data]
"aa.toml" = '''
[token_configs]
'''
"cdh.toml" = '''
[kbc]
name = "offline_fs_kbc"
url = ""

[image]
enable_embedded_image_cache = true
'''
```

The config-off case is identical with `enable_embedded_image_cache` removed.

---

## 5. Results

All pods use `runtimeClassName: kata-remote`. For the offline cases, guest
egress to TCP `:443` was blocked in **all three** pool VMs *before* the pod
was created:

```console
$ docker exec podvm-byom-N iptables -A OUTPUT -p tcp --dport 443 -j REJECT
$ docker exec podvm-byom-N curl -sS -m 5 https://registry-1.docker.io/v2/
curl: (7) Failed to connect … port 443 … Connection refused
```

| # | Case | Guest `:443` | Result | Apply → container running | Guest CDH image handling |
|---|---|---|---|---|---|
| A | cache on (`nginx`) | **blocked** | `1/1 Running` | **9.6 s** | cache hit in **71 ms** |
| B | cache off (`nginx`) | **blocked** | `StartError` | — | registry pull attempted, connection refused |
| C | cache off (`nginx`) | open | `1/1 Running` | **37.5 s** | registry pull in **3.35 s** (+ unpack) |
| D | signed, correct key | **blocked** | `1/1 Running` | — | cache hit + signature verify in **85 ms** |
| E | signed, wrong key | **blocked** | `StartError` | — | **72 ms** to policy rejection |

### A. Cache on, egress blocked → served locally

```console
$ kubectl get pod embedded-on -o wide
NAME          READY   STATUS    RESTARTS   AGE   IP                NODE
embedded-on   1/1     Running   0          10s   192.168.107.96    peer-pods-worker
```

Guest CDH journal (pod VM `172.18.0.5`):

```text
2026-11-04T04:46:26.065Z  INFO image_rs::builder: Image work directory: "/run/kata-containers/image/"
2026-11-04T04:46:26.135Z  INFO image_rs::image: Image docker.io/library/nginx:latest found in local cache, creating bundle
2026-11-04T04:46:26.136Z  INFO confidential_data_hub::hub: Extend image pull event via AA's runtime measurement API...
```

No outbound connection was possible (`:443` REJECTed), and image-rs never left
the `reference_db` fast path.

### B. Cache off, egress blocked → pull attempted and fails

```console
$ kubectl get pod embedded-off
NAME           READY   STATUS       RESTARTS   AGE
embedded-off   0/1     StartError   0          75s
```

```text
Warning  Failed  kubelet  Error: failed to create containerd task: … rpc status:
Status { code: INTERNAL, message: "[CDH] [ERROR]: Image Pull error: Failed to pull
image docker.io/library/nginx:latest from all mirror/mapping locations or
original location: … failed to pull image manifest: error sending request for url
(https://index.docker.io/v2/library/nginx/manifests/latest)" }
```

Guest CDH journal:

```text
2026-11-04T04:39:29.130Z  WARN image_rs::image: failed to pull image docker.io/library/nginx:latest from docker.io/library/nginx:latest: PullLayersFailed(
    url: "https://index.docker.io/v2/library/nginx/manifests/latest",
    … tcp connect error …
```

The `reference_db` entry is present in the guest, but the opt-in flag is off,
so it is deliberately ignored and the registry is contacted.

### C. Cache off, egress open → pulled from the network

```console
$ kubectl get pod embedded-off -o wide
NAME           READY   STATUS    RESTARTS   AGE   IP                NODE
embedded-off   1/1     Running   0          75s   192.168.107.92    peer-pods-worker
```

Guest CDH journal (`172.18.0.5`), ~3.3 s inside the guest:

```text
2026-11-04T04:41:49.406Z  INFO image_rs::builder: getting registry auth from file:///run/peerpod/auth.json ...
2026-11-04T04:41:49.419Z  INFO image_rs::builder: Existing metadata found. Using previous ones.
2026-11-04T04:41:49.419Z  INFO image_rs::builder: Image work directory: "/run/kata-containers/image/"
2026-11-04T04:41:52.764Z  INFO confidential_data_hub::hub: Extend image pull event via AA's runtime measurement API...
```

There is **no** `found in local cache` line: this run went to the registry.
The end-to-end pod start is ~4× slower than the cached case (37.5 s vs 9.6 s).

### D. Signed image, correct key, egress blocked → verified offline

```console
$ kubectl get pod signed-pos -o wide
NAME         READY   STATUS    RESTARTS   AGE   IP                NODE
signed-pos   1/1     Running   0          70s   192.168.107.98    peer-pods-worker
```

Guest CDH journal (`172.18.0.6`):

```text
2026-11-04T04:47:57.651Z  INFO image_rs::builder: getting image security policy from file:///etc/image-policy.json ...
2026-11-04T04:47:57.667Z  INFO image_rs::builder: Image work directory: "/run/kata-containers/image/"
2026-11-04T04:47:57.750Z  INFO image_rs::image: Image quay.io/kata-containers/confidential-containers:signed found in local cache, creating bundle
2026-11-04T04:47:57.752Z  INFO confidential_data_hub::hub: Extend image pull event via AA's runtime measurement API...
```

Signature material came from the baked local files (sigstore config points at
`file:///etc/containers/quay_verification/signatures`), with no network
access. Cache + policy check + bundle creation took **85 ms**.

### E. Signed image, wrong key, egress blocked → rejected

```console
$ kubectl get pod signed-neg
NAME         READY   STATUS       RESTARTS   AGE
signed-neg   0/1     StartError   0          3m1s
```

```text
Warning  Failed  kubelet  Error: failed to create containerd task: … rpc status:
Status { code: INTERNAL, message: "[CDH] [ERROR]: Image Pull error: Image policy
rejected: Denied by policy: rejected by `signedBy` rule: The signatures do not
satisfied! Reject reason: [not enough bytes in buffer: armor header]" }
```

Guest CDH journal (`172.18.0.4`):

```text
2026-11-04T04:50:08.946Z  INFO image_rs::image: Image quay.io/kata-containers/confidential-containers:signed found in local cache, creating bundle
2026-11-04T04:50:08.949Z ERROR ttrpc_cdh::ttrpc_server: [ttrPC CDH] Pull Image :
Image Pull error: Image policy rejected: Denied by policy: rejected by `signedBy` rule …
```

Rejection happened in **72 ms**, i.e. the cached content was never handed to
the agent.

### 5.1 Re-run against the locally built CAA image

The runs above used the published `quay.io/confidential-containers/cloud-api-adaptor:latest`.
To remove any doubts about which CAA revision produced them, CAA was rebuilt
from `main` (`24b09231`) and redeployed from the local image:

```console
$ cd cloud-api-adaptor/src
$ docker build --provenance false --sbom false \
    --build-arg RELEASE_BUILD=false --build-arg BUILD_TYPE=dev \
    --build-arg VERSION=local-24b09231 --build-arg COMMIT=24b09231f7c6… \
    --build-arg YQ_VERSION=v4.35.1 \
    -f cloud-api-adaptor/Dockerfile -t cloud-api-adaptor:local .
$ kind load docker-image cloud-api-adaptor:local --name peer-pods
$ helm upgrade peerpods install/charts/peerpods --reuse-values \
    --set image.name=cloud-api-adaptor --set image.tag=local \
    -n confidential-containers-system
# the chart hardcodes imagePullPolicy: Always, so patch it for the local tag
$ kubectl patch ds -n confidential-containers-system cloud-api-adaptor-daemonset \
    --type=json \
    -p '[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]'
```

The DaemonSet then reported `cloud-api-adaptor:local` and the adaptor logged
`starting Cloud API Adaptor daemon for "byom"`.

Cases A and B were repeated with all guest `:443` egress blocked:

| Case | Result | Apply → container running | Guest CDH |
|---|---|---|---|
| A (cache on) | `1/1 Running` | **8.9 s** | `found in local cache` again |
| B (cache off) | `StartError` | — | `index.docker.io/...: connect` refused |

```text
2026-11-04T05:06:25.055Z  INFO image_rs::builder: Image work directory: "/run/kata-containers/image/"
2026-11-04T05:06:25.125Z  INFO image_rs::image: Image docker.io/library/nginx:latest found in local cache, creating bundle
2026-11-04T05:06:25.126Z  INFO confidential_data_hub::hub: Extend image pull event via AA's runtime measurement API...
```

The behaviour is identical to the published image, so the cache path is a
property of the patched guest CDH and image-rs, not of the CAA build.

---

## 6. Takeaways

* The embedded cache is served **strictly from the pod VM** for CAA: with all
  TLS egress blocked, a cached image still starts in ~10 s end-to-end
  (vs ~38 s when the guest has to pull).
* Turning the opt-in flag off changes behaviour deterministically: the guest
  goes to `index.docker.io`, and fails loudly when the network is unavailable.
* Signature policy and sigstore data travel **inside the pod VM image**, so
  verification works offline and is per-deployment configurable.
* The `reference_db` is only consulted when `enable_embedded_image_cache` is
  `true`; the same `meta_store.json` is otherwise inert.

### Non-cache issues hit during bring-up

Documented here because they will bite anyone reproducing this with the
current artifacts:

1. kata-agent `3.31.0` (BYOM image) vs kata-deploy `latest` (4.2 main) →
   `missing Image information for ImagePull volume`. Pin kata-deploy `4.2.0`.
2. kind containerd `discard_unpacked_layers = true` → `error unpacking image
   … content digest … not found`. Set it to `false` (upstream troubleshooting
   doc).
3. Initdata without `aa.toml` → attestation-agent/CDH/kata-agent never start.
4. BYOM pool size must be ≥ the number of concurrently scheduled test pods,
   otherwise `no available IPs in pool`.

---

## 7. Reproduction summary

```console
# 1. patched CDH + one-shot
make -C guest-components/confidential-data-hub LIBC=gnu ENABLE_KBS=true KMS_PROVIDER=aliyun RPC=ttrpc
make -C guest-components/confidential-data-hub LIBC=gnu ENABLE_KBS=true KMS_PROVIDER=aliyun ONE_SHOT=true
# 2. populate cache with cdh-oneshot pull-image (see §3.1), build pod VM image (see §3.3)
# 3. kind cluster + Calico + labels + containerd fix (see §4)
# 4. start 3 BYOM containers, install CAA with kata-deploy 4.2.0
# 5. apply the pods, optionally with iptables REJECT for :443 in the pool VMs
```
