# Windows directory rename contention

The probe creates and closes 32 empty files in `gcc/child`, then renames
`gcc -> stage1-gcc -> gcc`. It stops at the first error or after 100 rounds.
Separate scanner processes normally enumerate the tree and close their handles;
there are no rename retries, delays, or deliberately retained handles.

## CI

- Windows labels: `windows-2022`, `windows-2025`, `windows-latest`.
- Concurrent scanners: 16, 0, 1, 4. The 16-scanner control is mandatory and runs first.
- Methods: `movefile` (MoveFileEx), `infoex` (FileRenameInfoEx), `posix` (same API plus POSIX_SEMANTICS).
- Default: 20 process runs per group. API order rotates each sample.
- Only CI builds with MSVC. Logs, CSV, summary, binary, and environment metadata are artifacts.

Run 39385795974 (2026-10-20) recorded the same pattern on all three labels:
every nonzero-scanner group failed with Win32 error 5 in 20/20 runs, and every
zero-scanner group passed 100 rounds in 20/20 runs. POSIX_SEMANTICS did not prevent
this source-directory contention. The two 2025 labels used the same image.

## Interpretation

Frequency is per process run, not per rename call. A 100% result can hide
differences in time to first failure; the CSV retains the failing round.
Unsupported APIs and invalid scanner results are not counted as passes.
Targets do not already exist, so this is not a POSIX target-replacement test.
The experiment demonstrates artificial scan contention, not the original GCC
failure's actual holder or a Windows version regression. Hosted jobs are VMs,
not a Windows container isolation comparison.
