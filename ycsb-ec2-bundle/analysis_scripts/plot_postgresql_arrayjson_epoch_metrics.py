import argparse
from pathlib import Path
import csv
import re

import matplotlib.pyplot as plt
import pandas as pd


DEFAULT_DATA_DIR = Path("DATA")
DEFAULT_RESULTS_DIR = Path("results")

OPERATIONS = ["READ", "INSERT", "UPDATE", "EXTEND"]
RUN_PHASE_ORDER = ["run", "clean-run", "avg-run"]
EXTEND_PHASE_ORDER = ["extend"]
PHASE_LABELS = {"run": "main-run", "clean-run": "clean-run", "avg-run": "avg-run", "extend": "extend"}
METRICS = [
    ("AverageLatency(us)", "avg_latency_us", "Average Latency (us)"),
    ("MinLatency(us)", "min_latency_us", "Min Latency (us)"),
    ("MaxLatency(us)", "max_latency_us", "Max Latency (us)"),
    ("95thPercentileLatency(us)", "p95_latency_us", "P95 Latency (us)"),
    ("99thPercentileLatency(us)", "p99_latency_us", "P99 Latency (us)"),
    ("Throughput(ops/sec)", "throughput_ops_sec", "Throughput (ops/sec)"),
]


def extract_suffix(csv_path: Path) -> str:
    stem = csv_path.stem
    with_variant = re.match(r"^postgresql_arrayjson_(.+)_run\d+_(.+)$", stem)
    if with_variant:
        variant = with_variant.group(1)
        scenario = with_variant.group(2)
        return "_".join(part for part in [variant, scenario] if part)

    without_variant = re.match(r"^postgresql_arrayjson_run\d+_(.+)$", stem)
    if without_variant:
        return without_variant.group(1)

    return "unknown"


def parse_rows(csv_path: Path, metric_col_name: str) -> pd.DataFrame:
    rows = []
    with csv_path.open("r", encoding="utf-8", newline="") as f:
        reader = csv.reader(f)
        header = next(reader, None)
        if not header:
            return pd.DataFrame(columns=["Epoch", "Phase", "Operation", "metric"])

        if metric_col_name not in header:
            raise ValueError(f"{metric_col_name} missing in {csv_path.name}")

        metric_idx = header.index(metric_col_name)
        epoch_idx = header.index("Epoch") if "Epoch" in header else 0
        phase_idx = header.index("Phase") if "Phase" in header else 1
        operation_idx = header.index("Operation") if "Operation" in header else 5

        for row in reader:
            if len(row) <= max(epoch_idx, phase_idx, operation_idx, metric_idx):
                continue
            rows.append(
                {
                    "Epoch": row[epoch_idx],
                    "Phase": row[phase_idx],
                    "Operation": row[operation_idx],
                    "metric": row[metric_idx],
                }
            )

    df = pd.DataFrame(rows)
    if df.empty:
        return df

    df["Phase"] = df["Phase"].astype(str).str.lower()
    df["Operation"] = df["Operation"].astype(str).str.upper()
    df["Epoch"] = pd.to_numeric(df["Epoch"], errors="coerce")
    df["metric"] = pd.to_numeric(df["metric"], errors="coerce")
    df = df.dropna(subset=["Epoch", "Phase", "Operation", "metric"])
    return df


