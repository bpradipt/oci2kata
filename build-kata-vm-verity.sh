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
# Pinned versions (edit here to bump):
#   KATA_VERSION    = 3.31.0
#   GC_BRANCH       = image-cache-0.20.0  (guest-components / CDH + cdh-oneshot)
#
# The script builds CDH and cdh-oneshot from source if the binaries are not
# already present at the expected paths. Set BUILD_BINARIES=always to force
# a rebuild, or BUILD_BINARIES=never to require pre-built binaries.
#
# Requirements (host tools):
#   git, cargo (rustup), musl-tools, curl, mkfs.erofs, parted, kpartx, rsync, veritysetup
#
# dm-verity note:
#   The resulting image has a proper two-partition layout (p1=rootfs, p2=hash
#   tree). veritysetup format computes a fresh hash after the rootfs is fully
#   populated, so kernel_verity_params in the drop-in is always consistent with
#   the actual data. The kernel verifies the hash at boot.

set -euo pipefail

# ── pinned versions ────────────────────────────────────────────────────────────
# Bump these two lines to target a different release combination.
KATA_VERSION=3.31.0
GC_BRANCH=image-cache-0.20.0

# SHA256 of the unmodified kata-ubuntu-noble-confidential.image for the pinned
# kata version. Used to verify the base rootfs before copying it into the new
# image, ensuring the build is bit-for-bit reproducible regardless of which
# kata version happens to be installed on the host.
KATA_IMAGE_SHA256=bec9581734b976ad23a1d9f900f60c91132f7140eb418640cb4e886e4c926fae

# ── configuration ──────────────────────────────────────────────────────────────
IMAGE_REF="${1:-quay.io/bpradipt/kata-vm-image:7may}"
OUTPUT_DIR="${2:-/home/ubuntu/kata-vm-images}"

# guest-components source — CDH and cdh-oneshot are built from here
GC_REPO=https://github.com/bpradipt/guest-components.git
GC_DIR=/opt/guest-components          # clone target

# Where the built binaries land (standard cargo output paths)
GC_RELEASE=${GC_DIR}/target/x86_64-unknown-linux-musl/release
CDH_BINARY=${GC_RELEASE}/confidential-data-hub
CDH_ONESHOT=${GC_RELEASE}/cdh-oneshot

# auto = build if binaries are missing; always = always rebuild; never = fail if missing
BUILD_BINARIES=${BUILD_BINARIES:-auto}

# Versioned cache for the base kata rootfs image — avoids re-downloading on
# repeated runs and insulates the build from whatever kata is currently installed.
KATA_IMAGE_CACHE=/opt/kata-images-cache/${KATA_VERSION}
ORIG_IMAGE=""    # set by ensure_kata_base_image()

WORK_DIR=/run/kata-containers/image
BLOCK_SIZE=4096   # dm-verity data and hash block size
GAP_MiB=3         # MBR + alignment gap before first partition

# ── derive filenames ───────────────────────────────────────────────────────────
# e.g. "quay.io/bpradipt/kata-vm-image:7may" → "kata-vm-image_7may"
IMAGE_SLUG=$(echo "$IMAGE_REF" | sed 's|.*/||; s|:|_|')
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
  [[ -n "${ORIG_IMAGE:-}"     ]] && [[ -n "$LOOP_ORIG_ATTACHED" ]] && sudo kpartx -dv "$ORIG_IMAGE" 2>/dev/null
}
trap cleanup EXIT

