# Embedded Image Cache via Kata Composable VM Images — Feasibility

Explore delivering the embedded image cache as a **Kata guest extension image**
instead of baking the container images into a single monolithic VM rootfs.

> **Context:** the embedded cache (image-rs `reference_db` + opt-in
> `enable_embedded_image_cache`) is validated end-to-end in
> [image-rs-embedded-cache-test.md](image-rs-embedded-cache-test.md). That work
> bakes the layers + `meta_store.json` into the **base rootfs** and recomputes
> dm-verity on the whole image. This document assesses moving the cache into the
> **composable VM image** mechanism
> ([design doc](https://github.com/kata-containers/kata-containers/blob/main/docs/design/composable-vm-images.md)).
>
> **Scope:** applicable to **Kata/QEMU** only (both the Go runtime and the
> runtime-rs). The composable feature is not available on **Kata/remote (CAA)**,
> which keeps the mkosi-embedded approach
> ([embedding-container-image-in-caa.md](embedding-container-image-in-caa.md)).
> The image-rs embedded-cache *feature* itself stays generic to both.

---

## Verdict

**Feasible, with a low and well-bounded amount of change.** The composable
feature is already present and working in the deployed Kata 4.0.0 environment —
a "coco" guest extension (EROFS + dm-verity, virtio-blk) is mounted at
`/run/kata-extensions/coco/` before kata-agent starts, purely from runtime
config. The embedded cache maps cleanly onto a second, purpose-specific
extension ("image cache") because:

1. The extension-mount machinery is **name-agnostic** — the systemd generator
   instantiates `kata-extension-mount@<name>.service` for *any*
   `kata.extension.<name>.verity_params` entry on the kernel cmdline, so adding
   an `image-cache` extension needs **no base-image change** for mounting.
2. The only genuinely new pieces are (a) a **cache-setup** step that
   bind-mounts the extension's layers into CDH's writable layer store, and
   (b) the **patched CDH** that understands `reference_db`/the opt-in flag.
3. The hard parts (bind-mount layer store onto writable tmpfs, the
   `meta_store.json` deletion gotcha) are already solved and documented in the
   CAA work ([embedding-container-image-in-caa.md](embedding-container-image-in-caa.md)).

The "huge flexibility" claim holds: the base image and the coco extension stay
fixed, and every cache change is isolated to the cache extension + one runtime
config entry.

---

## Background: what is already deployed (verified in the kind env)

Kata **4.0.0** (commit `cf82bb35c80320178bf7570252fe75d6fb263209`), QEMU
`11.0.1` (kata-static), kernel `6.18.35-200`. The composable feature is shipped:

| Artefact | Content | Notes |
|---|---|---|
| `kata-containers.img` → `kata-ubuntu-noble.image` | base rootfs, **no CDH** | ships the extension-mount infra |
| `kata-containers-coco-extension.img` (72 MB) | CDH, attestation-agent(-nv), api-server-rest, cryptsetup, ocicrypt config, pause bundle, `components.toml` | EROFS + dm-verity (p1 data, p2 hash) |
| `kata-containers-confidential.img` → `kata-ubuntu-noble-confidential.image` | old **monolithic** CoCo image | still used by the Go runtime |

Verified directly inside the base image (`kata-ubuntu-noble.image`, mounted ro):

```
/usr/lib/systemd/system/kata-extension-mount@.service   ← template unit
/usr/libexec/kata-extension-mount.sh                    ← mount helper
/usr/libexec/kata-extension-mount-generator             ← systemd generator
/usr/sbin/veritysetup                                   ← present (unconditional)
/usr/local/bin/confidential-data-hub                    ← ABSENT (moved to extension)
```

The **runtime-rs** runtime class `kata-qemu-coco-dev-runtime-rs` already uses the
composable path:

```toml
[hypervisor.qemu]
image = "/opt/kata/share/kata-containers/kata-containers.img"

[[hypervisor.qemu.guest_extension_images]]
name = "coco"
path = "/opt/kata/share/kata-containers/kata-containers-coco-extension.img"
verity_params = "root_hash=aea2f64f...,salt=f6a339c1...,data_blocks=17920,data_block_size=4096,hash_block_size=4096"
```

The **Go** runtime `kata-qemu-coco-dev` still points at the monolithic
`kata-containers-confidential.img` (its shipped config does not carry a
`guest_extension_images` entry). Both backends implement the feature per the
design doc; the natural prototype target is the runtime-rs class that is already
wired for it.

### How an extension gets mounted (the mechanism we reuse)

1. The runtime emits one `kata.extension.<name>.verity_params=...` kernel-cmdline
   entry per `guest_extension_images` entry (always, even empty — it is the
   guest-side activation signal).
2. `kata-extension-mount-generator` scans `/proc/cmdline`, and for every
   `kata.extension.<name>.verity_params` (bare or with value) symlinks
   `kata-extension-mount@<name>.service` into `kata-containers.target.wants`.
3. The unit (`ConditionKernelCommandLine`, `Before=kata-agent.service`,
   `OnFailure=poweroff.target`) runs `kata-extension-mount.sh <name>`, which
   discovers the virtio-blk device by serial `extension-<name>`, runs
   `veritysetup open` (if a hash partition `p2` exists), and mounts EROFS ro at
   `/run/kata-extensions/<name>/`.

Because discovery is serial-based and the generator is cmdline-driven, the
runtime does **not** need any per-name rootfs stub to mount a new extension.

---

## Proposed design

Split the embedded cache into a purpose-specific **image-cache extension**,
leaving the base image and the coco extension untouched.

```
Host                                                Guest VM
┌───────────────────────────────────┐
│ [hypervisor.qemu]                  │
│ image = kata-containers.img        │
│                                    │
│ [[guest_extension_images]]         │      /                       (base, erofs+verity, NVDIMM)
│   name = "coco"                    │      kata-agent, systemd,
│   ...                              │      kata-extension-mount infra
│ [[guest_extension_images]]         │
│   name = "imgcache"                │      /run/kata-extensions/coco/     (EROFS, ro)
│   path = ...-image-cache.img       │      /run/kata-extensions/imgcache/ (EROFS, ro)
│   verity_params = <root_hash,...>  │        layers/0..N, meta_store.json
└───────────────────────────────────┘
                                      kata-image-cache-setup.service (new, base)
                                        After=kata-extension-mount@imgcache.service
                                        Before=kata-agent.service
                                        → bind-mounts layers, installs meta_store.json
```

### Cache extension image contents

Built the same way as the coco extension (EROFS data `p1` + dm-verity hash `p2`,
`MEASURED_ROOTFS=yes`, `SKIP_DAX_HEADER=yes`), carrying:

```
layers/0..N          ← pre-pulled OCI layers (cdh-oneshot, shared work_dir)
meta_store.json      ← reference_db + layer_db + image_db
```

- **Pre-pull** with the patched `cdh-oneshot` into one `work_dir` (identical to
  the existing build), so `layer_db` dedup applies across images and
  `reference_db` carries both the tag and `@sha256:...` forms.
- **No nested erofs** — the extension *is* the EROFS; `mkfs.erofs -z lz4 -E dedupe`
  compresses the layers in place (same lz4-only constraint as the kata kernel).
- One cache extension can hold **many images** (see
  [multi-image-embedding.md](multi-image-embedding.md)); multiple cache
  extensions are also possible (below).

### Cache-setup step (the one new base-image piece)

A new `kata-image-cache-setup.service` (plus a small script) ships in the base
image, conditioned on the cache extension so it no-ops when none is configured:

```ini
[Unit]
Description=Set up embedded image cache from a guest extension
DefaultDependencies=no
After=local-fs-pre.target
After=kata-extension-mount@imgcache.service
Before=kata-agent.service
ConditionKernelCommandLine=kata.extension.imgcache.verity_params

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/libexec/kata-image-cache-setup.sh imgcache
```

The script reuses the CAA bind-mount design
([embedding-container-image-in-caa.md](embedding-container-image-in-caa.md)),
with the extension mount point as the read-only source:

```bash
set -euo pipefail
NAME="${1:?extension name required}"
SRC="/run/kata-extensions/${NAME}"

# 1. writable layer store (parent stays writable so cache misses can add layers)
mkdir -p /run/kata-containers/image/layers

# 2. bind-mount each embedded layer dir (ro) onto the writable store
for d in "${SRC}"/layers/*/; do
    n="$(basename "$d")"
    mkdir -p "/run/kata-containers/image/layers/${n}"
    mount --bind "${SRC}/layers/${n}" "/run/kata-containers/image/layers/${n}"
    mount -o remount,ro,bind "/run/kata-containers/image/layers/${n}"
done

# 3. install meta_store.json and protect it from the kata-agent cleanup
cp "${SRC}/meta_store.json" /run/kata-containers/image/meta_store.json
mount --bind /run/kata-containers/image/meta_store.json \
             /run/kata-containers/image/meta_store.json
```

This is exactly the pattern proven in CAA — per-layer read-only bind-mounts over
a writable tmpfs parent, and a self-bind-mounted `meta_store.json`.

### CDH: the patch + opt-in

Two independent things, both unchanged from the current approach:

- **Opt-in flag** — `[image] enable_embedded_image_cache = true` in the initdata
  `cdh.toml` (the kata-agent passes `--config .../initdata/cdh.toml`). No change.
- **The patched CDH** — the `reference_db` + embedded-cache change lives in
  `confidential-data-hub`, which the composable design serves from the **coco
  extension** (`usr/local/bin/confidential-data-hub`, launched via the
  `components.toml` manifest). So the patch must reach that binary:
  - **Short term** (patch not upstream): rebuild the coco extension from the
    `image-rs-embedded-cache-main` guest-components branch
    (`tools/coco-extension/`), or ship a custom CDH binary in a modified coco
    extension.
  - **Long term**: merge the image-rs change upstream; the stock coco extension
    CDH then carries it and only the config flag + cache extension are needed.

The kata-agent itself does **not** need the patch — it only launches CDH and
reads the manifest; the `reference_db` fast path is entirely inside CDH.

### Runtime config (the only per-cache-change surface)

```toml
[[hypervisor.qemu.guest_extension_images]]
name = "imgcache"
path = "/opt/kata/share/kata-containers/kata-containers-image-cache.img"
verity_params = "root_hash=<hash>,salt=<salt>,data_blocks=<n>,data_block_size=4096,hash_block_size=4096"
```

To change the cached images: rebuild only the cache extension, recompute its
root hash, update `verity_params`. Base and coco stay byte-identical, so their
measurements do not change.

---

## Feasibility analysis by concern

| Concern | Assessment | Notes / resolution |
|---|---|---|
| Extension mount for an arbitrary name | ✅ works today | Generator + template are name-agnostic; verified in the base image |
| Read-only source + writable layer store | ✅ solved | Per-layer ro bind-mounts onto writable tmpfs (CAA design) |
| `meta_store.json` deleted by kata-agent | ✅ solved | self-bind-mount; same gotcha as current work |
| Cache ready before CDH | ✅ solvable | `After=kata-extension-mount@imgcache.service Before=kata-agent.service` |
| CDH carries `reference_db` patch | ⚠️ dependency | coco extension rebuild until upstream merge |
| dm-verity / measured boot | ✅ better | cache ext has its own hash; base hash stays constant; cache root hash is on the measured cmdline |
| Integrity fail-closed | ✅ inherited | `OnFailure=poweroff.target`; verity mismatch → power off |
| Layer compression | ✅ | EROFS lz4 + dedupe (lz4-only kernel constraint) |
| virtio-blk vs NVDIMM | ✅ | extensions are always virtio-blk (needed for serial discovery); base stays NVDIMM |
| Attestation of cache contents | ✅ improved | cache root hash is part of the launch measurement; changing the cache changes *only* that extension's hash |
| Multiple images / extensions | ✅ | one extension holds N images (layer_db dedup); extra `guest_extension_images` entries for more |
| CAA / Kata-remote | ❌ out of scope | composable is QEMU-only; CAA keeps the mkosi embedded build |
| Kernel-cmdline size scaling | ⚠️ bounded | one long `verity_params` entry per cache extension; fine for a handful, a manifest-extension bootstrap is future work |

### Naming constraint

The virtio-blk serial is `extension-<name>`; the doc caps CLH/Dragonball serials
at 20 bytes, so the name must be ≤ 10 ASCII chars. `imgcache` (8) leaves headroom
(`image-cache` = 11 would exceed it). QEMU is not limited today, but a short
name keeps the design backend-portable.

### Extension ordering / multiple cache extensions

The cache-setup script can loop over every `imgcache*` extension present on
`/proc/cmdline` and bind-mount their layers into the single shared CDH layer
store. Layer numbering must be namespaced (e.g. per-extension subdir or an
offset) so two extensions do not collide on `layers/N`. This is a small
extension of the single-extension script, not a new mechanism.

---

## What needs to change (concrete)

| # | Artefact | Where | New / change |
|---|---|---|---|
| 1 | `kata-image-cache-setup.service` + script | **base image** (one-time) | new, generic, cmdline-conditioned |
| 2 | image-cache extension image | runtime host path | new build (cdh-oneshot pre-pull → EROFS+verity) |
| 3 | `guest_extension_images` entry `imgcache` | runtime config | new entry (the per-cache-change surface) |
| 4 | patched CDH (`reference_db` + opt-in) | coco extension (or upstream) | rebuild until merged |
| 5 | `enable_embedded_image_cache = true` | initdata `cdh.toml` | unchanged |

Items 2 + 3 are the only things that change per cache content change; item 1 is
a one-time base-image addition that should itself be upstreamed (mirroring the
existing `kata-extension-mount@` template + generator); item 4 disappears once
the image-rs change lands.

---

## Advantages over the current monolithic approach

- **Base image never rebuilds** — no rootfs copy, no whole-image dm-verity
  recompute, no NVDIMM 2-MiB-alignment dance per cache change.
- **Composable caches** — per-workload, per-tenant, or per-region cache images,
  mixed and matched via runtime config; add/remove an image by swapping one
  extension.
- **Stable base measurement** — the base and coco measurements are invariant;
  only the cache extension's root hash changes with cache content, so attestation
  stays meaningful and cheap to re-verify.
- **Smaller base image** — cached layers no longer inflate the rootfs; the
  cache is a cold-plugged, read-only, deduplicated EROFS.
- **Versioning/independence** — cache images can be built, signed, and published
  independently (same pipeline shape as the coco extension), not tied to the
  kata rootfs release cadence.
- **Failure isolation** — a bad cache extension fails closed at boot
  (`poweroff.target`), not by corrupting the rootfs.

## Relationship to the CAA path (Kata/remote)

The image-rs embedded-cache feature (opt-in flag, `reference_db`, signature
verification on the cached path) is **shared**. Only the *delivery mechanism*
differs:

| | Kata/QEMU (this doc) | Kata/remote (CAA) |
|---|---|---|
| Delivery | composable guest extension | mkosi-embedded qcow2 |
| Mount | `kata-extension-mount@` + cache-setup unit | `kata-image-cache.service` in the podvm |
| Layer store | ro bind-mounts onto tmpfs (same script) | ro bind-mounts onto tmpfs |
| dm-verity | per-extension hash partition | mkosi repart hash partition |
| Flexibility | add/remove cache via runtime config | rebuild podvm per cache change |

So this work does **not** replace the CAA approach — it is the QEMU-side analogue
that gets the flexibility the CAA path lacks, on top of the same image-rs change.

---

## Risks and open questions

1. **CDH patch upstreaming** — until the `reference_db` change is merged, a
   custom coco extension is required; this is the single biggest dependency.
2. **Base-image unit upstreaming** — `kata-image-cache-setup.service` must ship
   in the base image. A distroless/NVRC base (no systemd) would need its
   early-boot owner to do the equivalent, exactly as it does for extension
   mounting. The full-distro base is the primary target.
3. **Whether the kata-agent still deletes `meta_store.json`** in the composable
   guest — the self-bind-mount fix is assumed to carry over; needs re-verifying
   on 4.0.0.
4. **kata-agent namespace for the cache-setup unit** — the bind-mounts must run
   with sufficient privilege; the systemd unit runs as root in the base rootfs,
   matching the existing `kata-extension-mount@` unit, so this is expected to
   hold, but is worth confirming in the prototype.
5. **`reference_db` digest forms vs containerd-resolved digests** — the
   `@sha256:...` backfill must still match what containerd resolves inside the
   VM; unchanged from the current work.
6. **Go runtime support** — the deployed Go runtime config predates the
   `guest_extension_images` wiring; the prototype targets the runtime-rs class
   first, and the Go runtime should be confirmed separately.

---

## Suggested prototype plan

1. Reuse the patched `cdh-oneshot` to pre-pull a marker image into a `work_dir`.
2. Build a cache extension image: `mkfs.erofs -z lz4 -E dedupe` of `layers/` +
   `meta_store.json`, then the two-partition verity layout (mirror the
   guest-components `tools/coco-extension` build or the
   `build-kata-vm-verity.sh` verity steps).
3. Drop in the `kata-image-cache-setup.service` + script into the base image
   (or, for a first smoke test, a debug-console shell one-liner to confirm the
   bind-mount approach before baking the unit).
4. Configure the runtime-rs `qemu-coco-dev-runtime-rs` class with the `imgcache`
   `guest_extension_images` entry and the initdata `cdh.toml` opt-in.
5. Boot a pod with the registry blocked in-VM and confirm CDH logs
   `Image ... found in local cache, creating bundle` and no registry contact.
