# Multi-Image Embedding — Validation

Extends the [single-image embedding validation](no-double-pull.md) to **two
container images** embedded in the same peer pod VM, each with its own unique
marker file.  Proves that multiple images can be served from the embedded cache
simultaneously, with shared layers deduplicated and each image resolved
independently by CDH — with all registries unreachable.

---

## Result summary

| Image | Marker (unique secret) | In embedded cache | In running container | CDH behaviour |
|---|---|---|---|---|
| `multi-image-a:proof` (python base) | `96535fe1...` | yes | **yes** | `found in local cache` |
| `multi-image-b:proof` (nginx base) | `d5928b9e...` | yes | **yes** | `found in local cache` |

Both pods reached `Running` with the registry **blocked inside every peer pod
VM** (iptables DROP on the registry IP).  The two markers are random 64-hex
secrets that exist nowhere except the embedded cache.

---

## Test setup

### 1. Two marker images

Built two OCI images, each a different base with a unique marker file:

| Image | Base | Marker path | Marker secret |
|---|---|---|---|
| `multi-image-a:proof` | python:3.12 | `/opt/embedded-proof/PROOF1.txt` | `96535fe1d9b362edfb8e8dec1156f514dc79ff2e8bdafce96187f46afbc62b9c` |
| `multi-image-b:proof` | nginx:latest | `/opt/embedded-proof/PROOF2.txt` | `d5928b9e3e88d01cf5c6734f1c1174c7f1939682314aaf47427d4d02840238fe` |

Pushed to a throwaway local registry (default bridge + kind networks).

### 2. Multi-image embedded podvm

Built the podvm with `cdh-oneshot` pulling **both** images into the **same
`work_dir`**, so `image-rs` deduplicates shared layers across images:

```
cdh-oneshot pull-image --image-url multi-image-a:proof --bundle-path /tmp/bundle-a
cdh-oneshot pull-image --image-url multi-image-b:proof --bundle-path /tmp/bundle-b
cp -a <work_dir>/image/layers /usr/lib/kata-cache/layers/
cp    <work_dir>/image/meta_store.json /usr/lib/kata-cache/meta_store.json
```

### 3. Embedded cache contents (verified inside the podvm image)

```
layers:          18
reference_db:    multi-image-a:proof, multi-image-a@sha256:ead35d75...
                 multi-image-b:proof, multi-image-b@sha256:8ce98b50...
image_db:        2
layer_db:        18
```

Both markers present in the embedded layers:

```
find /usr/lib/kata-cache/layers -name PROOF1.txt  → 96535fe1...   (image A)
find /usr/lib/kata-cache/layers -name PROOF2.txt  → d5928b9e...   (image B)
```

### 4. Node state

Both image references registered on the worker node (manifest + config, ~4 KB
total).  Layer blobs are not required on the node for the embedded path.

### 5. Registry block

Registry IP (`172.18.0.9:5000`) blocked **inside every peer pod VM** with
iptables:

```
iptables -I OUTPUT  -d 172.18.0.9 -j DROP
iptables -I FORWARD -d 172.18.0.9 -j DROP
iptables -I INPUT   -s 172.18.0.9 -j DROP
```

Verified blocked on all three pool VMs before running the pods.

---

## Validation

### Case A — image A pod, registry blocked

```bash
kubectl exec multi-a-test -- cat /opt/embedded-proof/PROOF1.txt
# → 96535fe1d9b362edfb8e8dec1156f514dc79ff2e8bdafce96187f46afbc62b9c
```

### Case B — image B pod, registry blocked

```bash
kubectl exec multi-b-test -- cat /opt/embedded-proof/PROOF2.txt
# → d5928b9e3e88d01cf5c6734f1c1174c7f1939682314aaf47427d4d02840238fe
```

Both matched the expected secrets exactly.

### CDH journals (inside the pool VMs)

```
INFO image_rs::image: Image 172.18.0.9:5000/multi-image-a:proof found in local cache, creating bundle
INFO image_rs::image: Image 172.18.0.9:5000/multi-image-b:proof found in local cache, creating bundle
```

`found in local cache` is the `reference_db` fast path — CDH resolved each image
independently from the embedded cache.

---

## What this proves

1. **Multiple images can be embedded** in a single peer pod VM and served by
   CDH from the cache.
2. **Each image is resolved independently** via its own `reference_db` entry
   (tag + digest forms).
3. **Shared layers are deduplicated**: layers shared between the two images are
   stored once (`layer_db` of 18 < naive sum), exactly as `image-rs` layer_db
   dedup is designed to do.
4. **No registry contact**: with the registry blocked on every pool VM, both
   markers still appear in their containers — the only possible source is the
   embedded cache.

---

## Notes / observations

- The marker files are the **only** proof that does not rely on byte counts or
  logs: a random secret present in the container that exists nowhere outside the
  embedded cache is conclusive.
- The node-side containerd may still fetch manifest/config metadata (a few KB);
  the layer data is not required on the node for the embedded path.
- Pods running concurrently were allocated to different pool VMs; both served
  their embedded images from the cache on whichever VM they landed.

---

## Environment

Same as the single-image test:

- kind cluster `peer-pods` with Calico
- CAA v0.22.0 (helm), BYOM provider, 3 pool VMs
- kata-deploy `kata-remote` shim + nydus `config-guest-pulling.toml`
- Patched CDH `v0.21.0-04214c4e` from `image-cache-reference-db-v0.21.0`
- Multi-image embedded podvm built from the same adapted branches

---

## Files

- This document: `multi-image-embedding.md`
- Related: [no-double-pull.md](no-double-pull.md),
  [perf_analysis.md](perf_analysis.md), [experiments-byom.md](experiments-byom.md)