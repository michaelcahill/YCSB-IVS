#!/usr/bin/env bash
# Part of the experiment runner; sourced, never executed directly.

# Result-row measurements that are not backend-specific: how busy the database host looked
# during a phase. Which statistics columns appear next to them (and how they are collected)
# is a backend detail: each backend publishes its own list with backend::metric_names, and
# write_result() emits exactly those columns in exactly that order.

# Sample the database server's OS account. A backend whose server runs under another or
# several accounts reports host_os_user in backend::info; without it the two columns stay
# present but empty, so the CSV schema never depends on which backend ran.
collect_cpu_memory_metrics() {
    local account="${HOST_OS_USER:-}"
    if [[ -z "$account" ]]; then
        cpu=0
        memory=0
        return 0
    fi
    cpu=$(ps -u "$account" -o %cpu= | awk '{sum += $1} END {print sum + 0}')
    memory=$(ps -u "$account" -o %mem= | awk '{sum += $1} END {print sum + 0}')
}

# Column names contributed by collect_cpu_memory_metrics plus the backend's own metrics.
metrics::header() {
    local -a names=()
    mapfile -t names < <(backend::metric_names)
    # A backend may report no database statistics at all (MongoDB). The two OS columns are
    # always there, and an empty list must not add a nameless column to the CSV.
    if (( ${#names[@]} == 0 )); then
        printf 'CPU,Memory\n'
    else
        printf 'CPU,Memory,%s\n' "$(IFS=','; echo "${names[*]}")"
    fi
}
