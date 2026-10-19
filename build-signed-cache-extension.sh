#!/bin/bash
# Build a Kata composable image-cache extension carrying a SIGNED container
# image plus the local signature-verification infrastructure, so the cached
# path re-verifies the signature at runtime with zero registry contact.
#
# The extension is fully self-contained: it carries the layers, meta_store.json,
# the local sigstore (signatures), the GPG pubkey, and the image security policy
# + sigstore config whose paths point inside the extension mount point
# (/run/kata-extensions/<name>/etc/...).
#
# Runs inside a privileged Ubuntu container.
#
# Environment (mounted into the container):
#   /gc    -> guest-components source (cdh-oneshot-musl + image-rs test_data)
#   /work  -> working dir (outputs land here)
#
# Inputs (env):
#   EXTENSION_NAME   default "imgcache"
#   SIGNED_IMAGE     default quay.io/kata-containers/confidential-containers:signed
set -euo pipefail

EXTENSION_NAME="${EXTENSION_NAME:-imgcache}"
SIGNED_IMAGE="${SIGNED_IMAGE:-quay.io/kata-containers/confidential-containers:signed}"
WORK_DIR=/run/kata-containers/image
SRC=/gc/image-rs

OUTPUT_DIR="${OUTPUT_DIR:-/work}"
BUILD_VARIANT="image-cache"
IMAGE_NAME="kata-containers-${EXTENSION_NAME}.img"
ROOTFS_START_MB=1
IMAGE_SIZE_ALIGNMENT_MB=128

# Runtime paths inside the guest: the extension is mounted read-only at
# /run/kata-extensions/<name>/ and the policy/sigstore below are resolved there.
EXT_ROOT="/run/kata-extensions/${EXTENSION_NAME}"
RT_POLICY="${EXT_ROOT}/etc/image-policy.json"
RT_SIGSTORE_CFG="${EXT_ROOT}/etc/sigstore-config.yaml"
RT_SIGSTORE="${EXT_ROOT}/etc/containers/quay_verification/signatures"
RT_PUBKEY="${EXT_ROOT}/etc/containers/pubkey.asc"

info() { echo "[build-signed-cache-extension] $*"; }
die()  { echo "[build-signed-cache-extension] ERROR: $*" >&2; exit 1; }

[[ -x /gc/cdh-oneshot-musl ]] || die "cdh-oneshot-musl not found under /gc"
[[ -f "${SRC}/test_data/simple-signing-scheme/signatures.tar" ]] || die "signatures.tar not found"
[[ -f "${SRC}/test_data/offline-fs-kbc/aa-offline_fs_kbc-resources.json" ]] || die "offline-fs-kbc resources not found"

# ── Step 1: build-time signature infrastructure (for the pre-pull) ────────────
# The pre-pull runs on the build host, so the policy/sigstore use /etc/... paths
# here. The runtime copies (Step 3) use the extension mount paths instead.
BT_SIGSTORE=/etc/containers/quay_verification/signatures
BT_PUBKEY=/etc/containers/pubkey.asc
mkdir -p "${BT_SIGSTORE}"
tar -zxf "${SRC}/test_data/simple-signing-scheme/signatures.tar" -C "${BT_SIGSTORE}"
python3 - <<'PYEOF'
import base64, json
r = json.load(open('/gc/image-rs/test_data/offline-fs-kbc/aa-offline_fs_kbc-resources.json'))
open('/etc/containers/pubkey.asc', 'wb').write(base64.b64decode(r['default/gpg-public-key/test']))
print("wrote pubkey.asc")
PYEOF

# ── Step 2: pre-pull the signed image (regular path verifies the signature) ───
info "pre-pulling signed image: ${SIGNED_IMAGE}"
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
image_security_policy_uri = "file:///etc/image-policy.json"
sigstore_config_uri = "file:///etc/sigstore-config.yaml"
EOF
cat > /etc/image-policy.json <<EOF
{
    "default": [{"type": "insecureAcceptAnything"}],
    "transports": {
        "docker": {
            "quay.io/kata-containers/confidential-containers": [
                {"type": "signedBy", "keyType": "GPGKeys", "keyPath": "${BT_PUBKEY}"}
            ]
        }
    }
}
EOF
cat > /etc/sigstore-config.yaml <<EOF
docker:
    quay.io/kata-containers/confidential-containers:
        sigstore: file://${BT_SIGSTORE}
EOF

BUNDLE_DIR="$(mktemp -d /tmp/pull-bundle.XXXXXX)"
mount -t tmpfs tmpfs "${BUNDLE_DIR}"
RUST_LOG=info /gc/cdh-oneshot-musl --config /tmp/cdh-build.toml pull-image \
	--image-url "${SIGNED_IMAGE}" \
	--bundle-path "${BUNDLE_DIR}"
umount -l "${BUNDLE_DIR}/rootfs" 2>/dev/null || true
umount -l "${BUNDLE_DIR}" 2>/dev/null || true
rm -rf "${BUNDLE_DIR}"

info "reference_db keys:"
python3 -c "import json;d=json.load(open('${WORK_DIR}/meta_store.json'));print(list(d['reference_db'].keys()))"

