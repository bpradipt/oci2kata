# Embedding Container Images in Kata VM Images

Embed a container image into the Kata VM disk image so CDH (Confidential Data Hub)
serves it from local cache without any registry contact inside the VM.

---

## Prerequisites

- Kata containers 3.31.0 installed via helm (kata-deploy)
- Modified guest-components with image-rs caching patches:
  - Repo: `https://github.com/bpradipt/guest-components` branch `local-0.20.0`
  - Binary: `/opt/guest-components/target/x86_64-unknown-linux-musl/release/confidential-data-hub`
  - `cdh-oneshot` tool: `/opt/guest-components/target/x86_64-unknown-linux-musl/release/cdh-oneshot`
- Tools: `kpartx`, `mkfs.erofs` (erofs-utils), `rsync`, `parted`

---

## Steps

### 1. Pre-pull the container image

Pull into `/run/kata-containers/image/` so layer paths in `meta_store.json` match
what CDH uses at runtime. `cdh-oneshot` uses CDH's own image-rs code path, so the
layer store format is guaranteed to match what CDH expects at runtime.

```bash
CDH_ONESHOT=/opt/guest-components/target/x86_64-unknown-linux-musl/release/cdh-oneshot
IMAGE_REF=<IMAGE_REFERENCE>

sudo mkdir -p /run/kata-containers/image

# Write a minimal CDH config: offline_fs_kbc avoids any network KBS call
cat > /tmp/cdh-build.toml << EOF
[kbc]
name = "offline_fs_kbc"
url = ""

[image]
work_dir = "/run/kata-containers/image"
EOF

sudo env RUST_LOG=info "$CDH_ONESHOT" --config /tmp/cdh-build.toml pull-image \
  --image-url "$IMAGE_REF" \
  --bundle-path /tmp/pull-bundle
rm -f /tmp/cdh-build.toml

# Add the manifest-digest form of the reference to reference_db.
# kata-agent resolves the tag to a digest before calling CDH, so both
# "image:tag" and "image@sha256:..." must be present for the cache hit.
IMAGE_REPO=$(echo "$IMAGE_REF" | sed 's/:.*//')
sudo python3 - /run/kata-containers/image/meta_store.json "$IMAGE_REF" "$IMAGE_REPO" << 'PYEOF'
import json, sys
path, tag_ref, repo = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    meta = json.load(f)
config_hash = meta.get("reference_db", {}).get(tag_ref)
manifest_digest = meta.get("image_db", {}).get(config_hash, {}).get("digest")
digest_ref = f"{repo}@{manifest_digest}"
if digest_ref not in meta["reference_db"]:
    meta["reference_db"][digest_ref] = config_hash
    with open(path, "w") as f:
        json.dump(meta, f, indent=2)
    print(f"Added digest ref: {digest_ref}")
PYEOF
```

Check layer size:
```bash
sudo du -sh /run/kata-containers/image/layers
```

### 2. Create an erofs image of the layers

Only lz4 is supported in the kata kernel (`CONFIG_EROFS_FS_ZIP=y`, no squashfs/zstd).
Use `lz4` + block-level deduplication for best compression:

```bash
sudo mkfs.erofs -z lz4 -E dedupe \
  /tmp/layers.erofs \
  /run/kata-containers/image/layers
ls -lh /tmp/layers.erofs
```

### 3. Calculate the required VM image size

```
Required space = original rootfs (~215MB) + CDH binary (~35MB) + erofs size + 50MB headroom
```

The VM image file size **must be an exact multiple of 2MB** (NVDIMM alignment
requirement). Use the smallest multiple of `2 * 1024 * 1024` that fits:

```bash
EROFS_MB=$(du -sm /tmp/layers.erofs | cut -f1)
TOTAL_MB=$(( EROFS_MB + 215 + 35 + 50 ))
# Round up to next 2MB boundary
IMAGE_MB=$(( (TOTAL_MB / 2 + 1) * 2 ))
echo "Image size: ${IMAGE_MB}MB"
```

### 4. Create a fresh VM image

> **Critical**: Never extend an existing kata VM image. Extending preserves old NVDIMM
> labels that constrain the visible device size to the original. Always create a fresh file.

