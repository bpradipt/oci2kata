# Embedding Container Images into Confidential VMs: A Practical Guide

*How we make peer pod VMs boot with your container image already inside, so
they start in seconds and work even with no network access to the registry.*

---

## The problem

When you run a pod in a confidential computing setup like CAA (Cloud API
Adaptor), your container runs inside a virtual machine.  That VM has
its own tiny operating system, and a component called **CDH** (Confidential
Data Hub) is responsible for pulling the container image into the VM.

This works fine, but it has two problems:

1. **Slow**: every pod start downloads the image from a registry, inside the
   VM, over the network.  A 700 MB image can add minutes of startup time.
2. **Fragile**: if the VM cannot reach the registry (air-gapped environment,
   blocked firewall, satellite link, rate limits), the pod cannot start.

Putting the container image **into the VM image itself**, before the VM boots,
lets CDH find the image already present, serve it from local disk in
milliseconds, and never talk to a registry.

This project does that.  We call it **embedding a container image**.

---

## The idea in one sentence

Before the VM boots, we pre-pull the container image and bake its layers into
the VM's root filesystem.  At boot, a small service copies the image's metadata
into the CDH working directory and makes the layers visible.  When a pod asks
CDH for that image, CDH finds it locally and creates the container instantly, with
no network needed.

---

## The two projects we had to change

Making this work cleanly needed small changes in two open-source projects.

### 1. guest-components (the CDH / image library)

CDH uses a library called `image-rs` to manage images.  When you ask CDH to
"pull image X", `image-rs` normally goes to the registry, reads the manifest,
downloads the layers, and stores them in a local store.

We added a fast path:

- The store now keeps a map called **`reference_db`**, which records "image
  reference → image ID".
- On every `PullImage` call, `image-rs` first checks this map.
- If the image reference is already in the map **and** its layers are present
  locally, it skips the registry entirely and builds the container bundle from
  what is on disk.
- After a normal (online) pull, we also record the reference so the *next*
  time is fast.

This is a small, backwards-compatible change.  The two commits are:

```
image-rs: add reference-based image cache lookup to skip registry pull
image-rs: write manifest-digest form into reference_db after pull
```

The second one matters because container runtimes like containerd resolve an
image tag to a digest before passing it on.  We record both forms so the cache
is hit whether CDH is asked for the tag or the digest.

### 2. cloud-api-adaptor (CAA, the peer pod manager)

CAA builds the peer pod VM images with a tool called mkosi.  We added:

- A new build target `make image-embedded` that builds a podvm with a container
  image pre-embedded.
- The build pre-pulls the image using a small CLI called `cdh-oneshot`, then
  copies the layers and metadata into the image.
- A boot-time service, **`kata-image-cache`**, that:
  1. copies the image metadata (`meta_store.json`) into CDH's working directory
     first (so CDH always sees it),
  2. bind-mounts each cached layer directory into the CDH layer store,
     read-only.
- A new mkosi profile (`embedded`) that enables the service only for embedded
  images.

