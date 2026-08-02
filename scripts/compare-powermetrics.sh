#!/bin/bash

set -euo pipefail

readonly script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly project_directory="$(cd -- "$script_directory/.." && pwd)"
readonly sample_count="${1:-10}"
readonly interval_milliseconds="${2:-3000}"
readonly load_worker_count="${3:-0}"

if [[ ! "$sample_count" =~ ^[1-9][0-9]*$ ]]; then
    echo "Sample count must be a positive integer." >&2
    exit 64
fi
if [[ ! "$interval_milliseconds" =~ ^[1-9][0-9]*$ ]]; then
    echo "Interval must be a positive number of milliseconds." >&2
    exit 64
fi
if [[ ! "$load_worker_count" =~ ^[0-9]+$ ]]; then
    echo "Load-worker count must be a nonnegative integer." >&2
    exit 64
fi

readonly build_directory="$(mktemp -d "${TMPDIR:-/tmp}/battery-hogger-validation.XXXXXX")"
readonly probe="$build_directory/CPUAttributionProbe"
load_worker_pids=()

cleanup() {
    local worker_pid
    for worker_pid in "${load_worker_pids[@]}"; do
        kill "$worker_pid" 2>/dev/null || true
    done
    for worker_pid in "${load_worker_pids[@]}"; do
        wait "$worker_pid" 2>/dev/null || true
    done
    rm -rf -- "$build_directory"
}
trap cleanup EXIT

xcrun swiftc \
    -O \
    -target arm64-apple-macosx13.0 \
    "$project_directory/Daemon/PackageCPUEnergyReader.swift" \
    "$project_directory/Tools/CPUAttributionProbe.swift" \
    -o "$probe"

echo "Administrator access is required because powermetrics is root-only."
sudo -v

if (( load_worker_count > 0 )); then
    echo "Starting $load_worker_count controlled CPU load worker(s) and warming up for 5 seconds."
    for ((worker_index = 0; worker_index < load_worker_count; worker_index++)); do
        /usr/bin/yes > /dev/null &
        load_worker_pids+=("$!")
    done
    sleep 5
fi

echo "Comparing $sample_count synchronized samples at ${interval_milliseconds}ms intervals."
sudo -n "$probe" "$sample_count" "$interval_milliseconds"
