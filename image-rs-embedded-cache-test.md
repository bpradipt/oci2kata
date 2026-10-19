# Testing the image-rs Embedded Image Cache (opt-in) with Kata/QEMU

This document records the validation of the `guest-components` image-rs changes
that add an **opt-in embedded image cache** plus **signature verification on the
cached path**. It is preparation for a PR against
`confidential-containers/guest-components`.

---

## Summary

| Area | Status |
|------|--------|
| Code change: `reference_db` fast path + opt-in config + signature verify | ✅ verified |
| `cdh-oneshot` fast-path proof (registry blocked, served from cache) | ✅ verified |
| `cdh-oneshot` signature-verification proof (signed accepted, wrong-key rejected) | ✅ verified |
| Kata/QEMU (v4.0.0) embedded-image end-to-end | ✅ verified (after bind-mount fix) |

The image-rs change is **proven correct end-to-end**. The one Kata-specific
integration gotcha (the embedded `meta_store.json` is deleted by the kata-agent
during guest setup) is solved by bind-mounting it to itself — a learning carried
over from the earlier 3.31.0 work.

---

## 1. The code change

Branch `image-rs-embedded-cache-main`, commit `31732111`
`feat(image-rs): add opt-in embedded image cache with signature verification`.

Files changed (relative to `confidential-containers/guest-components` `main`):

- `image-rs/src/meta_store.rs` — adds `reference_db: HashMap<String,String>`
  (maps image reference → config digest), `#[serde(default)]`.
- `image-rs/src/image.rs`:
  - `ImageMeta.manifest_list_digest: Option<String>` (serde default) so the
    cached path can pass the manifest-list digest to cosign verification.
  - `pull_from_local_cache()` — when `enable_embedded_image_cache` is on, looks
    up the reference in `reference_db`, verifies the signature (if a policy is
    configured) and creates the bundle with **no registry contact**.
  - `resolve_auth()` helper (extracted from `pull_task`).
  - `backfill_reference_db()` + post-pull backfill — records both the tag form
    and the `registry/repo@sha256:…` digest form so containerd-resolved digests
    hit the fast path.
- `image-rs/src/config.rs` — `enable_embedded_image_cache: bool` (default
  `false`), wired through `Default`/`from_kernel_cmdline`.
- `image-rs/src/builder.rs` — `ClientBuilder::enable_embedded_image_cache`.
- `confidential-data-hub/hub/src/config/mod.rs` — test coverage.

Signature behaviour: the cached path reuses the existing
`SignatureValidator::check_image_signature` (same policy/schemes as the normal
pull path), resolving auth the same way. When no image security policy is
configured, no signature check runs (unchanged behaviour).

---

## 2. Definitive verification — `cdh-oneshot` fast path

