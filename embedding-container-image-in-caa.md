# Embedding Container Images in CAA Peer Pod VMs

Embed a container image into a CAA (Cloud API Adaptor) peer pod qcow2 so CDH
serves it from local cache with zero registry contact inside the VM.

> **See also:** [Kata/QEMU approach](embedding-container-image-in-kata-vm.md),
> the original implementation this is based on.  The CAA approach shares the same
> CDH fork and `meta_store.json` format; the differences are in the VM image
> build tooling, filesystem layout, and layer store mount strategy.

---

## How It Differs from the Kata/QEMU Approach

| | Kata/QEMU | CAA peer pod |
|---|---|---|
| VM image format | raw ext4 + dm-verity | squashfs + UKI (mkosi) |
| Build tool | `build-kata-vm-verity.sh` | `make image-embedded` |
| Runtime class | `kata-qemu-coco-dev` | `kata-remote` |
| VM RAM required | 256 Mi | **4 Gi** (UKI bundles 62.6 MB initrd) |
| Cache paths in squashfs | `/opt/kata-cache/` | `/usr/lib/kata-cache/` |
| Layer store strategy | tar-extract to tmpfs | **bind-mount** from erofs |
| Case 4 timing | ~10 s | ~52 s (VM create + UEFI + UKI boot) |
| dm-verity | two-partition (p1=data, p2=hash) | mkosi repart (256 M hash partition) |

