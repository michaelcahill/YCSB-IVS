from __future__ import annotations

from pathlib import Path
import re

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd


DATA_DIR = Path("DATA")
ANALYSIS_DIR = Path("analysis")
ASSET_DIR = ANALYSIS_DIR / "postgresql_arrayjson_latency_increase_report_files"
REPORT_PATH = ANALYSIS_DIR / "postgresql_arrayjson_latency_increase_report.md"

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
SCENARIO_LABELS = {
    "vacuum_notfull_uniform_heavy_pure": "vacuum_notfull_uniform_heavy_pure",
    "vacuum_notfull_zipfian_heavy_pure": "vacuum_notfull_zipfian_heavy_pure",
}


def parse_filename(path: Path) -> tuple[str, int]:
    match = re.match(r"^postgresql_arrayjson_(.+)_run(\d+)_(.+)\.csv$", path.name)
    if not match:
        raise ValueError(f"Unexpected arrayjson filename: {path.name}")
    scenario = f"{match.group(1)}_{match.group(3)}"
    run = int(match.group(2))
    return scenario, run


def load_phase_rows() -> tuple[pd.DataFrame, list[str]]:
    files = sorted(DATA_DIR.glob("postgresql_arrayjson*.csv"))
    if not files:
        raise FileNotFoundError("No postgresql_arrayjson*.csv files found in DATA/")

    rows: list[pd.DataFrame] = []
    for csv_path in files:
        scenario, run = parse_filename(csv_path)
        df = pd.read_csv(csv_path)
        df = df[df["Phase"].isin(PHASES)].copy()
        df["source_file"] = csv_path.name
        df["scenario"] = scenario
        df["run"] = run
        df["Phase"] = df["Phase"].astype(str).str.lower()
        df["Operation"] = df["Operation"].astype(str).str.upper()
        df["Epoch"] = pd.to_numeric(df["Epoch"], errors="coerce")
        df["Operations"] = pd.to_numeric(df["Operations"], errors="coerce")
        df["AverageLatency(us)"] = pd.to_numeric(df["AverageLatency(us)"], errors="coerce")
        df["95thPercentileLatency(us)"] = pd.to_numeric(df["95thPercentileLatency(us)"], errors="coerce")
        df["Throughput(ops/sec)"] = pd.to_numeric(df["Throughput(ops/sec)"], errors="coerce")
        for col in COUNTERS:
            df[col] = pd.to_numeric(df[col], errors="coerce")

        for phase, phase_df in df.groupby("Phase", dropna=False):
            phase_df = phase_df.sort_values("Epoch").copy()
            for col in COUNTERS:
                phase_df[f"{col}_per_op"] = phase_df[col].diff() / phase_df["Operations"]

            denom = (phase_df["blks_hit"] + phase_df["blks_read"]).replace(0, np.nan)
            phase_df["cache_hit_ratio"] = phase_df["blks_hit"] / denom
            phase_df["internal_inserts_per_logical_update"] = (
                phase_df["tup_inserted"].diff() / phase_df["tup_updated"].diff().replace(0, np.nan)
            )
            phase_df["latency_change_pct"] = 100 * (
                phase_df["AverageLatency(us)"] / phase_df["AverageLatency(us)"].shift(1) - 1
            )
            rows.append(phase_df)

    phase_rows = pd.concat(rows, ignore_index=True)
    return phase_rows, [path.name for path in files]


def pct_change(start: float, end: float) -> float:
    if pd.isna(start) or pd.isna(end) or abs(start) < 1e-12:
        return np.nan
    return 100.0 * (end / start - 1.0)


def summarize_first_last(group: pd.DataFrame, columns: list[str]) -> dict[str, float]:
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


