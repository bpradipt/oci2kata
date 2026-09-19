# Avoiding the Double Image Pull with Guest Image Pull

When a kata-remote peer pod uses the nydus `image_guest_pull` snapshotter,
the image is pulled **in the guest** by CDH.  But by default the worker node
also downloads the full image, because kubelet invokes containerd's CRI
`PullImage`, which fetches the manifest *and all layer blobs* into the node
content store.

This document explains the problem, the measured evidence, and the
configuration that makes the node **skip the layer download entirely** — so
the image is only ever pulled once (inside the guest), never on the node.

---

## The problem (double pull)

Test: `docker.io/library/python:3.12` (411 MB compressed / 1.6 GB
uncompressed), run as a kata-remote pod with the embedded cache, image
**fully absent** from the worker node.

Measured node-side effect during pod start:

| Node store | Before | After | Delta |
|---|---|---|---|
| containerd content store | 4,801,104,931 B | 5,212,068,924 B | **+391 MB** |
| nydus store | 148 MB | 1,256 MB | **+1,056 MB** |

The node content store ends up with **all 7 real OCI layer blobs** of python
(their digests match the image manifest).  So the node downloaded the full
image — even though the guest pulls it again via CDH.  That is the double
pull.

### Root cause

kubelet → containerd CRI `PullImage` **always** downloads the image
(manifest + all layers) when the image is not already present on the node.
The nydus remote snapshotter cannot prevent this; it only gets involved
later, at `CreateContainer` time, when it emits the `image_guest_pull`
volume for the guest.

---

## The fix: register the manifest, keep the layers off the node

Containerd's CRI `PullImage` is skipped entirely when the image reference is
already registered (`imagePullPolicy: IfNotPresent` + image "present").
Registration only requires the **manifest + config** (tens of KB), not the
layers.

So the correct setup is:

1. **Pre-register the image manifest + config on the worker node** (small).
2. **Ensure the layer blobs are NOT present** on the node (delete them, or
   register the manifest without pulling layers).
3. kubelet sees the image as "present" → skips the CRI pull → **no node-side
   layer download**.
4. At `CreateContainer`, nydus emits `image_guest_pull` → CDH pulls the image
   **in the guest** — from the embedded cache (fast) or the registry.

### Measured result

Same test (python:3.12, embedded cache, `IfNotPresent`), with **only the
manifest on the node** and the layer blobs removed:

| Node store | Before | After | Delta |
|---|---|---|---|
| containerd content store | 4,801,124,091 B | 4,801,124,091 B | **0 B** |
| python blobs on node | manifest+config only | manifest+config only | **unchanged** |

- Node content store: **unchanged** — no layer download at all.
- Pod start: **~7 s** (6.8 s median), identical to when the full image was
  cached on the node.
- Registry **blocked on both node and VM** during the run — so nothing could
  have been pulled except the embedded cache.
- CDH journal:
  ```
  INFO image_rs::image: Image docker.io/library/python:3.12 found in local cache, creating bundle
  ```

This proves the node downloads **zero** image bytes, and the guest serves
the image from the embedded cache.  The double pull is eliminated.

---

## How to register the manifest without the layers

### Option A — pre-pull then delete the layers (used in this validation)

```bash
# 1. Pre-pull the image (registers manifest + config + layers)
sudo crictl pull docker.io/library/python:3.12

# 2. Delete only the layer blobs from the containerd content store,
#    keeping the manifest and config.
#    (Layer digests come from the image manifest.)
sudo ctr -n k8s.io content rm \
  sha256:<layer1> sha256:<layer2> ... sha256:<layerN>

# 3. The image is still "present" for IfNotPresent, but the node has no layers.
sudo crictl images   # still lists python:3.12
```

### Option B — fetch only manifest + config (cleaner)

Fetch just the manifest and config into the content store (no layer blobs),
which registers the image reference without any layer data.  This is the
recommended approach for a production setup / image puller job.

---

## What this means for embedded images

With the node configured this way:

- The **embedded cache** inside the peer pod VM is the *only* copy of the
  image layers; CDH serves them in-guest with zero registry contact (proven
  by blocking the VM registry).
