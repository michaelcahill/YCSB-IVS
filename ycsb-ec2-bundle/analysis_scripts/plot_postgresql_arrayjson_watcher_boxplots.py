import argparse
import re
from pathlib import Path

import matplotlib

matplotlib.use("Agg")

import matplotlib.pyplot as plt
import pandas as pd


RAW_COLUMNS = ["Phase", "Epoch", "Timestamp", "CPU", "MemoryKB", "DeltaReadBytes", "DeltaWriteBytes"]
PHASE_ORDER = ["reference", "run", "clean-run", "avg-run", "extend"]
METRICS = [
    ("CPU", "cpu_pct", "CPU (%)", 1.0, "#1d3557"),
    ("MemoryKB", "memory_mib", "Memory (MiB)", 1024.0, "#457b9d"),
    ("DeltaReadBytes", "delta_read_bytes", "Delta Read Bytes", 1.0, "#2a9d8f"),
    ("DeltaWriteBytes", "delta_write_bytes", "Delta Write Bytes", 1.0, "#e76f51"),
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Plot watcher metric distributions by epoch.")
    parser.add_argument(
        "--metrics-dir",
        type=Path,
        required=True,
        help="Directory containing raw .metrics files for a single run.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        required=True,
        help="Directory where boxplot PNGs will be written.",
    )
    parser.add_argument(
        "--run-label",
        default="run",
        help="Label used in plot titles and output filenames, for example run6.",
    )
    parser.add_argument(
        "--epochs",
        type=int,
        default=100,
        help="Expected epoch count for repeated phases.",
    )
    return parser.parse_args()


def phase_sort_key(path: Path) -> tuple[int, str]:
    phase = infer_phase_name(path)
    try:
        return PHASE_ORDER.index(phase), path.name
    except ValueError:
        return len(PHASE_ORDER), path.name


def infer_phase_name(path: Path) -> str:
    match = re.search(r"_([a-z-]+)\.metrics$", path.name)
    if match:
        return match.group(1)
    return path.stem


def load_metrics_file(path: Path) -> pd.DataFrame:
    df = pd.read_csv(path, header=None, names=RAW_COLUMNS)
    df["Phase"] = df["Phase"].astype(str).str.lower()
    df["Epoch"] = pd.to_numeric(df["Epoch"], errors="coerce")
    df["Timestamp"] = pd.to_numeric(df["Timestamp"], errors="coerce")
    for column in ["CPU", "MemoryKB", "DeltaReadBytes", "DeltaWriteBytes"]:
        df[column] = pd.to_numeric(df[column], errors="coerce")
    df = df.dropna(subset=["Epoch"])
    return df


def render_metric_boxplot(
    df: pd.DataFrame,
    phase: str,
    source_name: str,
    metric_column: str,
    metric_slug: str,
    metric_label: str,
    scale: float,
    color: str,
    out_path: Path,
    expected_epochs: int,
    run_label: str,
) -> None:
    phase_df = df[(df["Phase"] == phase) & (df["Epoch"].between(1, expected_epochs))].copy()
    phase_df = phase_df.dropna(subset=[metric_column])
    if phase_df.empty:
        return

    epoch_values = []
    epoch_positions = []
    for epoch in range(1, expected_epochs + 1):
        values = phase_df.loc[phase_df["Epoch"] == epoch, metric_column] / scale
        if values.empty:
            continue
        epoch_positions.append(epoch)
        epoch_values.append(values.to_list())

    if not epoch_values:
        return

    fig, ax = plt.subplots(figsize=(24, 6))
    boxplot = ax.boxplot(
        epoch_values,
        positions=epoch_positions,
        widths=0.55,
        showfliers=False,
        patch_artist=True,
        medianprops={"color": "black", "linewidth": 1.0},
        whiskerprops={"color": "#444444", "linewidth": 0.8},
        capprops={"color": "#444444", "linewidth": 0.8},
        boxprops={"edgecolor": "#444444", "linewidth": 0.8},
    )

    for patch in boxplot["boxes"]:
        patch.set_facecolor(color)
        patch.set_alpha(0.75)

    ax.set_xlim(0.5, expected_epochs + 0.5)
    ax.set_xticks(range(1, expected_epochs + 1, 5))
    ax.set_xticklabels(range(1, expected_epochs + 1, 5), rotation=90)
    ax.set_xlabel("Epoch")
    ax.set_ylabel(metric_label)
    ax.set_title(f"{run_label} {phase}: {metric_label} distribution by epoch")
    ax.grid(True, axis="y", alpha=0.3)

    min_samples = min(len(values) for values in epoch_values)
    max_samples = max(len(values) for values in epoch_values)
    ax.text(
        0.995,
        0.98,
        f"epochs={len(epoch_positions)} | samples/epoch={min_samples}-{max_samples}",
        transform=ax.transAxes,
        ha="right",
        va="top",
        fontsize=9,
        bbox={"facecolor": "white", "alpha": 0.7, "edgecolor": "none"},
    )

    fig.tight_layout()
    fig.savefig(out_path, dpi=160, bbox_inches="tight")
    plt.close(fig)


def main() -> None:
    args = parse_args()
    metrics_dir = args.metrics_dir
    output_dir = args.output_dir

    if not metrics_dir.exists():
        raise FileNotFoundError(f"Metrics directory not found: {metrics_dir}")

    metrics_files = sorted(metrics_dir.glob("*.metrics"), key=phase_sort_key)
    if not metrics_files:
        raise RuntimeError(f"No .metrics files found in {metrics_dir}")

    generated = 0
    for metrics_file in metrics_files:
        df = load_metrics_file(metrics_file)
        if df.empty:
            continue

        phase_names = sorted(df["Phase"].dropna().unique().tolist())
        if len(phase_names) != 1:
            raise ValueError(f"Expected exactly one phase in {metrics_file.name}, found {phase_names}")
        phase = phase_names[0]

        if phase == "load":
            continue

        phase_output_dir = output_dir / phase
        phase_output_dir.mkdir(parents=True, exist_ok=True)

        for metric_column, metric_slug, metric_label, scale, color in METRICS:
            out_path = phase_output_dir / f"{args.run_label}_{phase}_{metric_slug}_epoch_boxplots.png"
            render_metric_boxplot(
                df=df,
                phase=phase,
                source_name=metrics_file.name,
                metric_column=metric_column,
                metric_slug=metric_slug,
                metric_label=metric_label,
                scale=scale,
                color=color,
                out_path=out_path,
                expected_epochs=args.epochs,
                run_label=args.run_label,
            )
            if out_path.exists():
                generated += 1
                print(f"generated,{phase},{metric_slug},{out_path}")

    print(f"total_generated,{generated}")


if __name__ == "__main__":
    main()
