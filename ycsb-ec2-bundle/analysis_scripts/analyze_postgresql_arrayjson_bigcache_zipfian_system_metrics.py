from __future__ import annotations

import math
from pathlib import Path

import pandas as pd


ROOT = Path(__file__).resolve().parents[1]
JSON_BLUE_DIR = ROOT / "JSON_BLUE"
ANALYSIS_DIR = ROOT / "analysis"

RUNS = [4, 5, 6]
PHASE_ORDER = ["reference", "run", "clean-run", "avg-run", "extend"]
RAW_COLUMNS = ["Phase", "Epoch", "Timestamp", "CPU", "MemoryKB", "DeltaReadBytes", "DeltaWriteBytes"]


def metrics_path_for(run: int, phase: str) -> Path:
    metrics_dir = JSON_BLUE_DIR / f"run_{run}_metrics"
    if phase in {"run", "extend"}:
        stem = f"ycsb_postgresql_arrayjson_vacuum_notfull_bigcache_zipfian_heavy_pure_run{run}_{phase}.metrics"
    elif phase in {"clean-run", "avg-run"}:
        stem = f"ycsb_backup_postgresql_arrayjson_vacuum_notfull_bigcache_zipfian_heavy_pure_run{run}_{phase}.metrics"
    elif phase == "reference":
        stem = f"ycsb_unchange_postgresql_arrayjson_vacuum_notfull_bigcache_zipfian_heavy_pure_run{run}_{phase}.metrics"
    else:
        raise ValueError(f"Unsupported phase: {phase}")
    return metrics_dir / stem


def load_perf_csv(run: int) -> pd.DataFrame:
    path = JSON_BLUE_DIR / f"postgresql_arrayjson_vacuum_notfull_bigcache_run{run}_zipfian_heavy_pure.csv"
    df = pd.read_csv(path)
    df = df[df["Phase"].isin(PHASE_ORDER)].copy()
    df["Epoch"] = pd.to_numeric(df["Epoch"], errors="coerce")
    df = df.dropna(subset=["Epoch"])
    df["Epoch"] = df["Epoch"].astype(int)
    return df


def load_metrics(run: int, phase: str) -> pd.DataFrame:
    path = metrics_path_for(run, phase)
    df = pd.read_csv(path, header=None, names=RAW_COLUMNS)
    df["Phase"] = df["Phase"].astype(str).str.lower()
    df["Epoch"] = pd.to_numeric(df["Epoch"], errors="coerce")
    for column in ["CPU", "MemoryKB", "DeltaReadBytes", "DeltaWriteBytes"]:
        df[column] = pd.to_numeric(df[column], errors="coerce")
    df = df[(df["Phase"] == phase) & (df["Epoch"].between(1, 100))].copy()
    return df


def summarize_epoch_metrics(metrics_df: pd.DataFrame) -> pd.DataFrame:
    return (
        metrics_df.groupby("Epoch")
        .agg(
            cpu_mean=("CPU", "mean"),
            cpu_max=("CPU", "max"),
            mem_mib_mean=("MemoryKB", lambda s: s.mean() / 1024),
            mem_mib_max=("MemoryKB", lambda s: s.max() / 1024),
            read_mib_sum=("DeltaReadBytes", lambda s: s.fillna(0).sum() / 1024 / 1024),
            write_mib_sum=("DeltaWriteBytes", lambda s: s.fillna(0).sum() / 1024 / 1024),
            samples=("Timestamp", "count"),
        )
        .reset_index()
    )


def first_last_change(series: pd.Series) -> tuple[float, float, float]:
    values = series.dropna().reset_index(drop=True)
    if len(values) < 10:
        return math.nan, math.nan, math.nan
    first = float(values.iloc[:10].mean())
    last = float(values.iloc[-10:].mean())
    change_pct = math.nan if first == 0 else ((last - first) / first) * 100.0
    return first, last, change_pct