def build_phase_summary(phase_rows: pd.DataFrame) -> pd.DataFrame:
    per_run_rows: list[dict[str, object]] = []
    for (scenario, run, phase), group in phase_rows.groupby(["scenario", "run", "Phase"], dropna=False):
        row: dict[str, object] = {"scenario": scenario, "run": run, "phase": phase}
        row.update(summarize_first_last(group, SUMMARY_METRICS))
        per_run_rows.append(row)

    per_run = pd.DataFrame(per_run_rows)
    agg_rows: list[dict[str, object]] = []
    for (scenario, phase), group in per_run.groupby(["scenario", "phase"], dropna=False):
        row = {"scenario": scenario, "phase": phase, "runs": int(group["run"].nunique())}
        for column in SUMMARY_METRICS:
            row[f"{column}_first10_mean"] = group[f"{column}_first10"].mean()
            row[f"{column}_last10_mean"] = group[f"{column}_last10"].mean()
            row[f"{column}_change_pct_mean"] = group[f"{column}_change_pct"].mean()
        agg_rows.append(row)

    summary = pd.DataFrame(agg_rows).sort_values(["scenario", "phase"]).reset_index(drop=True)
    return summary


def build_driver_summary(phase_rows: pd.DataFrame) -> pd.DataFrame:
    rows: list[dict[str, object]] = []
    for (scenario, run, phase), group in phase_rows.groupby(["scenario", "run", "Phase"], dropna=False):
        corr_source = group[DRIVER_COLUMNS + ["AverageLatency(us)", "Throughput(ops/sec)"]].copy()
        corr = corr_source.corr(method="spearman", numeric_only=True)
        if "AverageLatency(us)" not in corr.columns:
            continue
        latency_corr = corr["AverageLatency(us)"].drop(
            labels=["AverageLatency(us)", "Throughput(ops/sec)"],
            errors="ignore",
        )
        throughput_corr = corr["Throughput(ops/sec)"].drop(
            labels=["AverageLatency(us)", "Throughput(ops/sec)"],
            errors="ignore",
        )
        for driver, latency_rho in latency_corr.dropna().items():
            rows.append(
                {
                    "scenario": scenario,
                    "run": run,
                    "phase": phase,
                    "driver": driver,
                    "driver_label": DRIVER_LABELS.get(driver, driver),
                    "latency_spearman_rho": latency_rho,
                    "throughput_spearman_rho": throughput_corr.get(driver, np.nan),
                }
            )

    driver_df = pd.DataFrame(rows)
    summary = (
        driver_df.groupby(["scenario", "phase", "driver", "driver_label"], as_index=False)[
            ["latency_spearman_rho", "throughput_spearman_rho"]
        ]
        .mean()
        .reset_index(drop=True)
    )
    return summary


def build_run_read_amplification(phase_rows: pd.DataFrame) -> pd.DataFrame:
    columns = [
        "tup_returned_per_op",
        "tup_fetched_per_op",
        "blks_read_per_op",
        "blks_hit_per_op",
        "cache_hit_ratio",
    ]
    rows: list[dict[str, object]] = []
    run_rows = phase_rows[phase_rows["Phase"] == "run"].copy()
    for (scenario, run), group in run_rows.groupby(["scenario", "run"], dropna=False):
        row: dict[str, object] = {"scenario": scenario, "run": run}
        row.update(summarize_first_last(group, columns))
        rows.append(row)

    per_run = pd.DataFrame(rows)
    summary_rows: list[dict[str, object]] = []
    for scenario, group in per_run.groupby("scenario", dropna=False):
        row = {"scenario": scenario}
        for column in columns:
            row[f"{column}_first10_mean"] = group[f"{column}_first10"].mean()
            row[f"{column}_last10_mean"] = group[f"{column}_last10"].mean()
            row[f"{column}_change_pct_mean"] = group[f"{column}_change_pct"].mean()
        summary_rows.append(row)

    return pd.DataFrame(summary_rows).sort_values("scenario").reset_index(drop=True)


