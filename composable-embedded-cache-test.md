# Testing the Embedded Image Cache via Kata Composable VM Images

This document records the end-to-end validation of delivering the image-rs
embedded image cache as a **Kata composable guest extension image** (the design
in [composable-embedded-cache.md](composable-embedded-cache.md)) instead of a
single monolithic rootfs.

---

## Summary

| Piece | Status |
|---|---|
| Kata base-image `kata-image-cache-setup` unit + script (kata-containers) | ✅ built, committed |
| Cache extension image (`imgcache`, EROFS + dm-verity) | ✅ built |
| Coco extension rebuilt with patched CDH (`reference_db`) | ✅ built |
| Runtime config (`guest_extension_images` coco + imgcache) | ✅ wired |
| Pod boots, extensions mount, cache-setup runs | ✅ verified |
| Image served from embedded cache, registry blocked | ✅ verified |

---

## 1. What was built

Three images, all produced locally (scripts in this repo):

| Image | Script | Contents |
|---|---|---|
| `kata-ubuntu-noble-cache.image` | `inject-base-image-cache-setup.sh` | base image + `kata-image-cache-setup@.service`/`.sh` + updated generator |
| `kata-containers-coco-extension-cache.img` | `rebuild-coco-extension-cdh.sh` | stock coco extension with `confidential-data-hub` swapped for the patched `reference_db` build |
| `kata-containers-imgcache.img` | `build-image-cache-extension.sh` | pre-pulled busybox layers + `meta_store.json` as EROFS + dm-verity |

The cache extension carries `layers/0` + `meta_store.json`; `reference_db` maps
both `docker.io/library/busybox:latest` and its `@sha256:…` form to the config
digest.

### Build note — loop devices in containers

Partition device nodes (`/dev/loopNp1`) do not appear in a container without
udev; `partprobe`/`partx -a` silently fail. The scripts address the data/hash
partitions **by offset** with dedicated loop devices
(`losetup --offset --sizelimit`), matching the earlier `build-kata-vm-verity.sh`
approach, and write the EROFS payload with `dd … seek=`.

---

## 2. Environment gotchas (Kata 4.0.0 on kind)

Two environment issues had to be worked around before the runtime would start:

1. **runtime-rs shim needs systemd D-Bus for cgroups.** The kind node runs
   systemd as PID 1 but ships no `dbus-daemon`; the runtime-rs shim failed with
   `systemd dbus error: No such file or directory`. Fix: `apt-get install dbus`
   in the node and `systemctl start dbus.socket`. (`sandbox_cgroup_only = false`
   only moves the failure from the sandbox cgroup to the overhead cgroup — the
   D-Bus socket is the real requirement.)
2. **The Go runtime (`kata-qemu-coco-dev`) is wired for the monolithic
   guest-pull image** and refuses the composable base image
   (`cannot enable virtio-fs without daemon path`). The **runtime-rs** class
   (`kata-qemu-coco-dev-runtime-rs`) is the one that already ships the composable
   `guest_extension_images` wiring, so the test targets that class.

The composable feature is therefore exercised via `kata-qemu-coco-dev-runtime-rs`.

---

## 3. Runtime wiring

- Base image + coco extension + imgcache extension in the runtime-rs
  `qemu-coco-dev-runtime-rs` config, each with its fresh verity params.
- `enable_embedded_image_cache = true` injected via initdata `cdh.toml`
  (the `io.katacontainers.config.hypervisor.cc_init_data` pod annotation).
- `debug_console_enabled = true` for the in-VM inspection below.

---

## 4. Proof — extensions mounted, cache served

From the running VM (via the agent debug console, vsock `guest-cid:1026`).

**Both extensions mounted read-only (EROFS + dm-verity):**

```
/dev/mapper/extension-coco     on /run/kata-extensions/coco     type erofs (ro)
/dev/mapper/extension-imgcache on /run/kata-extensions/imgcache type erofs (ro)
```

QEMU cold-plugs them as virtio-blk with the expected serials:

```
virtio-blk-pci,drive=image-3c851697a81bb0d9,...,serial=extension-coco
virtio-blk-pci,drive=image-279ff34143b31b45,...,serial=extension-imgcache
```

**The cache-setup unit bind-mounted the embedded layer and installed the meta
store** (note the `extension-imgcache` source on the layer bind-mount):

```
/dev/mapper/extension-imgcache on /run/kata-containers/image/layers/0 type erofs (ro)
```

**CDH launched from the patched coco extension, with the initdata config:**

```
root 247 228 ... /run/kata-extensions/coco/usr/local/bin/confidential-data-hub \
    -c /run/confidential-containers/initdata/cdh.toml
```

**The container rootfs overlay is built from the embedded layer:**

```
overlay on .../rootfs type overlay (rw,lowerdir=/run/kata-containers/image/layers/0,...)
```

**The embedded `reference_db` is intact in the guest:**

```
reference_db":{"docker.io/library/busybox@sha256:f97baa533a…":"sha256:aaef90e0…",
               "docker.io/library/busybox:latest":"sha256:aaef90e0…"}
```

---

## 5. Registry-blocked test

Blocked the VM's egress to any registry with a FORWARD rule on the pod subnet:

```
iptables -I FORWARD -s 10.244.1.0/24 -p tcp --dport 443 -j REJECT --reject-with tcp-reset
```

With the rule in place the pod still reached `Running` and the busybox container
worked (`uname -r` → `6.18.35`), so the image could only have come from the
embedded cache.

---

## 6. Files

- `composable-embedded-cache.md` — feasibility design.
- `build-image-cache-extension.sh` — builds the `imgcache` extension image.
- `inject-base-image-cache-setup.sh` — injects the cache-setup unit into the base image.
- `rebuild-coco-extension-cdh.sh` — swaps the patched CDH into the coco extension.
- `composable-embedded-cache-test.md` — this record.

### kata-containers changes (upstream PR)

Branch `embedded-image-cache-composable`:

```
68fe0cc28 agent: add systemd template unit for embedded image cache setup
2ae224d8c agent: wire image cache setup into extension generator and Makefile
```
