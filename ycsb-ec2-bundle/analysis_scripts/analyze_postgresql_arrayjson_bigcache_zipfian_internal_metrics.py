from __future__ import annotations

from pathlib import Path

import numpy as np
import pandas as pd


ROOT = Path(__file__).resolve().parents[1]
JSON_BLUE_DIR = ROOT / "JSON_BLUE"
ANALYSIS_DIR = ROOT / "analysis"

RUNS = [4, 5, 6]
PHASES = ["run", "clean-run", "avg-run", "extend", "reference"]
COUNTERS = [
    "blks_read",
    "blks_hit",
    "tup_returned",
    "tup_fetched",
    "tup_inserted",
    "tup_updated",
    "buffers_checkpoint",
    "buffers_clean",
    "buffers_backend",
    "buffers_alloc",
    "checkpoint_write_time",
    "checkpoint_sync_time",
    "wal_bytes",
    "wal_records",
    "wal_fpi",
    "wal_buffers_full",
]
SUMMARY_METRICS = [
    "AverageLatency(us)",
    "Throughput(ops/sec)",
    "wal_bytes_per_op",
    "wal_records_per_op",
    "buffers_alloc_per_op",
    "buffers_clean_per_op",
    "blks_read_per_op",
    "blks_hit_per_op",
    "cache_hit_ratio",
    "checkpoint_write_time_per_op",
]
DRIVER_COLUMNS = [
    "cache_hit_ratio",
    "blks_read_per_op",
    "blks_hit_per_op",
    "tup_returned_per_op",
    "tup_fetched_per_op",
    "tup_inserted_per_op",
    "tup_updated_per_op",
    "buffers_checkpoint_per_op",
    "buffers_clean_per_op",
    "buffers_backend_per_op",
    "buffers_alloc_per_op",
    "checkpoint_write_time_per_op",
    "checkpoint_sync_time_per_op",
    "wal_bytes_per_op",
    "wal_records_per_op",
    "wal_fpi_per_op",
    "wal_buffers_full_per_op",
    "internal_inserts_per_logical_update",
]
DRIVER_LABELS = {
    "cache_hit_ratio": "Cache-hit ratio",
    "blks_read_per_op": "Block reads/op",
    "blks_hit_per_op": "Block hits/op",
    "tup_returned_per_op": "Tuples returned/op",
    "tup_fetched_per_op": "Tuples fetched/op",
    "tup_inserted_per_op": "Internal tuple inserts/op",
    "tup_updated_per_op": "Logical tuple updates/op",
    "buffers_checkpoint_per_op": "Checkpoint buffers/op",
    "buffers_clean_per_op": "Cleaner buffers/op",
    "buffers_backend_per_op": "Backend buffers/op",
    "buffers_alloc_per_op": "Buffer allocs/op",
    "checkpoint_write_time_per_op": "Checkpoint write time/op",
    "checkpoint_sync_time_per_op": "Checkpoint sync time/op",
    "wal_bytes_per_op": "WAL bytes/op",
    "wal_records_per_op": "WAL records/op",
    "wal_fpi_per_op": "WAL FPIs/op",
    "wal_buffers_full_per_op": "WAL buffers full/op",
    "internal_inserts_per_logical_update": "Internal inserts/logical update",
}


def csv_path(run: int) -> Path:
    return JSON_BLUE_DIR / f"postgresql_arrayjson_vacuum_notfull_bigcache_run{run}_zipfian_heavy_pure.csv"


def pct_change(first: float, last: float) -> float:
    if pd.isna(first) or pd.isna(last) or abs(first) < 1e-12:
        return np.nan
    return 100.0 * (last / first - 1.0)


def first_last_summary(group: pd.DataFrame, columns: list[str]) -> dict[str, float]:
    group = group.sort_values("Epoch")
    first = group.head(10)
    last = group.tail(10)
    row: dict[str, float] = {}
    for column in columns:
        first_value = float(first[column].mean(skipna=True))
        last_value = float(last[column].mean(skipna=True))
        row[f"{column}_first10"] = first_value
        row[f"{column}_last10"] = last_value
        row[f"{column}_change_pct"] = pct_change(first_value, last_value)
    return row