def build_extend_storage_summary(phase_rows: pd.DataFrame) -> pd.DataFrame:
    columns = [
        "tup_updated_per_op",
        "tup_inserted_per_op",
        "internal_inserts_per_logical_update",
        "wal_bytes_per_op",
        "blks_read_per_op",
        "blks_hit_per_op",
    ]
    rows: list[dict[str, object]] = []
    extend_rows = phase_rows[phase_rows["Phase"] == "extend"].copy()
    for (scenario, run), group in extend_rows.groupby(["scenario", "run"], dropna=False):
        row: dict[str, object] = {"scenario": scenario, "run": run}
        row.update(summarize_first_last(group, columns))
        rows.append(row)

    per_run = pd.DataFrame(rows)
    summary_rows: list[dict[str, object]] = []
    for scenario, group in per_run.groupby("scenario", dropna=False):
        row = {"scenario": scenario}
        for column in columns:
            row[f"{column}_first10_mean"] = group[f"{column}_first10"].mean()
            row[f"{column}_last10_mean"] = group[f"{column}_last10"].mean()
            row[f"{column}_change_pct_mean"] = group[f"{column}_change_pct"].mean()
        summary_rows.append(row)

    return pd.DataFrame(summary_rows).sort_values("scenario").reset_index(drop=True)


def normalize_series(series: pd.Series) -> pd.Series:
    baseline = series.dropna().head(10).mean()
    if pd.isna(baseline) or abs(baseline) < 1e-12:
        return pd.Series(np.nan, index=series.index)
    return series / baseline


def plot_phase_latencies(phase_rows: pd.DataFrame, scenario: str, out_path: Path) -> None:
    scenario_rows = phase_rows[phase_rows["scenario"] == scenario].copy()
    phases = ["run", "clean-run", "avg-run", "extend", "reference"]
    fig, axes = plt.subplots(3, 2, figsize=(13, 11), sharex=False)
    axes_list = list(axes.flatten())

    for ax, phase in zip(axes_list, phases):
        sub = scenario_rows[scenario_rows["Phase"] == phase]
        if sub.empty:
            ax.axis("off")
            continue
        mean_by_epoch = (
            sub.groupby("Epoch", as_index=False)[["AverageLatency(us)", "95thPercentileLatency(us)"]]
            .mean()
            .sort_values("Epoch")
        )
        ax.plot(mean_by_epoch["Epoch"], mean_by_epoch["AverageLatency(us)"], label="Average", linewidth=2)
        ax.plot(mean_by_epoch["Epoch"], mean_by_epoch["95thPercentileLatency(us)"], label="P95", linewidth=1.6)
        ax.set_title(phase)
        ax.set_xlabel("Epoch")
        ax.set_ylabel("Latency (us)")
        ax.grid(True, alpha=0.3)
        ax.legend(fontsize=8)

    axes_list[-1].axis("off")
    fig.suptitle(f"{scenario}: latency by phase", y=0.995)
    fig.tight_layout()
    fig.savefig(out_path, dpi=160, bbox_inches="tight")
    plt.close(fig)


def plot_run_pressure(phase_rows: pd.DataFrame, scenario: str, out_path: Path) -> None:
    sub = phase_rows[(phase_rows["scenario"] == scenario) & (phase_rows["Phase"] == "run")].copy()
    mean_by_epoch = sub.groupby("Epoch", as_index=False)[
        ["AverageLatency(us)", "wal_bytes_per_op", "buffers_alloc_per_op", "blks_read_per_op", "cache_hit_ratio"]
    ].mean()

    fig, axes = plt.subplots(2, 1, figsize=(12, 8), sharex=True)

    normalized_cols = [
        ("AverageLatency(us)", "Latency index"),
        ("wal_bytes_per_op", "WAL bytes/op index"),
        ("buffers_alloc_per_op", "Buffer alloc/op index"),
        ("blks_read_per_op", "Block reads/op index"),
    ]
    for column, label in normalized_cols:
        axes[0].plot(mean_by_epoch["Epoch"], normalize_series(mean_by_epoch[column]), label=label, linewidth=2)
    axes[0].set_ylabel("Index vs first 10 epochs")
    axes[0].set_title("Run phase drift")
    axes[0].grid(True, alpha=0.3)
    axes[0].legend(fontsize=8)

    axes[1].plot(
        mean_by_epoch["Epoch"],
        100.0 * mean_by_epoch["cache_hit_ratio"],
        color="#005f73",
        linewidth=2,
    )
    axes[1].set_ylabel("Cache-hit ratio (%)")
    axes[1].set_xlabel("Epoch")
    axes[1].grid(True, alpha=0.3)

    fig.suptitle(f"{scenario}: run-phase pressure trends", y=0.995)
    fig.tight_layout()
    fig.savefig(out_path, dpi=160, bbox_inches="tight")
    plt.close(fig)