The most important design difference is the **bind-mount layer store**: the CAA
version mounts the erofs archive at a private location and bind-mounts each
cached layer directory individually onto a writable tmpfs layer store, rather
than extracting layers to tmpfs.  See [Why bind-mounts](#why-bind-mounts) below.

---

## Repository

CAA changes live in:

```
https://github.com/bpradipt/cloud-api-adaptor  branch: image-cache-0.21.1
src/cloud-api-adaptor/podvm-mkosi/
├── Dockerfile.mkosi.embedded.ubuntu      ← multi-stage build
├── Makefile                              ← image-embedded target
├── EMBEDDED_IMAGE.md                     ← detailed build notes
└── mkosi.images/system/mkosi.skeleton/
    ├── usr/lib/kata-cache/               ← erofs + meta_store injected at build
    ├── usr/local/bin/kata-image-cache-setup
    └── usr/lib/systemd/system/
        ├── kata-image-cache.service
        ├── kata-agent.service.d/10-image-cache.conf
        └── confidential-data-hub.service.d/10-image-cache.conf
```

---

## Architecture

### Build time (Docker multi-stage → qcow2)

```
Stage 1  cdh-builder
         Clone bpradipt/guest-components @ image-cache-0.20.0
         Build CDH daemon  (reference_db patch, musl static) → /cdh-daemon
         Build cdh-oneshot (ONE_SHOT=true)                   → /cdh-oneshot
         NOTE: ONE_SHOT=true renames cdh-oneshot → confidential-data-hub
         in target/; save the daemon binary BEFORE running ONE_SHOT.

Stage 2  image-puller
         mount tmpfs at /run/kata-containers  (avoids overlay-on-overlay
         EINVAL inside BuildKit's overlay2 storage driver)
         cdh-oneshot pull-image \
           --image-url <EMBEDDED_IMAGE> --bundle-path /tmp/bundle
             → layers in /run/kata-containers/image/layers/0..N
             → /run/kata-containers/image/meta_store.json written
         mkfs.erofs -z lz4 -E dedupe /layers.erofs \
             /run/kata-containers/image/layers
         copy meta_store.json → /meta_store.json

Stage 3  mkosi-builder
         Standard mkosi build with extra files injected:
           /cdh-daemon   → resources/binaries-tree/.../confidential-data-hub
           /layers.erofs → mkosi.skeleton/usr/lib/kata-cache/layers.erofs
           /meta_store.json → mkosi.skeleton/usr/lib/kata-cache/meta_store.json
         mkosi --profile=embedded --profile=debug
           Finalize: systemctl enable kata-image-cache.service
           Repart:   squashfs rootfs (1.5 G) + dm-verity hash (256 M)

Output: system.raw → qemu-img convert → podvm-ubuntu-amd64-embedded.qcow2
```

### Boot time (inside the peer pod VM)

```
kata-image-cache.service   (Type=oneshot, Before=CDH + kata-agent)

  Step 1: cp /usr/lib/kata-cache/meta_store.json
             /run/kata-containers/image/meta_store.json
             ← ALWAYS done first, before any mount that could fail

  Step 2: modprobe erofs

  Step 3: mount -t erofs -o ro /usr/lib/kata-cache/layers.erofs
                               /run/kata-cache-erofs     ← private location

  Step 4: mkdir -p /run/kata-containers/image/layers     ← writable tmpfs

  Step 5: for each layer N in /run/kata-cache-erofs/:
            mount --bind --make-private /run/kata-cache-erofs/N
                                        /run/kata-containers/image/layers/N
            mount -o remount,ro,bind    /run/kata-containers/image/layers/N

CDH daemon starts, reads meta_store.json → reference_db hit for the embedded image.
image-rs: create_bundle → snapshot.mount(bind-mounted layer dirs as overlay lower-dir)
kata-agent: container bundle ready, container starts.
```

### Why bind-mounts

Three designs were tried:

**Design 1: `cp -a` layers to tmpfs**: copying 700 MB of layers before
kata-agent could start added minutes of latency.

**Design 2: direct erofs mount at the CDH layer store path**:
mounting erofs at `/run/kata-containers/image/layers` made the CDH layer store
read-only.  Any attempt by CDH to create a new layer directory (e.g. a
reference_db miss, or a different embedded image) hit EROFS; the subsequent
`remove_dir_all` rollback got ENOENT because the directory was never created,
producing the opaque error:

```
Failed to decode layer data stream: Failed to roll back when unpacking
```

**Design 3 (current): bind-mount per layer onto writable tmpfs**:

```
/run/kata-cache-erofs/          private erofs mount (ro)
/run/kata-containers/image/layers/   writable tmpfs
  layers/0  → bind-mount (ro) from /run/kata-cache-erofs/0
  layers/1  → bind-mount (ro) from /run/kata-cache-erofs/1
  ...
  layers/<n> → plain tmpfs directory for new network-pulled layers
```

The CDH layer store remains writable, so CDH can create new layer directories
for images not in the embedded cache without hitting EROFS.  Bind-mounted
directories are valid overlay lower-dir sources, so `snapshot.mount()` succeeds.

---

## Prerequisites

### CDH fork

The patched CDH daemon must be built from:

```
Repo:   https://github.com/bpradipt/guest-components.git
Branch: image-cache-0.20.0
```

This branch adds `reference_db` to `MetaStore`, enabling fast local cache lookup
by image reference string without contacting the registry.

### Docker buildx insecure-builder

The image-puller stage pulls a container image from quay.io at build time and
requires `security.insecure` (for tmpfs mount) and `network.host`:

```bash
docker buildx rm insecure-builder 2>/dev/null || true
docker buildx create \
  --driver-opt image=moby/buildkit:master \
  --name insecure-builder \
  --buildkitd-flags '--allow-insecure-entitlement security.insecure \
                     --allow-insecure-entitlement network.host'
```

### Standard binaries must be built first

```bash
cd src/cloud-api-adaptor/podvm-mkosi
PODVM_DISTRO=ubuntu make binaries
```

---

## Build

```bash
cd src/cloud-api-adaptor/podvm-mkosi

PODVM_DISTRO=ubuntu \
EMBEDDED_IMAGE="quay.io/bpradipt/kata-vm-image:7may" \
make image-embedded
```

Output:
```
build/system.raw                         (2.3 GB raw disk)
build/podvm-ubuntu-amd64-embedded.qcow2  (1.8 GB compressed qcow2)
```

| Makefile variable | Default | Description |
|---|---|---|
| `EMBEDDED_IMAGE` | `docker.io/library/nginx:latest` | OCI image to pre-cache |
| `GC_REPO` | `https://github.com/bpradipt/guest-components.git` | CDH fork |
| `GC_BRANCH` | `image-cache-0.20.0` | branch with reference_db patch |

---

## Embedding Multiple Images

Multiple container images can be embedded into a single `layers.erofs` archive
with automatic cross-image layer deduplication.  The erofs archive and
`meta_store.json` are produced by a sequential pull loop that feeds all images
into the **same `work_dir`** before the single `mkfs.erofs` call.

### Why deduplication is free

`image-rs` deduplicates at the `layer_db` level inside `MetaStore`.  In
`pull.rs`, before writing any new layer directory, it checks:

```rust
if let Some(layer_meta) = ms.read().await.layer_db.get(&layer.digest) {
    return Ok(layer_meta.clone());  // reuses existing store_path integer
}
```

Pulling Image B into the same `work_dir` as Image A returns the **existing**
integer directory for any layer whose digest is already in `layer_db`.  Nothing
is written twice.  After all pulls, `meta_store.json` contains every image in
`image_db` and `reference_db`, and every unique layer once in `layer_db`.
No manual merge step, no external digest registry file.

### The pull loop pattern

Replace the single `cdh-oneshot pull-image` call in Stage 2 with a loop.  The
**`work_dir` is shared** across all iterations; the **`bundle-path` is
per-image**: `cdh-oneshot` writes `config.json` into `bundle-path` on every
invocation and fails with `"OCI config file already exists"` if the same
directory is reused for a second image.

```bash
# One CDH config: work_dir shared across all pulls so layer_db dedup applies.
CDH_CONFIG=$(mktemp /tmp/cdh-build-XXXXXX.toml)
WORK_DIR=$(mktemp -d)
mkdir -p "$WORK_DIR/image"

cat > "$CDH_CONFIG" << EOF
[kbc]
name = "offline_fs_kbc"
url = ""

[image]
work_dir = "${WORK_DIR}/image"
max_concurrent_layer_downloads_per_image = 8
EOF

# EMBEDDED_IMAGES is a space-separated list of OCI image refs.
# Each pull extends layer_db and image_db in-place; shared layers are reused.
for img in $EMBEDDED_IMAGES; do
    BUNDLE_DIR=$(mktemp -d)         # fresh dir per image (mandatory)
    cdh-oneshot --config "$CDH_CONFIG" pull-image \
        --image-url  "$img" \
        --bundle-path "$BUNDLE_DIR"
    umount -l "$BUNDLE_DIR/rootfs" 2>/dev/null || true   # clean up overlay mount
    rm -rf "$BUNDLE_DIR"
done

# Pack once after all pulls: shared layers appear once in the archive.
mkfs.erofs -z lz4 -E dedupe layers.erofs "$WORK_DIR/image/layers"
cp "$WORK_DIR/image/meta_store.json" meta_store.json
```

`meta_store.json` now contains all N images in `image_db` and `reference_db`.
The boot-time script is unchanged: it bind-mounts every integer directory it
finds in the erofs archive, regardless of how many images contributed to it.

### Backward compatibility

`EMBEDDED_IMAGE` (singular) is still accepted via a compat shim:

```bash
if [ -n "${EMBEDDED_IMAGE:-}" ] && [ -z "${EMBEDDED_IMAGES:-}" ]; then
    EMBEDDED_IMAGES="$EMBEDDED_IMAGE"
fi
```

### Stale-cache sentinel

The sentinel file `layers.erofs.imageref` changes from a single image ref to a
**sorted, newline-separated list**.  Any change to the list (addition, removal,
or tag update) invalidates the entire cache and re-pulls all images.

```bash
# Write sentinel after a successful build
printf '%s\n' $EMBEDDED_IMAGES | sort > layers.erofs.imageref

# Stale-cache check on the next run
CURRENT=$(printf '%s\n' $EMBEDDED_IMAGES | sort)
CACHED=$(cat layers.erofs.imageref 2>/dev/null || true)
if [ "$CURRENT" != "$CACHED" ]; then
    rm -f layers.erofs meta_store.json layers.erofs.imageref
fi
```

### Verification

After building with two images, inspect `meta_store.json` to confirm both are
present and shared layers are stored once:

```bash
# Both images registered
jq '.image_db | length' meta_store.json
# → 2

# Unique layer count is less than the naive sum of each image's layer count
jq '[.image_db[].layer_metas[].store_path] | unique | length' meta_store.json

# Both image refs in the reference_db fast-path lookup
jq '.reference_db | keys' meta_store.json
```

At runtime, request container creation for each embedded image in turn and
confirm CDH resolves both from the local cache:

```bash
journalctl -u confidential-data-hub.service --no-pager | grep "Existing metadata"
# → must appear for EACH of the embedded images
```

---

## Deploying to libvirt

Upload the embedded qcow2 to the libvirt storage pool as the podvm base volume:

```bash
virsh -c qemu:///system vol-delete podvm-base.qcow2 default 2>/dev/null || true
virsh -c qemu:///system vol-create-as default podvm-base.qcow2 20G \
    --format qcow2 --allocation 2G
virsh -c qemu:///system vol-upload --pool default podvm-base.qcow2 \
    build/podvm-ubuntu-amd64-embedded.qcow2
```

CAA creates a COW overlay on `podvm-base.qcow2` for each peer pod VM, so no
data is modified in the base volume.

---

## One-time worker-node configuration

The embedded UKI bundles a 62.6 MB compressed initrd; UEFI needs ~4 GB of RAM to
load it.  Two timeouts also need raising:

```bash
# kata-remote dial_timeout (default 30 s, too short for the UEFI + UKI boot)
sudo sed -i 's/dial_timeout = [0-9]*/dial_timeout = 600/' \
  /opt/kata/share/defaults/kata-containers/configuration-remote.toml

# kubelet runtimeRequestTimeout (default 2 min)
# In /var/lib/kubelet/config.yaml add:  runtimeRequestTimeout: 10m
sudo systemctl restart kubelet
```

---

## Running a pod

```yaml
# test-kata-pod-caa.yaml
apiVersion: v1
kind: Pod
metadata:
  name: embedded-image-test
spec:
  runtimeClassName: kata-remote
  containers:
  - name: test
    image: quay.io/bpradipt/kata-vm-image:7may
    imagePullPolicy: IfNotPresent
    args: ["sleep", "3600"]
    resources:
      requests:
        memory: "4Gi"
      limits:
        memory: "4Gi"
  restartPolicy: Never
```

`imagePullPolicy: IfNotPresent` is critical for the offline test: it lets the
kubelet skip the node-side pull (using the locally cached image) so the only
variable is whether CDH inside the VM can serve the image from the embedded cache.

```bash
kubectl apply -f test-kata-pod-caa.yaml
kubectl wait --for=condition=Ready pod/embedded-image-test --timeout=120s
kubectl logs embedded-image-test
kubectl exec embedded-image-test -- echo "running from embedded cache"
```

### Key paths inside the running VM

| Path | Content |
|---|---|
| `/usr/lib/kata-cache/layers.erofs` | erofs archive of all OCI image layers (squashfs, read-only) |
| `/usr/lib/kata-cache/meta_store.json` | image-rs reference database (squashfs, read-only) |
| `/run/kata-cache-erofs/` | private erofs mount point (tmpfs, runtime) |
| `/run/kata-containers/image/layers/0…N` | writable tmpfs + read-only bind mounts from erofs |
| `/run/kata-containers/image/meta_store.json` | copy of reference database (writable tmpfs) |
| `/usr/local/bin/confidential-data-hub` | patched CDH daemon (reference_db support) |

---

## Verified boot timeline (libvirt KVM, 4 GB VM)

| Time | Event |
|---|---|
| T+0 s | CAA creates VM (COW overlay on podvm-base.qcow2) |
| T+20 s | VM ready, APF connects to worker node |
| T+27 s | CreateContainer: CDH resolves image from reference_db, overlay mounted |
| T+28 s | StartContainer: container running |

CDH resolves `quay.io/bpradipt/kata-vm-image:7may` from the embedded
reference_db on first request, with no network contact and no layer download.

---

## Key files in the CAA repo

| File | Purpose |
|---|---|
| `podvm-mkosi/Dockerfile.mkosi.embedded.ubuntu` | Multi-stage build: cdh-builder → image-puller → mkosi-builder |
| `podvm-mkosi/Makefile` (`image-embedded` target) | Orchestrates the Docker buildx build |
| `podvm-mkosi/EMBEDDED_IMAGE.md` | Full build notes, all design decisions, all bugs fixed |
| `mkosi.skeleton/usr/local/bin/kata-image-cache-setup` | Boot script: copies meta_store.json, bind-mounts layers |
| `mkosi.skeleton/…/kata-image-cache.service` | Systemd unit enabled by the `embedded` mkosi profile |
| `mkosi.repart/20-root-verity.conf` | dm-verity partition enlarged to 256 M for 1.5 G squashfs |
