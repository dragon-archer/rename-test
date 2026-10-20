# Windows directory rename contention

Each probe performs exactly 100 scheduled rename attempts. Before each attempt
it creates and closes 32 new empty files in the current directory's `child`.
A successful rename switches between `gcc` and `stage1-gcc`; a failed rename
leaves the source name unchanged. The next attempt follows its normal file
workload, without an immediate retry or recovery loop. Scanner processes
normally enumerate the tree and close their handles; no delay or deliberate
handle retention is added. Setup errors and unsupported APIs stop the probe.

## CI

- Windows labels: `windows-2022`, `windows-2025`, `windows-latest`.
- Concurrent scanners: 16, 0, 1, 4. The 16-scanner control is mandatory and runs first.
- Methods: `movefile` (MoveFileEx), `infoex` (FileRenameInfoEx), `posix` (same API plus POSIX_SEMANTICS).
- Default: 20 process runs per group, 100 rename attempts each. API order rotates each sample.
- Only CI builds with MSVC. Logs, CSV, summary, binary, and environment metadata are artifacts.

### Defender and MSYS build comparison

Each Windows label now runs three isolated jobs: Defender `as-is`, `on`, and
`off` (nine jobs total). `as-is` only records the image's original settings.
The other two jobs clear path/process/extension exclusions and disable automatic
server-role exclusions equally, then request real-time protection on or off.
This is not uninstalling Defender or disabling all of its components. Actual
status and preferences are saved before configuration, after configuration,
and after the workloads in `metadata/defender/`. A blocked switch or state
drift makes the experiment invalid and fails the job.

After installing MSYS2 `gcc`, `make`, and `libtool`, every job runs the existing
16/0/1/4 scanner comparison, then `run-msys-build.sh` with `make -j1` and `-j8`.
The latter has no artificial scanner: compile eight objects, link a library and
program, execute it, wait for make to exit, then immediately rename the build
directory forward and back. A failed forward rename skips the reverse attempt;
CSV and summary record actual attempts. Build errors are not rename failures.
All build logs and results are uploaded from `results-msys-j1/` and
`results-msys-j8/`, including when another experimental step fails.

`ci-defender.ps1` refuses to query or change Defender outside GitHub-hosted
Windows CI. For a local build-only smoke test, use MSYS2 Bash:

```bash
/usr/bin/bash run-msys-build.sh 1 8 /tmp/rename-build-smoke-unique
```

Use a fresh output directory. Local validation does not require reproducing a
rename error. These newly wired Defender jobs still need a remote CI run; local
flow validation is not evidence that remote Defender state changes succeed.

The previous stop-at-first-failure version, run 39385795974 (2026-10-20),
recorded the same pattern on all three labels:
every nonzero-scanner group failed with Win32 error 5 in 20/20 runs, and every
zero-scanner group passed 100 rounds in 20/20 runs. POSIX_SEMANTICS did not prevent
this source-directory contention. The two 2025 labels used the same image.

## Interpretation

The summary reports both runs with any Win32 error 5 and total Win32 error 5
failures divided by completed rename attempts. CSV retains attempts, successes,
Win32 error 5, other errors, and scanner activity for every process run. Other
rename errors are counted separately and fail the job after saving results.
Unsupported APIs and invalid scanner results are not counted as passes.

Consecutive attempts share one tree and scanner state, so their outcomes are
correlated. The call failure rate is an observed fraction, not 100 independent
trials. Compare the distribution of per-run rates and repeat on independent
runner VMs before claiming an OS difference. Saturation may persist even with
call-level counts. The two 2025 labels are not distinct OS versions.

This protocol differs from the old 100 rounds of two renames: it performs 100
attempts, creates files before each, and continues after failure. Do not directly
compare its call rates with the old run-level frequency. The new protocol still
needs CI compilation and execution; old artifacts use the old output format.

Targets do not already exist, so this is not a POSIX target-replacement test.
The shared feature with GCC bootstrap is renaming a populated parent directory
after file operations have closed their handles. Unlike a real stage transition,
this test creates empty files, injects continuous scanning, and repeatedly
renames the same tree. It is a contention mechanism test, not a reconstruction
of the real workload or identification of its holder. The completed CI run
does not demonstrate a recent Windows regression or equivalent risk across
versions; every nonzero-scanner group merely saturated the old metric.
Hosted jobs are VMs, not a Windows container isolation comparison.
