# %% [markdown]
"""
Benchmark Analysis Script

This script is designed as a notebook-friendly `.py` file.
It uses `# %%` cell markers so you can convert/open it as a notebook.

Convert to notebook (if jupytext is installed):
    jupytext --to notebook scripts/benchmark_analysis.py

Run as script:
    python3 scripts/benchmark_analysis.py
"""

# %%
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import re

import matplotlib.pyplot as plt
import pandas as pd


# %%
DATA_DIR = Path("DATA")
OUTPUT_DIR = Path("results")
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)


@dataclass
class FileMeta:
    database: str
    run: int
    scenario: str
    requestdist_file: str
    intensity: str
    variant: str
    source_file: str


def parse_file_metadata(path: Path) -> FileMeta:
    match = re.match(r"(?P<db>[^_]+)_run(?P<run>\d+)_(?P<scenario>.+)\.csv$", path.name)
    if not match:
        raise ValueError(f"Unexpected filename format: {path.name}")

    database = match.group("db")
    run = int(match.group("run"))
    scenario = match.group("scenario")

    parts = scenario.split("_")
    requestdist_file = "uniform" if "uniform" in parts else ("zipfian" if "zipfian" in parts else "unknown")
    intensity = "heavy" if "heavy" in parts else ("light" if "light" in parts else "unknown")

    if "mixed" in parts:
        variant = "mixed"
    elif "vacuum" in parts:
        variant = "vacuum"
    elif "dup" in parts:
        variant = "dup"
    else:
        variant = "base"

    return FileMeta(
        database=database,
        run=run,
        scenario=scenario,
        requestdist_file=requestdist_file,
        intensity=intensity,
        variant=variant,
        source_file=path.name,
    )


COMMON_HEAD = ["Epoch", "Phase", "Recordcount", "Readallfields", "Requestdist", "Operation"]
COMMON_TAIL = [
    "Readprop",
    "Updateprop",
    "Scanprop",
    "Insertprop",
    "Extendprop",
    "Runtime(ms)",
    "Throughput(ops/sec)",
    "Operations",
    "AverageLatency(us)",
    "MinLatency(us)",
    "MaxLatency(us)",
    "95thPercentileLatency(us)",
    "99thPercentileLatency(us)",
    "Return=OK",
]

NEO4J_TAIL = [
    "Readprop",
    "Updateprop",
    "Scanprop",
    "Insertprop",
    "Extendprop",
    "Runtime(ms)",
    "Throughput(ops/sec)",
    "RETURN=ERROR",
    "Operations",
    "AverageLatency(us)",
    "MinLatency(us)",
    "MaxLatency(us)",
    "95thPercentileLatency(us)",
    "99thPercentileLatency(us)",
    "Return=OK",
]


def parse_csv_robust(path: Path) -> pd.DataFrame:
    """
    Parse CSV robustly despite malformed middle columns in some files.

    Strategy:
    - Keep first 6 standard columns from the left.
    - Keep analysis metrics from the right (tail columns).
    - Ignore DB-specific middle columns where malformed commas appear.
    """
    rows = []

    with path.open("r", encoding="utf-8") as f:
        header = f.readline().strip().split(",")
        tail_cols = NEO4J_TAIL if "RETURN=ERROR" in header else COMMON_TAIL

        for line_no, line in enumerate(f, start=2):
            line = line.strip()
            if not line:
                continue

            parts = line.split(",")
            if len(parts) < len(COMMON_HEAD) + len(tail_cols):
                # Too malformed to safely recover
                continue

            head = parts[: len(COMMON_HEAD)]
            tail = parts[-len(tail_cols) :]

            row = dict(zip(COMMON_HEAD, head))
            row.update(dict(zip(tail_cols, tail)))
            row["_line_no"] = line_no
            rows.append(row)

    return pd.DataFrame(rows)


def load_all_data(data_dir: Path) -> pd.DataFrame:
    frames = []

    for csv_path in sorted(data_dir.glob("*.csv")):
        meta = parse_file_metadata(csv_path)
        df = parse_csv_robust(csv_path)
        if df.empty:
            continue

        for key, value in meta.__dict__.items():
            df[key] = value

        frames.append(df)

    if not frames:
        raise RuntimeError(f"No parseable CSV files found in {data_dir.resolve()}")

    data = pd.concat(frames, ignore_index=True)

    numeric_cols = [
        "Epoch",
        "Recordcount",
        "Readprop",
        "Updateprop",
        "Scanprop",
        "Insertprop",
        "Extendprop",
        "Runtime(ms)",
        "Throughput(ops/sec)",
        "Operations",
        "AverageLatency(us)",
        "MinLatency(us)",
        "MaxLatency(us)",
        "95thPercentileLatency(us)",
        "99thPercentileLatency(us)",
        "Return=OK",
        "run",
    ]
    for col in numeric_cols:
        data[col] = pd.to_numeric(data[col], errors="coerce")

    data["Phase"] = data["Phase"].str.lower()
    data["Operation"] = data["Operation"].str.upper()
    data["Requestdist"] = data["Requestdist"].str.lower()

    return data


# %%
raw_df = load_all_data(DATA_DIR)
print(f"Loaded {len(raw_df):,} records from {raw_df['source_file'].nunique()} files")
raw_df.head(10)


