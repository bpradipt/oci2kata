#!/bin/bash
# Build a fresh kata VM image with dm-verity and an embedded container image.
#
# Usage:
#   sudo ./build-kata-vm-verity.sh [IMAGE_REF [OUTPUT_DIR]]
#
# Defaults:
#   IMAGE_REF  = quay.io/bpradipt/kata-vm-image:7may
#   OUTPUT_DIR = /home/ubuntu/kata-vm-images
#
# Requirements:
#   - pull_debug binary (image-rs) compiled at PULL_DEBUG path
#   - mkfs.erofs (erofs-utils), parted, kpartx, rsync, veritysetup
#   - ~3 GB free disk (erofs + new image)
#
# dm-verity note:
#   The resulting image has a proper two-partition layout (p1=rootfs, p2=hash
#   tree). veritysetup format computes a fresh hash after the rootfs is fully
#   populated, so kernel_verity_params in the drop-in is always consistent with
#   the actual data. The kernel verifies the hash at boot — it works the same
#   in nested and non-nested KVM.

set -euo pipefail

# ── configuration ──────────────────────────────────────────────────────────────
IMAGE_REF="${1:-quay.io/bpradipt/kata-vm-image:7may}"
OUTPUT_DIR="${2:-/home/ubuntu/kata-vm-images}"

PULL_DEBUG=/home/ubuntu/guest-components/target/x86_64-unknown-linux-musl/release/pull_debug
ORIG_IMAGE=/opt/kata/share/kata-containers/kata-ubuntu-noble-confidential.image
CDH_BINARY=/home/ubuntu/guest-components/target/x86_64-unknown-linux-musl/release/confidential-data-hub
WORK_DIR=/run/kata-containers/image
BLOCK_SIZE=4096   # dm-verity data and hash block size
GAP_MiB=3         # MBR + alignment gap before first partition

# ── derive filenames ───────────────────────────────────────────────────────────
# e.g. "quay.io/bpradipt/kata-vm-image:7may" → "kata-vm-image-7may"
IMAGE_SLUG=$(echo "$IMAGE_REF" | sed 's|.*/||; s|:|_|; s|:|-|')
EROFS_TMP=/tmp/${IMAGE_SLUG}-layers.erofs
OUTPUT_IMAGE="${OUTPUT_DIR}/kata-ubuntu-noble-confidential-${IMAGE_SLUG}-verity.image"
CONFIG_FILE=/opt/kata/share/defaults/kata-containers/runtimes/qemu-coco-dev/config.d/50-verity-embedded.toml

LOOP_NEW_ATTACHED=""
LOOP_ORIG_ATTACHED=""
MNT_NEW=""
MNT_ORIG=""

# ── cleanup on exit ────────────────────────────────────────────────────────────
cleanup() {
  set +e
  [[ -n "$MNT_NEW"  ]] && mountpoint -q "$MNT_NEW"  2>/dev/null && sudo umount "$MNT_NEW"  && rmdir "$MNT_NEW"
  [[ -n "$MNT_ORIG" ]] && mountpoint -q "$MNT_ORIG" 2>/dev/null && sudo umount "$MNT_ORIG" && rmdir "$MNT_ORIG"
  [[ -n "$LOOP_NEW_ATTACHED"  ]] && sudo kpartx -dv "$OUTPUT_IMAGE" 2>/dev/null
  [[ -n "$LOOP_ORIG_ATTACHED" ]] && sudo kpartx -dv "$ORIG_IMAGE"   2>/dev/null
}
trap cleanup EXIT

# ── preflight checks ───────────────────────────────────────────────────────────
for bin in mkfs.erofs parted kpartx rsync veritysetup; do
  command -v $bin > /dev/null || { echo "ERROR: $bin not found"; exit 1; }
