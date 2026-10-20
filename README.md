# Windows directory rename contention

Each probe performs exactly 100 scheduled rename attempts. Before each attempt
it creates and closes 32 new empty files in the current directory's `child`.
A successful rename switches between `gcc` and `stage1-gcc`; a failed rename
leaves the source name unchanged. The next attempt follows its normal file
workload, without an immediate retry or recovery loop. Scanner processes
normally enumerate the tree and close their handles; no delay or deliberate
handle retention is added. Setup errors and unsupported APIs stop the probe.

## CI

- Windows labels: `windows-2022`, `windows-2025`, with at most two parallel jobs.
- Concurrent scanners: 0 and 1. Saturated 4/16-scanner groups and the duplicate
	`windows-latest` matrix entry are removed from the default workflow.
- Methods: `movefile` (MoveFileEx), `infoex` (FileRenameInfoEx), `posix` (same API plus POSIX_SEMANTICS).
- Default: 5 process runs per scanner/API group, 100 rename attempts each.
	Scanner-count and API order rotate each sample.
- Directory access: 3 samples in both the checkout workspace and `RUNNER_TEMP`,
	using `infoex` to distinguish source-open from rename-stage failures. Each
	sample tests no added scan, passive recursive notifications, shallow ancestor
	enumeration, shallow enumeration of the renamed directory, and enumeration
	inside its `child`. Location and scope order rotate each sample.
- Only CI builds with MSVC. Logs, CSV, summary, binary, and environment metadata are artifacts.
- Defender state is recorded before and after, without changing it. Process
	names/IDs and file system filter names are also recorded; these snapshots
	alone do not identify the holder at a failed rename.

The default now has two jobs and 60 probe processes per job: 30 scanner/API
comparisons and 30 directory-access comparisons. It no longer installs MSYS2
unless the optional build comparison is selected. Results and raw evidence are
uploaded from `results/`, `results-depth/`, and `metadata/`, together with the
MSVC executable. Test trees under `RUNNER_TEMP` are separate from artifact logs.

Manual workflow inputs:

| Input | Default | Meaning |
| --- | --- | --- |
| `runs` | 5 | Process runs per scanner/API group, 1-100 |
| `depth_runs` | 3 | Samples per location/scope group, 1-100 |
| `msys_build` | false | Install MSYS2 and run the optional build comparison |
| `build_runs` | 3 | Builds per optional serial/parallel group, 1-100 |

The directory comparison is implemented by `run-depth-tests.ps1`, which calls
`test-scan-depth.ps1` and combines per-sample CSVs into `results-depth/results.csv`
and a job summary. Notification mode only queues events on an ancestor; it does
not perform a scan in a callback. Enumeration modes use at most one added
scanner. Counts include actual notification events, scan activity, source-open
denials, and rename-stage denials. All calls within a process remain correlated.
If the no-scan workspace baseline fails, do not attribute failures in other
workspace groups solely to their added observer.

The revised workflow passed actionlint and the PowerShell entrypoints were
smoke-tested with an existing CI executable. It has not yet been run remotely;
the historical results below are not results of this revised matrix.

### Optional MSYS build comparison and previous Defender matrix

The previous workflow used nine jobs: three Windows labels crossed with
Defender `as-is`, `on`, and `off`. Those state-changing treatments are not part
of the revised workflow. `ci-defender.ps1` retains them for historical
reproducibility, but CI now calls only `-State as-is` before and after the tests.
It does not change protection or exclusions. Historical on/off results and
their limitations are documented below.

Only when manually dispatched with `msys_build=true`, the workflow installs
MSYS2 `gcc`, `make`, and `libtool`, then runs `run-msys-build.sh` with `make -j1`
and `-j8`, using `build_runs` samples per group.
The latter has no artificial scanner: compile eight objects, link a library and
program, execute it, wait for make to exit, then immediately rename the build
directory forward and back. A failed forward rename skips the reverse attempt;
CSV and summary record actual attempts. Build errors are not rename failures.
Available build logs and results are uploaded from `results-msys-j1/` and
`results-msys-j8/` even if a later step fails.

`ci-defender.ps1` refuses to query or change Defender outside GitHub-hosted
Windows CI. For a local build-only smoke test, use MSYS2 Bash:

```bash
/usr/bin/bash run-msys-build.sh 1 8 /tmp/rename-build-smoke-unique
```

Use a fresh output directory. Local validation does not require reproducing a
rename error. Run 39393284118 completed the remote Defender experiment for the
five jobs with artifacts; the four jobs without artifacts cannot be substituted
with local flow validation.

The previous stop-at-first-failure version, run 39385795974 (2026-10-20),
recorded the same pattern on all three labels:
every nonzero-scanner group failed with Win32 error 5 in 20/20 runs, and every
zero-scanner group passed 100 rounds in 20/20 runs. POSIX_SEMANTICS did not prevent
this source-directory contention. The two 2025 labels used the same image.

## Run 39393284118 (2026-10-20)

Commit: `64b5ea38bc34948a39609ed5f4def51c0426c02a`. Nine jobs were scheduled;
five supplied complete artifacts. Four red jobs have the annotation
"The hosted runner lost communication with the server": Windows 2022 on/off,
Windows 2025 off, and windows-latest on. Their logs returned `BlobNotFound`
when retrieved. This is an infrastructure outcome, not a recorded rename-test
assertion failure; its cause is unknown. Do not attribute it to Defender changes
or scanner CPU pressure without further evidence, or count missing artifacts
as successful or failed experimental cells.

Downloaded evidence is preserved locally in
`work/ci-39393284118-qLkrWihA/`. Each complete artifact contains 240 rows:
20 samples x four scanner counts x three methods. The table below uses only
`movefile` and reports denied calls / 2,000 completed calls per cell.

