#!/bin/bash
# Rebuild the kata coco guest extension image with a patched CDH binary.
#
# The composable runtime launches confidential-data-hub from the coco extension
# (usr/local/bin/confidential-data-hub). To enable the embedded image cache we
# swap in a CDH built from the image-rs embedded-cache branch (which adds
# reference_db + the enable_embedded_image_cache option) and repack the EROFS +
# dm-verity image.
#
# Runs inside a privileged Ubuntu container.
#
# Environment (mounted into the container):
#   /work/coco/kata-containers-coco-extension.img -> pristine coco extension
#   /gc/cdh-daemon-musl                           -> patched CDH daemon
#   /work/coco                                    -> outputs land here
set -euo pipefail

INPUT=/work/coco/kata-containers-coco-extension.img
OUTPUT=/work/coco/kata-containers-coco-extension-cache.img
CDH=/gc/cdh-daemon-musl

# Partition layout of the coco extension (from fdisk):
#   p1: start 2048 sectors (1 MiB), EROFS data
#   p2: start 145408 sectors, dm-verity hash
P1_OFFSET=$((2048 * 512))

BUILD_VARIANT="coco-extension"
ROOTFS_START_MB=1
IMAGE_SIZE_ALIGNMENT_MB=128

info() { echo "[rebuild-coco-extension-cdh] $*"; }
die()  { echo "[rebuild-coco-extension-cdh] ERROR: $*" >&2; exit 1; }

[[ -f "${INPUT}" ]] || die "coco extension not found at ${INPUT}"
[[ -x "${CDH}" ]] || die "patched CDH not found at ${CDH}"

for i in 0 1 2 3 4 5 6 7; do
	[ -e "/dev/loop${i}" ] || mknod "/dev/loop${i}" b 7 "${i}" 2>/dev/null || true
done
losetup -D 2>/dev/null || true

# ── Step 1: mount the existing EROFS and copy its contents ─────────────────────
info "mounting pristine coco extension EROFS"
mkdir -p /mnt/coco
mount -t erofs -o ro,loop,offset=${P1_OFFSET} "${INPUT}" /mnt/coco

STAGING="$(mktemp -d /tmp/coco-rootfs.XXXXXX)"
cp -a /mnt/coco/. "${STAGING}/"
umount /mnt/coco

# ── Step 2: swap the CDH binary ────────────────────────────────────────────────
info "replacing confidential-data-hub with patched CDH"
ls -l "${STAGING}/usr/local/bin/confidential-data-hub"
install -D -m 755 "${CDH}" "${STAGING}/usr/local/bin/confidential-data-hub"
ls -l "${STAGING}/usr/local/bin/confidential-data-hub"

# ── Step 3: EROFS payload ──────────────────────────────────────────────────────
FS_IMAGE="$(mktemp /tmp/coco-erofs.XXXXXX)"
mkfs.erofs -z lz4 -E dedupe "${FS_IMAGE}" "${STAGING}"
rm -rf "${STAGING}"
info "erofs payload: $(ls -lh "${FS_IMAGE}" | awk '{print $5}')"

# ── Step 4: two-partition verity disk ──────────────────────────────────────────
FS_SIZE_BYTES="$(stat -c '%s' "${FS_IMAGE}")"
IMAGE_SIZE_MB=$(( ((FS_SIZE_BYTES + 1048576) / 1048576) + 1 + ROOTFS_START_MB ))
IMAGE_SIZE_MB=$(( (IMAGE_SIZE_MB * 100 / 99) + 1 ))
REM=$(( IMAGE_SIZE_MB % IMAGE_SIZE_ALIGNMENT_MB ))
[[ "${REM}" == "0" ]] || IMAGE_SIZE_MB=$(( IMAGE_SIZE_MB + IMAGE_SIZE_ALIGNMENT_MB - REM ))
HASH_START_MB=$(( IMAGE_SIZE_MB * 99 / 100 ))

info "creating ${OUTPUT} (${IMAGE_SIZE_MB} MiB)"
rm -f "${OUTPUT}"
truncate -s "${IMAGE_SIZE_MB}M" "${OUTPUT}"
parted -s -a optimal "${OUTPUT}" -- \
	mklabel msdos \
	mkpart primary ext4 "${ROOTFS_START_MB}MiB" "${HASH_START_MB}MiB" \
	mkpart primary ext4 "${HASH_START_MB}MiB" 100% \
	set 1 boot on

# Byte offsets/sizes derived from the partition table above. Address p1/p2 by
# offset with dedicated loop devices (partition device nodes need udev, which a
# container does not run).
P1_OFFSET=$(( ROOTFS_START_MB * 1048576 ))
P1_SIZE=$(( (HASH_START_MB - ROOTFS_START_MB) * 1048576 ))
P2_OFFSET=$(( HASH_START_MB * 1048576 ))
P2_SIZE=$(( (IMAGE_SIZE_MB - HASH_START_MB) * 1048576 ))

info "writing EROFS payload to p1 (offset ${P1_OFFSET})"
dd if="${FS_IMAGE}" of="${OUTPUT}" bs=1M seek="${ROOTFS_START_MB}" conv=notrunc,fsync status=none

info "formatting dm-verity hash device"
DATA_LOOP="$(losetup -f --show --offset ${P1_OFFSET} --sizelimit ${P1_SIZE} "${OUTPUT}")"
HASH_LOOP="$(losetup -f --show --offset ${P2_OFFSET} --sizelimit ${P2_SIZE} "${OUTPUT}")"
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

losetup -d "${DATA_LOOP}" "${HASH_LOOP}" 2>/dev/null || true
losetup -D 2>/dev/null || true
rm -f "${FS_IMAGE}"

KVP="root_hash=${ROOT_HASH},salt=${SALT},data_blocks=${DATA_BLOCKS},data_block_size=${DATA_BLOCK_SIZE},hash_block_size=${HASH_BLOCK_SIZE}"
printf '%s\n' "${KVP}" > /work/coco/root_hash_coco_cache.txt

info "done: ${OUTPUT}"
info "coco extension verity_params:"
cat /work/coco/root_hash_coco_cache.txt