def render_plot(
    df: pd.DataFrame,
    metric_ylabel: str,
    phase_order: list[str],
    title: str,
    out_path: Path,
    band_df: pd.DataFrame | None = None,
) -> Path:
    operations_to_plot = [op for op in OPERATIONS if not df[df["Operation"] == op].empty]
    if len(operations_to_plot) > 2:
        operations_to_plot = operations_to_plot[:2]
    if not operations_to_plot:
        operations_to_plot = [OPERATIONS[0]]

    if len(operations_to_plot) == 1:
        fig, ax = plt.subplots(1, 1, figsize=(6, 4), sharex=False, sharey=False)
        axes = [ax]
    else:
        fig, axes = plt.subplots(1, 2, figsize=(12, 4), sharex=False, sharey=False)
        axes = list(axes)

    for ax, operation in zip(axes, operations_to_plot):
        op_df = df[df["Operation"] == operation]
        if op_df.empty:
            ax.set_title(operation)
            ax.set_xlabel("Epoch")
            ax.set_ylabel(metric_ylabel)
            ax.grid(False)
            continue

        plotted_any_phase = False
        for phase in phase_order:
            if phase not in op_df["Phase"].values:
                continue
            phase_df = op_df[op_df["Phase"] == phase]
            by_epoch = phase_df.groupby("Epoch", as_index=False)["metric"].mean().sort_values("Epoch")
            ax.plot(by_epoch["Epoch"], by_epoch["metric"], marker="o", label=PHASE_LABELS.get(phase, phase))
            if band_df is not None:
                phase_band = band_df[(band_df["Operation"] == operation) & (band_df["Phase"] == phase)].sort_values(
                    "Epoch"
                )
                if not phase_band.empty:
                    ax.fill_between(
                        phase_band["Epoch"],
                        phase_band["lower"],
                        phase_band["upper"],
                        alpha=0.2,
                    )
            plotted_any_phase = True

        ax.set_title(operation)
        ax.set_xlabel("Epoch")
        ax.set_ylabel(metric_ylabel)
        ax.grid(True, alpha=0.3)
        if plotted_any_phase:
            ax.legend(title="Phase", fontsize=8)

    fig.suptitle(title, y=1.02)
    fig.tight_layout()
    fig.savefig(out_path, dpi=160, bbox_inches="tight")
    plt.close(fig)
    return out_path


def make_plot(
    csv_path: Path,
    metric_col_name: str,
    metric_ylabel: str,
    output_dir: Path,
    phase_order: list[str],
    plot_suffix: str,
) -> Path:
    df = parse_rows(csv_path, metric_col_name)
    df = df[df["Phase"].isin(phase_order)]
    metric_slug = re.sub(r"[^A-Za-z0-9._-]+", "_", metric_col_name).strip("_")
    out_path = output_dir / f"{csv_path.stem}_{plot_suffix}_epoch_vs_{metric_slug}.png"
    title = f"{csv_path.stem} [{plot_suffix}]: Epoch vs {metric_ylabel} by Operation"
    return render_plot(df, metric_ylabel, phase_order, title, out_path)