done
[[ -f "$PULL_DEBUG"  ]] || { echo "ERROR: pull_debug not found at $PULL_DEBUG"; exit 1; }
[[ -f "$CDH_BINARY"  ]] || { echo "ERROR: CDH binary not found at $CDH_BINARY"; exit 1; }
[[ -f "$ORIG_IMAGE"  ]] || { echo "ERROR: original kata image not found: $ORIG_IMAGE"; exit 1; }

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Building kata VM image with dm-verity + embedded container"
echo "  Image ref:  $IMAGE_REF"
echo "  Output:     $OUTPUT_IMAGE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── step 1: pre-pull container image ──────────────────────────────────────────
echo ""
echo "=== Step 1: Pre-pull container image ==="
if sudo test -d "$WORK_DIR/layers" && sudo test -f "$WORK_DIR/meta_store.json"; then
  echo "  Layers already present at $WORK_DIR — skipping pull."
  echo "  (Delete $WORK_DIR to force re-pull)"
else
  sudo mkdir -p "$WORK_DIR"
  sudo "$PULL_DEBUG" \
    --image "$IMAGE_REF" \
    --work-dir "$WORK_DIR" \
    --bundle-dir /tmp/pull-bundle-${IMAGE_SLUG}
fi
echo "  Layers: $(sudo du -sh $WORK_DIR/layers 2>/dev/null | cut -f1)"

# ── step 2: create erofs image of layers ──────────────────────────────────────
echo ""
echo "=== Step 2: Create erofs image of layers ==="
if [[ -f "$EROFS_TMP" ]]; then
  echo "  erofs already exists at $EROFS_TMP — skipping."
else
  sudo mkfs.erofs -z lz4 -E dedupe "$EROFS_TMP" "$WORK_DIR/layers"
fi
EROFS_BYTES=$(stat -c%s "$EROFS_TMP")
EROFS_MiB=$(( (EROFS_BYTES + 1048575) / 1048576 ))
echo "  erofs size: ${EROFS_MiB} MiB"

# ── step 3: calculate image and partition sizes ────────────────────────────────
echo ""
echo "=== Step 3: Calculating partition sizes ==="

# Rootfs partition: original rootfs (~215 MiB) + CDH binary (~35 MiB) +
# erofs image + 100 MiB headroom, then +15% for ext4 overhead.
# Rounded up to the next 4-MiB multiple for a clean data_blocks count.
CONTENT_MiB=$(( 215 + 35 + EROFS_MiB + 100 ))
P1_MiB=$(( ((CONTENT_MiB * 115 / 100) + 3) / 4 * 4 ))

# dm-verity hash tree size for SHA-256 with 4096-byte blocks:
#   128 hashes per block → levels until 1 block remains.
DATA_BLOCKS=$(( P1_MiB * 1024 * 1024 / BLOCK_SIZE ))
L0=$(( (DATA_BLOCKS + 127) / 128 ))
L1=$(( (L0 + 127) / 128 ))
L2=$(( (L1 + 127) / 128 ))
TOTAL_HASH_BLOCKS=$(( L0 + L1 + L2 ))
# Add 4 MiB headroom; veritysetup writes a 4096-byte superblock too.
P2_MiB=$(( (TOTAL_HASH_BLOCKS * BLOCK_SIZE + 1048575) / 1048576 + 4 ))

TOTAL_MiB=$(( GAP_MiB + P1_MiB + P2_MiB ))
# NVDIMM alignment: image file must be an exact multiple of 2 MiB.
IMAGE_MiB=$(( ((TOTAL_MiB + 1) / 2) * 2 ))

echo "  P1 rootfs:    ${P1_MiB} MiB  (data_blocks=${DATA_BLOCKS})"
echo "  P2 hash tree: ${P2_MiB} MiB  (estimated hash_blocks=${TOTAL_HASH_BLOCKS})"
echo "  Total image:  ${IMAGE_MiB} MiB (2-MiB aligned)"

# ── step 4: create raw image file ─────────────────────────────────────────────
echo ""
echo "=== Step 4: Create raw image file (${IMAGE_MiB} MiB) ==="
mkdir -p "$OUTPUT_DIR"
dd if=/dev/zero of="$OUTPUT_IMAGE" bs=1M count="$IMAGE_MiB" status=progress

