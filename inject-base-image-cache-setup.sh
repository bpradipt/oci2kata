#!/bin/bash
# Inject the embedded image cache setup unit into a copy of the kata base
# image (kata-ubuntu-noble.image) and recompute dm-verity.
#
# The base image is a two-partition ext4 disk (p1 = rootfs, p2 = dm-verity
# hash). We install the kata-image-cache-setup unit + script and the updated
# extension generator into p1, then recompute the root hash so the runtime's
# kernel_verity_params stay consistent.
#
# Runs inside a privileged Ubuntu container.
#
# Environment (mounted into the container):
#   /work/base/kata-ubuntu-noble.image   -> pristine base image (input)
#   /agent                                -> kata-containers src/agent (units)
#   /work/base                            -> outputs land here
set -euo pipefail

INPUT=/work/base/kata-ubuntu-noble.image
OUTPUT=/work/base/kata-ubuntu-noble-cache.image

# Partition layout of the base image (from fdisk):
#   p1: start 6144 sectors (3 MiB), 512000 sectors (250 MiB)
#   p2: start 518144 sectors, 6144 sectors (3 MiB)
P1_OFFSET=$((6144 * 512))
P1_SIZE=$((512000 * 512))
P2_OFFSET=$((518144 * 512))
P2_SIZE=$((6144 * 512))

info() { echo "[inject-base-image-cache-setup] $*"; }
die()  { echo "[inject-base-image-cache-setup] ERROR: $*" >&2; exit 1; }

[[ -f "${INPUT}" ]] || die "base image not found at ${INPUT}"

for i in 0 1 2 3 4 5 6 7; do
	[ -e "/dev/loop${i}" ] || mknod "/dev/loop${i}" b 7 "${i}" 2>/dev/null || true
done
losetup -D 2>/dev/null || true

info "copying base image"
cp "${INPUT}" "${OUTPUT}"

info "mounting p1 (ext4)"
mkdir -p /mnt/base
mount -o loop,offset=${P1_OFFSET},sizelimit=${P1_SIZE} "${OUTPUT}" /mnt/base

info "installing kata-image-cache-setup unit + script"
install -D -m 644 /agent/kata-image-cache-setup@.service \
	/mnt/base/usr/lib/systemd/system/kata-image-cache-setup@.service
install -D -m 755 /agent/kata-image-cache-setup.sh \
	/mnt/base/usr/libexec/kata-image-cache-setup.sh

info "updating the extension mount generator (to also enable cache setup)"
install -D -m 755 /agent/kata-extension-mount-generator.sh \
	/mnt/base/usr/lib/systemd/system-generators/kata-extension-mount-generator

info "installed:"; ls -l \
	/mnt/base/usr/lib/systemd/system/kata-image-cache-setup@.service \
	/mnt/base/usr/libexec/kata-image-cache-setup.sh \
	/mnt/base/usr/lib/systemd/system-generators/kata-extension-mount-generator

sync
umount /mnt/base

info "recomputing dm-verity"
DATA_LOOP="$(losetup -f --show --offset ${P1_OFFSET} --sizelimit ${P1_SIZE} "${OUTPUT}")"
HASH_LOOP="$(losetup -f --show --offset ${P2_OFFSET} --sizelimit ${P2_SIZE} "${OUTPUT}")"
VERITY_OUTPUT="$(veritysetup format --no-superblock \
	--data-block-size=4096 --hash-block-size=4096 --hash=sha256 \
	"${DATA_LOOP}" "${HASH_LOOP}" 2>&1)"

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

KVP="root_hash=${ROOT_HASH},salt=${SALT},data_blocks=${DATA_BLOCKS},data_block_size=${DATA_BLOCK_SIZE},hash_block_size=${HASH_BLOCK_SIZE}"
printf '%s\n' "${KVP}" > /work/base/root_hash_base_cache.txt

info "done: ${OUTPUT}"
info "base image kernel_verity_params:"
cat /work/base/root_hash_base_cache.txt