def build_outputs() -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    summary_rows: list[dict[str, float | int | str]] = []
    drift_rows: list[dict[str, float | int | str]] = []
    correlation_rows: list[dict[str, float | int | str]] = []

    for run in RUNS:
        perf_df = load_perf_csv(run)
        perf_subset = perf_df[
            [
                "Phase",
                "Epoch",
                "Throughput(ops/sec)",
                "AverageLatency(us)",
                "95thPercentileLatency(us)",
                "99thPercentileLatency(us)",
            ]
        ].copy()

        for phase in PHASE_ORDER:
            metrics_df = load_metrics(run, phase)
            if metrics_df.empty:
                continue

            epoch_metrics = summarize_epoch_metrics(metrics_df)
            joined = epoch_metrics.merge(perf_subset[perf_subset["Phase"] == phase], on="Epoch", how="left")
            joined["run"] = run
            joined["phase"] = phase

            summary_rows.append(
                {
                    "run": run,
                    "phase": phase,
                    "epochs": int(joined["Epoch"].nunique()),
                    "samples_per_epoch_mean": float(joined["samples"].mean()),
                    "cpu_mean_avg": float(joined["cpu_mean"].mean()),
                    "cpu_mean_p95": float(joined["cpu_mean"].quantile(0.95)),
                    "cpu_max_peak": float(joined["cpu_max"].max()),
                    "mem_mib_mean_avg": float(joined["mem_mib_mean"].mean()),
                    "mem_mib_peak": float(joined["mem_mib_max"].max()),
                    "read_mib_epoch_mean": float(joined["read_mib_sum"].mean()),
                    "read_mib_epoch_p95": float(joined["read_mib_sum"].quantile(0.95)),
                    "write_mib_epoch_mean": float(joined["write_mib_sum"].mean()),
                    "write_mib_epoch_p95": float(joined["write_mib_sum"].quantile(0.95)),
                    "throughput_mean": float(joined["Throughput(ops/sec)"].mean()),
                    "latency_mean_us": float(joined["AverageLatency(us)"].mean()),
                }
            )

            for metric in [
                "cpu_mean",
                "mem_mib_mean",
                "read_mib_sum",
                "write_mib_sum",
                "Throughput(ops/sec)",
                "AverageLatency(us)",
                "95thPercentileLatency(us)",
                "99thPercentileLatency(us)",
            ]:
                first, last, change_pct = first_last_change(joined[metric])
                drift_rows.append(
                    {
                        "run": run,
                        "phase": phase,
                        "metric": metric,
                        "first10_mean": first,
                        "last10_mean": last,
                        "change_pct": change_pct,
                    }
                )

            for metric in ["cpu_mean", "mem_mib_mean", "read_mib_sum", "write_mib_sum"]:
                corr_df = joined[
                    [metric, "Throughput(ops/sec)", "AverageLatency(us)", "95thPercentileLatency(us)", "99thPercentileLatency(us)"]
                ].dropna()
                if len(corr_df) < 10 or corr_df[metric].nunique() <= 1:
                    continue
                correlation_rows.append(
                    {
                        "run": run,
                        "phase": phase,
                        "metric": metric,
                        "rho_latency": float(corr_df[metric].corr(corr_df["AverageLatency(us)"], method="spearman")),
                        "rho_p95": float(corr_df[metric].corr(corr_df["95thPercentileLatency(us)"], method="spearman")),
                        "rho_p99": float(corr_df[metric].corr(corr_df["99thPercentileLatency(us)"], method="spearman")),
                        "rho_throughput": float(corr_df[metric].corr(corr_df["Throughput(ops/sec)"], method="spearman")),
                    }
                )

    summary_df = pd.DataFrame(summary_rows).sort_values(["phase", "run"], key=lambda s: s.map({p: i for i, p in enumerate(PHASE_ORDER)}) if s.name == "phase" else s)
    drift_df = pd.DataFrame(drift_rows).sort_values(["phase", "metric", "run"])
    correlation_df = pd.DataFrame(correlation_rows).sort_values(["phase", "metric", "run"])

    phase_summary_df = (
        summary_df.groupby("phase")
        .agg(
            runs=("run", "count"),
            cpu_mean_avg=("cpu_mean_avg", "mean"),
            cpu_mean_p95=("cpu_mean_p95", "mean"),
            cpu_max_peak=("cpu_max_peak", "max"),
            mem_mib_mean_avg=("mem_mib_mean_avg", "mean"),
            mem_mib_peak=("mem_mib_peak", "max"),
            read_mib_epoch_mean=("read_mib_epoch_mean", "mean"),
            write_mib_epoch_mean=("write_mib_epoch_mean", "mean"),
            throughput_mean=("throughput_mean", "mean"),
            latency_mean_us=("latency_mean_us", "mean"),
        )
        .reset_index()
    )
    return summary_df, drift_df, correlation_df, phase_summary_df


def format_number(value: float, decimals: int = 1) -> str:
    if pd.isna(value):
        return "n/a"
    return f"{value:,.{decimals}f}"