def plot_extend_storage(phase_rows: pd.DataFrame, scenario: str, out_path: Path) -> None:
    sub = phase_rows[(phase_rows["scenario"] == scenario) & (phase_rows["Phase"] == "extend")].copy()
    mean_by_epoch = sub.groupby("Epoch", as_index=False)[
        [
            "AverageLatency(us)",
            "wal_bytes_per_op",
            "tup_inserted_per_op",
            "tup_updated_per_op",
            "internal_inserts_per_logical_update",
        ]
    ].mean()

    fig, axes = plt.subplots(2, 1, figsize=(12, 8), sharex=True)

    axes[0].plot(mean_by_epoch["Epoch"], normalize_series(mean_by_epoch["AverageLatency(us)"]), label="Latency index", linewidth=2)
    axes[0].plot(mean_by_epoch["Epoch"], normalize_series(mean_by_epoch["wal_bytes_per_op"]), label="WAL bytes/op index", linewidth=2)
    axes[0].plot(
        mean_by_epoch["Epoch"],
        normalize_series(mean_by_epoch["tup_inserted_per_op"]),
        label="Internal tuple inserts/op index",
        linewidth=2,
    )
    axes[0].set_ylabel("Index vs first 10 epochs")
    axes[0].set_title("Extend phase storage amplification")
    axes[0].grid(True, alpha=0.3)
    axes[0].legend(fontsize=8)

    axes[1].plot(
        mean_by_epoch["Epoch"],
        mean_by_epoch["internal_inserts_per_logical_update"],
        label="Internal inserts per logical update",
        color="#ae2012",
        linewidth=2,
    )
    axes[1].plot(
        mean_by_epoch["Epoch"],
        mean_by_epoch["tup_updated_per_op"],
        label="Logical updates/op",
        color="#0a9396",
        linewidth=1.8,
    )
    axes[1].set_ylabel("Per-op value")
    axes[1].set_xlabel("Epoch")
    axes[1].grid(True, alpha=0.3)
    axes[1].legend(fontsize=8)

    fig.suptitle(f"{scenario}: extend-phase storage amplification", y=0.995)
    fig.tight_layout()
    fig.savefig(out_path, dpi=160, bbox_inches="tight")
    plt.close(fig)


def format_number(value: object, digits: int = 2) -> str:
    if value is None or pd.isna(value):
        return ""
    return f"{float(value):,.{digits}f}"


def markdown_table(df: pd.DataFrame, column_formats: dict[str, int] | None = None) -> str:
    if df.empty:
        return "_No data._"

    column_formats = column_formats or {}
    headers = list(df.columns)
    lines = [
        "| " + " | ".join(headers) + " |",
        "| " + " | ".join(["---"] * len(headers)) + " |",
    ]
    for _, row in df.iterrows():
        cells = []
        for column in headers:
            value = row[column]
            if column in column_formats:
                cells.append(format_number(value, column_formats[column]))
            else:
                cells.append("" if pd.isna(value) else str(value))
        lines.append("| " + " | ".join(cells) + " |")
    return "\n".join(lines)


