#!/bin/bash
# Build a Kata composable guest extension image that carries an embedded
# container image cache (pre-pulled OCI layers + meta_store.json).
#
# The output is a two-partition disk (EROFS data + dm-verity hash) that the
# kata runtime cold-plugs as a virtio-blk device and the guest mounts at
# /run/kata-extensions/<name>/. The base image's kata-image-cache-setup@.service
# then bind-mounts these layers into CDH's image work directory.
#
# Runs inside a privileged Ubuntu container.
#
# Environment (mounted into the container):
#   /gc    -> guest-components source (contains cdh-oneshot-musl)
#   /work  -> working dir (outputs land here)
#
# Inputs (env):
#   EXTENSION_NAME   extension name used in guest_extension_images.name
#                    (must be <= 10 ASCII chars for CLH/Dragonball serials;
#                    default "imgcache")
#   IMAGE_REFS       space-separated list of OCI image refs to pre-pull
#                    (default docker.io/library/busybox:latest)
set -euo pipefail

EXTENSION_NAME="${EXTENSION_NAME:-imgcache}"
IMAGE_REFS="${IMAGE_REFS:-docker.io/library/busybox:latest}"
WORK_DIR=/run/kata-containers/image

OUTPUT_DIR="${OUTPUT_DIR:-/work}"
BUILD_VARIANT="image-cache"
IMAGE_NAME="kata-containers-${EXTENSION_NAME}.img"
ROOTFS_START_MB=1
IMAGE_SIZE_ALIGNMENT_MB=128

info() { echo "[build-image-cache-extension] $*"; }
die()  { echo "[build-image-cache-extension] ERROR: $*" >&2; exit 1; }

[[ -x /gc/cdh-oneshot-musl ]] || die "cdh-oneshot-musl not found under /gc"

# ── Step 1: pre-pull all images into a single work_dir ─────────────────────────
# Pull into /run/kata-containers/image so the layer store paths recorded in
# meta_store.json are the same absolute paths CDH uses at runtime in the guest.
# Sharing one work_dir lets image-rs dedupe layers shared across images.
info "pre-pulling images: ${IMAGE_REFS}"
mkdir -p /run/kata-containers
mount -t tmpfs tmpfs /run/kata-containers
mkdir -p "${WORK_DIR}"

cat > /tmp/cdh-build.toml <<EOF
[kbc]
name = "offline_fs_kbc"
url = ""

[image]
work_dir = "${WORK_DIR}"
enable_embedded_image_cache = true
max_concurrent_layer_downloads_per_image = 8
EOF

for img in ${IMAGE_REFS}; do
	info "pulling ${img}"
	BUNDLE_DIR="$(mktemp -d /tmp/pull-bundle.XXXXXX)"
	mount -t tmpfs tmpfs "${BUNDLE_DIR}"
	RUST_LOG=info /gc/cdh-oneshot-musl --config /tmp/cdh-build.toml pull-image \
		--image-url "${img}" \
		--bundle-path "${BUNDLE_DIR}"
	umount -l "${BUNDLE_DIR}/rootfs" 2>/dev/null || true
	umount -l "${BUNDLE_DIR}" 2>/dev/null || true
	rm -rf "${BUNDLE_DIR}"
done

info "meta_store.json reference_db keys:"
python3 -c "import json;d=json.load(open('${WORK_DIR}/meta_store.json'));print(list(d['reference_db'].keys()))" 2>/dev/null \
	|| cat "${WORK_DIR}/meta_store.json"

# ── Step 2: lay out the extension payload ──────────────────────────────────────
# The extension root carries the layers/ tree and meta_store.json. Its presence
# of meta_store.json is what kata-image-cache-setup.sh uses to recognise the
# extension as an embedded image cache.
STAGING="$(mktemp -d /tmp/imgcache-rootfs.XXXXXX)"
cp -a "${WORK_DIR}/layers" "${STAGING}/layers"
cp "${WORK_DIR}/meta_store.json" "${STAGING}/meta_store.json"
info "payload:"; du -sh "${STAGING}"

# ── Step 3: EROFS payload ──────────────────────────────────────────────────────
# lz4 is the only EROFS compression the kata kernel enables; dedupe collapses
# blocks shared across images.
FS_IMAGE="$(mktemp /tmp/imgcache-erofs.XXXXXX)"
mkfs.erofs -z lz4 -E dedupe "${FS_IMAGE}" "${STAGING}"
rm -rf "${STAGING}"
info "erofs payload: $(ls -lh "${FS_IMAGE}" | awk '{print $5}')"