# ── Step 3: lay out the extension payload (runtime paths) ─────────────────────
info "assembling extension rootfs"
STAGING="$(mktemp -d /tmp/imgcache-signed-rootfs.XXXXXX)"
cp -a "${WORK_DIR}/layers" "${STAGING}/layers"
cp "${WORK_DIR}/meta_store.json" "${STAGING}/meta_store.json"

# signature infrastructure, with runtime (extension) paths
mkdir -p "${STAGING}/etc/containers/quay_verification/signatures"
tar -zxf "${SRC}/test_data/simple-signing-scheme/signatures.tar" \
	-C "${STAGING}/etc/containers/quay_verification/signatures"
cp "${BT_PUBKEY}" "${STAGING}/etc/containers/pubkey.asc"
cat > "${STAGING}/etc/image-policy.json" <<EOF
{
    "default": [{"type": "insecureAcceptAnything"}],
    "transports": {
        "docker": {
            "quay.io/kata-containers/confidential-containers": [
                {"type": "signedBy", "keyType": "GPGKeys", "keyPath": "${RT_PUBKEY}"}
            ]
        }
    }
}
EOF
cat > "${STAGING}/etc/sigstore-config.yaml" <<EOF
docker:
    quay.io/kata-containers/confidential-containers:
        sigstore: file://${RT_SIGSTORE}
EOF
info "payload:"; du -sh "${STAGING}"

# ── Step 4: EROFS payload ─────────────────────────────────────────────────────
FS_IMAGE="$(mktemp /tmp/imgcache-signed-erofs.XXXXXX)"
mkfs.erofs -z lz4 -E dedupe "${FS_IMAGE}" "${STAGING}"
rm -rf "${STAGING}"
info "erofs payload: $(ls -lh "${FS_IMAGE}" | awk '{print $5}')"

# ── Step 5: two-partition verity disk ─────────────────────────────────────────
FS_SIZE_BYTES="$(stat -c '%s' "${FS_IMAGE}")"
IMAGE_SIZE_MB=$(( ((FS_SIZE_BYTES + 1048576) / 1048576) + 1 + ROOTFS_START_MB ))
IMAGE_SIZE_MB=$(( (IMAGE_SIZE_MB * 100 / 99) + 1 ))
REM=$(( IMAGE_SIZE_MB % IMAGE_SIZE_ALIGNMENT_MB ))
[[ "${REM}" == "0" ]] || IMAGE_SIZE_MB=$(( IMAGE_SIZE_MB + IMAGE_SIZE_ALIGNMENT_MB - REM ))
HASH_START_MB=$(( IMAGE_SIZE_MB * 99 / 100 ))

P1_OFFSET=$(( ROOTFS_START_MB * 1048576 ))
P1_SIZE=$(( (HASH_START_MB - ROOTFS_START_MB) * 1048576 ))
P2_OFFSET=$(( HASH_START_MB * 1048576 ))
P2_SIZE=$(( (IMAGE_SIZE_MB - HASH_START_MB) * 1048576 ))

IMAGE="${OUTPUT_DIR}/${IMAGE_NAME}"
info "creating ${IMAGE} (${IMAGE_SIZE_MB} MiB)"
rm -f "${IMAGE}"
truncate -s "${IMAGE_SIZE_MB}M" "${IMAGE}"
parted -s -a optimal "${IMAGE}" -- \
	mklabel msdos \
	mkpart primary ext4 "${ROOTFS_START_MB}MiB" "${HASH_START_MB}MiB" \
	mkpart primary ext4 "${HASH_START_MB}MiB" 100% \
	set 1 boot on

for i in 0 1 2 3 4 5 6 7; do
	[ -e "/dev/loop${i}" ] || mknod "/dev/loop${i}" b 7 "${i}" 2>/dev/null || true
done
losetup -D 2>/dev/null || true

dd if="${FS_IMAGE}" of="${IMAGE}" bs=1M seek="${ROOTFS_START_MB}" conv=notrunc,fsync status=none
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

losetup -d "${DATA_LOOP}" "${HASH_LOOP}" 2>/dev/null || true
losetup -D 2>/dev/null || true
rm -f "${FS_IMAGE}"

KVP="root_hash=${ROOT_HASH},salt=${SALT},data_blocks=${DATA_BLOCKS},data_block_size=${DATA_BLOCK_SIZE},hash_block_size=${HASH_BLOCK_SIZE}"
printf '%s\n' "${KVP}" > "${OUTPUT_DIR}/root_hash_${BUILD_VARIANT}.txt"

info "done: ${IMAGE}"
info "runtime initdata [image] section:"
cat <<EOF
enable_embedded_image_cache = true
image_security_policy_uri = "file://${RT_POLICY}"
sigstore_config_uri = "file://${RT_SIGSTORE_CFG}"
EOF
info "guest_extension_images entry:"
cat <<EOF
[[hypervisor.qemu.guest_extension_images]]
name = "${EXTENSION_NAME}"
path = "${IMAGE}"
verity_params = "${KVP}"
EOF