The design choice that made it work: we **bind-mount** each layer directory
onto a writable layer store, instead of mounting the whole cache read-only.
If the layer store path itself were read-only, CDH would fail whenever it
tried to add a new layer for an image not in the cache (with a confusing "failed
to roll back when unpacking" error).  Keeping the store writable while exposing
the embedded layers through read-only bind mounts gives us both: cached images
are instant, and new images can still be pulled normally.

---

## The test setup (BYOM on kind)

We validated everything on a local test environment using CAA's **BYOM**
(Bring Your Own Machine) provider on a **kind** cluster.

In BYOM, the "VM" is a Docker container.  We can
`docker exec` into it and inspect what CDH is doing (the journal, the
mounts, the network) without a full virtualization setup.

We did this in five steps.

### Step 1: Build the patched CDH

We built the CDH daemon and a small helper CLI (`cdh-oneshot`) from the updated
guest-components branch:

```
confidential-data-hub  v0.21.0-04214c4e
resource providers:    KBS, SEV
kms plugins:           ALIYUN
```

### Step 2: Pre-pull the test image

Using `cdh-oneshot`, we pulled a small test image (`nginx`, 66 MB) and saved its
layers plus its `meta_store.json`.  That file now contains the `reference_db`
map:

```json
"reference_db": {
  "docker.io/library/nginx:latest": "sha256:878c3373...",
  "docker.io/library/nginx@sha256:1eeaa05a...": "sha256:878c3373..."
}
```

### Step 3: Build an embedded podvm image

We took the standard BYOM podvm container image and added:

- the patched CDH daemon,
- the nginx layers at `/usr/lib/kata-cache/layers/`,
- the `meta_store.json` at `/usr/lib/kata-cache/meta_store.json`,
- the `kata-image-cache` boot service.

### Step 4: Deploy CAA with the embedded VMs

We deployed CAA v0.22.0 on the kind cluster, pointed the BYOM pool at our three
embedded VMs, and confirmed everything came up healthy.

### Step 5: Run the tests

We created a pod that uses the embedded image with `imagePullPolicy:
IfNotPresent` (so the node uses its local copy and the only question is whether
CDH inside the VM can get the image).

---

## The results

### Case A: registry open

Pod started normally.  No surprises.

### Case B: registry blocked, embedded image

We blocked the registry **inside the VM** with iptables rules that drop every
packet to docker.io.  We confirmed the registry was unreachable, then created
the pod again.

**The pod reached Ready in 10 seconds.**

Inside the VM, the CDH journal showed the cache hit:

```
INFO image_rs::builder: Existing metadata found. Using previous ones.
INFO image_rs::image: Image docker.io/library/nginx:latest found in local cache, creating bundle
```

That line, *"found in local cache, creating bundle"*, is the proof.  CDH pulled
nothing.  It found the image in the embedded cache and built the container
there.

The boot service log confirmed it had run and mounted the layers:

```
kata-image-cache.service ... Active: active (exited)
kata-image-cache-setup: kata-image-cache: bound layer 0
kata-image-cache-setup: kata-image-cache: bound layer 1
...
/run/kata-containers/image/layers/0   overlay[/usr/lib/kata-cache/layers/0]   overlay ro
```

### Case C: registry blocked, image NOT embedded (the control)

To confirm the block worked, we ran a pod with a
different image (`redis`) that was **not** in the embedded cache, on the same
cluster with the same block.

```
[CDH] [ERROR]: Image Pull error: Failed to pull image
docker.io/library/redis:latest ... failed to pull image manifest:
Not authorized: url https://index.docker.io/v2/library/redis/manifests/latest
```

It failed as expected.  CDH had no local copy, tried the registry, and was
blocked.

### The conclusion

| Case | Image in embedded cache | Registry blocked | Result |
|---|---|---|---|
| A | nginx, yes | no | PASS |
| B | nginx, yes | **yes** | **PASS** (10 s) |
| C | redis, no | **yes** | FAIL |

The embedded image runs with the registry unreachable; a
non-embedded image fails.  The only explanation is that CDH serves the
embedded image from local disk, with **no registry contact**.

---

## How fast is it? (measurements)

To quantify the benefit we measured pod start time for a **large image**
(`python:3.12`, 411 MB compressed, 1.6 GB uncompressed) in three configurations:

1. **Regular pod** (runc) with the image already on the worker node: the
   baseline for "container already present".
2. **kata-remote with the embedded cache**: the image is inside the VM, and we
   blocked the registry in the VM to prove the cache is what serves it.
3. **kata-remote without embedding**: the stock VM pulls the 1.6 GB image from
   the registry inside the guest.

The image is pre-pulled on the node in all cases (`imagePullPolicy:
IfNotPresent`), so the node-side is identical and no node download happens
during the measured window.

| Case | Run 1 | Run 2 | Run 3 | Median |
|---|---|---|---|---|
| Regular pod (runc), image on node | 1.89 s | 1.82 s | 1.78 s | **1.82 s** |
| kata-remote **embedded**, VM registry blocked | 6.48 s | 6.82 s | 9.87 s | **6.82 s** |
| kata-remote non-embedded, VM registry open | 59.09 s | 61.72 s | 66.22 s | **61.72 s** |

**Result: embedding makes pod start ~9x faster** (61.7 s → 6.8 s median).  The
55 s saved is the in-guest download of the 1.6 GB image.

The embedded case is ~3.7x the regular-pod baseline.  The remaining ~5 s gap is
the peer pod VM boot (QEMU/UKI + kata-agent start), a kata-remote cost
unrelated to the image.  Embedding removes the image-specific latency.

Full methodology, the node-side analysis, and the CDH journal proof are in
[perf_analysis.md](perf_analysis.md).

---

## Benefits

- **Fast pod startup**: image creation drops from "download over the network"
  to "mount local layers" (milliseconds of CDH work).
- **Works offline / air-gapped**: the VM never needs registry access for
  embedded images.
- **Resilient**: no rate-limit surprises, no registry outages during pod start.
- **Fits confidential computing**: everything stays inside the trusted VM
  boundary; the image is baked into the verified root filesystem.

It is not for every scenario: for very large images the embedded cache grows the
VM image, so for fast local registries the trade-off may not pay off.  Measure
first.  But for air-gapped, restricted, or slow-network deployments it is a
clean win.

---

## Where to find the changes

The changes live on two local branches, ready to be opened as pull requests:

| Project | Branch | What |
|---|---|---|
| guest-components | `image-cache-reference-db-v0.21.0` | `reference_db` fast path in image-rs |
| cloud-api-adaptor | `feature/embedded-image-cache-v0.22.0` | `image-embedded` build + cache boot service |

Both are based on the **latest releases** of their projects (guest-components
v0.21.0, cloud-api-adaptor v0.22.0), so they are ready to be proposed upstream.

The full technical details, build scripts, and test documentation are in the
project repository:

- [embedding-container-image-in-caa.md](embedding-container-image-in-caa.md): the CAA/qcow2 approach
- [embedding-container-image-in-kata-vm.md](embedding-container-image-in-kata-vm.md): the Kata/QEMU approach
- [experiments-caa.md](experiments-caa.md): CAA validation experiments
- [experiments-byom.md](experiments-byom.md): the BYOM test described here
- [build-kata-vm-verity.sh](build-kata-vm-verity.sh): automated VM image build

---

## Acknowledgements

This work builds on the guest-components and cloud-api-adaptor projects, and
the Confidential Containers community around them.