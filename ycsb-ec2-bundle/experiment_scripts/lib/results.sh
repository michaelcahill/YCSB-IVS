#!/usr/bin/env bash
# Part of the experiment runner; sourced, never executed directly.

# Results CSV writer: merges previously stored rows with the YCSB summary just
# parsed from $INPUT_FILE, widening the header when a new measurement label
# appears. Column order is the backend's metric names (metrics::header) plus the
# base header.
write_result() {
    local first="$1" field_name stats_csv base_header previous temp_result r
    local -a stats_values=("$cpu" "$memory")
    for field_name in "${metric_field_names[@]}"; do
        stats_values+=("${!field_name}")
    done
    stats_csv=$(IFS=','; echo "${stats_values[*]}")
    r=$((STEPS_PER_EPOCH * (${epoch:-1} - 1) + ${step:-0}))
    [[ "$phase" != load ]] || r=0
    base_header="Epoch,Phase,Recordcount,Readallfields,Requestdist,Operation,$(metrics::header),Readprop,Updateprop,Scanprop,Insertprop,Extendprop,Runtime(ms),Throughput(ops/sec)"
    previous="$OUTPUT_FILE"
    [[ "$first" != TRUE ]] || previous=/dev/null
    temp_result=$(mktemp "${OUTPUT_FILE}.tmp.XXXXXX")
    log "START CSV write database statistics phase=$phase"
    if ! awk -F, -v OFS=, -v base="$base_header" -v previous="$previous" \
        -v step="$r" -v phase="$phase" -v records="${recordcount:-}" \
        -v allfields="${readallfields:-}" -v distribution="${requestdistribution:-}" \
        -v readdist="${readrequestdistribution:-}" -v updatedist="${updaterequestdistribution:-}" \
        -v stats="$stats_csv" -v readprop="${readproportion:-}" \
        -v updateprop="${updateproportion:-}" -v scanprop="${scanproportion:-}" \
        -v insertprop="${insertproportion:-}" -v extendprop="${extendproportion:-}" '
        function trim(x) { sub(/^[[:space:]]+/, "", x); sub(/[[:space:]]+$/, "", x); return x }
        BEGIN { base_count=split(base, base_fields, ",") }
        FILENAME == previous {
            if (FNR == 1) {
                for (i=base_count+1; i<=NF; i++) { labels[++nlabels]=$i; known[$i]=1 }
                old_width=NF
            } else { old[++nold]=$0 }
            next
        }
        /^\[(OVERALL|INSERT|READ|UPDATE|SCAN|EXTEND|READ-MODIFY-WRITE)\],/ {
            op=trim($1); gsub(/[][]/, "", op)
            label=trim($2); value=trim($3)
            if (op == "OVERALL") { overall[label]=value; next }
            if (!(op in seen)) { operations[++nops]=op; seen[op]=1 }
            if (!(label in known)) { labels[++nlabels]=label; known[label]=1 }
            measurements[op,label]=value
        }
        END {
            if (!nops || !("RunTime(ms)" in overall) || !("Throughput(ops/sec)" in overall)) {
                print "[ERROR] Missing YCSB operation/overall metrics; CSV left unchanged." > "/dev/stderr"
                exit 1
            }
            printf "%s", base
            for (i=1; i<=nlabels; i++) printf ",%s", labels[i]
            printf "\n"
            for (j=1; j<=nold; j++) {
                printf "%s", old[j]
                for (i=old_width+1; i<=base_count+nlabels; i++) printf ","
                printf "\n"
            }
            for (j=1; j<=nops; j++) {
                op=operations[j]; dist=distribution
                if (op == "READ" && readdist != "") dist=readdist
                if (op == "UPDATE" && updatedist != "") dist=updatedist
                printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s", \
                    step, phase, records, allfields, dist, op, stats, readprop, updateprop, \
                    scanprop, insertprop, extendprop, overall["RunTime(ms)"], overall["Throughput(ops/sec)"]
                for (i=1; i<=nlabels; i++) printf ",%s", measurements[op,labels[i]]
                printf "\n"
            }
        }
    ' "$previous" "$INPUT_FILE" > "$temp_result"; then
        rm -f "$temp_result"
        return 1
    fi
    mv "$temp_result" "$OUTPUT_FILE"
    log "END CSV write output=$OUTPUT_FILE"
}