def build_report(
    input_files: list[str],
    phase_summary: pd.DataFrame,
    driver_summary: pd.DataFrame,
    run_read_summary: pd.DataFrame,
    extend_storage_summary: pd.DataFrame,
) -> str:
    scenario_order = [
        "vacuum_notfull_uniform_heavy_pure",
        "vacuum_notfull_zipfian_heavy_pure",
    ]

    phase_table = phase_summary[
        [
            "scenario",
            "phase",
            "AverageLatency(us)_first10_mean",
            "AverageLatency(us)_last10_mean",
            "AverageLatency(us)_change_pct_mean",
            "Throughput(ops/sec)_first10_mean",
            "Throughput(ops/sec)_last10_mean",
            "Throughput(ops/sec)_change_pct_mean",
        ]
    ].copy()
    phase_table.columns = [
        "Scenario",
        "Phase",
        "Avg latency first10 us",
        "Avg latency last10 us",
        "Avg latency change %",
        "Throughput first10",
        "Throughput last10",
        "Throughput change %",
    ]

    extend_table = extend_storage_summary[
        [
            "scenario",
            "tup_updated_per_op_first10_mean",
            "tup_updated_per_op_last10_mean",
            "tup_inserted_per_op_first10_mean",
            "tup_inserted_per_op_last10_mean",
            "internal_inserts_per_logical_update_first10_mean",
            "internal_inserts_per_logical_update_last10_mean",
            "wal_bytes_per_op_first10_mean",
            "wal_bytes_per_op_last10_mean",
        ]
    ].copy()
    extend_table.columns = [
        "Scenario",
        "Logical updates/op first10",
        "Logical updates/op last10",
        "Internal tuple inserts/op first10",
        "Internal tuple inserts/op last10",
        "Internal inserts per logical update first10",
        "Internal inserts per logical update last10",
        "WAL bytes/op first10",
        "WAL bytes/op last10",
    ]

    run_table = run_read_summary[
        [
            "scenario",
            "tup_returned_per_op_first10_mean",
            "tup_returned_per_op_last10_mean",
            "tup_fetched_per_op_first10_mean",
            "tup_fetched_per_op_last10_mean",
            "blks_read_per_op_first10_mean",
            "blks_read_per_op_last10_mean",
            "blks_hit_per_op_first10_mean",
            "blks_hit_per_op_last10_mean",
            "cache_hit_ratio_first10_mean",
            "cache_hit_ratio_last10_mean",
        ]
    ].copy()
    run_table.columns = [
        "Scenario",
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

    top_driver_rows: list[pd.DataFrame] = []
    for scenario in scenario_order:
        for phase in ["run", "clean-run", "avg-run", "extend"]:
            sub = driver_summary[(driver_summary["scenario"] == scenario) & (driver_summary["phase"] == phase)].copy()
            if sub.empty:
                continue
            top = sub.assign(abs_rho=sub["latency_spearman_rho"].abs()).sort_values("abs_rho", ascending=False).head(3)
            top_driver_rows.append(
                top[["scenario", "phase", "driver_label", "latency_spearman_rho", "throughput_spearman_rho"]]
            )

    top_driver_table = pd.concat(top_driver_rows, ignore_index=True)
    top_driver_table.columns = [
        "Scenario",
        "Phase",
        "Driver",
        "Latency rho",
        "Throughput rho",
    ]

    uniform_extend = extend_storage_summary[
        extend_storage_summary["scenario"] == "vacuum_notfull_uniform_heavy_pure"
    ].iloc[0]
    zipfian_extend = extend_storage_summary[
        extend_storage_summary["scenario"] == "vacuum_notfull_zipfian_heavy_pure"
    ].iloc[0]
    uniform_run = run_read_summary[run_read_summary["scenario"] == "vacuum_notfull_uniform_heavy_pure"].iloc[0]
    zipfian_run = run_read_summary[run_read_summary["scenario"] == "vacuum_notfull_zipfian_heavy_pure"].iloc[0]

    lines = [
        "# PostgreSQL ArrayJSON Latency Increase Report",
        "",
        "## Scope",
        "",
        "This report analyzes the six PostgreSQL `arrayjson` CSVs:",
        "",
    ]
    lines.extend([f"- `DATA/{name}`" for name in input_files])
    lines.extend(
        [
            "",
            "Repeated phases analyzed:",
            "",
            "- `run`",
            "- `clean-run`",
            "- `avg-run`",
            "- `extend`",
            "- `reference`",
            "",
            "The counters are cumulative, so the report uses same-phase epoch deltas normalized by `Operations` to estimate per-operation pressure.",
            "",
            "## Executive Summary",
            "",
            "- The latency increase is real and severe in both scenarios, but it is much worse under `zipfian` access, especially for `extend`.",
            "- The most consistent long-run drivers are rising `WAL bytes/op`, `WAL records/op`, `buffer allocs/op`, and block-access intensity, alongside a falling cache-hit ratio.",
            "- The clearest mechanism is storage amplification during `extend`: logical updates stay close to one tuple per op, but internal tuple inserts per logical update climb sharply over time.",
            "- This pattern is consistent with growing `arrayjson` values forcing more internal PostgreSQL work per logical extend. That is an inference from the counters, but it matches the observed WAL and buffer growth very closely.",
            "- The read phases then get slower because the amount of data touched per read rises dramatically. In `run`, tuples fetched/op and block reads/op grow by multiples, not just a few percent.",
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
            "## Most Consistent Long-Run Drivers",
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
            "- The dominant pattern is cumulative pressure, not a single isolated checkpoint spike.",
            "- `run`, `clean-run`, and `avg-run` all track the same family of drivers: more WAL, more buffer allocation churn, and more block work per logical operation.",
            "- `reference` is the exception. It stays mostly flat in `uniform` because its read pressure barely changes, which is useful evidence that the worst latency growth is tied to the active extend-driven workload rather than an unrelated global slowdown.",
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
                    "Internal inserts per logical update first10": 3,
                    "Internal inserts per logical update last10": 3,
                    "WAL bytes/op first10": 1,
                    "WAL bytes/op last10": 1,
                },
            ),
            "",
            "Why this matters:",
            "",
            f"- In `uniform`, `extend` stays near `{uniform_extend['tup_updated_per_op_first10_mean']:.2f} -> {uniform_extend['tup_updated_per_op_last10_mean']:.2f}` logical tuple updates/op, but internal tuple inserts rise from `{uniform_extend['tup_inserted_per_op_first10_mean']:.2f}` to `{uniform_extend['tup_inserted_per_op_last10_mean']:.2f}` per op.",
            f"- In `zipfian`, the same signal is much stronger: internal tuple inserts rise from `{zipfian_extend['tup_inserted_per_op_first10_mean']:.2f}` to `{zipfian_extend['tup_inserted_per_op_last10_mean']:.2f}` per op while logical updates stay near one.",
            f"- WAL bytes/op rise from about `{uniform_extend['wal_bytes_per_op_first10_mean']:.0f}` to `{uniform_extend['wal_bytes_per_op_last10_mean']:.0f}` in `uniform`, and from `{zipfian_extend['wal_bytes_per_op_first10_mean']:.0f}` to `{zipfian_extend['wal_bytes_per_op_last10_mean']:.0f}` in `zipfian`.",
            "- Because there are no user-level INSERT phases in these repeating workloads, the rising internal insert counter is best read as PostgreSQL doing extra storage work underneath each logical extend. The most plausible explanation is growing TOAST/storage chunk churn as the JSON arrays get larger.",
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
            "Interpretation:",
            "",
            f"- In `uniform` run phases, tuples fetched/op rise from `{uniform_run['tup_fetched_per_op_first10_mean']:.2f}` to `{uniform_run['tup_fetched_per_op_last10_mean']:.2f}` and block reads/op rise from `{uniform_run['blks_read_per_op_first10_mean']:.2f}` to `{uniform_run['blks_read_per_op_last10_mean']:.2f}`.",
            f"- In `zipfian` run phases, tuples fetched/op rise from `{zipfian_run['tup_fetched_per_op_first10_mean']:.2f}` to `{zipfian_run['tup_fetched_per_op_last10_mean']:.2f}` and block reads/op rise from `{zipfian_run['blks_read_per_op_first10_mean']:.2f}` to `{zipfian_run['blks_read_per_op_last10_mean']:.2f}`.",
            "- That means the read path is paying for much larger or more fragmented state later in the run, which lines up with the storage-amplification story above.",
            "",
            "## Figures",
            "",
            "### Uniform Scenario",
            "",
            "![](postgresql_arrayjson_latency_increase_report_files/vacuum_notfull_uniform_heavy_pure_phase_latencies.png)",
            "",
            "![](postgresql_arrayjson_latency_increase_report_files/vacuum_notfull_uniform_heavy_pure_run_pressure.png)",
            "",
            "![](postgresql_arrayjson_latency_increase_report_files/vacuum_notfull_uniform_heavy_pure_extend_storage.png)",
            "",
            "### Zipfian Scenario",
            "",
            "![](postgresql_arrayjson_latency_increase_report_files/vacuum_notfull_zipfian_heavy_pure_phase_latencies.png)",
            "",
            "![](postgresql_arrayjson_latency_increase_report_files/vacuum_notfull_zipfian_heavy_pure_run_pressure.png)",
            "",
            "![](postgresql_arrayjson_latency_increase_report_files/vacuum_notfull_zipfian_heavy_pure_extend_storage.png)",
            "",
            "## Bottom Line",
            "",
            "- The latency increase is mainly explained by cumulative storage and write amplification as the `arrayjson` payloads grow over epochs.",
            "- The strongest evidence is the near-perfect long-run tie between latency and `WAL bytes/op`, `WAL records/op`, `buffer allocs/op`, and read/block intensity.",
            "- The extend phase appears to be the root of that drift: one logical update increasingly causes many more internal inserted tuples, which is consistent with PostgreSQL having to create more out-of-line storage chunks for larger JSON values.",
            "- Zipfian access makes the problem much worse because the hottest rows accumulate that storage growth fastest, so both extend latency and later read latency deteriorate more sharply.",
        ]
    )
    return "\n".join(lines) + "\n"


