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

## First end-to-end build

Run 40627363411 on 2026-10-28 built CrossOver 26.3.0 (no newer source was out) and kept the runtime as
the artifact `stepover-runtime-cx26.3` (sha256 `7575be24…d765`, 289 MB). 53 minutes from start to
upload:

| Step | Minutes |
|---|---|
| Host libraries | 9 |
| Wine | 29 |
| DXVK | 8 |
| Runtime | 1 |
| Checks | 1 |
| Pack and upload | 3 |

Checks: `ok files`, `ok boot`, `ok program`, `ok plugin`, `ok previous` (a bottle made by the 0.2.2
runtime runs on the new one), `skip metal`.

**Metal on the runner:** the previous run (40621955718) ran the Direct3D checks; `d3d11.exe` printed
nothing within 300 seconds on the Apple Paravirtual device, so D3DMetal doesn't run on the runner's
virtual GPU. The repository variable `STEPOVER_CI_METAL` is set to `false`. The Direct3D checks still
run in the local test suite (`runtime/tests/test-check.sh`), and a CrossOver jump that could need a
newer D3DMetal gets the spec's manual approval when publishing is turned on (plan 5).

**Compared with the runtime built on the maintainer's Mac:** the same 4,832 files. D3DMetal, DXMT,
Mono, Gecko and `wine.inf` are byte-identical (so bottles don't redo their setup); compiled Wine, DXVK
and library binaries differ in bytes, as expected from a different machine and compiler versions.

Two earlier runs found real problems: `build-dxvk.sh` couldn't find its patches from a fresh tree (fixed),
and D3DMetal doesn't run on the virtual GPU (above).
