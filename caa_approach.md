# CAA Approach

This file is superseded by the full implementation docs:

- **[embedding-container-image-in-caa.md](embedding-container-image-in-caa.md)** —
  build approach, architecture, bind-mount design, deployment guide
- **[experiments-caa.md](experiments-caa.md)** — four-case validation with
  setup, results, and registry-blocking methodology

CAA changes (mkosi Dockerfile, Makefile target, systemd service):
```
https://github.com/bpradipt/cloud-api-adaptor  branch: image-cache-0.21.1
src/cloud-api-adaptor/podvm-mkosi/
```