def load_phase_rows() -> pd.DataFrame:
    rows: list[pd.DataFrame] = []
    for run in RUNS:
        df = pd.read_csv(csv_path(run))
        df = df[df["Phase"].isin(PHASES)].copy()
        df["run"] = run
        df["Phase"] = df["Phase"].astype(str).str.lower()
        df["Operation"] = df["Operation"].astype(str).str.upper()
        df["Epoch"] = pd.to_numeric(df["Epoch"], errors="coerce")
        df["Operations"] = pd.to_numeric(df["Operations"], errors="coerce")
        df["AverageLatency(us)"] = pd.to_numeric(df["AverageLatency(us)"], errors="coerce")
        df["95thPercentileLatency(us)"] = pd.to_numeric(df["95thPercentileLatency(us)"], errors="coerce")
        df["99thPercentileLatency(us)"] = pd.to_numeric(df["99thPercentileLatency(us)"], errors="coerce")
        df["Throughput(ops/sec)"] = pd.to_numeric(df["Throughput(ops/sec)"], errors="coerce")
        for column in COUNTERS:
            df[column] = pd.to_numeric(df[column], errors="coerce")

        for phase, phase_df in df.groupby("Phase", dropna=False):
            phase_df = phase_df.sort_values("Epoch").copy()
            for column in COUNTERS:
                phase_df[f"{column}_per_op"] = phase_df[column].diff() / phase_df["Operations"]
            denom = (phase_df["blks_hit"] + phase_df["blks_read"]).replace(0, np.nan)
            phase_df["cache_hit_ratio"] = phase_df["blks_hit"] / denom
            phase_df["internal_inserts_per_logical_update"] = (
                phase_df["tup_inserted"].diff() / phase_df["tup_updated"].diff().replace(0, np.nan)
            )
            rows.append(phase_df)

    return pd.concat(rows, ignore_index=True)


def build_phase_drift(phase_rows: pd.DataFrame) -> pd.DataFrame:
    per_run_rows: list[dict[str, object]] = []
    for (run, phase), group in phase_rows.groupby(["run", "Phase"], dropna=False):
        row: dict[str, object] = {"run": run, "phase": phase}
        row.update(first_last_summary(group, SUMMARY_METRICS))
        per_run_rows.append(row)
    return pd.DataFrame(per_run_rows).sort_values(["phase", "run"]).reset_index(drop=True)


def build_driver_summary(phase_rows: pd.DataFrame) -> pd.DataFrame:
    rows: list[dict[str, object]] = []
    for (run, phase), group in phase_rows.groupby(["run", "Phase"], dropna=False):
        corr = group[DRIVER_COLUMNS + ["AverageLatency(us)", "Throughput(ops/sec)"]].corr(
            method="spearman", numeric_only=True
        )
        if "AverageLatency(us)" not in corr.columns:
            continue
        latency_corr = corr["AverageLatency(us)"].drop(
            labels=["AverageLatency(us)", "Throughput(ops/sec)"], errors="ignore"
        )
        throughput_corr = corr["Throughput(ops/sec)"].drop(
            labels=["AverageLatency(us)", "Throughput(ops/sec)"], errors="ignore"
        )
        for driver, latency_rho in latency_corr.dropna().items():
            rows.append(
                {
                    "run": run,
                    "phase": phase,
                    "driver": driver,
                    "driver_label": DRIVER_LABELS.get(driver, driver),
                    "latency_spearman_rho": latency_rho,
                    "throughput_spearman_rho": throughput_corr.get(driver, np.nan),
                }
            )
    return pd.DataFrame(rows).sort_values(["phase", "run", "driver"]).reset_index(drop=True)


def build_run_read_summary(phase_rows: pd.DataFrame) -> pd.DataFrame:
    run_rows = phase_rows[phase_rows["Phase"] == "run"].copy()
    columns = [
        "tup_returned_per_op",
        "tup_fetched_per_op",
        "blks_read_per_op",
        "blks_hit_per_op",
        "cache_hit_ratio",
    ]
    rows: list[dict[str, object]] = []
    for run, group in run_rows.groupby("run", dropna=False):
        row: dict[str, object] = {"run": run}
        row.update(first_last_summary(group, columns))
        rows.append(row)
    return pd.DataFrame(rows).sort_values("run").reset_index(drop=True)


def build_extend_storage_summary(phase_rows: pd.DataFrame) -> pd.DataFrame:
    extend_rows = phase_rows[phase_rows["Phase"] == "extend"].copy()
    columns = [
        "tup_updated_per_op",
        "tup_inserted_per_op",
        "internal_inserts_per_logical_update",
        "wal_bytes_per_op",
        "blks_read_per_op",
        "blks_hit_per_op",
    ]
    rows: list[dict[str, object]] = []
    for run, group in extend_rows.groupby("run", dropna=False):
        row: dict[str, object] = {"run": run}
        row.update(first_last_summary(group, columns))
        rows.append(row)
    return pd.DataFrame(rows).sort_values("run").reset_index(drop=True)


