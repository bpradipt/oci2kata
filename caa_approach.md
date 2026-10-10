# CAA Approach

This file is superseded by the full implementation docs:

- **[embedding-container-image-in-caa.md](embedding-container-image-in-caa.md)**:
  build approach, architecture, bind-mount design, deployment guide
- **[experiments-caa.md](experiments-caa.md)**: four-case validation with
  setup, results, and registry-blocking methodology
- **[experiments-byom.md](experiments-byom.md)**: end-to-end validation on the
  local CAA BYOM kind setup using the adapted latest-release branches
- **[blog-embedded-images.md](blog-embedded-images.md)**: plain-English
  write-up of the approach, the code changes, and the test results

CAA changes (mkosi Dockerfile, Makefile target, systemd service):
```
https://github.com/bpradipt/cloud-api-adaptor  branch: image-cache-0.21.1
src/cloud-api-adaptor/podvm-mkosi/
```