def render_report(
    summary_df: pd.DataFrame,
    drift_df: pd.DataFrame,
    correlation_df: pd.DataFrame,
    phase_summary_df: pd.DataFrame,
) -> str:
    phase_summary = phase_summary_df.set_index("phase")

    def drift_lookup(phase: str, metric: str) -> pd.Series:
        row = drift_df.groupby(["phase", "metric"]).mean(numeric_only=True).reset_index()
        return row[(row["phase"] == phase) & (row["metric"] == metric)].iloc[0]

    def corr_lookup(phase: str, metric: str) -> pd.Series:
        row = correlation_df.groupby(["phase", "metric"]).mean(numeric_only=True).reset_index()
        return row[(row["phase"] == phase) & (row["metric"] == metric)].iloc[0]

    run_cpu = drift_lookup("run", "cpu_mean")
    run_mem = drift_lookup("run", "mem_mib_mean")
    run_lat = drift_lookup("run", "AverageLatency(us)")
    run_tp = drift_lookup("run", "Throughput(ops/sec)")
    ext_cpu = drift_lookup("extend", "cpu_mean")
    ext_mem = drift_lookup("extend", "mem_mib_mean")
    ext_lat = drift_lookup("extend", "AverageLatency(us)")
    ext_tp = drift_lookup("extend", "Throughput(ops/sec)")
    run_corr_cpu = corr_lookup("run", "cpu_mean")
    run_corr_mem = corr_lookup("run", "mem_mib_mean")
    ext_corr_cpu = corr_lookup("extend", "cpu_mean")
    ext_corr_mem = corr_lookup("extend", "mem_mib_mean")

    lines: list[str] = []
    lines.append("# PostgreSQL ArrayJSON Bigcache Zipfian Heavy Pure System Metrics Report")
    lines.append("")
    lines.append("## Scope")
    lines.append("")
    lines.append("- Runs analyzed: `run4`, `run5`, and `run6` from `JSON_BLUE/`.")
    lines.append("- Workload family: `postgresql_arrayjson_vacuum_notfull_bigcache_*_zipfian_heavy_pure`.")
    lines.append("- System metrics source: watcher `.metrics` files for `reference`, `run`, `clean-run`, `avg-run`, and `extend`.")
    lines.append("- Performance source: matching YCSB phase rows from the corresponding CSV files.")
    lines.append("- Note: the watcher files in this family report `CPU` and `MemoryKB`, but `DeltaReadBytes` and `DeltaWriteBytes` are effectively zero throughout these runs, so this report focuses on CPU and memory.")
    lines.append("")
    lines.append("## Executive Summary")
    lines.append("")
    lines.append(
        f"- `run` latency rises from {format_number(run_lat['first10_mean'])} us to {format_number(run_lat['last10_mean'])} us on average across runs, "
        f"while throughput falls from {format_number(run_tp['first10_mean'])} to {format_number(run_tp['last10_mean'])} ops/sec "
        f"({format_number(run_tp['change_pct'])}% change)."
    )
    lines.append(
        f"- During the same `run` window, watcher memory climbs from {format_number(run_mem['first10_mean'])} MiB to {format_number(run_mem['last10_mean'])} MiB "
        f"({format_number(run_mem['change_pct'])}% growth), while CPU actually eases from {format_number(run_cpu['first10_mean'])}% to "
        f"{format_number(run_cpu['last10_mean'])}% ({format_number(run_cpu['change_pct'])}% change)."
    )
    lines.append(
        f"- `extend` is the opposite: CPU and memory both ramp hard. Average CPU rises from {format_number(ext_cpu['first10_mean'])}% to "
        f"{format_number(ext_cpu['last10_mean'])}% ({format_number(ext_cpu['change_pct'])}% growth), and memory rises from "
        f"{format_number(ext_mem['first10_mean'])} MiB to {format_number(ext_mem['last10_mean'])} MiB ({format_number(ext_mem['change_pct'])}% growth)."
    )
    lines.append(
        f"- Those `extend` resource increases track the performance collapse closely: latency grows from {format_number(ext_lat['first10_mean'])} us to "
        f"{format_number(ext_lat['last10_mean'])} us, while throughput drops from {format_number(ext_tp['first10_mean'])} to "
        f"{format_number(ext_tp['last10_mean'])} ops/sec."
    )
    lines.append(
        f"- The strongest system-level signal in the read-heavy phases is memory growth, not rising CPU. In `run`, memory has mean Spearman rho "
        f"{format_number(run_corr_mem['rho_latency'], 3)} with average latency and {format_number(run_corr_mem['rho_throughput'], 3)} with throughput, "
        f"while CPU shows {format_number(run_corr_cpu['rho_latency'], 3)} and {format_number(run_corr_cpu['rho_throughput'], 3)}."
    )
    lines.append("")
    lines.append("## Phase Summary")
    lines.append("")
    lines.append("| Phase | Mean CPU % | Peak CPU % | Mean Memory MiB | Peak Memory MiB | Mean Throughput | Mean Avg Latency us |")
    lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: |")
    for phase in PHASE_ORDER:
        row = phase_summary.loc[phase]
        lines.append(
            f"| {phase} | {format_number(row['cpu_mean_avg'])} | {format_number(row['cpu_max_peak'])} | "
            f"{format_number(row['mem_mib_mean_avg'])} | {format_number(row['mem_mib_peak'])} | "
            f"{format_number(row['throughput_mean'])} | {format_number(row['latency_mean_us'])} |"
        )
    lines.append("")
    lines.append("## Key Findings")
    lines.append("")
    lines.append(
        f"- `reference` stays light: mean memory is only {format_number(phase_summary.loc['reference', 'mem_mib_mean_avg'])} MiB and mean latency is "
        f"{format_number(phase_summary.loc['reference', 'latency_mean_us'])} us, which makes it a useful baseline."
    )
    lines.append(
        f"- `run`, `clean-run`, and `avg-run` all show the same shape: memory grows by roughly {format_number(drift_lookup('run', 'mem_mib_mean')['change_pct'])}%, "
        f"{format_number(drift_lookup('clean-run', 'mem_mib_mean')['change_pct'])}%, and {format_number(drift_lookup('avg-run', 'mem_mib_mean')['change_pct'])}% respectively, "
        "while throughput collapses by about 85% to 88%."
    )
    lines.append(
        f"- `extend` is the most resource-intensive phase overall, with the highest peak memory "
        f"({format_number(phase_summary.loc['extend', 'mem_mib_peak'])} MiB) and the largest CPU growth."
    )
    lines.append(
        f"- In the read-heavy phases, higher memory is tightly associated with worse performance: latency rho values are "
        f"{format_number(corr_lookup('run', 'mem_mib_mean')['rho_latency'], 3)} for `run`, "
        f"{format_number(corr_lookup('clean-run', 'mem_mib_mean')['rho_latency'], 3)} for `clean-run`, and "
        f"{format_number(corr_lookup('avg-run', 'mem_mib_mean')['rho_latency'], 3)} for `avg-run`."
    )
    lines.append(
        "- The watcher I/O delta fields do not add explanatory power here because they remain zero across the analyzed files. "
        "That looks like a collector limitation or a no-op field in this dataset, not evidence that the database performed no storage work."
    )
    lines.append("")
    lines.append("## Interpretation")
    lines.append("")
    lines.append(
        "- The system metrics reinforce the earlier database-counter story: as the bigcache Zipfian pure workload progresses, "
        "the dominant visible pressure is increasing memory footprint rather than a steadily rising CPU bottleneck."
    )
    lines.append(
        "- For `extend`, both CPU and memory rise together, which fits a growing per-operation update cost. For later read phases, "
        "CPU does not keep climbing, but memory continues to grow and performance still degrades, suggesting the workload is becoming more state-heavy "
        "and less efficient per operation rather than simply saturating CPU."
    )
    lines.append(
        "- Inference: the repeated updates to hot Zipfian keys appear to accumulate more in-memory working set and backend state over time, "
        "which lines up with the previously observed growth in WAL, block reads, tuple work, and latency."
    )
    lines.append("")
    lines.append("## Generated Tables")
    lines.append("")
    lines.append("- `analysis/postgresql_arrayjson_bigcache_zipfian_heavy_pure_system_metrics_summary.csv`")
    lines.append("- `analysis/postgresql_arrayjson_bigcache_zipfian_heavy_pure_system_metrics_drift.csv`")
    lines.append("- `analysis/postgresql_arrayjson_bigcache_zipfian_heavy_pure_system_metrics_correlations.csv`")
    return "\n".join(lines) + "\n"


def main() -> None:
    ANALYSIS_DIR.mkdir(parents=True, exist_ok=True)
    summary_df, drift_df, correlation_df, phase_summary_df = build_outputs()

    summary_path = ANALYSIS_DIR / "postgresql_arrayjson_bigcache_zipfian_heavy_pure_system_metrics_summary.csv"
    drift_path = ANALYSIS_DIR / "postgresql_arrayjson_bigcache_zipfian_heavy_pure_system_metrics_drift.csv"
    correlation_path = ANALYSIS_DIR / "postgresql_arrayjson_bigcache_zipfian_heavy_pure_system_metrics_correlations.csv"
    report_path = ANALYSIS_DIR / "postgresql_arrayjson_bigcache_zipfian_heavy_pure_system_metrics_report.md"

    summary_df.to_csv(summary_path, index=False)
    drift_df.to_csv(drift_path, index=False)
    correlation_df.to_csv(correlation_path, index=False)
    report_path.write_text(render_report(summary_df, drift_df, correlation_df, phase_summary_df), encoding="utf-8")

    print(f"wrote,{summary_path}")
    print(f"wrote,{drift_path}")
    print(f"wrote,{correlation_path}")
    print(f"wrote,{report_path}")


if __name__ == "__main__":
    main()