```bash
IMAGE=/path/to/new-kata-vm.image
dd if=/dev/zero of=$IMAGE bs=1M count=${IMAGE_MB}
sudo parted $IMAGE --script mklabel msdos
sudo parted $IMAGE --script mkpart primary ext4 3MiB 100%
sudo parted $IMAGE --script set 1 boot on
sudo kpartx -av $IMAGE
sudo mkfs.ext4 -L kata-rootfs /dev/mapper/loop0p1
```

### 5. Copy the original rootfs

```bash
ORIG=/opt/kata/share/kata-containers/kata-ubuntu-noble-confidential.image
sudo kpartx -av $ORIG
sudo mkdir -p /mnt/kata-orig /mnt/kata-new
sudo mount -o ro /dev/mapper/loop1p1 /mnt/kata-orig
sudo mount /dev/mapper/loop0p1 /mnt/kata-new
sudo rsync -a /mnt/kata-orig/ /mnt/kata-new/
```

### 6. Install the modified CDH binary

```bash
sudo cp \
  /opt/guest-components/target/x86_64-unknown-linux-musl/release/confidential-data-hub \
  /mnt/kata-new/usr/local/bin/confidential-data-hub
```

### 7. Install the image cache

```bash
sudo mkdir -p /mnt/kata-new/opt/kata-cache
sudo cp /tmp/layers.erofs          /mnt/kata-new/opt/kata-cache/layers.erofs
sudo cp /run/kata-containers/image/meta_store.json \
                                   /mnt/kata-new/opt/kata-cache/meta_store.json
```

### 8. Install the systemd cache service

```bash
sudo tee /mnt/kata-new/usr/lib/systemd/system/kata-image-cache.service > /dev/null << 'EOF'
[Unit]
Description=Mount pre-embedded container image cache at kata image work directory
DefaultDependencies=no
Before=kata-agent.service
After=local-fs.target tmp.mount

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '\
  set -e; \
  mkdir -p /run/kata-layers-erofs /run/kata-layers-upper /run/kata-layers-work && \
  mount -t erofs -o loop /opt/kata-cache/layers.erofs /run/kata-layers-erofs && \
  mkdir -p /run/kata-containers/image/layers /run/kata-containers/image/overlay && \
  mount -t overlay overlay \
    -o lowerdir=/run/kata-layers-erofs,upperdir=/run/kata-layers-upper,workdir=/run/kata-layers-work \
    /run/kata-containers/image/layers && \
  cp /opt/kata-cache/meta_store.json /run/kata-containers/image/meta_store.json && \
  mount --bind /run/kata-containers/image/meta_store.json \
               /run/kata-containers/image/meta_store.json'

[Install]
WantedBy=kata-containers.target
EOF

# Enable the service
sudo mkdir -p /mnt/kata-new/etc/systemd/system/kata-containers.target.wants
sudo ln -sf /usr/lib/systemd/system/kata-image-cache.service \
  /mnt/kata-new/etc/systemd/system/kata-containers.target.wants/kata-image-cache.service

# Weak dependency: agent starts even if cache service fails
sudo mkdir -p /mnt/kata-new/etc/systemd/system/kata-agent.service.d
sudo tee /mnt/kata-new/etc/systemd/system/kata-agent.service.d/after-image-cache.conf > /dev/null << 'EOF'
[Unit]
After=kata-image-cache.service
Wants=kata-image-cache.service
EOF
```

### 9. Unmount and clean up

```bash
sudo umount /mnt/kata-new /mnt/kata-orig
sudo kpartx -dv $IMAGE
sudo kpartx -dv $ORIG
```

### 10. Configure kata to use the new image

Create a config.d drop-in (do not edit the managed config file directly):

```bash
sudo tee /opt/kata/share/defaults/kata-containers/runtimes/qemu-coco-dev/config.d/50-embedded-image.toml > /dev/null << EOF
[hypervisor.qemu]
image = "$IMAGE"
# Disable dm-verity: the image has been modified, so the original hash no longer
# matches the data. Use the fresh-image-with-dm-verity process (below) to get a
# valid hash for the modified rootfs instead.
kernel_verity_params = ""
# Boot directly from pmem0p1 (no dm-verity)
kernel_params = "root=/dev/pmem0p1 rootflags=data=ordered,errors=remount-ro ro rootfstype=ext4"
EOF
```