# ── ensure kata base image (pinned to KATA_VERSION) ───────────────────────────
ensure_kata_base_image() {
  local cache_file="${KATA_IMAGE_CACHE}/kata-ubuntu-noble-confidential.image"
  local installed=/opt/kata/share/kata-containers/kata-ubuntu-noble-confidential.image

  _verify_hash() {
    local file=$1
    local actual
    actual=$(sha256sum "$file" | awk '{print $1}')
    [[ "$actual" == "$KATA_IMAGE_SHA256" ]]
  }

  # 1. Cached copy already verified?
  if [[ -f "$cache_file" ]]; then
    if _verify_hash "$cache_file"; then
      echo "  Base image: using cached copy ($cache_file)"
      ORIG_IMAGE="$cache_file"
      return
    fi
    echo "  Cached base image hash mismatch — re-fetching"
    rm -f "$cache_file"
  fi

  # 2. Installed kata image matches pinned version?
  if [[ -f "$installed" ]]; then
    if _verify_hash "$installed"; then
      echo "  Installed kata image matches version $KATA_VERSION — caching"
      mkdir -p "$KATA_IMAGE_CACHE"
      cp "$installed" "$cache_file"
      ORIG_IMAGE="$cache_file"
      return
    fi
    local actual_hash
    actual_hash=$(sha256sum "$installed" | awk '{print $1}')
    echo "  WARNING: installed kata image does not match $KATA_VERSION"
    echo "    Expected: $KATA_IMAGE_SHA256"
    echo "    Got:      $actual_hash"
    echo "  Downloading correct version from GitHub releases..."
  else
    echo "  kata base image not found at $installed — downloading from GitHub..."
  fi

  # 3. Download from GitHub releases and extract just the base image.
  local tarball="/tmp/kata-static-${KATA_VERSION}-amd64.tar.zst"
  local url="https://github.com/kata-containers/kata-containers/releases/download/${KATA_VERSION}/kata-static-${KATA_VERSION}-amd64.tar.zst"

  if [[ ! -f "$tarball" ]]; then
    echo "  Downloading $url ..."
    curl -fL --progress-bar -o "$tarball" "$url"
  else
    echo "  Using cached tarball: $tarball"
  fi

  echo "  Extracting base image from tarball..."
  local tmp
  tmp=$(mktemp -d)
  tar --zstd -xf "$tarball" \
    -C "$tmp" \
    ./opt/kata/share/kata-containers/kata-ubuntu-noble-confidential.image

  mkdir -p "$KATA_IMAGE_CACHE"
  mv "$tmp/opt/kata/share/kata-containers/kata-ubuntu-noble-confidential.image" "$cache_file"
  rm -rf "$tmp"

  if ! _verify_hash "$cache_file"; then
    local actual_hash
    actual_hash=$(sha256sum "$cache_file" | awk '{print $1}')
    echo "ERROR: downloaded base image SHA256 mismatch"
    echo "  Expected: $KATA_IMAGE_SHA256"
    echo "  Got:      $actual_hash"
    rm -f "$cache_file"
    exit 1
  fi

  echo "  Base image verified: $cache_file"
  ORIG_IMAGE="$cache_file"
}

# ── build CDH and cdh-oneshot from source ─────────────────────────────────────
build_binaries() {
  echo "=== Building CDH and cdh-oneshot from source ==="
  echo "  Repo:   $GC_REPO"
  echo "  Branch: $GC_BRANCH"
  echo "  Dir:    $GC_DIR"

  command -v cargo > /dev/null || { echo "ERROR: cargo not found — install Rust (https://rustup.rs)"; exit 1; }
  command -v git   > /dev/null || { echo "ERROR: git not found"; exit 1; }

  # Ensure the musl target is installed
  rustup target add x86_64-unknown-linux-musl

  # Clone or update
  if [[ -d "$GC_DIR/.git" ]]; then
    echo "  Updating existing clone at $GC_DIR ..."
    git -C "$GC_DIR" fetch origin
    git -C "$GC_DIR" checkout "$GC_BRANCH"
    git -C "$GC_DIR" pull origin "$GC_BRANCH"
  else
    echo "  Cloning $GC_REPO ($GC_BRANCH) ..."
    git clone --branch "$GC_BRANCH" --depth 1 "$GC_REPO" "$GC_DIR"
  fi

  # Build confidential-data-hub
  # The Makefile builds --bin ttrpc-cdh with musl, then renames it to
  # confidential-data-hub under target/x86_64-unknown-linux-musl/release/.
  echo ""
  echo "  Building confidential-data-hub (musl static) ..."
  make -C "$GC_DIR/confidential-data-hub" \
    LIBC=musl \
    RESOURCE_PROVIDER=kbs,sev \
    KMS_PROVIDER=aliyun \
    RPC=ttrpc

  # Build cdh-oneshot — CDH's one-shot CLI used for build-time pre-pull.
  # ONE_SHOT=true selects --bin cdh-oneshot with only the "bin" feature
  # (no ttrpc/grpc), so no AA socket is required when running on the host.
  echo ""
  echo "  Building cdh-oneshot (musl static) ..."
  make -C "$GC_DIR/confidential-data-hub" \
    LIBC=musl \
    RESOURCE_PROVIDER=kbs,sev \
    KMS_PROVIDER=aliyun \
    ONE_SHOT=true

  echo ""
  echo "  Built:"
  ls -lh "$CDH_BINARY" "$CDH_ONESHOT"
}

