# Automatic runtime builds: roadmap

**Spec:** `docs/superpowers/specs/2026-10-27-automatic-runtime-builds-design.md`

The spec covers five separate parts. Each gets its own plan, and each plan ends in software that works
and is tested on its own. The order is chosen so that **users have a safe way back before anything
reaches them automatically**: the pipeline only starts publishing in plan 5, after plans 2 to 4 have
shipped in an app release.

| Plan | Covers (spec sections) | Ships | Depends on |
|---|---|---|---|
| 1. Build pipeline | build-machine spike; 1 detection; 2 build; 3 checks | A daily GitHub job that builds and checks a runtime from new CrossOver source and keeps it as a workflow artifact. Publishes nothing. | none |
| 2. Runtime list and side-by-side runtimes | 4 index; 5 app side; 10 plug-in format version and `minApp` | App reads `runtime/index.json`; runtimes install next to each other; per-bottle Wine version picker; pinned indicator; pulled runtimes; disk space and offline handling. Released as an app version. | 1 (runtime names with build numbers) |
| 3. Snapshots and going back | 6; 5 (going back with no snapshot) | First-launch snapshot, restore on going back, whole-bottle clone when there's no snapshot, installed-software warning. | 2 |
| 4. Crash watcher and reports | 7; 8 | `stepover run` watcher during runtime changes, the prompt (opens Stepover), extended reports with redacted logs, Copy Report, duplicate search. | 2, 3 |
| 5. Publishing | 4 (pipeline side); 1 (config.sh commit); 10 (release-tag builds, app-release rebuilds); D3DMetal section; `release/pull-runtime.sh` | The pipeline publishes runtime releases and appends them to the index. Turned on only after an app release containing plans 2 to 4. | 1 to 4 |

Plan 1 is written in detail: `2026-10-27-runtime-build-pipeline.md`. Plans 2 to 5 are written when
the plan before them is done, so they start from what the previous one taught.