---

---

## Creating a Fresh Image with dm-verity (Recommended for Bare-Metal)

The process above creates a **single-partition image with dm-verity disabled** because
the original kata image's hash is no longer valid after the rootfs is modified. To keep
dm-verity, you must compute a fresh hash after finalising the rootfs — which requires a
two-partition layout (`p1` = rootfs data, `p2` = Merkle hash tree).

### How it differs from the existing approach

| | Existing (no dm-verity) | Fresh with dm-verity |
|---|---|---|
| Partitions | 1 (rootfs only) | 2 (rootfs + hash tree) |
| Boot | `root=/dev/pmem0p1` direct | `root=/dev/dm-0` via dm-verity |
| `kernel_verity_params` | empty string | `root_hash=…,salt=…,data_blocks=…` |
| Tamper detection | None | Yes (kernel panics on corruption) |
| dm-verity hash valid | N/A (disabled) | Yes — hash computed after rootfs is finalised |
| Original kata hash | Discarded | Must recompute with `veritysetup format` |

### Partition layout

```
┌────────────────────────────────────────────────────────────┐
│ Raw image file  (multiple of 2 MiB — NVDIMM alignment)    │
├──────┬──────────────────────────┬──────────────────────────┤
│ 3MiB │ p1: ext4 rootfs (data)  │ p2: dm-verity hash tree  │
│ gap  │  - original kata rootfs │  - SHA-256 Merkle tree   │
│      │  - CDH binary           │  - computed by verity-   │
│      │  - layers.erofs         │    setup format          │
│      │  - meta_store.json      │  - ~10 MiB for 1.2 GiB  │
│      │  - cache service        │    rootfs                │
└──────┴──────────────────────────┴──────────────────────────┘
```

The Merkle tree in `p2` covers every 4 KiB block of `p1`. `veritysetup format`
computes the tree and returns the root hash, salt, and block count — these go into
`kernel_verity_params` in the kata config drop-in.

### Automated build

A single script handles all steps:

```bash
cd /home/ubuntu/kata-vm-images
sudo ./build-kata-vm-verity.sh [IMAGE_REF [OUTPUT_DIR]]

# Default (7may image):
sudo ./build-kata-vm-verity.sh quay.io/bpradipt/kata-vm-image:7may
```

The script:
1. Pre-pulls the container image via `cdh-oneshot pull-image` (skips if layers exist at `/run/kata-containers/image/`), then injects the manifest-digest form of the reference into `reference_db`
2. Creates an erofs image of the layers (lz4 + dedup)
3. Calculates partition sizes (rootfs + hash tree + 2-MiB alignment)
4. Creates a fresh raw image file with `dd if=/dev/zero`
5. Partitions: `p1` (ext4, bootable) and `p2` (raw, for hash tree)
6. Populates `p1`: original kata rootfs + CDH binary + erofs cache + cache service
7. Unmounts and runs `veritysetup format p1 p2` → captures `root_hash`, `salt`, `data_blocks`
8. Writes the kata config drop-in with `kernel_verity_params`

### Manual step-by-step

If you need to run steps individually:

#### 1. Pre-pull the container image