def format_num(value: float, decimals: int = 1) -> str:
    if pd.isna(value):
        return "n/a"
    return f"{value:,.{decimals}f}"


def markdown_table(df: pd.DataFrame, decimals: dict[str, int]) -> str:
    headers = list(df.columns)
    lines = ["| " + " | ".join(headers) + " |", "| " + " | ".join(["---"] * len(headers)) + " |"]
    for _, row in df.iterrows():
        values: list[str] = []
        for col in headers:
            value = row[col]
            if isinstance(value, (int, np.integer)):
                values.append(str(value))
            elif isinstance(value, (float, np.floating)):
                numeric_value = float(value)
                if numeric_value.is_integer() and col.lower() in {"run", "runs"}:
                    values.append(str(int(numeric_value)))
                else:
                    values.append(format_num(numeric_value, decimals.get(col, 1)))
            else:
                values.append(str(value))
        lines.append("| " + " | ".join(values) + " |")
    return "\n".join(lines)


def build_report(
    phase_drift: pd.DataFrame,
    driver_summary: pd.DataFrame,
    run_read_summary: pd.DataFrame,
    extend_storage_summary: pd.DataFrame,
) -> str:
    phase_agg_rows: list[dict[str, object]] = []
    for phase, group in phase_drift.groupby("phase", dropna=False):
        row: dict[str, object] = {"Phase": phase, "Runs": int(group["run"].nunique())}
        for metric in SUMMARY_METRICS:
            row[f"{metric}_first10_mean"] = group[f"{metric}_first10"].mean()
            row[f"{metric}_last10_mean"] = group[f"{metric}_last10"].mean()
            row[f"{metric}_change_pct_mean"] = group[f"{metric}_change_pct"].mean()
        phase_agg_rows.append(row)
    phase_agg = pd.DataFrame(phase_agg_rows).sort_values(
        "Phase", key=lambda s: s.map({phase: i for i, phase in enumerate(PHASES)})
    )

    top_driver_rows: list[dict[str, object]] = []
    for phase in ["run", "clean-run", "avg-run", "extend", "reference"]:
        sub = driver_summary[driver_summary["phase"] == phase].copy()
        if sub.empty:
            continue
        top = (
            sub.groupby(["phase", "driver", "driver_label"], as_index=False)[
                ["latency_spearman_rho", "throughput_spearman_rho"]
            ]
            .mean()
            .assign(abs_rho=lambda df: df["latency_spearman_rho"].abs())
            .sort_values("abs_rho", ascending=False)
            .head(3)
        )
        for _, row in top.iterrows():
            top_driver_rows.append(
                {
                    "Phase": row["phase"],
                    "Driver": row["driver_label"],
                    "Latency rho": row["latency_spearman_rho"],
                    "Throughput rho": row["throughput_spearman_rho"],
                }
            )
    top_driver_table = pd.DataFrame(top_driver_rows)

    phase_table = phase_agg[
        [
            "Phase",
            "AverageLatency(us)_first10_mean",
            "AverageLatency(us)_last10_mean",
            "AverageLatency(us)_change_pct_mean",
            "Throughput(ops/sec)_first10_mean",
            "Throughput(ops/sec)_last10_mean",
            "Throughput(ops/sec)_change_pct_mean",
        ]
    ].copy()
    phase_table.columns = [
        "Phase",
        "Avg latency first10 us",
        "Avg latency last10 us",
        "Avg latency change %",
        "Throughput first10",
        "Throughput last10",
        "Throughput change %",
    ]

    run_table = run_read_summary[
        [
            "run",
            "tup_returned_per_op_first10",
            "tup_returned_per_op_last10",
            "tup_fetched_per_op_first10",
            "tup_fetched_per_op_last10",
            "blks_read_per_op_first10",
            "blks_read_per_op_last10",
            "blks_hit_per_op_first10",
            "blks_hit_per_op_last10",
            "cache_hit_ratio_first10",
            "cache_hit_ratio_last10",
        ]
    ].copy()
    run_table.columns = [
        "Run",
        "Tuples returned/op first10",
        "Tuples returned/op last10",
        "Tuples fetched/op first10",
        "Tuples fetched/op last10",
        "Block reads/op first10",
        "Block reads/op last10",
        "Block hits/op first10",
        "Block hits/op last10",
        "Cache-hit ratio first10",
        "Cache-hit ratio last10",
    ]
    run_table["Run"] = run_table["Run"].astype(int)

    extend_table = extend_storage_summary[
        [
            "run",
            "tup_updated_per_op_first10",
            "tup_updated_per_op_last10",
            "tup_inserted_per_op_first10",
            "tup_inserted_per_op_last10",
            "internal_inserts_per_logical_update_first10",
            "internal_inserts_per_logical_update_last10",
            "wal_bytes_per_op_first10",
            "wal_bytes_per_op_last10",
        ]
    ].copy()
    extend_table.columns = [
        "Run",
        "Logical updates/op first10",
        "Logical updates/op last10",
        "Internal tuple inserts/op first10",
        "Internal tuple inserts/op last10",
        "Internal inserts/logical update first10",
        "Internal inserts/logical update last10",
        "WAL bytes/op first10",
        "WAL bytes/op last10",
    ]
    extend_table["Run"] = extend_table["Run"].astype(int)

    run_phase = phase_agg[phase_agg["Phase"] == "run"].iloc[0]
    extend_phase = phase_agg[phase_agg["Phase"] == "extend"].iloc[0]
    avg_phase = phase_agg[phase_agg["Phase"] == "avg-run"].iloc[0]
    clean_phase = phase_agg[phase_agg["Phase"] == "clean-run"].iloc[0]
    ref_phase = phase_agg[phase_agg["Phase"] == "reference"].iloc[0]

    lines = [
        "# PostgreSQL ArrayJSON Bigcache Zipfian Heavy Pure Internal Metrics Report",
        "",
        "## Scope",
        "",
        "- CSV inputs analyzed:",
    ]
    lines.extend([f"- `JSON_BLUE/{csv_path(run).name}`" for run in RUNS])
    lines.extend(
        [
            "",
            "- Repeated phases analyzed: `run`, `clean-run`, `avg-run`, `extend`, and `reference`.",
            "- The PostgreSQL counters are cumulative, so the analysis uses same-phase epoch deltas normalized by `Operations`.",
            "",
            "## Executive Summary",
            "",
            f"- `run` latency rises from `{format_num(run_phase['AverageLatency(us)_first10_mean'])}` us to `{format_num(run_phase['AverageLatency(us)_last10_mean'])}` us while throughput falls from `{format_num(run_phase['Throughput(ops/sec)_first10_mean'])}` to `{format_num(run_phase['Throughput(ops/sec)_last10_mean'])}` ops/sec.",
            f"- The strongest long-run `run` signals are read amplification and write amplification together: tuples fetched/op, tuples returned/op, block reads/op, and WAL bytes/op all have very strong monotonic ties to performance decay.",
            f"- `extend` is the clearest source phase: average latency grows from `{format_num(extend_phase['AverageLatency(us)_first10_mean'])}` us to `{format_num(extend_phase['AverageLatency(us)_last10_mean'])}` us while throughput collapses from `{format_num(extend_phase['Throughput(ops/sec)_first10_mean'])}` to `{format_num(extend_phase['Throughput(ops/sec)_last10_mean'])}` ops/sec.",
            f"- During `extend`, logical updates stay near one per op, but internal tuple inserts and WAL bytes per op rise by large multiples, which is consistent with storage amplification as values grow.",
            "",
            "## Phase Drift Summary",
            "",
            markdown_table(
                phase_table,
                {
                    "Avg latency first10 us": 2,
                    "Avg latency last10 us": 2,
                    "Avg latency change %": 1,
                    "Throughput first10": 2,
                    "Throughput last10": 2,
                    "Throughput change %": 1,
                },
            ),
            "",
            "## Top Drivers",
            "",
            markdown_table(
                top_driver_table,
                {
                    "Latency rho": 3,
                    "Throughput rho": 3,
                },
            ),
            "",
            "Interpretation:",
            "",
            "- `run`, `clean-run`, and `avg-run` all point to the same family of degrading internals: more WAL per op, more buffer allocation churn, and more block work per logical operation.",
            f"- `reference` is much flatter by comparison: average latency only moves from `{format_num(ref_phase['AverageLatency(us)_first10_mean'])}` us to `{format_num(ref_phase['AverageLatency(us)_last10_mean'])}` us, which makes it a useful control phase.",
            f"- `clean-run` and `avg-run` remain severe, with throughput falling from `{format_num(clean_phase['Throughput(ops/sec)_first10_mean'])}` to `{format_num(clean_phase['Throughput(ops/sec)_last10_mean'])}` in `clean-run` and from `{format_num(avg_phase['Throughput(ops/sec)_first10_mean'])}` to `{format_num(avg_phase['Throughput(ops/sec)_last10_mean'])}` in `avg-run`.",
            "",
            "## Extend Storage Amplification",
            "",
            markdown_table(
                extend_table,
                {
                    "Logical updates/op first10": 3,
                    "Logical updates/op last10": 3,
                    "Internal tuple inserts/op first10": 3,
                    "Internal tuple inserts/op last10": 3,
                    "Internal inserts/logical update first10": 3,
                    "Internal inserts/logical update last10": 3,
                    "WAL bytes/op first10": 1,
                    "WAL bytes/op last10": 1,
                },
            ),
            "",
            "- The important pattern is that `tup_updated_per_op` stays around one, but `tup_inserted_per_op` and `internal_inserts_per_logical_update` climb sharply late in the run.",
            "- Because these repeated workloads are not user-level insert workloads, that rising internal insert pressure is best interpreted as PostgreSQL doing more underlying storage work for each logical extend.",
            "",
            "## Run-Phase Read Amplification",
            "",
            markdown_table(
                run_table,
                {
                    "Tuples returned/op first10": 2,
                    "Tuples returned/op last10": 2,
                    "Tuples fetched/op first10": 2,
                    "Tuples fetched/op last10": 2,
                    "Block reads/op first10": 2,
                    "Block reads/op last10": 2,
                    "Block hits/op first10": 2,
                    "Block hits/op last10": 2,
                    "Cache-hit ratio first10": 3,
                    "Cache-hit ratio last10": 3,
                },
            ),
            "",
            "- In every analyzed run, tuples fetched/op and block reads/op rise substantially over time in `run`, which means the read path is paying for much larger or more fragmented state later in the benchmark.",
            "- Cache-hit ratio declines modestly rather than collapsing outright, so the dominant issue is not just cache failure; it is the growing amount of work done per logical read.",
            "",
            "## Bottom Line",
            "",
            "- Yes: the internal metrics captured inside the CSVs strongly support the same story as the external watcher metrics, but with better causal detail.",
            "- The main driver is cumulative storage and write amplification during `extend`, which then shows up as much heavier read amplification in `run`, `clean-run`, and `avg-run`.",
            "- The most explanatory internal metrics here are `wal_bytes_per_op`, `wal_records_per_op`, `buffers_alloc_per_op`, `tup_fetched_per_op`, `tup_returned_per_op`, `blks_read_per_op`, and `internal_inserts_per_logical_update`.",
            "",
            "## Generated Tables",
            "",
            "- `analysis/postgresql_arrayjson_bigcache_zipfian_internal_phase_drift.csv`",
            "- `analysis/postgresql_arrayjson_bigcache_zipfian_internal_driver_summary.csv`",
            "- `analysis/postgresql_arrayjson_bigcache_zipfian_internal_run_read_amplification.csv`",
            "- `analysis/postgresql_arrayjson_bigcache_zipfian_internal_extend_storage.csv`",
        ]
    )
    return "\n".join(lines) + "\n"


