from __future__ import annotations

from pathlib import Path
import csv
import re

import matplotlib.pyplot as plt
import pandas as pd


RESULTS_DIR = Path("results")
DATA_DIR = Path("DATA")
OPERATIONS = ["READ", "INSERT", "UPDATE", "EXTEND"]

METRIC_DIR_TO_COLUMN = {
    "postgresql_epoch_avg_latency_us": "AverageLatency(us)",
    "postgresql_epoch_min_latency_us": "MinLatency(us)",
    "postgresql_epoch_max_latency_us": "MaxLatency(us)",
    "postgresql_epoch_p95": "95thPercentileLatency(us)",
    "postgresql_epoch_p95_latency_us": "95thPercentileLatency(us)",
    "postgresql_epoch_p99_latency_us": "99thPercentileLatency(us)",
    "postgresql_epoch_throughput_ops_sec": "Throughput(ops/sec)",
}


def parse_metric_rows(csv_path: Path, metric_col: str, run: int) -> pd.DataFrame:
    rows = []
    with csv_path.open("r", encoding="utf-8", newline="") as f:
        reader = csv.reader(f)
        header = next(reader, None)
        if not header or metric_col not in header:
            return pd.DataFrame(columns=["run", "Epoch", "Operation", "value"])
        metric_idx = header.index(metric_col)

        for row in reader:
            if len(row) <= max(5, metric_idx):
                continue
            rows.append(
                {
                    "run": run,
                    "Epoch": row[0],
                    "Operation": row[5],
                    "value": row[metric_idx],
                }
            )

    df = pd.DataFrame(rows)
    if df.empty:
        return df
    df["Epoch"] = pd.to_numeric(df["Epoch"], errors="coerce")
    df["Operation"] = df["Operation"].astype(str).str.upper()
    df["value"] = pd.to_numeric(df["value"], errors="coerce")
    df = df.dropna(subset=["Epoch", "Operation", "value"])
    return df


def summarize_runs(frames: list[pd.DataFrame]) -> pd.DataFrame:
    if not frames:
        return pd.DataFrame(columns=["Operation", "Epoch", "mean", "sd"])

    all_df = pd.concat(frames, ignore_index=True)
    # First: collapse any duplicates within each run.
    per_run = (
        all_df.groupby(["run", "Operation", "Epoch"], as_index=False)["value"]
        .mean()
        .sort_values(["run", "Operation", "Epoch"])
    )

    # Then aggregate across runs.
    summary = (
        per_run.groupby(["Operation", "Epoch"])["value"]
        .agg(["mean", lambda s: s.std(ddof=1)])
        .reset_index()
        .sort_values(["Operation", "Epoch"])
    )
    lambda_col = [c for c in summary.columns if c not in ("Operation", "Epoch", "mean")]
    if lambda_col:
        summary = summary.rename(columns={lambda_col[0]: "sd"})
    else:
        summary["sd"] = 0.0
    summary["sd"] = summary["sd"].fillna(0.0)
    return summary


def plot_summary(summary: pd.DataFrame, out_path: Path, title: str, ylabel: str) -> None:
    fig, axes = plt.subplots(2, 2, figsize=(12, 8), sharex=False, sharey=False)
    axes = axes.flatten()

    for ax, op in zip(axes, OPERATIONS):
        op_df = summary[summary["Operation"] == op]
        ax.set_title(op)
        ax.set_xlabel("Epoch")
        ax.set_ylabel(ylabel)
        if op_df.empty:
            ax.grid(False)
            continue

        x = op_df["Epoch"]
        mean = op_df["mean"]
        band = 2.0 * op_df["sd"]
        lower = mean - band
        upper = mean + band

        ax.plot(x, mean, marker="o", label="mean")
        ax.fill_between(x, lower, upper, alpha=0.2, label="mean ± 2*sd")
        ax.grid(True, alpha=0.3)
        ax.legend(loc="best", fontsize=8)

    fig.suptitle(title, y=1.02)
    fig.tight_layout()
    fig.savefig(out_path, dpi=160, bbox_inches="tight")
    plt.close(fig)


def extract_run_and_scenario(filename: str) -> tuple[int, str] | None:
    m = re.match(r"^postgresql_run(\d+)_(.+?)_epoch_vs_.*\.png$", filename)
    if not m:
        return None
    return int(m.group(1)), m.group(2)


def main() -> None:
    processed = 0
    for metric_dir_name, metric_col in METRIC_DIR_TO_COLUMN.items():
        metric_dir = RESULTS_DIR / metric_dir_name
        if not metric_dir.is_dir():
            continue

        for scenario_dir in sorted([d for d in metric_dir.iterdir() if d.is_dir() and d.name != "raw"]):
            raw_dir = scenario_dir / "raw"
            raw_dir.mkdir(parents=True, exist_ok=True)

            # Move per-run plots into raw/
            run_plots = [p for p in scenario_dir.glob("postgresql_run*.png") if p.is_file()]
            for plot in run_plots:
                target = raw_dir / plot.name
                if target.exists():
                    plot.unlink()
                else:
                    plot.rename(target)

            # Identify runs from raw filenames.
            run_files = sorted([p for p in raw_dir.glob("postgresql_run*.png") if p.is_file()])
            run_to_datafile = {}
            for rf in run_files:
                parsed = extract_run_and_scenario(rf.name)
                if not parsed:
                    continue
                run_num, scenario_name = parsed
                data_file = DATA_DIR / f"postgresql_run{run_num}_{scenario_name}.csv"
                if data_file.exists():
                    run_to_datafile[run_num] = data_file

            frames = []
            for run_num, data_file in sorted(run_to_datafile.items()):
                frames.append(parse_metric_rows(data_file, metric_col, run_num))

            summary = summarize_runs(frames)
            out_path = scenario_dir / "summary_mean_plusminus_2sd.png"
            plot_summary(
                summary=summary,
                out_path=out_path,
                title=f"{metric_dir_name}/{scenario_dir.name}: mean ± 2*sd",
                ylabel=metric_col,
            )
            processed += 1

    print(f"Processed scenario directories: {processed}")


if __name__ == "__main__":
    main()