```bash
CDH_ONESHOT=/opt/guest-components/target/x86_64-unknown-linux-musl/release/cdh-oneshot
IMAGE_REF=quay.io/bpradipt/kata-vm-image:7may

sudo mkdir -p /run/kata-containers/image

cat > /tmp/cdh-build.toml << EOF
[kbc]
name = "offline_fs_kbc"
url = ""

[image]
work_dir = "/run/kata-containers/image"
EOF

sudo env RUST_LOG=info "$CDH_ONESHOT" --config /tmp/cdh-build.toml pull-image \
  --image-url "$IMAGE_REF" \
  --bundle-path /tmp/pull-bundle
rm -f /tmp/cdh-build.toml

# Inject digest form into reference_db (kata-agent resolves tag → digest)
IMAGE_REPO=$(echo "$IMAGE_REF" | sed 's/:.*//')
sudo python3 - /run/kata-containers/image/meta_store.json "$IMAGE_REF" "$IMAGE_REPO" << 'PYEOF'
import json, sys
path, tag_ref, repo = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    meta = json.load(f)
config_hash = meta.get("reference_db", {}).get(tag_ref)
manifest_digest = meta.get("image_db", {}).get(config_hash, {}).get("digest")
digest_ref = f"{repo}@{manifest_digest}"
if digest_ref not in meta["reference_db"]:
    meta["reference_db"][digest_ref] = config_hash
    with open(path, "w") as f:
        json.dump(meta, f, indent=2)
    print(f"Added digest ref: {digest_ref}")
PYEOF

sudo du -sh /run/kata-containers/image/layers
```

#### 2. Create erofs image of layers

```bash
sudo mkfs.erofs -z lz4 -E dedupe /tmp/layers.erofs /run/kata-containers/image/layers
EROFS_MiB=$(( ($(stat -c%s /tmp/layers.erofs) + 1048575) / 1048576 ))
echo "erofs: ${EROFS_MiB} MiB"
```

#### 3. Calculate sizes

```bash
BLOCK_SIZE=4096
# rootfs 215 MiB + CDH 35 MiB + erofs + 100 MiB headroom; +15% ext4 overhead; 4-MiB aligned
P1_MiB=$(( ((215 + 35 + EROFS_MiB + 100) * 115 / 100 + 3) / 4 * 4 ))
DATA_BLOCKS=$(( P1_MiB * 1024 * 1024 / BLOCK_SIZE ))

# Hash tree: SHA-256, 128 hashes per 4096-byte block
L0=$(( (DATA_BLOCKS + 127) / 128 ))
L1=$(( (L0 + 127) / 128 ))
L2=$(( (L1 + 127) / 128 ))
P2_MiB=$(( ((L0 + L1 + L2) * BLOCK_SIZE + 1048575) / 1048576 + 4 ))

TOTAL_MiB=$(( 3 + P1_MiB + P2_MiB ))
IMAGE_MiB=$(( ((TOTAL_MiB + 1) / 2) * 2 ))   # round to 2-MiB boundary

echo "P1=${P1_MiB} MiB  P2=${P2_MiB} MiB  Image=${IMAGE_MiB} MiB"
```

#### 4. Create raw image with two partitions

```bash
IMAGE=/home/ubuntu/kata-vm-images/kata-ubuntu-noble-confidential-7may-verity.image
dd if=/dev/zero of=$IMAGE bs=1M count=$IMAGE_MiB status=progress

P1_END=$(( 3 + P1_MiB ))
P2_END=$(( P1_END + P2_MiB ))

sudo parted $IMAGE --script mklabel msdos
sudo parted $IMAGE --script mkpart primary ext4 3MiB ${P1_END}MiB
sudo parted $IMAGE --script set 1 boot on
sudo parted $IMAGE --script mkpart primary ${P1_END}MiB ${P2_END}MiB
sudo parted $IMAGE --script print
```

#### 5. Populate p1

```bash
ORIG=/opt/kata/share/kata-containers/kata-ubuntu-noble-confidential.image
KPARTX_NEW=$(sudo kpartx -av $IMAGE); LOOP_NEW=$(echo "$KPARTX_NEW" | head -1 | grep -oP 'loop\d+')
KPARTX_ORIG=$(sudo kpartx -av $ORIG); LOOP_ORIG=$(echo "$KPARTX_ORIG" | head -1 | grep -oP 'loop\d+')

sudo mkfs.ext4 -L kata-rootfs /dev/mapper/${LOOP_NEW}p1
sudo mkdir -p /mnt/kata-orig /mnt/kata-new
sudo mount -o ro /dev/mapper/${LOOP_ORIG}p1 /mnt/kata-orig
sudo mount /dev/mapper/${LOOP_NEW}p1 /mnt/kata-new

sudo rsync -a /mnt/kata-orig/ /mnt/kata-new/

# CDH binary
sudo cp /opt/guest-components/target/x86_64-unknown-linux-musl/release/confidential-data-hub \
  /mnt/kata-new/usr/local/bin/confidential-data-hub

# Image cache
sudo mkdir -p /mnt/kata-new/opt/kata-cache
sudo cp /tmp/layers.erofs                     /mnt/kata-new/opt/kata-cache/layers.erofs
sudo cp /run/kata-containers/image/meta_store.json /mnt/kata-new/opt/kata-cache/meta_store.json

# Install the cache service (same service as in the existing process above)
# ... (see Steps 8 and 9 of the existing process)

sudo umount /mnt/kata-new /mnt/kata-orig
```

