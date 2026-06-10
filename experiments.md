# Embedding Container Image in Kata VM — Investigation Findings

## Overview

This document captures all findings from investigating whether a container image
pre-embedded inside a Kata VM image is actually used at runtime (instead of being
pulled from the registry inside the guest), including methodology, raw logs, and
conclusions.

---

## What Was Built

A fresh custom Kata VM image was built using `build-kata-vm-verity.sh`:

```
/opt/kata/share/kata-containers/kata-ubuntu-noble-confidential-kata-vm-image_7may-verity.image
```

Contents:
- Original kata rootfs (~215 MiB)
- Custom CDH binary (from `github.com/bpradipt/guest-components` branch `image-cache-0.20.0`)
- erofs of pre-pulled layers for `quay.io/bpradipt/kata-vm-image:7may` (714 MiB compressed)
- `meta_store.json` with layer metadata and image reference index
- `kata-image-cache.service` systemd unit (runs before kata-agent)

The image uses non-verity mode (two-partition verity layout is incompatible with
kata's QEMU NVDIMM configuration).

---

## Active Configuration

```
/opt/kata/share/defaults/kata-containers/runtimes/qemu-coco-dev/config.d/50-verity-embedded.toml
```

```toml
[hypervisor.qemu]
image = "/opt/kata/share/kata-containers/kata-ubuntu-noble-confidential-kata-vm-image_7may-verity.image"
kernel_verity_params = ""
kernel_params = "root=/dev/pmem0p1 rootflags=data=ordered,errors=remount-ro ro rootfstype=ext4 agent.aa_kbc_params=offline_fs_kbc::"
```

The `agent.aa_kbc_params=offline_fs_kbc::` is required to prevent CDH from
trying to reach a network KBS (Key Broker Service) during initialization.

---

## How the Embedded Cache Works

At VM boot, `kata-image-cache.service` runs **before** `kata-agent.service`:

```bash
# Current service (tar-extraction approach — layers in native tmpfs)
mount -t erofs -o loop /opt/kata-cache/layers.erofs /run/kata-layers-erofs
mkdir -p /run/kata-containers/image/layers /run/kata-containers/image/overlay
tar -c -C /run/kata-layers-erofs . | tar -x -C /run/kata-containers/image/layers
umount /run/kata-layers-erofs
cp /opt/kata-cache/meta_store.json /run/kata-containers/image/meta_store.json
# Bind-mount protects meta_store.json from kata-agent cleanup
mount --bind /run/kata-containers/image/meta_store.json \
             /run/kata-containers/image/meta_store.json
```

After the service:
- `/run/kata-containers/image/layers/0..4` → native tmpfs (extracted from erofs)
- `/run/kata-containers/image/meta_store.json` → bind-mounted, survives kata-agent cleanup

`meta_store.json` maps:
- `reference_db["quay.io/bpradipt/kata-vm-image:7may"]` → image config SHA256
- `reference_db["quay.io/bpradipt/kata-vm-image@sha256:0a09419b..."]` → same (digest form)
- `layer_metas[].store_path` → `/run/kata-containers/image/layers/N`
- `image_db[config_sha256]` → full image metadata

CDH uses `work_dir = /run/kata-containers/image/` (default). On the first
`PullImage` call from kata-agent, CDH:
1. Reads `meta_store.json` (lazy init)
2. Checks `reference_db` → image found
3. Checks `image_db` → layers found at `store_path`
4. Calls `snapshot.mount(layer_paths, bundle_dir/rootfs)` → overlay mount (3ms)
5. Returns bundle path to kata-agent

---

## Test Pod YAMLs

### Regular pod (for Cases 1 and 2)

```yaml
# test-regular-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-test
spec:
  containers:
  - args: [sleep, "360000"]
    image: quay.io/bpradipt/kata-vm-image:7may
    imagePullPolicy: Always   # always contacts registry for manifest
    name: pod-test
```

### Kata pod (for Cases 3 and 4)

```yaml
# test-kata-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-test
spec:
  runtimeClassName: kata-qemu-coco-dev
  containers:
  - args: [sleep, "360000"]
    image: quay.io/bpradipt/kata-vm-image:7may
    imagePullPolicy: IfNotPresent   # uses cached node image; only in-VM CDH is tested
    name: pod-test
```

`IfNotPresent` is used for the kata pod in Cases 3 and 4 so that the node-side
"pull" succeeds from the local cache (the image was cached in Case 2), isolating
the in-guest CDH behavior as the only variable.

---

## Blocking Approach

Two mechanisms are combined to block registry access completely:

**Host-side (node) — blocks kubelet, crictl, podman:**
```bash
echo "0.0.0.0 quay.io  # block-registry-test" | sudo tee -a /etc/hosts
```
`/etc/hosts` is checked **before** DNS. When containerd resolves `quay.io` it
gets `0.0.0.0` and immediately fails: `dial tcp 0.0.0.0:443: connect: connection
refused`. Only the hostname `quay.io` is affected — SSH access and all other
HTTPS traffic are unaffected.

**Why `/etc/hosts` alone is not enough for kata VMs:**
The kata VM is a full virtual machine with its **own network stack and DNS
resolver**. The host's `/etc/hosts` is not visible inside the VM. CDH inside
the VM resolves `quay.io` through its own DNS (the pod's DNS, routed via the
CNI bridge) and gets real IPs — the host `/etc/hosts` entry has no effect on it.

**In-VM side — blocks kata VM's CDH:**
```bash
sudo iptables -I FORWARD -s 10.244.0.0/24 -p tcp --dport 443 \
  -m comment --comment "block-registry-test-vm" -j REJECT --reject-with tcp-reset
```
When CDH inside the VM tries to connect to a resolved quay.io IP on port 443,
the packet leaves the VM (source IP 10.244.0.x) and hits the host's FORWARD
chain before it can reach the network. The REJECT sends a TCP reset back
immediately. This is the only mechanism that reaches in-VM traffic.

**Why not block OUTPUT:443?** Blocking all port 443 on the OUTPUT chain also
blocks the testing session's own HTTPS access. The `/etc/hosts` approach is
targeted for host-side and does not have this side-effect.

**Cleanup:**
```bash
sudo sed -i '/block-registry-test/d' /etc/hosts
sudo iptables -D FORWARD -s 10.244.0.0/24 -p tcp --dport 443 \
  -m comment --comment "block-registry-test-vm" -j REJECT --reject-with tcp-reset
```

---

## Four-Case Validation Test

### Prerequisites

- Kubernetes cluster with kata-containers 3.31.0 installed
- `kata-qemu-coco-dev` runtime class available
- `nydus-for-kata-tee` in-guest pull snapshotter configured
- Pod CIDR: `10.244.0.0/24`

---

### Case 1 — Regular pod | image OFF node | registry BLOCKED → FAIL

**Purpose:** Confirm the blocking mechanism works; kubelet cannot pull.

**Setup:**
```bash
sudo crictl rmi quay.io/bpradipt/kata-vm-image:7may
echo "0.0.0.0 quay.io  # block-registry-test" | sudo tee -a /etc/hosts
sudo iptables -I FORWARD -s 10.244.0.0/24 -p tcp --dport 443 \
  -m comment --comment "block-registry-test-vm" -j REJECT --reject-with tcp-reset
kubectl apply -f test-regular-pod.yaml
```

**Result: FAIL (as expected)**

```
NAME       READY   STATUS         RESTARTS   AGE
pod-test   0/1     ErrImagePull   0          35s
```

**Events:**
```
Warning  Failed  Failed to pull image "quay.io/bpradipt/kata-vm-image:7may":
  failed to pull and unpack image "quay.io/bpradipt/kata-vm-image:7may":
  failed to resolve reference "quay.io/bpradipt/kata-vm-image:7may":
  failed to do request: Head "https://quay.io/v2/bpradipt/kata-vm-image/manifests/7may":
  dial tcp 0.0.0.0:443: connect: connection refused
Warning  Failed    Error: ErrImagePull
Warning  Failed    Error: ImagePullBackOff
```

`dial tcp 0.0.0.0:443` confirms quay.io resolved to `0.0.0.0` from `/etc/hosts`.

---

### Case 2 — Regular pod | registry UNBLOCKED → PASS, image cached

**Purpose:** Confirm image is reachable normally; image gets cached on node.

**Setup:**
```bash
sudo sed -i '/block-registry-test/d' /etc/hosts
sudo iptables -D FORWARD ...  # remove FORWARD rule
kubectl apply -f test-regular-pod.yaml
```

**Result: PASS in 16.1 seconds**

```
NAME       READY   STATUS    RESTARTS   AGE
pod-test   1/1     Running   0          16s
```

**Events:**
```
Normal  Pulling  Pulling image "quay.io/bpradipt/kata-vm-image:7may"
Normal  Pulled   Successfully pulled image "quay.io/bpradipt/kata-vm-image:7may"
                 in 14.4s. Image size: 702014696 bytes.
Normal  Created  Created container: pod-test
Normal  Started  Started container pod-test
```

**After Case 2:** Image is cached on node:
```
quay.io/bpradipt/kata-vm-image   7may   f0a289dca6e63   702MB
```

---

### Case 3 — Kata pod | STANDARD VM | registry BLOCKED → FAIL

**Purpose:** Prove that without embedded cache, even a kata pod fails when the
registry is blocked — standard CDH always contacts the registry inside the VM.

**Setup:**
```bash
# Re-apply block
echo "0.0.0.0 quay.io  # block-registry-test" | sudo tee -a /etc/hosts
sudo iptables -I FORWARD -s 10.244.0.0/24 -p tcp --dport 443 \
  -m comment --comment "block-registry-test-vm" -j REJECT --reject-with tcp-reset

# Configure standard kata VM (no embedding)
cat > /opt/kata/.../config.d/50-verity-embedded.toml << 'EOF'
[hypervisor.qemu]
image = "/opt/kata/share/kata-containers/kata-ubuntu-noble-confidential.image"
kernel_verity_params = ""
kernel_params = "root=/dev/pmem0p1 rootflags=data=ordered,errors=remount-ro ro rootfstype=ext4"
EOF

kubectl apply -f test-kata-pod.yaml  # imagePullPolicy: IfNotPresent
```

Node image is cached → node-side "pull" instant (`already present on machine`).
The only variable: does CDH inside the VM reach the registry?

**Result: FAIL — CrashLoopBackOff**

```
NAME       READY   STATUS              RESTARTS      AGE
pod-test   0/1     RunContainerError   4 (11s ago)   2m6s
```

**Events:**
```
Normal   Pulled   Container image "quay.io/bpradipt/kata-vm-image:7may"
                  already present on machine
Normal   Created  Created container: pod-test
Warning  Failed   Error: failed to create containerd task: failed to create shim task:
  rpc status: Status { code: INTERNAL, message: "[CDH] [ERROR]: Image Pull error:
  Failed to pull image quay.io/bpradipt/kata-vm-image:7may from all mirror/mapping
  locations or original location: image: quay.io/bpradipt/kata-vm-image:7may,
  error: Errors happened when pulling image: failed to pull image manifest:
  error sending request for url
  (https://quay.io/v2/bpradipt/kata-vm-image/manifests/7may)" }
Warning  BackOff  Back-off restarting failed container
```

The node-side pull was skipped (`already present on machine`). Inside the VM,
the standard CDH attempted `https://quay.io/v2/.../manifests/7may` — the FORWARD
iptables rule rejected the connection. CDH failed; container never started.

---

### Case 4 — Kata pod | EMBEDDED VM | registry BLOCKED → PASS

**Purpose:** Prove that with the embedded image, the kata pod succeeds even
when no registry access is possible from inside the VM.

**Setup:** Same block as Case 3. Only the kata VM image changes:

```bash
# Configure embedded kata VM image
cat > /opt/kata/.../config.d/50-verity-embedded.toml << 'EOF'
[hypervisor.qemu]
image = "/opt/kata/share/kata-containers/kata-ubuntu-noble-confidential-kata-vm-image_7may-verity.image"
kernel_verity_params = ""
kernel_params = "root=/dev/pmem0p1 rootflags=data=ordered,errors=remount-ro ro rootfstype=ext4 agent.aa_kbc_params=offline_fs_kbc::"
EOF

kubectl apply -f test-kata-pod.yaml  # imagePullPolicy: IfNotPresent
```

**Result: PASS in 10.5 seconds**

```
NAME       READY   STATUS    RESTARTS   AGE
pod-test   1/1     Running   0          10s
```

**Events:**
```
Normal  Scheduled  Successfully assigned default/pod-test to ai-pg
Normal  Pulled     Container image "quay.io/bpradipt/kata-vm-image:7may"
                   already present on machine
Normal  Created    Created container: pod-test
Normal  Started    Started container pod-test
```

No CDH errors. No registry contact. The embedded cache inside the kata VM image
provided all the layer data CDH needed.

---

## Summary Table

| Case | VM image | Node image | Registry | imagePullPolicy | Result |
|---|---|---|---|---|---|
| 1 | standard | **absent** | **blocked** | Always | **FAIL** — ErrImagePull |
| 2 | standard | absent | open | Always | **PASS** — pulled 14.4s, cached |
| 3 | standard | cached | **blocked** | IfNotPresent | **FAIL** — CDH registry error |
| 4 | **embedded** | cached | **blocked** | IfNotPresent | **PASS** — 10.5s, no registry |

**Conclusion: The embedded container image is definitively used by CDH inside
the kata VM. No registry contact is made when the embedded cache is present.**

---

## Supporting Measurements

### CDH CPU usage (entire lifetime — 35s uptime)

Measured via `/proc/PID/stat` inside the running VM:

| Process | CPU ticks | Wall time | Interpretation |
|---|---|---|---|
| `confidential-data-hub` | **16 ticks = 160ms** | 35s | Near-zero compute |
| `kata-agent` | **15 ticks = 150ms** | 36s | Near-zero compute |

Standard CDH downloading 700MB at 50 MB/s would consume ~14s of CPU for
decompression and extraction. 160ms total rules that out completely.

### Real-time network monitoring (sampled every 1–2 seconds, 30s window)

```
11:19:29: TCP=0  UDP=1  DNS_queries=0
11:19:31: TCP=0  UDP=1  DNS_queries=0
...
11:19:57: TCP=0  UDP=1  DNS_queries=0
```

Zero external TCP connections and zero DNS queries throughout. The persistent
UDP=1 is the kata vsock (internal).

### Individual operation timings (inside kata VM)

| Operation | Time |
|---|---|
| Overlay mount (5 layers, warm) | **3ms** |
| NVDIMM sequential read (100 MiB) | **239 MB/s** |
| Tar extraction service (811 MiB) | **6 seconds** |

---

## Unexplained: 18-second Kata-Agent Overhead

Both baseline (standard CDH, no embedding) and embedded approach show
~17–18 seconds from "Pulled → Created" in timing tests. This overhead:

- Is **not** CDH making a registry call (Case 4 passes with registry blocked)
- Is **not** CPU-bound (CDH and kata-agent together use <200ms CPU)
- Disappears when the node image is already cached (pod ready in ~10s)
- Is present in **both** the standard and embedded configurations

The 18s is an unexplained kata-agent container setup overhead that is
independent of whether the embedded cache is used. It does not affect the
correctness of the embedding — the pod still starts and uses the embedded
layers correctly.

---

## Files

| File | Purpose |
|---|---|
| `build-kata-vm-verity.sh` | Builds the custom embedded kata VM image |
| `test-regular-pod.yaml` | Regular (non-kata) pod for Cases 1 and 2 |
| `test-kata-pod.yaml` | Kata pod (IfNotPresent) for Cases 3 and 4 |
| `test-baseline.yaml` | Timing benchmark pod (imagePullPolicy: Always) |
| `test-embed.yaml` | Kata pod with explicit image annotation |
| `FINDINGS.md` | This document |

### Kata config files modified

```
/opt/kata/share/defaults/kata-containers/runtimes/qemu-coco-dev/config.d/
  50-verity-embedded.toml   ← points to custom VM image
  50-original.toml          ← standard VM image (for baseline)
  60-debug-console.toml     ← dial_timeout=180s, debug console on
```

### Inside the kata VM image

```
/usr/lib/systemd/system/kata-image-cache.service   ← extracts erofs at boot
/opt/kata-cache/layers.erofs                        ← embedded container layers
/opt/kata-cache/meta_store.json                     ← image index (layer → path)
/usr/local/bin/confidential-data-hub                ← custom CDH binary
```

---

## Events

Events without embedded container image

```bash
Events:
  Type     Reason     Age              From               Message
  ----     ------     ----             ----               -------
  Normal   Scheduled  9s               default-scheduler  Successfully assigned default/pod-7may to ai-pg
  Normal   Pulled     4s (x2 over 5s)  kubelet            spec.containers{pod-7may}: Container image "quay.io/bpradipt/kata-vm-image:7may" already present on machine
  Normal   Created    4s (x2 over 5s)  kubelet            spec.containers{pod-7may}: Created container: pod-7may
  Warning  Failed     4s (x2 over 5s)  kubelet            spec.containers{pod-7may}: Error: failed to create containerd task: failed to create shim task: rpc status: Status { code: INTERNAL, message: "[CDH] [ERROR]: Image Pull error: Failed to pull image quay.io/bpradipt/kata-vm-image:7may from all mirror/mapping locations or original location: image: quay.io/bpradipt/kata-vm-image:7may, error: Errors happened when pulling image: failed to pull image manifest: error sending request for url (https://quay.io/v2/bpradipt/kata-vm-image/manifests/7may)", details: [], special_fields: SpecialFields { unknown_fields: UnknownFields { fields: None }, cached_size: CachedSize { size: 0 } } }

Stack backtrace:
   0: <unknown>
   1: <unknown>
   2: <unknown>
   3: <unknown>
   4: <unknown>
   5: <unknown>
   6: <unknown>
   7: <unknown>
   8: <unknown>
   9: <unknown>
  10: <unknown>
  11: <unknown>
  12: <unknown>
  13: <unknown>
  14: <unknown>
  15: <unknown>
  16: <unknown>
  17: <unknown>
  18: <unknown>
  19: <unknown>
  20: <unknown>
  21: <unknown>
  22: <unknown>
  Warning  BackOff  3s  kubelet  spec.containers{pod-7may}: Back-off restarting failed container pod-7may in pod pod-7may_default(ce7f83ae-5ab5-46a8-b58b-e58cf4ccfb57)
```

Events when using embedded container image

```bash
Events:
  Type    Reason     Age   From               Message
  ----    ------     ----  ----               -------
  Normal  Scheduled  5s    default-scheduler  Successfully assigned default/pod-7may-cache to ai-pg
  Normal  Pulled     1s    kubelet            spec.containers{pod-7may-cache}: Container image "quay.io/bpradipt/kata-vm-image:7may" already present on machine
  Normal  Created    1s    kubelet            spec.containers{pod-7may-cache}: Created container: pod-7may-cache
  Normal  Started    1s    kubelet            spec.containers{pod-7may-cache}: Started container pod-7may-cache
```