- The **node never downloads the image** — saving the 391 MB node-side pull
  and the storage it would consume.
- Pod start is **flat** (~7 s, dominated by VM boot) regardless of image
  size.

For **non-embedded** images the same manifest-only setup means the node also
skips the download; the guest pulls from the registry once.  No double pull
in either case.

---

## Relationship to the upstream docs

The kata-containers guide
[how-to-pull-images-in-guest-with-kata.md](https://github.com/kata-containers/kata-containers/blob/main/docs/how-to/how-to-pull-images-in-guest-with-kata.md)
says to "delete images used for pulling in the guest".  That step is about
containerd's `CRI Runtime Specific Snapshotter` experimental feature not
being able to manage the same image under two snapshotters.  It does **not**,
by itself, stop the node-side download — deleting the image entirely makes
containerd re-pull it (manifest + layers) on the next pod.  The fix above
(register the manifest, keep layers off the node) is what actually avoids
the node-side pull.

The design intent is captured in
[kata-guest-image-management-design.md](https://github.com/kata-containers/kata-containers/blob/main/docs/design/kata-guest-image-management-design.md):

> containerd will not pull the image layers from registry, instead it
> assumes that remote snapshotter and/or an external entity will perform
> that operation on his behalf.

The manifest-only node setup is what makes that statement true in practice.

---

## Validation environment

- kind cluster `peer-pods` with Calico
- CAA v0.22.0 (helm), BYOM provider, 3 pool VMs
- kata-deploy with `kata-remote` shim + nydus `config-guest-pulling.toml`
  (`enable_kata_volume = true`)
- Patched CDH `v0.21.0-04214c4e` from `image-cache-reference-db-v0.21.0`
- Embedded podvm image `podvm-byom-embedded:py312` (patched CDH + python
  layers + `meta_store.json` + `kata-image-cache` service)
- Pod: `kata-remote`, `imagePullPolicy: IfNotPresent`

### Key measured numbers

| Scenario | Node layer download | Pod start (median) | CDH behavior |
|---|---|---|---|
| Image fully absent on node | **391 MB** (full image) | ~62 s (guest pull) | pulls in guest |
| Manifest-only on node, embedded cache | **0 B** | **6.8 s** | `found in local cache` |

---

## Content-based proof: the marker test

Byte-count deltas and the CDH journal are strong but indirect.  To make the
verification airtight, we embedded a **unique marker file** that exists only in
the embedded cache and verified it appears in the running container with all
registries unreachable.

### Setup

1. Build a custom image `marker-image:proof` = python:3.12 plus a file
   `/opt/embedded-proof/PROOF.txt` containing a unique 64-hex random secret
   (generated once, known only to us).
2. Push it to a throwaway local registry, then pre-pull it during the embedded
   podvm build with `cdh-oneshot` — so the marker lives **only** in the
   embedded cache inside the podvm image.
3. Register the image **manifest only** on the worker node (manifest + config,
   no layer blobs).
4. Block the registry **inside the peer pod VM** (iptables) and confirm the
   node holds no layers.
5. Run the pod with `imagePullPolicy: IfNotPresent`.

### Result (all four checks)

| # | Check | Result |
|---|---|---|
| 1 | Marker file inside the running container | `cat /opt/embedded-proof/PROOF.txt` printed the secret |
| 2 | VM registry blocked | `curl` to the registry → connection refused |
| 3 | Node content store for the image | **1,203 bytes** total (manifest/config/index only, zero layers) |
| 4 | Embedded cache inside the VM | `find /usr/lib/kata-cache/layers -name PROOF.txt` → same secret |

CDH journal:

```
INFO image_rs::image: Image 172.18.0.9:5000/marker-image:proof found in local cache, creating bundle
```

The secret is a random 64-hex value that exists nowhere except the embedded
cache.  Its presence in the container, with the VM registry blocked and only
1.2 KB of manifest on the node, proves the layers were served **from the
embedded cache** — no local (node) pull and no in-guest registry pull.

---

## Files

- This document: `no-double-pull.md`
- Setup helper: `manifest-only-node.sh`
- Related: [perf_analysis.md](perf_analysis.md),
  [experiments-byom.md](experiments-byom.md)