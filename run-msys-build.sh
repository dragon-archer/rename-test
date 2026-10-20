#!/usr/bin/bash
set -eu
export LC_ALL=C

runs=${1:-20}
jobs=${2:-8}
output=${3:-results-msys}
case $runs:$jobs in *[!0-9:]*|:*|*:) exit 2 ;; esac
if ((runs < 1 || runs > 100 || jobs < 1 || jobs > 32)); then exit 2; fi
source_directory=$(cd -- "$(dirname -- "$0")" && pwd)
mkdir -p -- "$output"
output=$(cd -- "$output" && pwd)
{
    uname -a
    pacman -Q msys2-runtime gcc make libtool
    printf 'runs=%s jobs=%s artificial_scanners=0\n' "$runs" "$jobs"
} > "$output/environment.log"
printf 'sample,direction,outcome\n' > "$output/results.csv"
attempts=0
denied=0
for ((sample = 1; sample <= runs; ++sample)); do
    directory=$(mktemp -d "$output/run-$sample-XXXXXXXX")
    mkdir "$directory/gcc"
    if ! /usr/bin/make -j"$jobs" -C "$directory/gcc" \
        -f "$source_directory/build-load.mk" SOURCE="$source_directory/build-load.c" \
        check > "$directory/build.log" 2>&1; then
        printf '%s,build,invalid\n' "$sample" >> "$output/results.csv"
        printf 'BUILD_FAILURE sample=%d log=%s/build.log\n' "$sample" "$directory" >&2
        exit 2
    fi
    for direction in forward reverse; do
        if [[ $direction == forward ]]; then from=gcc; to=stage1-gcc; else from=stage1-gcc; to=gcc; fi
        ((attempts+=1))
        if /usr/bin/mv -T -- "$directory/$from" "$directory/$to" 2> "$directory/$direction.log"; then
            outcome=success
        elif /usr/bin/grep -q 'Permission denied' "$directory/$direction.log"; then
            outcome=access_denied
            ((denied+=1))
        else
            cat "$directory/$direction.log" >&2
            printf '%s,%s,invalid\n' "$sample" "$direction" >> "$output/results.csv"
            exit 2
        fi
        printf '%s,%s,%s\n' "$sample" "$direction" "$outcome" >> "$output/results.csv"
        printf 'sample=%d direction=%s outcome=%s\n' "$sample" "$direction" "$outcome"
        if [[ $outcome == access_denied ]]; then break; fi
    done
done
printf 'MSYS_BUILD_RESULT runs=%d rename_attempts=%d denied=%d jobs=%d\n' \
    "$runs" "$attempts" "$denied" "$jobs" | tee "$output/summary.txt"
if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    {
        printf '## MSYS make/libtool build, make -j%s\n\n' "$jobs"
        printf 'Completed builds: %d. Actual rename attempts: %d. Permission denied: %d.\n' "$runs" "$attempts" "$denied"
        printf 'No artificial scanner or rename retry. Forward and reverse results are separated in CSV.\n'
    } >> "$GITHUB_STEP_SUMMARY"
fi