# ── step 5: create partition table ────────────────────────────────────────────
echo ""
echo "=== Step 5: Create partition table ==="
P1_START_MiB=$GAP_MiB
P1_END_MiB=$(( P1_START_MiB + P1_MiB ))
P2_END_MiB=$(( P1_END_MiB + P2_MiB ))

sudo parted "$OUTPUT_IMAGE" --script mklabel msdos
sudo parted "$OUTPUT_IMAGE" --script mkpart primary ext4 ${P1_START_MiB}MiB ${P1_END_MiB}MiB
sudo parted "$OUTPUT_IMAGE" --script set 1 boot on
sudo parted "$OUTPUT_IMAGE" --script mkpart primary ${P1_END_MiB}MiB ${P2_END_MiB}MiB
sudo parted "$OUTPUT_IMAGE" --script print

# ── step 6: attach loop devices ───────────────────────────────────────────────
echo ""
echo "=== Step 6: Attach loop devices ==="
KPARTX_NEW=$(sudo kpartx -av "$OUTPUT_IMAGE")
echo "$KPARTX_NEW"
LOOP_NEW=$(echo "$KPARTX_NEW" | head -1 | grep -oP 'loop\d+')
LOOP_NEW_ATTACHED=yes
DEV_P1=/dev/mapper/${LOOP_NEW}p1
DEV_P2=/dev/mapper/${LOOP_NEW}p2

KPARTX_ORIG=$(sudo kpartx -av "$ORIG_IMAGE")
echo "$KPARTX_ORIG"
LOOP_ORIG=$(echo "$KPARTX_ORIG" | head -1 | grep -oP 'loop\d+')
LOOP_ORIG_ATTACHED=yes
DEV_ORIG=/dev/mapper/${LOOP_ORIG}p1

echo "  new p1: $DEV_P1   new p2: $DEV_P2"
echo "  orig:   $DEV_ORIG"

# ── step 7: format p1 and populate rootfs ─────────────────────────────────────
echo ""
echo "=== Step 7: Format p1 and populate rootfs ==="
sudo mkfs.ext4 -L kata-rootfs "$DEV_P1"

MNT_NEW=$(mktemp -d)
MNT_ORIG=$(mktemp -d)
sudo mount -o ro "$DEV_ORIG" "$MNT_ORIG"
sudo mount "$DEV_P1" "$MNT_NEW"

echo "  Syncing original rootfs..."
sudo rsync -a "$MNT_ORIG/" "$MNT_NEW/"

echo "  Installing CDH binary..."
sudo cp "$CDH_BINARY" "$MNT_NEW/usr/local/bin/confidential-data-hub"
sudo chmod 755 "$MNT_NEW/usr/local/bin/confidential-data-hub"

echo "  Installing image cache..."
sudo mkdir -p "$MNT_NEW/opt/kata-cache"
sudo cp "$EROFS_TMP" "$MNT_NEW/opt/kata-cache/layers.erofs"
sudo cp "$WORK_DIR/meta_store.json" "$MNT_NEW/opt/kata-cache/meta_store.json"
echo "  erofs in image: $(sudo du -sh $MNT_NEW/opt/kata-cache/layers.erofs | cut -f1)"

echo "  Installing kata-image-cache systemd service..."
sudo tee "$MNT_NEW/usr/lib/systemd/system/kata-image-cache.service" > /dev/null << 'SVCEOF'
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
  cp /opt/kata-cache/meta_store.json /run/kata-containers/image/meta_store.json'

[Install]
WantedBy=kata-containers.target
SVCEOF

sudo mkdir -p "$MNT_NEW/etc/systemd/system/kata-containers.target.wants"
sudo ln -sf /usr/lib/systemd/system/kata-image-cache.service \
  "$MNT_NEW/etc/systemd/system/kata-containers.target.wants/kata-image-cache.service"