def main() -> None:
    plt.style.use("seaborn-v0_8-whitegrid")
    plt.rcParams["axes.spines.top"] = False
    plt.rcParams["axes.spines.right"] = False

    ANALYSIS_DIR.mkdir(parents=True, exist_ok=True)
    ASSET_DIR.mkdir(parents=True, exist_ok=True)

    phase_rows, input_files = load_phase_rows()
    phase_summary = build_phase_summary(phase_rows)
    driver_summary = build_driver_summary(phase_rows)
    run_read_summary = build_run_read_amplification(phase_rows)
    extend_storage_summary = build_extend_storage_summary(phase_rows)

    for scenario in sorted(phase_rows["scenario"].unique()):
        plot_phase_latencies(
            phase_rows,
            scenario,
            ASSET_DIR / f"{scenario}_phase_latencies.png",
        )
        plot_run_pressure(
            phase_rows,
            scenario,
            ASSET_DIR / f"{scenario}_run_pressure.png",
        )
        plot_extend_storage(
            phase_rows,
            scenario,
            ASSET_DIR / f"{scenario}_extend_storage.png",
        )

    phase_summary.to_csv(ANALYSIS_DIR / "postgresql_arrayjson_phase_drift_summary.csv", index=False)
    driver_summary.to_csv(ANALYSIS_DIR / "postgresql_arrayjson_monotonic_driver_summary.csv", index=False)
    run_read_summary.to_csv(ANALYSIS_DIR / "postgresql_arrayjson_run_read_amplification.csv", index=False)
    extend_storage_summary.to_csv(ANALYSIS_DIR / "postgresql_arrayjson_extend_storage_amplification.csv", index=False)

    report = build_report(
        input_files=input_files,
        phase_summary=phase_summary,
        driver_summary=driver_summary,
        run_read_summary=run_read_summary,
        extend_storage_summary=extend_storage_summary,
    )
    REPORT_PATH.write_text(report, encoding="utf-8")

    print(f"Wrote report: {REPORT_PATH}")
    print("Wrote supporting files:")
    print(f"- {ANALYSIS_DIR / 'postgresql_arrayjson_phase_drift_summary.csv'}")
    print(f"- {ANALYSIS_DIR / 'postgresql_arrayjson_monotonic_driver_summary.csv'}")
    print(f"- {ANALYSIS_DIR / 'postgresql_arrayjson_run_read_amplification.csv'}")
    print(f"- {ANALYSIS_DIR / 'postgresql_arrayjson_extend_storage_amplification.csv'}")
    print(f"- {ASSET_DIR}")


if __name__ == "__main__":
    main()