# %%
# Focus on benchmark execution rows (exclude setup and reference phases).
analysis_df = raw_df[raw_df["Phase"].isin(["run", "extend", "load"])].copy()

# Optional: remove rows where operation count is missing/non-positive.
analysis_df = analysis_df[analysis_df["Operations"].fillna(0) > 0]

analysis_df[[
    "database",
    "run",
    "scenario",
    "variant",
    "Phase",
    "Operation",
    "Throughput(ops/sec)",
    "AverageLatency(us)",
    "95thPercentileLatency(us)",
]].head(12)


# %%
def weighted_mean(value: pd.Series, weights: pd.Series) -> float:
    w = weights.fillna(0)
    x = value.fillna(0)
    total = w.sum()
    if total == 0:
        return float("nan")
    return float((x * w).sum() / total)


def summarize(df: pd.DataFrame) -> pd.DataFrame:
    grouping = [
        "database",
        "run",
        "scenario",
        "requestdist_file",
        "intensity",
        "variant",
        "Phase",
        "Operation",
    ]

    out = []
    for keys, group in df.groupby(grouping, dropna=False):
        ops = group["Operations"]
        out.append(
            {
                **dict(zip(grouping, keys)),
                "rows": len(group),
                "total_operations": ops.sum(),
                "mean_throughput_ops_sec": weighted_mean(group["Throughput(ops/sec)"], ops),
                "mean_latency_us": weighted_mean(group["AverageLatency(us)"], ops),
                "p95_latency_us": weighted_mean(group["95thPercentileLatency(us)"], ops),
                "p99_latency_us": weighted_mean(group["99thPercentileLatency(us)"], ops),
            }
        )

    return pd.DataFrame(out).sort_values(grouping).reset_index(drop=True)


summary_df = summarize(analysis_df)
summary_path = OUTPUT_DIR / "summary_by_operation.csv"
summary_df.to_csv(summary_path, index=False)
print(f"Saved summary: {summary_path}")
summary_df.head(20)


# %%
# Per-scenario rollup (across operations).
scenario_rollup = (
    summary_df.groupby([
        "database",
        "run",
        "scenario",
        "requestdist_file",
        "intensity",
        "variant",
    ], as_index=False)
    .agg(
        total_operations=("total_operations", "sum"),
        mean_throughput_ops_sec=("mean_throughput_ops_sec", "mean"),
        mean_latency_us=("mean_latency_us", "mean"),
        p95_latency_us=("p95_latency_us", "mean"),
        p99_latency_us=("p99_latency_us", "mean"),
    )
    .sort_values(["database", "run", "scenario"])
)

scenario_rollup_path = OUTPUT_DIR / "scenario_rollup.csv"
scenario_rollup.to_csv(scenario_rollup_path, index=False)
print(f"Saved rollup: {scenario_rollup_path}")
scenario_rollup.head(20)


# %%
# Throughput comparison plot.
plt.figure(figsize=(14, 6))
plot_df = scenario_rollup.sort_values(["database", "scenario", "run"])  # deterministic order
x_labels = [f"{d}\n{sc}\nrun{r}" for d, sc, r in zip(plot_df["database"], plot_df["scenario"], plot_df["run"])]

plt.bar(x_labels, plot_df["mean_throughput_ops_sec"])
plt.ylabel("Mean Throughput (ops/sec)")
plt.title("Benchmark Throughput by Scenario")
plt.xticks(rotation=70, ha="right")
plt.tight_layout()
throughput_plot_path = OUTPUT_DIR / "throughput_by_scenario.png"
plt.savefig(throughput_plot_path, dpi=160)
plt.close()
print(f"Saved plot: {throughput_plot_path}")


# %%
# P95 latency comparison plot.
plt.figure(figsize=(14, 6))
plt.bar(x_labels, plot_df["p95_latency_us"])
plt.ylabel("P95 Latency (us)")
plt.title("Benchmark P95 Latency by Scenario")
plt.xticks(rotation=70, ha="right")
plt.tight_layout()
latency_plot_path = OUTPUT_DIR / "p95_latency_by_scenario.png"
plt.savefig(latency_plot_path, dpi=160)
plt.close()
print(f"Saved plot: {latency_plot_path}")


# %%
# Quick top/bottom views for easier interpretation.
best_throughput = scenario_rollup.nlargest(10, "mean_throughput_ops_sec")
worst_p95 = scenario_rollup.nlargest(10, "p95_latency_us")

best_path = OUTPUT_DIR / "top10_throughput.csv"
worst_path = OUTPUT_DIR / "top10_p95_latency.csv"
best_throughput.to_csv(best_path, index=False)
worst_p95.to_csv(worst_path, index=False)

print(f"Saved top throughput table: {best_path}")
print(f"Saved top p95 latency table: {worst_path}")

print("\nTop throughput scenarios:")
print(best_throughput[["database", "run", "scenario", "mean_throughput_ops_sec", "mean_latency_us"]])

print("\nWorst p95 latency scenarios:")
print(worst_p95[["database", "run", "scenario", "p95_latency_us", "mean_throughput_ops_sec"]])