def make_summary_plot(
    csv_paths: list[Path],
    metric_col_name: str,
    metric_ylabel: str,
    output_dir: Path,
    phase_order: list[str],
    plot_suffix: str,
    suffix_name: str,
) -> Path:
    per_file_frames = []
    for csv_path in csv_paths:
        df = parse_rows(csv_path, metric_col_name)
        if df.empty:
            continue
        df = df[df["Phase"].isin(phase_order)].copy()
        if df.empty:
            continue
        df["source"] = csv_path.stem
        per_file_frames.append(df)

    band_df = pd.DataFrame(columns=["Epoch", "Phase", "Operation", "lower", "upper"])
    if per_file_frames:
        merged = pd.concat(per_file_frames, ignore_index=True)
        per_file_mean = merged.groupby(["source", "Epoch", "Phase", "Operation"], as_index=False)["metric"].mean()

        mean_df = per_file_mean.groupby(["Epoch", "Phase", "Operation"], as_index=False)["metric"].mean()
        std_df = (
            per_file_mean.groupby(["Epoch", "Phase", "Operation"], as_index=False)["metric"]
            .std()
            .rename(columns={"metric": "std"})
        )
        summary_df = mean_df.merge(std_df, on=["Epoch", "Phase", "Operation"], how="left")
        summary_df["std"] = summary_df["std"].fillna(0.0)
        summary_df["lower"] = summary_df["metric"] - 2.0 * summary_df["std"]
        summary_df["upper"] = summary_df["metric"] + 2.0 * summary_df["std"]
        band_df = summary_df[["Epoch", "Phase", "Operation", "lower", "upper"]].copy()
        summary_df = summary_df[["Epoch", "Phase", "Operation", "metric"]]
    else:
        summary_df = pd.DataFrame(columns=["Epoch", "Phase", "Operation", "metric"])

    metric_slug = re.sub(r"[^A-Za-z0-9._-]+", "_", metric_col_name).strip("_")
    out_path = output_dir / f"{suffix_name}_summary_mean_{plot_suffix}_epoch_vs_{metric_slug}.png"
    title = f"{suffix_name} [summary-mean+-2sd-{plot_suffix}]: Epoch vs {metric_ylabel} by Operation"
    return render_plot(summary_df, metric_ylabel, phase_order, title, out_path, band_df=band_df)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Plot PostgreSQL arrayjson epoch metrics.")
    parser.add_argument(
        "--data-dir",
        type=Path,
        default=DEFAULT_DATA_DIR,
        help="Directory containing postgresql_arrayjson*.csv files.",
    )
    parser.add_argument(
        "--results-dir",
        type=Path,
        default=DEFAULT_RESULTS_DIR,
        help="Base directory where plots will be written.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    data_dir = args.data_dir
    results_dir = args.results_dir

    files = sorted(data_dir.glob("postgresql_arrayjson*.csv"))
    if not files:
        raise RuntimeError(f"No PostgreSQL arrayjson files found in {data_dir}/")

    base_out_dir = results_dir / "postgresql_arrayjson"
    base_out_dir.mkdir(parents=True, exist_ok=True)

    files_by_suffix: dict[str, list[Path]] = {}
    for csv_path in files:
        suffix = extract_suffix(csv_path)
        files_by_suffix.setdefault(suffix, []).append(csv_path)

    total = 0
    suffix_summary: dict[str, dict[str, object]] = {}
    for suffix, suffix_files in sorted(files_by_suffix.items()):
        generated_for_suffix = 0

        for metric_col, folder_name, metric_label in METRICS:
            metric_dir = base_out_dir / f"postgresql_arrayjson_epoch_{folder_name}"
            suffix_dir = metric_dir / suffix
            run_out_dir = suffix_dir / "run"
            extend_out_dir = suffix_dir / "extend"
            run_out_dir.mkdir(parents=True, exist_ok=True)
            extend_out_dir.mkdir(parents=True, exist_ok=True)

            for csv_path in suffix_files:
                make_plot(
                    csv_path=csv_path,
                    metric_col_name=metric_col,
                    metric_ylabel=metric_label,
                    output_dir=run_out_dir,
                    phase_order=RUN_PHASE_ORDER,
                    plot_suffix="run",
                )
                make_plot(
                    csv_path=csv_path,
                    metric_col_name=metric_col,
                    metric_ylabel=metric_label,
                    output_dir=extend_out_dir,
                    phase_order=EXTEND_PHASE_ORDER,
                    plot_suffix="extend",
                )
                generated_for_suffix += 2
                total += 2

            make_summary_plot(
                csv_paths=suffix_files,
                metric_col_name=metric_col,
                metric_ylabel=metric_label,
                output_dir=run_out_dir,
                phase_order=RUN_PHASE_ORDER,
                plot_suffix="run",
                suffix_name=suffix,
            )
            make_summary_plot(
                csv_paths=suffix_files,
                metric_col_name=metric_col,
                metric_ylabel=metric_label,
                output_dir=extend_out_dir,
                phase_order=EXTEND_PHASE_ORDER,
                plot_suffix="extend",
                suffix_name=suffix,
            )
            generated_for_suffix += 2
            total += 2

        suffix_summary[suffix] = {
            "files": [p.name for p in suffix_files],
            "plots": generated_for_suffix,
        }

    print(f"Total generated plots: {total}")
    print(f"Data directory: {data_dir}")
    print(f"Results directory: {base_out_dir}")
    print("Summary by suffix:")
    for suffix, info in suffix_summary.items():
        files_list = ", ".join(info["files"])  # type: ignore[index]
        print(f"- {suffix}: {info['plots']} plots from {len(info['files'])} file(s): {files_list}")  # type: ignore[index]


if __name__ == "__main__":
    main()