#### 6. Compute dm-verity hash tree

```bash
# p2 must be unmounted and attached. The hash tree is written to p2.
VERITY=$(sudo veritysetup format \
  --data-block-size=4096 --hash-block-size=4096 --hash=sha256 \
  /dev/mapper/${LOOP_NEW}p1 /dev/mapper/${LOOP_NEW}p2 2>&1)
echo "$VERITY"

ROOT_HASH=$(echo "$VERITY" | grep "Root hash:"   | awk '{print $3}')
SALT=$(      echo "$VERITY" | grep "Salt:"        | awk '{print $2}')
DBLOCKS=$(   echo "$VERITY" | grep "Data blocks:" | awk '{print $3}')

sudo kpartx -dv $IMAGE
sudo kpartx -dv $ORIG
```

#### 7. Configure kata

```bash
sudo tee /opt/kata/share/defaults/kata-containers/runtimes/qemu-coco-dev/config.d/50-verity-embedded.toml > /dev/null << EOF
[hypervisor.qemu]
image = "${IMAGE}"
kernel_verity_params = "root_hash=${ROOT_HASH},salt=${SALT},data_blocks=${DBLOCKS},data_block_size=4096,hash_block_size=4096"
kernel_params = ""
EOF
```

### Verification inside the VM

After booting a pod with the dm-verity image:

```bash
# Inside the kata VM (via kata-runtime exec <sandbox-id>)

# Confirm dm-verity device is active
dmsetup info /dev/dm-0
dmsetup status /dev/dm-0      # should show "V" (valid) not "C" (corrupted)

# Confirm the cache service ran
systemctl status kata-image-cache.service

# Confirm overlay mount
findmnt /run/kata-containers/image/layers
```

---

## Customised Kata VM Images

All images are stored in `/home/ubuntu/kata-vm-images/`:

| File | Embedded Image | VM Size | Notes |
|------|---------------|---------|-------|
| `kata-ubuntu-noble-confidential-fedora41.image` | `quay.io/fedora/fedora:41` | 384MB | Uses original 384MB VM; 96MB erofs; dm-verity disabled |
| `kata-ubuntu-noble-confidential-kata-vm-image-7may.image` | `quay.io/bpradipt/kata-vm-image:7may` | 1.5GB | Fresh 1.5GB VM; 714MB erofs; dm-verity disabled |
| `kata-ubuntu-noble-confidential-kata-vm-image_7may-verity.image` | `quay.io/bpradipt/kata-vm-image:7may` | 1.21GiB | Fresh image with dm-verity; p1=1224MiB rootfs (313344 blocks), p2=14MiB hash tree; `root_hash=70052d21a6ad8dc301e157e8b21caf189eec80537347a22c4b6f94dd6d5d9d76` |

The original (unmodified) kata 3.31.0 image is at:
```
/opt/kata/share/kata-containers/kata-ubuntu-noble-confidential.image  (384MB)
```

---

## Key Technical Findings

### NVDIMM Alignment
The kata VM image is presented to the guest as an NVDIMM (persistent memory) device.
The `nd_pmem` kernel driver **requires the image file size to be an exact multiple of 2MB**.
Non-aligned sizes cause `nd_pmem: probe failed with error -95 (EOPNOTSUPP)`.

```
Valid:   384MB = 192 × 2MB ✓    768MB = 384 × 2MB ✓    1536MB = 768 × 2MB ✓
Invalid: 734MB, 769MB — nd_pmem probe fails, kernel panic at boot
```

