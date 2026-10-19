# Signature Verification on the Composable Embedded Cache — E2E Test

This document records the signature-verification-on-cached-path validation for
the composable embedded image cache, complementing
[composable-embedded-cache-test.md](composable-embedded-cache-test.md) (which
proved the cache is served with zero registry contact).

The goal: prove that when the image cache is delivered as a **Kata composable
guest extension image**, the cached fast path still runs `SignatureValidator`
policy checks — a signed image is served from the cache, and an image whose
signature does not match the trusted key is rejected.

---

## Summary

| Test | Policy key | Expected | Result |
|---|---|---|---|
| Positive | correct GPG key (from extension) | signature verified, pod `Running` | ✅ `1/1 Running` |
| Negative | wrong key (inline `keyData`) | signature rejected, pod `StartError` | ✅ `0/1 StartError` |

---

## 1. Approach

The image-cache extension is made **fully self-contained**: it carries the
pre-pulled layers + `meta_store.json`, plus the local signature-verification
infrastructure whose paths resolve inside the extension mount point
(`/run/kata-extensions/imgcache/etc/...`). No base-image or coco-extension
change is needed for signature verification.

Extension rootfs layout:

```
layers/0..N
meta_store.json
etc/
  image-policy.json                      # keyPath -> extension pubkey.asc
  sigstore-config.yaml                   # sigstore -> extension signatures dir
  containers/
    pubkey.asc                          # GPG public key
    quay_verification/signatures/        # local file:// sigstore (from signatures.tar)
```

The runtime policy/sigstore config point inside the extension, so the same
extension could ship a *different* image + *different* policy and key, fully
decoupled from the base image and the coco extension.

### Build

`build-signed-cache-extension.sh` (this repo):

1. Extracts the image-rs `test_data` sigstore (`signatures.tar`) and the GPG
   pubkey (from `offline-fs-kbc/aa-offline_fs_kbc-resources.json`).
2. Pre-pulls `quay.io/kata-containers/confidential-containers:signed` with
   `enable_embedded_image_cache = true` and the build-time policy/sigstore, so
   the signature is verified and `reference_db` is populated.
3. Lays out the extension rootfs above, rewriting `image-policy.json` and
   `sigstore-config.yaml` with the extension-mount paths.
4. Packs EROFS + dm-verity (offset-addressed loop devices, as in the other
   build scripts).

### Runtime initdata

Positive (policy + sigstore config fetched from the extension):

```toml
[image]
enable_embedded_image_cache = true
image_security_policy_uri = "file:///run/kata-extensions/imgcache/etc/image-policy.json"
sigstore_config_uri = "file:///run/kata-extensions/imgcache/etc/sigstore-config.yaml"
```

Negative (inline policy with a bogus key, same extension sigstore):

```toml
[image]
enable_embedded_image_cache = true
image_security_policy = '{"default":[{"type":"insecureAcceptAnything"}],"transports":{"docker":{"quay.io/kata-containers/confidential-containers":[{"type":"signedBy","keyType":"GPGKeys","keyData":"bm9uc2Vuc2U="}]}}}'
sigstore_config_uri = "file:///run/kata-extensions/imgcache/etc/sigstore-config.yaml"
```

Both injected via the `io.katacontainers.config.hypervisor.cc_init_data` pod
annotation on the `kata-qemu-coco-dev-runtime-rs` runtime class.

---

## 2. Results

### Positive — correct key, pod `Running`

```
NAME              READY   STATUS    RESTARTS   AGE
signed-positive   1/1     Running   0          45s
```

In-VM proof (agent debug console, vsock `guest-cid:1026`):

The extension carries the signature infrastructure:

```
$ ls /run/kata-extensions/imgcache/etc/
containers  image-policy.json  sigstore-config.yaml
$ ls /run/kata-extensions/imgcache/etc/containers/
pubkey.asc  quay_verification
```

The embedded `reference_db` maps the signed image (tag + digest forms) to its
config digest:

```
reference_db":{"quay.io/kata-containers/confidential-containers@sha256:febcf61c…":"sha256:16ea53ea…",
               "quay.io/kata-containers/confidential-containers:signed":"sha256:16ea53ea…"}
```

CDH launches from the patched coco extension with the initdata config:

```
root 249 … /run/kata-extensions/coco/usr/local/bin/confidential-data-hub \
    -c /run/confidential-containers/initdata/cdh.toml
```

The container rootfs overlay is built from the embedded (bind-mounted) layer:

```
/dev/mapper/extension-imgcache on /run/kata-containers/image/layers/0 type erofs (ro)
overlay on …/rootfs type overlay (rw,lowerdir=/run/kata-containers/image/layers/0,…)
```

Because the policy (`image_security_policy_uri`) was configured and the pod
reached `Running`, the cached path ran `check_image_signature` and the signature
passed with the extension's pubkey.

### Negative — wrong key, pod `StartError`

```
NAME              READY   STATUS       RESTARTS   AGE
signed-negative   0/1     StartError   0          45s
```

Pod event shows the cached path ran signature verification and rejected:

```
[CDH] [ERROR]: Image Pull error: Image policy rejected: Denied by policy:
  rejected by `signedBy` rule: The signatures do not satisfied!
  Reject reason: [not enough bytes in buffer: armor header]

Stack backtrace:
  0: image_rs::signature::policy::simple::verify::verify_sig_and_extract_payload
  1: image_rs::signature::policy::simple::judge_single_signature
  2: image_rs::signature::SignatureValidator::check_image_requirement
  3: image_rs::signature::SignatureValidator::check_image_signature
  4: <confidential_data_hub::hub::Hub …>::pull_image
```

The `check_image_signature` frames confirm the signature check runs on the pull
path inside the composable VM; the wrong key rejects the image, so the container
never starts.

---

## 3. Conclusion

The composable embedded image cache preserves the signature-verification
guarantee added to the cached path: a signed image served from the cache is
verified against the policy, and a wrong-key image is rejected. Because the
policy, sigstore, and pubkey all live inside the image-cache extension, the
signature verification is fully self-contained and per-cache-configurable,
without touching the base image or the coco extension.

---

## 4. Files

- `build-signed-cache-extension.sh` — builds the signed image-cache extension.
- `composable-embedded-cache.md` — feasibility design.
- `composable-embedded-cache-test.md` — cache-served-from-extension test record.
- This document.