# ── Step 4: two-partition verity disk ──────────────────────────────────────────
# p1 = EROFS data, p2 = dm-verity hash. Layout mirrors kata's coco-extension
# image so kata-extension-mount.sh (data=dev p1, hash=dev p2) works unchanged.
FS_SIZE_BYTES="$(stat -c '%s' "${FS_IMAGE}")"
IMAGE_SIZE_MB=$(( ((FS_SIZE_BYTES + 1048576) / 1048576) + 1 + ROOTFS_START_MB ))
IMAGE_SIZE_MB=$(( (IMAGE_SIZE_MB * 100 / 99) + 1 ))
REM=$(( IMAGE_SIZE_MB % IMAGE_SIZE_ALIGNMENT_MB ))
[[ "${REM}" == "0" ]] || IMAGE_SIZE_MB=$(( IMAGE_SIZE_MB + IMAGE_SIZE_ALIGNMENT_MB - REM ))

HASH_START_MB=$(( IMAGE_SIZE_MB * 99 / 100 ))
[[ "${HASH_START_MB}" -gt "${ROOTFS_START_MB}" ]] || die "image too small"

IMAGE="${OUTPUT_DIR}/${IMAGE_NAME}"
info "creating ${IMAGE} (${IMAGE_SIZE_MB} MiB)"
rm -f "${IMAGE}"
truncate -s "${IMAGE_SIZE_MB}M" "${IMAGE}"
parted -s -a optimal "${IMAGE}" -- \
	mklabel msdos \
	mkpart primary ext4 "${ROOTFS_START_MB}MiB" "${HASH_START_MB}MiB" \
	mkpart primary ext4 "${HASH_START_MB}MiB" 100% \
	set 1 boot on

# Byte offsets/sizes derived from the partition table above. We address p1/p2
# by offset with dedicated loop devices rather than partition device nodes,
# which need udev that a container does not run.
P1_OFFSET=$(( ROOTFS_START_MB * 1048576 ))
P1_SIZE=$(( (HASH_START_MB - ROOTFS_START_MB) * 1048576 ))
P2_OFFSET=$(( HASH_START_MB * 1048576 ))
P2_SIZE=$(( (IMAGE_SIZE_MB - HASH_START_MB) * 1048576 ))

for i in 0 1 2 3 4 5 6 7; do
	[ -e "/dev/loop${i}" ] || mknod "/dev/loop${i}" b 7 "${i}" 2>/dev/null || true
done
losetup -D 2>/dev/null || true

info "writing EROFS payload to p1 (offset ${P1_OFFSET})"
dd if="${FS_IMAGE}" of="${IMAGE}" bs=1M seek="${ROOTFS_START_MB}" conv=notrunc,fsync status=none

info "formatting dm-verity hash device"
DATA_LOOP="$(losetup -f --show --offset ${P1_OFFSET} --sizelimit ${P1_SIZE} "${IMAGE}")"
HASH_LOOP="$(losetup -f --show --offset ${P2_OFFSET} --sizelimit ${P2_SIZE} "${IMAGE}")"
VERITY_OUTPUT="$(veritysetup format --no-superblock "${DATA_LOOP}" "${HASH_LOOP}" 2>&1)"
read_verity_field() {
	local label="$1"; local value
	value="$(printf '%s\n' "${VERITY_OUTPUT}" | sed -n "s/^${label}:[[:space:]]*//p")"
	value="${value// \[*/}"
	[[ -n "${value}" ]] || die "missing '${label}' in veritysetup output"
	echo "${value}"
}
ROOT_HASH="$(read_verity_field "Root hash")"
SALT="$(read_verity_field "Salt")"
DATA_BLOCKS="$(read_verity_field "Data blocks")"
DATA_BLOCK_SIZE="$(read_verity_field "Data block size")"
HASH_BLOCK_SIZE="$(read_verity_field "Hash block size")"

KVP="root_hash=${ROOT_HASH},salt=${SALT},data_blocks=${DATA_BLOCKS},data_block_size=${DATA_BLOCK_SIZE},hash_block_size=${HASH_BLOCK_SIZE}"
printf '%s\n' "${KVP}" > "${OUTPUT_DIR}/root_hash_${BUILD_VARIANT}.txt"

losetup -d "${DATA_LOOP}" "${HASH_LOOP}" 2>/dev/null || true
losetup -D 2>/dev/null || true
rm -f "${FS_IMAGE}"

info "done: ${IMAGE}"
info "guest_extension_images entry:"
cat <<EOF
[[hypervisor.qemu.guest_extension_images]]
name = "${EXTENSION_NAME}"
path = "${IMAGE}"
verity_params = "${KVP}"
EOF