Built `cdh-oneshot` and the CDH daemon as static musl binaries (see
[Build](#build-the-guest-components-binaries)) and proved the fast path directly:

**Pull 1 (registry reachable):** populates `reference_db` with both forms:

```
$ python3 -c "import json;d=json.load(open('meta_store.json'));print(list(d['reference_db'].keys()))"
['docker.io/library/busybox:latest',
 'docker.io/library/busybox@sha256:f97baa533a26513c453a362be331a43eb60214302f449c16571b23cea141dce4']
```

**Pull 2 (registry BLOCKED via iptables `-I OUTPUT -p tcp --dport 443 -j REJECT`):**

```
image_rs::builder: Existing metadata found. Using previous ones.
image_rs::image: Image docker.io/library/busybox:latest found in local cache, creating bundle
image digest: sha256:f97baa533a26513c453a362be331a43eb60214302f449c16571b23cea141dce4
```

Exit code 0, bundle created, **with the registry unreachable**. This proves:

1. `enable_embedded_image_cache = true` gates the fast path (off → no lookup).
2. `reference_db` is populated (tag + digest forms).
3. `pull_from_local_cache` serves the image with **zero registry contact**.
4. `manifest_list_digest` round-trips through `meta_store.json`.

Repro script: `verify-fastpath.sh` (see appendix).

---

## 2b. Signature verification on the cached path

Proved that the cached path **runs** signature verification (the key thing my
change adds — the old code served cached images without any check). Uses the
image-rs test data: pre-signed public images
`quay.io/kata-containers/confidential-containers:{signed,other_signed}`, a local
`file://` sigstore, and a `signedBy` (simple-signing) policy with the test GPG
key. Inline `image_security_policy` + `sigstore_config` (no KBS/AA needed).

**Positive — signed image served from cache:**

```
$ # pull 1: pre-pull, regular path verifies signature
image digest: sha256:febcf61cd6e1ac9628f6ac14fa40836d16f3c6ddef3b303ff0321606e55ddd0b

$ # pull 2: cached path re-verifies signature and serves the image
image_rs::builder: Existing metadata found. Using previous ones.
image_rs::image: Image quay.io/kata-containers/confidential-containers:signed found in local cache, creating bundle
image_rs::image: Use Anonymous image registry auth   # resolve_auth() -> signature path taken
image digest: sha256:febcf61cd6e1ac9628f6ac14fa40836d16f3c6ddef3b303ff0321606e55ddd0b
```

The `Use Anonymous image registry auth` line on the cached path is emitted only
because a policy is configured (`signature_validator` is `Some`), proving the
cached path resolves auth and invokes `check_image_signature` before creating
the bundle.

**Negative — wrong-key image rejected from cache:**

```
$ # pull 1: pre-pull WITHOUT policy -> cached, no verification
image digest: sha256:7250923ba3543110040462388756ef099331822c6172a050b12c7a38361ea46f

$ # pull 2: cached path WITH policy -> signature check rejects
image_rs::builder: Existing metadata found. Using previous ones.
image_rs::image: Image quay.io/kata-containers/confidential-containers:other_signed found in local cache, creating bundle
image_rs::image: Use Anonymous image registry auth
failed to pull image: ImagePull(SignatureValidationFailed(DeniedByPolicy { source: rejected by `signedBy` rule
    The signatures do not satisfied! Reject reason: [signature verify failed! There is no pubkey can verify the signature!] }))
```

The cached path found the image, ran signature verification, and **rejected** the
image whose signature does not match the trusted key. (Before this change, the
cached path would have served it without checking.)

Note: for simple-signing this uses a **local** `file://` sigstore, so the
signature itself is fetched locally, not from the registry. With cosign, or with
the `signature-simple-xrss` registry extension, the signature is fetched over
the network — the layers still come from the embedded cache.

Repro script: `verify-signature-cache.sh` (see appendix); full log
`signature-test-output.log`.

---

## 3. Kata/QEMU test setup (v4.0.0)

Environment: kind cluster `test` (control-plane + worker), kata installed inside
the kind node via the `confidential-containers` (CoCo) helm chart
`kata-as-coco-runtime` DaemonSet. Kata **4.0.0**, kernel 6.18.35, runtime class
`kata-qemu-coco-dev` (guest-pull), guest image
`kata-ubuntu-noble-confidential.image` (384 MB, two-partition dm-verity).

### Build the guest-components binaries

No rustup/musl on the host, so the build ran in a Debian-based rust container
(host `~/.cargo/registry` reused):

```bash
docker run --rm -v /home/pkb/Code/guest-components:/src \
  -v /home/pkb/.cargo/registry:/usr/local/cargo/registry -w /src \
  rust:1.82-bookworm bash -c '
  rustup target add x86_64-unknown-linux-musl
  apt-get update -qq && apt-get install -y -qq musl-tools clang libclang-dev sudo
  make -C confidential-data-hub LIBC=musl ENABLE_KBS=true KMS_PROVIDER=aliyun RPC=ttrpc
  cp target/x86_64-unknown-linux-musl/release/confidential-data-hub /src/cdh-daemon-musl
  make -C confidential-data-hub LIBC=musl ENABLE_KBS=true KMS_PROVIDER=aliyun ONE_SHOT=true
  cp target/x86_64-unknown-linux-musl/release/confidential-data-hub /src/cdh-oneshot-musl
'
```

Produces `cdh-daemon-musl` (31 MB) and `cdh-oneshot-musl` (30 MB), both
`static-pie` (musl). `loopdev`'s `bindgen` build requires `libclang` — hence
`clang libclang-dev`.

### Build the embedded VM image

`build-embedded-image.sh` (privileged Ubuntu container, see appendix) does:

1. Pre-pull busybox with `cdh-oneshot pull-image` using
   `enable_embedded_image_cache = true` → `layers/` + `meta_store.json`
   (with `reference_db`).
2. `mkfs.erofs -z lz4 -E dedupe` of the layers.
3. Copy the base kata image, mount p1 (offset 3145728), replace
   `/usr/local/bin/confidential-data-hub`, install `/opt/kata-cache/` +
   a `kata-image-cache.service` (mounts erofs → tar-extracts layers →
   copies `meta_store.json`).
4. Recompute dm-verity on p1/p2 (`veritysetup format --no-superblock`).

```bash
docker run --rm --privileged -v /home/pkb/Code/guest-components:/gc \
  -v "$PWD":/work -w /work -e IMAGE_REF=docker.io/library/busybox:latest \
  ubuntu:24.04 bash -c 'apt-get install -y erofs-utils cryptsetup-bin kpartx parted rsync python3 && bash /work/build-embedded-image.sh'
```

Output `kata-embedded-test.image` + `kernel_verity_params` (fresh root hash).

### Deploy + configure kata

```bash
docker cp kata-embedded-test.image test-worker:/opt/kata/share/kata-containers/
# config.d drop-in for kata-qemu-coco-dev:
[hypervisor.qemu]
image = "/opt/kata/share/kata-containers/kata-embedded-test.image"
kernel_verity_params = "root_hash=<..>,salt=<..>,data_blocks=96512,data_block_size=4096,hash_block_size=4096"
[agent.kata]
debug_console_enabled = true   # only for debugging
```

### Opt-in config via initdata

The `enable_embedded_image_cache = true` flag is injected per-pod through the
CoCo **initdata** `cdh.toml` (the kata-agent launches CDH with
`--config /run/confidential-containers/initdata/cdh.toml`):

```toml
version = "0.1.0"
algorithm = "sha384"
[data]
"cdh.toml" = '''
[kbc]
name = "offline_fs_kbc"
url = ""

[image]
enable_embedded_image_cache = true
'''
```

gzip + base64 → pod annotation
`io.katacontainers.config.hypervisor.cc_init_data`. See `gen-initdata-pod.sh`.

### Test pod

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: embedded-image-test
  annotations:
    io.katacontainers.config.hypervisor.cc_init_data: "<gzip|base64 initdata>"
spec:
  runtimeClassName: kata-qemu-coco-dev
  restartPolicy: Never
  containers:
  - name: app
    image: docker.io/library/busybox:latest
    imagePullPolicy: IfNotPresent
    command: ["sleep", "3600"]
```

---

## 4. Kata/QEMU results

**What worked:**

- The VM boots from the modified image with the freshly computed dm-verity hash
  (confirmed via the qemu `-append dm-mod.create=… root_hash=c0b…/cf8…`).
- The initdata `cdh.toml` is injected (qemu `-drive id=initdata,…`), and CDH
  starts with `-c /run/confidential-containers/initdata/cdh.toml`.
- The new CDH binary is in place (`/usr/local/bin/confidential-data-hub`).
- `kata-image-cache.service` runs successfully and reports the files present:

```
kata-image-cache[180]: DONE: layers meta_store.json
```

- The pod reaches `Running` and the busybox container works (`uname -r` →
  `6.18.35`).

**What did NOT work initially (and how it was fixed):**

CDH logged `Initialize new metadata.` (it did **not** load the embedded
`meta_store.json`) and then `Use Anonymous image registry auth` (pulled from the
registry). Evidence: the cache service reported `DONE: layers meta_store.json`
at T+0, but `stat` showed `meta_store.json` Birth time == CDH's post-pull write
time (T+6s), and a local test confirmed `O_TRUNC` does **not** change tmpfs
btime — so the file was **deleted, then recreated**.

**Root cause + fix:** the kata-agent deletes `meta_store.json` during guest
setup. The previous 3.31.0 work already hit this and solved it by
**bind-mounting the file to itself**, making it a mount point that survives the
unlink (`experiments.md`):

```bash
mount --bind /run/kata-containers/image/meta_store.json \
             /run/kata-containers/image/meta_store.json
```

My first harness dropped that line. After restoring it, the cache is used:

```
image_rs::builder: Existing metadata found. Using previous ones.
image_rs::builder: Image work directory: "/run/kata-containers/image/"
image_rs::image: Image docker.io/library/busybox:latest found in local cache, creating bundle
```

No `Use Anonymous image registry auth` line, and `stat` confirms the layers and
`meta_store.json` keep their cache-service birth time (no re-pull).

```bash
$ stat /run/kata-containers/image/layers/0 | grep Birth
 Birth: 2026-10-19 04:07:16 ...   # cache-service time, not CDH re-pull
```

---

## 5. Kata/QEMU findings

- **`enable_embedded_image_cache` is injected via initdata `cdh.toml`**, not via
  kernel cmdline — the kata-agent launches CDH with
  `--config /run/confidential-containers/initdata/cdh.toml`, so the `[image]`
  section there is the natural opt-in point for kata.
- **NVDIMM, not virtio-scsi**: despite `block_device_driver = "virtio-scsi"`,
  the guest image is attached as an NVDIMM (`-device nvdimm … mem-path=<image>`)
  and booted via `dm-mod.create=… /dev/pmem0p1 /dev/pmem0p2 …` (matches Kata
  3.x). `block_device_driver` only affects container rootfs block devices.
- **dm-verity layout unchanged** from 3.x: p1 (data, 96512×4096) + p2 (hash
  tree), `--no-superblock`. Recomputing the hash on the modified image works.
- The embedded `meta_store.json` format matches the image-rs struct exactly
  (including `reference_db` and `manifest_list_digest`).
- **`meta_store.json` must be bind-mounted to itself** in the
  `kata-image-cache.service`, or the kata-agent deletes it before CDH reads it.
  This is the same gotcha as the earlier 3.31.0 work.

---

## Appendix — key scripts (in `/tmp/opencode/kata-test/`)

- `verify-fastpath.sh` — host-side fast-path proof (pre-pull, then registry-blocked re-pull).
- `verify-signature-cache.sh` — signature-verification proof on the cached path (signed accepted / wrong-key rejected).
- `signature-test-output.log` — full log of the signature-verification run.
- `build-embedded-image.sh` — builds the embedded VM image + dm-verity recompute.
- `gen-initdata-pod.sh` — generates `initdata.toml` + the test pod YAML.
- `read-console.py` — reads a kata VM serial console socket.

### Loop-device notes for the image build

The privileged container shares the host loop devices; after repeated runs the
loop nodes get stale. The script now does `losetup -D` + `mknod /dev/loop{0..7}`
and mounts/veritys by **offset** (`mount -o loop,offset=3145728`,
`losetup --offset/--sizelimit`) to avoid partition-node races:

```
P1_OFFSET=3145728  P1_SIZE=395313152   # ext4 data
P2_OFFSET=398458880 P2_SIZE=4194304    # hash tree
```
