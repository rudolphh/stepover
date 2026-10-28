# Runtime CI: the GitHub macOS runner

Measured by `.github/workflows/runtime-spike.yml`, run 40608516916 on 2026-10-28 (branch
`runtime-ci/pipeline`), for plan 1 of the automatic runtime builds
(`docs/superpowers/plans/2026-10-27-runtime-build-pipeline.md`).

```
machine=Apple M1 (Virtual), arm64, macOS 15.7.9, Xcode 16.4
cores=3
memory_gb=7
free_disk_gb=42
rosetta=yes
metal=Apple Paravirtual device
metal-queue=ok
brew_minutes=1
```

**Gate:** passed. Rosetta is there and 42 GB is free, above the 15 GB the build needs
(`STEPOVER_CI_MIN_DISK_GB`). Every build also checks both itself, in the workflow's preflight step.

**Metal:** the runner has a paravirtual GPU that creates a Metal device and command queue, so the
workflow runs the Direct3D checks (`check-runtime.sh --metal`). If D3DMetal turns out not to work on
that device, set the repository variable `STEPOVER_CI_METAL` to `false` to skip them.