| Complete job | 0 scanners | 1 scanner | 4 scanners | 16 scanners |
| --- | --- | --- | --- | --- |
| windows-2022 / as-is | 0 | 1476 | 1998 | 1994 |
| windows-2025 / as-is | 0 | 1503 | 1993 | 1993 |
| windows-2025 / on | 0 | 1599 | 1994 | 1998 |
| windows-latest / as-is | 0 | 1510 | 1984 | 1993 |
| windows-latest / off | 0 | 1512 | 1981 | 1994 |

- Across all three methods in these five jobs, zero-scanner groups completed
	300 process runs and 30,000 rename attempts with no denial or other error.
- `infoex` and `posix` showed the same pressure-dependent pattern. All recorded
	failures in those groups occurred at `phase=FileRenameInfoEx`, not
	`phase=open-source`. No unsupported API or non-target rename error was
	recorded in the five complete artifacts.
- The serial and parallel no-scanner MSYS make/libtool groups completed
	200 builds and 400 actual forward/reverse rename attempts, with no denial.
	This small workload did not reproduce the original GCC failure.
- Windows 2022 was build `20348.5622`, image `20261012.333.1`; both 2025 labels
	were build `26100.33438`, image `20261007.264.1`. Scanner contention therefore
	reproduces on 2022 too, but saturation and one VM per matrix cell prevent a
	defensible conclusion about relative OS risk.
- All three as-is jobs had effective real-time protection false and C:/D:
	exclusions. The complete on job had real-time protection true and no
	path/process/extension exclusions; the complete off job had it false with
	exclusions cleared. Status was checked after configuration and after tests.
	Real-time scanning is not necessary for the artificial contention result.
	This is not a test of removing Defender, disabling every filter, or proving
	that Defender cannot affect the real GCC workload. Missing cells leave the
	intended factorial comparison incomplete.

The failure fractions are descriptive counts of correlated calls. In
particular, 16-scanner results near 100% provide little resolution for small
effects. Continuous scanners are an injected cause of contention, not evidence
that a similar process actually held the original GCC tree.

## Local scan-depth control (2026-10-20)

`test-scan-depth.ps1` reuses an existing fixed-attempt executable; it does not
compile or change it. Evidence always goes to this repository's `work/`.
`-TestParent` selects a unique test tree, separately from evidence. Each scope
uses a fresh subtree; scopes run in fixed order. This is an artificial mechanism
control, not a natural failure-rate estimate. No deliberate handle retention,
sleep, rename retry, or security-state change is added.

An initial run inside this workspace had 28/100 denials even without the added
scanner (`work/scan-depth-c4b660c2969f4695b30f753cfd21a4ba/`). That baseline is
contaminated by an unknown background condition; its shallow-scanner denials
cannot be attributed to the test's added scan.

The follow-up placed managed test trees under `D:/msys64/tmp`, outside the
workspace, while keeping all logs in this repository. Results are denied calls
out of 100 scheduled calls per group:

| Enumeration scope | MoveFileEx | FileRenameInfoEx | POSIX flag |
| --- | --- | --- | --- |
| No added scan | 0 | 0 | 0 |
| Ancestor, nonrecursive | 0 | 0 | 0 |
| gcc/stage1-gcc itself, nonrecursive | 0 | 0 | 0 |
| gcc/child or stage1-gcc/child, nonrecursive | 67 | 81 | 74 |
| Recursive test root | not run | 71 | not run |

All scope groups other than none completed enumeration passes; no non-target
probe errors were observed. `infoex` and `posix` again failed at the rename API,
not source-handle open. Evidence directories in `work/`:

- `scan-depth-c0ea16e182164a72a2122097fd66908f`: infoex.
- `scan-depth-38f00a18d6084e0cbbcd731c793fd275`: movefile.
- `scan-depth-ba88d71e85b24b73a18f7d4009f664ed`: posix.

The executable is from the windows-2025/as-is artifact, SHA256
`3ad5bf2138188f615604ebcb4f3fff8ec39b9f4b098c08f3d191120ac4016efb`.
The user's original MSVC executable remains unchanged, SHA256
`af0b401ea7730271f23e18d85c08b9af2c43d249c0473df1a6052ced976d49d1`.
The two binaries implement different protocols; do not combine their metrics.

From the repository root in PowerShell, using the downloaded artifact:

```powershell
$exe = './work/ci-39393284118-qLkrWihA/rename-windows-2025-defender-as-is-1/build/rename-win32.exe'
./test-scan-depth.ps1 -Executable $exe -Method infoex -TestParent D:/msys64/tmp
```

The narrower signal is access inside the renamed directory's descendant, not
just enumerating its ancestor or itself. Each combination has one 100-call
sample; enumeration volume and duration differ by scope. This does not establish
that shallow enumeration is always harmless or identify the natural holder.
Prefer capturing the actual descendant accessor at the failing rename over
adding scanner pressure or inferring a recent Windows regression. The current
CI data does not identify the original GCC failure's external process.

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
compare its call rates with the old run-level frequency. Run 39393284118 used
the new protocol; older artifacts use the old output format.

Targets do not already exist, so this is not a POSIX target-replacement test.
The shared feature with GCC bootstrap is renaming a populated parent directory
after file operations have closed their handles. Unlike a real stage transition,
this test creates empty files, injects continuous scanning, and repeatedly
renames the same tree. It is a contention mechanism test, not a reconstruction
of the real workload or identification of its holder. The completed CI run
does not demonstrate a recent Windows regression or equivalent risk across
versions; every nonzero-scanner group merely saturated the old metric.
Hosted jobs are VMs, not a Windows container isolation comparison.