# ── decide whether to build ────────────────────────────────────────────────────
case "$BUILD_BINARIES" in
  always)
    build_binaries
    ;;
  never)
    [[ -f "$CDH_BINARY"   ]] || { echo "ERROR: CDH binary not found at $CDH_BINARY (BUILD_BINARIES=never)"; exit 1; }
    [[ -f "$CDH_ONESHOT"  ]] || { echo "ERROR: cdh-oneshot not found at $CDH_ONESHOT (BUILD_BINARIES=never)"; exit 1; }
    ;;
  auto|*)
    if [[ ! -f "$CDH_BINARY" || ! -f "$CDH_ONESHOT" ]]; then
      echo "  Binaries not found — building from source (set BUILD_BINARIES=never to skip)."
      build_binaries
    else
      echo "  Using existing binaries (set BUILD_BINARIES=always to force rebuild):"
      ls -lh "$CDH_BINARY" "$CDH_ONESHOT"
    fi
    ;;
esac

# ── preflight checks (host tools) ─────────────────────────────────────────────
for bin in mkfs.erofs parted kpartx rsync veritysetup curl; do
  command -v $bin > /dev/null || { echo "ERROR: $bin not found"; exit 1; }
done

echo "=== Ensuring kata $KATA_VERSION base image ==="
ensure_kata_base_image

echo ""
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
  # Unmount any stale overlay/bind mounts left under WORK_DIR before wiping,
  # so the directory is fully clean and layer indices start at 0.
  sudo findmnt --raw --noheadings -o TARGET | grep "^${WORK_DIR}" | sort -r | \
    xargs -r -I{} sudo umount {} 2>/dev/null || true
  sudo rm -rf "$WORK_DIR"
  sudo mkdir -p "$WORK_DIR"
  # Write a minimal CDH config: offline_fs_kbc avoids any network KBS call,
  # and work_dir must match WORK_DIR so layers and meta_store.json land where
  # the erofs packaging step expects them.
  CDH_BUILD_CONFIG=$(mktemp /tmp/cdh-build-XXXXXX.toml)
  cat > "$CDH_BUILD_CONFIG" << CDHEOF
[kbc]
name = "offline_fs_kbc"
url = ""

[image]
work_dir = "${WORK_DIR}"
CDHEOF
  BUNDLE_DIR=/tmp/pull-bundle-${IMAGE_SLUG}
  sudo rm -rf "$BUNDLE_DIR" && sudo mkdir -p "$BUNDLE_DIR"
  sudo env RUST_LOG=info "$CDH_ONESHOT" --config "$CDH_BUILD_CONFIG" pull-image \
    --image-url "$IMAGE_REF" \
    --bundle-path "$BUNDLE_DIR"
  rm -f "$CDH_BUILD_CONFIG"
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
  mkdir -p /run/kata-layers-erofs && \
  mount -t erofs -o loop /opt/kata-cache/layers.erofs /run/kata-layers-erofs && \
  mkdir -p /run/kata-containers/image/layers /run/kata-containers/image/overlay && \
  tar -c -C /run/kata-layers-erofs . | tar -x -C /run/kata-containers/image/layers && \
  umount /run/kata-layers-erofs && \
  cp /opt/kata-cache/meta_store.json /run/kata-containers/image/meta_store.json && \
  mount --bind /run/kata-containers/image/meta_store.json \
               /run/kata-containers/image/meta_store.json'

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
echo "NOTE: dm-verity is active. The hash was computed against the final rootfs"
echo "and will verify correctly. Boot will panic if the image is tampered with"
echo "after this point — that is the intended behaviour."
