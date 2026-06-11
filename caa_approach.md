# Embedding Container Image in CAA Peer Pod qcow2

Feasibility analysis for duplicating the embedded-container-image approach for
cloud-api-adaptor (CAA) peer pod VMs, which use mkosi-built qcow2 images and
the `kata-remote` runtimeclass.

**Repo:** https://github.com/confidential-containers/cloud-api-adaptor

---

## What's the Same

- CDH with `reference_db` fast-path (same image-rs patches) — CAA also runs CDH
  inside the peer pod VM
- `kata-image-cache.service` concept — `Before=kata-agent.service`, extracts erofs
  to tmpfs, bind-mounts `meta_store.json`
- `cdh-oneshot pull-image` for build-time pre-pull of layers and `meta_store.json`

---

## Key Differences

| | kata-qemu (done) | CAA peer pod |
|---|---|---|
| Image format | raw ext4 (kpartx/dd) | qcow2 (mkosi + qemu-img) |
| Build tool | shell script | Docker buildx → mkosi |
| Root filesystem | mounted `ro` via pmem | UKI, `systemd.volatile=state` |
| CDH config source | kernel cmdline / static toml | `process-user-data.service` (IMDS at boot) |
| File injection | direct `rsync` into mounted partition | mkosi `files/` tree or post-process qcow2 |

---

## CAA mkosi Build Structure

**Location:** `podvm/mkosi.images/system/`

| File/Dir | Purpose |
|---|---|
| `mkosi.conf` | UKI bootloader, `systemd.volatile=state`, kernel modules |
| `mkosi.conf.d/` | Distro-specific package lists (`fedora.conf`, `ubuntu.conf`) |
| `mkosi.postinst` | Post-install script (udev rules, OS release metadata) |
| `mkosi.finalize.chroot` | Final chroot customizations |
| `mkosi.skeleton/`, `mkosi.repart/` | Filesystem layout and partition definitions |
| `resources/binaries-tree/` | Compiled kata-agent, CDH, AA binaries injected at build time |

**Build flow:**
```
make podvm-binaries
  → Docker buildx
  → binaries compiled to resources/binaries-tree/

make image
  → Docker buildx + Dockerfile.mkosi
  → mkosi runs inside container
  → raw disk image
  → qemu-img convert → qcow2
```

**CDH inside the peer pod VM:**
- Binary: `/usr/local/bin/confidential-data-hub`
- Config: `/run/peerpod/cdh.toml` (written at boot by `process-user-data.service` from IMDS)
- Env: `CDH_DEFAULT_IMAGE_AUTHENTICATED_REGISTRY_CREDENTIALS=file:///run/peerpod/auth.json`
- Unit: `confidential-data-hub.service` (Type=simple, Restart=always, After=process-user-data.service)

**kata-agent:**
- Unit: `kata-agent.service` (depends on `netns@podns.service`, `scratch-storage.service`)
- Creates `/run/kata-containers` at startup; cleanup on post-stop

---

## Blockers to Resolve Before Starting

### 1. CDH patch not upstream

CAA builds CDH from `github.com/confidential-containers/guest-components` (upstream),
which does **not** have the `reference_db` patch from `bpradipt/guest-components`
branch `local-0.20.0`. Options:

- Submit the patch upstream to `confidential-containers/guest-components`
- Point the CAA build at the fork temporarily

### 2. Runtime CDH `work_dir` unknown

`process-user-data.service` writes `/run/peerpod/cdh.toml` at boot from IMDS data.
This may set a custom `work_dir` for CDH's image store. The `kata-image-cache.service`
must populate **exactly** the path CDH will use at runtime.

**Next step:** Read `process-user-data.service` in the CAA repo to confirm what
`work_dir` value ends up in `cdh.toml`.

---

## Proposed Implementation

### Step 1 — Build-time pre-pull (same as kata-qemu)

```bash
CDH_ONESHOT=.../cdh-oneshot

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

sudo mkfs.erofs -z lz4 -E dedupe layers.erofs /run/kata-containers/image/layers
```

### Step 2 — Inject files into qcow2

Post-process the mkosi-built qcow2 using `guestfish` (libguestfs) — no loop devices
needed, works directly on qcow2:

```bash
guestfish -a built.qcow2 -i <<'EOF'
  mkdir-p /opt/kata-cache
  upload layers.erofs /opt/kata-cache/layers.erofs
  upload meta_store.json /opt/kata-cache/meta_store.json
  upload kata-image-cache.service /usr/lib/systemd/system/kata-image-cache.service
  ln-sf /usr/lib/systemd/system/kata-image-cache.service \
    /etc/systemd/system/kata-agent.service.wants/kata-image-cache.service
EOF
```

### Step 3 — `kata-image-cache.service`

Same as the kata-qemu service — needs adjustment for `After=` ordering:

```ini
[Unit]
Description=Mount pre-embedded container image cache
DefaultDependencies=no
Before=kata-agent.service
After=local-fs.target tmp.mount process-user-data.service

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
WantedBy=multi-user.target
```

Key difference from kata-qemu: `After=process-user-data.service` ensures the service
runs after CDH's runtime config is written, so `work_dir` is known and consistent.

---

## Open Questions

1. Does `systemd.volatile=state` affect `/opt`? If `/opt` is on the volatile tmpfs
   overlay, the embedded erofs stored at `/opt/kata-cache` would be lost at boot.
   May need to use a path on the immutable root (e.g. `/usr/lib/kata-cache/`).

2. Does CAA's `kata-agent.service` clean `/run/kata-containers/image/` on startup
   (same issue we hit with the kata-qemu setup)? If yes, the bind-mount on
   `meta_store.json` is still required.

3. For the `kata-remote` runtimeclass, does the peer pod VM receive the image
   reference as a tag or digest when kata-agent calls CDH? The `reference_db`
   fix (writing both forms) should handle this regardless.