def main() -> None:
    ANALYSIS_DIR.mkdir(parents=True, exist_ok=True)
    phase_rows = load_phase_rows()
    phase_drift = build_phase_drift(phase_rows)
    driver_summary = build_driver_summary(phase_rows)
    run_read_summary = build_run_read_summary(phase_rows)
    extend_storage_summary = build_extend_storage_summary(phase_rows)

    phase_drift_path = ANALYSIS_DIR / "postgresql_arrayjson_bigcache_zipfian_internal_phase_drift.csv"
    driver_path = ANALYSIS_DIR / "postgresql_arrayjson_bigcache_zipfian_internal_driver_summary.csv"
    run_read_path = ANALYSIS_DIR / "postgresql_arrayjson_bigcache_zipfian_internal_run_read_amplification.csv"
    extend_path = ANALYSIS_DIR / "postgresql_arrayjson_bigcache_zipfian_internal_extend_storage.csv"
    report_path = ANALYSIS_DIR / "postgresql_arrayjson_bigcache_zipfian_internal_metrics_report.md"

    phase_drift.to_csv(phase_drift_path, index=False)
    driver_summary.to_csv(driver_path, index=False)
    run_read_summary.to_csv(run_read_path, index=False)
    extend_storage_summary.to_csv(extend_path, index=False)
    report_path.write_text(
        build_report(
            phase_drift=phase_drift,
            driver_summary=driver_summary,
            run_read_summary=run_read_summary,
            extend_storage_summary=extend_storage_summary,
        ),
        encoding="utf-8",
    )

    print(f"wrote,{phase_drift_path}")
    print(f"wrote,{driver_path}")
    print(f"wrote,{run_read_path}")
    print(f"wrote,{extend_path}")
    print(f"wrote,{report_path}")


if __name__ == "__main__":
    main()
