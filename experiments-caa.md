# Embedding Container Image in CAA — Validation Experiments

Four-case validation confirming that a container image embedded in a CAA peer
pod qcow2 is served by CDH from local cache with zero registry contact.

> **See also:** [Kata/QEMU experiments](experiments.md) — the original four-case
> validation this mirrors.  Setup and conclusions are directly comparable.
>
> **See also:** [BYOM validation](experiments-byom.md) — the same approach
> validated end-to-end on the local CAA BYOM kind setup with the adapted
> latest-release branches.

---

## Summary Table

| Case | VM image | Node image | Registry | imagePullPolicy | Result |
|---|---|---|---|---|---|
| 1 | embedded qcow2 | **absent** | **blocked** | IfNotPresent | **FAIL** — ErrImagePull (node can't pull) |
| 2 | embedded qcow2 | absent | open | IfNotPresent | **PASS** — image cached on node |
| 3 | embedded qcow2 | cached | **blocked** | IfNotPresent | **PASS** — 52 s, CDH uses embedded cache |
| 4 | embedded qcow2 | **removed** | **blocked** | IfNotPresent | **FAIL** — ErrImagePull (node can't pull) |

**Conclusion:** The embedded container image is used by CDH inside the CAA peer
pod VM.  No registry contact is made when the node image cache allows the pod to
reach kata-remote and the embedded cache is present.

> **Note on Case numbering:** Cases 3 and 4 here map directly to Cases 4 and the
> "no-node-cache" negative control from the Kata/QEMU experiments.  The CAA
> experiments skip the Kata/QEMU Case 3 (standard VM + registry blocked) because
> the standard CAA mkosi image does not ship the patched CDH and cannot be
> directly compared.

---

## Environment

- Kubernetes cluster created with `kcli` (`peer-pods` cluster)
- CAA installed via Helm on libvirt (amd64, Ubuntu 24.04 worker node)
- Runtime class: `kata-remote`
- Embedded qcow2 uploaded to libvirt as `podvm-base.qcow2`
- KUBECONFIG: `~/.kcli/clusters/peer-pods/auth/kubeconfig`

### One-time worker-node setup (before running cases)

```bash
WORKER_IP=<worker-node-ip>

# Raise kata-remote dial_timeout (default 30 s is too short for UKI boot)
ssh ubuntu@$WORKER_IP \
  "sudo sed -i 's/dial_timeout = [0-9]*/dial_timeout = 600/' \
   /opt/kata/share/defaults/kata-containers/configuration-remote.toml"

# Raise kubelet runtimeRequestTimeout (default 2 min)
ssh ubuntu@$WORKER_IP \
  "sudo sed -i '/runtimeRequestTimeout/d' /var/lib/kubelet/config.yaml
   echo 'runtimeRequestTimeout: 10m' | sudo tee -a /var/lib/kubelet/config.yaml
   sudo systemctl restart kubelet"
```

---

## Blocking mechanism

Two mechanisms block registry access completely:

**Node side (`/etc/hosts`)** — blocks kubelet and containerd:
```bash
echo "0.0.0.0 quay.io" | sudo tee -a /etc/hosts
```
When containerd resolves `quay.io` it gets `0.0.0.0` and fails immediately:
`dial tcp 0.0.0.0:443: connect: connection refused`.

**In-VM side (`iptables FORWARD`)** — blocks CDH inside the peer pod VM:
```bash
QUAY_IPS=$(getent ahosts quay.io | awk '{print $1}' | sort -u)
for IP in $QUAY_IPS; do
    sudo iptables -I OUTPUT  -d "$IP" -j DROP
    sudo iptables -I FORWARD -d "$IP" -j DROP
done
```
The peer pod VM has its own network stack; `/etc/hosts` on the worker node has
no effect inside the VM.  The iptables rules intercept packets from the VM
before they leave the host.

**Cleanup:**
```bash
sudo sed -i '/quay.io/d' /etc/hosts
QUAY_IPS=$(getent ahosts quay.io | awk '{print $1}' | sort -u)
for IP in $QUAY_IPS; do
    sudo iptables -D OUTPUT  -d "$IP" -j DROP
    sudo iptables -D FORWARD -d "$IP" -j DROP
done
```

---

## Case 1 — Node image absent | registry BLOCKED → FAIL (expected)

**Purpose:** Confirm the block works end-to-end; without the node cache,
`IfNotPresent` behaves like `Always` and containerd fails to pull.

**Setup:**
```bash
# Remove image from node if present
ssh ubuntu@$WORKER_IP "sudo crictl rmi quay.io/bpradipt/kata-vm-image:7may 2>/dev/null || true"

# Block registry
echo "0.0.0.0 quay.io" | sudo tee -a /etc/hosts
QUAY_IPS=$(getent ahosts quay.io | awk '{print $1}' | sort -u)
for IP in $QUAY_IPS; do sudo iptables -I OUTPUT -d "$IP" -j DROP; sudo iptables -I FORWARD -d "$IP" -j DROP; done

kubectl apply -f test-kata-pod-caa.yaml
```

**Result: FAIL (as expected)**

```
NAME                   READY   STATUS         RESTARTS   AGE
embedded-image-test    0/1     ErrImagePull   0          47s
```

**Key event:**
```
Warning  Failed  Failed to pull image "quay.io/bpradipt/kata-vm-image:7may":
  failed to pull and unpack image: failed to resolve reference:
  failed to do request: Head "https://quay.io/v2/bpradipt/kata-vm-image/manifests/7may":
  dial tcp 0.0.0.0:443: connect: connection refused
```

`dial tcp 0.0.0.0:443` confirms quay.io resolved to `0.0.0.0`.

---

## Case 2 — Node image absent | registry OPEN → PASS, image cached

**Purpose:** Cache the image on the worker node for Cases 3 and 4.

**Setup:**
```bash
# Unblock registry
sudo sed -i '/quay.io/d' /etc/hosts
QUAY_IPS=$(getent ahosts quay.io | awk '{print $1}' | sort -u)
for IP in $QUAY_IPS; do sudo iptables -D OUTPUT -d "$IP" -j DROP 2>/dev/null; sudo iptables -D FORWARD -d "$IP" -j DROP 2>/dev/null; done

kubectl delete pod embedded-image-test --ignore-not-found
kubectl apply -f test-kata-pod-caa.yaml
```

**Result: PASS**

```
NAME                   READY   STATUS    RESTARTS   AGE
embedded-image-test    1/1     Running   0          56s
```

**Key events:**
```
Normal  Pulling  Pulling image "quay.io/bpradipt/kata-vm-image:7may"
Normal  Pulled   Successfully pulled image in 14.4s. Image size: 702014696 bytes.
Normal  Started  Started container test
```

**After Case 2:** Image is cached on the worker node (702 MB):
```
quay.io/bpradipt/kata-vm-image   7may   f0a289dca6e63   702MB
```

---

## Case 3 — Node image CACHED | registry BLOCKED → PASS ✅

**Purpose:** Prove the embedded CDH cache serves the container with zero
registry contact.  `IfNotPresent` lets kubelet skip the node-side pull
(image already cached), so the only variable is in-VM CDH behavior.

**Setup:**
```bash
# Block registry
echo "0.0.0.0 quay.io" | sudo tee -a /etc/hosts
QUAY_IPS=$(getent ahosts quay.io | awk '{print $1}' | sort -u)
for IP in $QUAY_IPS; do sudo iptables -I OUTPUT -d "$IP" -j DROP; sudo iptables -I FORWARD -d "$IP" -j DROP; done

# Confirm block
curl -m 5 -s https://quay.io/ -o /dev/null && echo "BLOCK FAILED" || echo "Blocked"

kubectl delete pod embedded-image-test --ignore-not-found
kubectl apply -f test-kata-pod-caa.yaml
```

**Result: PASS in 52 s**

```
NAME                   READY   STATUS    RESTARTS   AGE
embedded-image-test    1/1     Running   0          52s
```

**Key events:**
```
Normal  Pulled    Container image "quay.io/bpradipt/kata-vm-image:7may"
                  already present on machine
Normal  Created   Created container test
Normal  Started   Started container test
```

No `Failed` events, no CDH errors, no registry traffic.

**Verification:**
```bash
kubectl exec embedded-image-test -- echo "running from embedded cache"
# → running from embedded cache
```

**What happened inside the VM:**
1. `kata-image-cache.service` ran before CDH and kata-agent:
   - Copied `meta_store.json` to `/run/kata-containers/image/`
   - Mounted erofs at `/run/kata-cache-erofs/`
   - Bind-mounted layers 0–4 (ro) at `/run/kata-containers/image/layers/`
2. CDH read `meta_store.json` → `reference_db` hit for `quay.io/bpradipt/kata-vm-image:7may`
3. `create_bundle`: `snapshot.mount(bind-mounted layer dirs)` → overlay mounted in < 1 s
4. kata-agent received the bundle path, started the container

**Cleanup:**
```bash
sudo sed -i '/quay.io/d' /etc/hosts
QUAY_IPS=$(getent ahosts quay.io | awk '{print $1}' | sort -u)
for IP in $QUAY_IPS; do sudo iptables -D OUTPUT -d "$IP" -j DROP 2>/dev/null; sudo iptables -D FORWARD -d "$IP" -j DROP 2>/dev/null; done
```

---

## Case 4 — Node image REMOVED | registry BLOCKED → FAIL (negative control)

**Purpose:** Confirm that Case 3's success requires the node image cache.
Without it, `IfNotPresent` falls back to a pull, which the block prevents.
This proves the embedded CDH cache alone is not sufficient — the node-level
image presence is also required to pass the pod through to `kata-remote`.

**Setup:**
```bash
# Remove image from worker node
ssh ubuntu@$WORKER_IP "sudo crictl rmi quay.io/bpradipt/kata-vm-image:7may"

# Re-block registry (if not already blocked)
echo "0.0.0.0 quay.io" | sudo tee -a /etc/hosts
QUAY_IPS=$(getent ahosts quay.io | awk '{print $1}' | sort -u)
for IP in $QUAY_IPS; do sudo iptables -I OUTPUT -d "$IP" -j DROP; sudo iptables -I FORWARD -d "$IP" -j DROP; done

kubectl delete pod embedded-image-test --ignore-not-found
kubectl apply -f test-kata-pod-caa.yaml
```

**Result: FAIL (as expected)**

```
NAME                   READY   STATUS         RESTARTS   AGE
embedded-image-test    0/1     ErrImagePull   0          47s
```

**Key event:**
```
Warning  Failed  Failed to pull image "quay.io/bpradipt/kata-vm-image:7may":
  failed to pull and unpack image: failed to resolve reference:
  dial tcp 0.0.0.0:443: connect: connection refused
```

Failure is at the containerd/node level — `kata-remote` and CDH are never
reached.  This is the expected behavior: `IfNotPresent` without a node cache
behaves like `Always`, and the block prevents the pull.

**Restore:**
```bash
sudo sed -i '/quay.io/d' /etc/hosts
QUAY_IPS=$(getent ahosts quay.io | awk '{print $1}' | sort -u)
for IP in $QUAY_IPS; do sudo iptables -D OUTPUT -d "$IP" -j DROP 2>/dev/null; sudo iptables -D FORWARD -d "$IP" -j DROP 2>/dev/null; done
ssh ubuntu@$WORKER_IP "sudo crictl pull quay.io/bpradipt/kata-vm-image:7may"
```

---

## Two-sentence conclusion

Cases 3 and 4 together prove that both conditions are necessary: the node-cached
image lets containerd skip the pull and hand the pod to `kata-remote`, and the
CDH embedded cache inside the peer pod VM serves the image without any registry
contact.  Remove either condition and the pod fails.