sudo mkdir -p "$MNT_NEW/etc/systemd/system/kata-agent.service.d"
sudo tee "$MNT_NEW/etc/systemd/system/kata-agent.service.d/after-image-cache.conf" > /dev/null << 'DROPEOF'
[Unit]
After=kata-image-cache.service
Wants=kata-image-cache.service
DROPEOF

echo "  Rootfs content: $(sudo du -sh $MNT_NEW | cut -f1)"

# ── step 8: unmount before veritysetup ────────────────────────────────────────
echo ""
echo "=== Step 8: Unmount partitions ==="
sudo umount "$MNT_NEW";  rmdir "$MNT_NEW";  MNT_NEW=""
sudo umount "$MNT_ORIG"; rmdir "$MNT_ORIG"; MNT_ORIG=""

# Detach the original image — no longer needed.
sudo kpartx -dv "$ORIG_IMAGE"
LOOP_ORIG_ATTACHED=""

# ── step 9: compute dm-verity hash tree ───────────────────────────────────────
echo ""
echo "=== Step 9: Compute dm-verity hash tree ==="
# veritysetup format writes the superblock + Merkle tree to DEV_P2 and prints
# the root hash, salt, and data block count to stdout.
VERITY_OUTPUT=$(sudo veritysetup format \
  --data-block-size=$BLOCK_SIZE \
  --hash-block-size=$BLOCK_SIZE \
  --hash=sha256 \
  "$DEV_P1" "$DEV_P2" 2>&1)
echo "$VERITY_OUTPUT"

ROOT_HASH=$(echo "$VERITY_OUTPUT" | grep -i "Root hash:"   | awk '{print $3}')
SALT=$(      echo "$VERITY_OUTPUT" | grep -i "Salt:"        | awk '{print $2}')
ACTUAL_DATA_BLOCKS=$(echo "$VERITY_OUTPUT" | grep -i "Data blocks:" | awk '{print $3}')

[[ -n "$ROOT_HASH" ]] || { echo "ERROR: failed to parse root hash from veritysetup output"; exit 1; }

# ── step 10: detach loop device ───────────────────────────────────────────────
echo ""
echo "=== Step 10: Detach loop device ==="
sudo kpartx -dv "$OUTPUT_IMAGE"
LOOP_NEW_ATTACHED=""

# ── step 11: write kata config drop-in ───────────────────────────────────────
echo ""
echo "=== Step 11: Write kata config drop-in ==="
sudo tee "$CONFIG_FILE" > /dev/null << EOF
[hypervisor.qemu]
image = "${OUTPUT_IMAGE}"
# dm-verity over pmem0p1 (data) and pmem0p2 (hash tree).
# Kata runtime assembles the dm-verity kernel parameters from this field.
# Hash was computed by veritysetup format after rootfs was finalised.
kernel_verity_params = "root_hash=${ROOT_HASH},salt=${SALT},data_blocks=${ACTUAL_DATA_BLOCKS},data_block_size=${BLOCK_SIZE},hash_block_size=${BLOCK_SIZE}"
# Leave kernel_params empty — kata sets root=/dev/dm-0 automatically when
# kernel_verity_params is non-empty.
kernel_params = ""
EOF

echo "  Written: $CONFIG_FILE"

# ── summary ───────────────────────────────────────────────────────────────────
IMAGE_SIZE=$(du -sh "$OUTPUT_IMAGE" | cut -f1)
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Image:        $OUTPUT_IMAGE  ($IMAGE_SIZE)"
echo "  Config:       $CONFIG_FILE"
echo ""
echo "  dm-verity params written to config:"
echo "    root_hash=${ROOT_HASH}"
echo "    salt=${SALT}"
echo "    data_blocks=${ACTUAL_DATA_BLOCKS}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Verify the config drop-in is active:"
echo "  cat $CONFIG_FILE"
echo ""
echo "NOTE: dm-verity is active. The hash was computed against the final rootfs"
echo "and will verify correctly. Boot will panic if the image is tampered with"
echo "after this point — that is the intended behaviour."