### Never Extend an Existing Image
Extending a kata VM image with `truncate` preserves NVDIMM labels from the original
size. The kernel reads these labels and creates a device of the *original* size,
ignoring the extended space. Always create a fresh image at the target size.

### Why the Existing Custom Images Disable dm-verity
The default `kata-qemu-coco-dev` configuration uses dm-verity over NVDIMM partitions
(`/dev/pmem0p1` data, `/dev/pmem0p2` hash tree). When the rootfs is modified (CDH
binary replaced, erofs cache added), the original hash in `kernel_verity_params` no
longer matches the data — the kernel detects corruption and panics. The workaround used
in the existing custom images is to disable dm-verity (`kernel_verity_params = ""`). The
correct approach is to recompute the hash after finalising the rootfs, which is what
`build-kata-vm-verity.sh` does.

### Filesystem Compression: erofs only
The kata kernel (6.18.28) has:
- `CONFIG_EROFS_FS=y` with `CONFIG_EROFS_FS_ZIP=y` (lz4 only)
- `CONFIG_SQUASHFS` — not set
- `CONFIG_EROFS_FS_ZIP_LZMA` — not set

Only erofs with lz4 compression is available. Compression ratios vary:
- fedora:41 layers (325MB → 96MB with lz4+dedup): good compression
- kata-vm-image:7may layers (810MB → 714MB): poor compression (binary/already-compressed content)

### Overlay Mount Architecture
The cache service uses two stacked mounts to allow both cache hits and new layer writes:

```
/run/kata-layers-erofs/          ← erofs mounted (ro, embedded layers)
/run/kata-containers/image/layers/ ← overlay: lower=erofs, upper=tmpfs
/run/kata-containers/image/meta_store.json ← copied to tmpfs at boot
```

The image-rs snapshotter creates container bundle overlays at
`/run/kata-containers/image/overlay/<hash>/` which lands directly on tmpfs —
avoiding the "overlay-on-overlay upperdir" restriction.

### When Embedding Helps vs Hurts
| Scenario | Embedded cache | Verdict |
|----------|---------------|---------|
| Air-gapped / no registry access from VM | Required | **Use it** |
| Slow network (satellite, cross-region) | Saves 10s–minutes | **Use it** |
| Fast local registry (same datacenter) | Overhead may exceed savings | **Measure first** |
| Large erofs (>500MB) + small VM image | VM boot overhead grows | **Profile** |

---

## Sample Pod YAML

### Pod using embedded image (kata-qemu-coco-dev)

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: kata-embedded-test
spec:
  runtimeClassName: kata-qemu-coco-dev
  restartPolicy: Never
  containers:
  - name: app
    image: quay.io/bpradipt/kata-vm-image:7may
    command: ["sleep", "3600"]
    resources:
      requests:
        memory: "256Mi"
        cpu: "500m"
```

Save as `pod-embedded.yaml` and run:
```bash
kubectl apply -f pod-embedded.yaml
kubectl wait --for=condition=Ready pod/kata-embedded-test --timeout=120s
kubectl exec kata-embedded-test -- uname -r   # should show kata kernel (6.18.28)
kubectl exec kata-embedded-test -- cat /etc/os-release
```

### Verify cache was used (exec into the kata VM)

```bash
# Get the sandbox ID
SANDBOX=$(sudo ls /run/vc/vm/ | while read s; do
  pid=$(sudo cat /run/vc/vm/$s/pid 2>/dev/null)
  tr '\0' '\n' < /proc/$pid/cmdline 2>/dev/null | grep -q "7may\|embedded" && echo $s
done)

# Enter the kata VM
sudo /opt/kata/bin/kata-runtime exec $SANDBOX
```

Inside the VM, verify:
```bash
# Service ran successfully
systemctl status kata-image-cache.service

# Layers available from erofs
ls /run/kata-containers/image/layers/

# Image URL is in the reference cache
grep reference_db /run/kata-containers/image/meta_store.json

# Confirm erofs is the layer source
findmnt /run/kata-containers/image/layers
```

Expected output for `findmnt`:
```
TARGET                              SOURCE  FSTYPE  OPTIONS
/run/kata-containers/image/layers   overlay overlay lowerdir=/run/kata-layers-erofs,...
```
