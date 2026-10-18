"""Plot all workload CSVs for one experiment configuration.

Usage (Python 3.10+, pandas and matplotlib):
    python3 plot_postgresql_epoch_metrics.py /path/to/workload_csv_directory
    python3 plot_postgresql_epoch_metrics.py --no-title /path/to/workload_csv_directory

--no-title produces the untitled figures used in the paper.
"""

from pathlib import Path
import argparse
import csv
import re

import matplotlib.pyplot as plt
import pandas as pd


ROOT = Path(__file__).resolve().parents[1]
RESULTS_DIR = ROOT / "figures"

OPERATIONS = ["READ", "INSERT", "UPDATE", "EXTEND"]
RUN_PHASE_ORDER = ["run", "clean-run", "avg-run", "textrow", "textarray", "json", "run-uniform", "run-zipfian"]
EXTEND_PHASE_ORDER = ["extend", "extend-textrow", "extend-textarray", "extend-json", "extend-uniform", "extend-zipfian"]
#PHASE_LABELS = {"run": "main-run", "clean-run": "clean-run", "avg-run": "avg-run", "extend": "extend"}
PHASE_LABELS = {"run": "incr-extend", "clean-run": "bulk-loaded", "avg-run": "equal-avg-size", "extend": "extend", 
                # dummy-phases used to plot data type comparisons into one plot
                "textrow": "textrow", "textarray": "textarrays", "json": "json", "extend-textrow": "extend-textrow", "extend-textarray": "extend-textarray", "extend-json": "extend-json",
                # dummy-phases used to plot unifrom-vs-zipfian extend comparisons into one plot
                "run-uniform": "incr-extend (uniform)", "extend-uniform": "extend (uniform)", "run-zipfian": "incr-extend (zipfian)", "extend-zipfian": "extend (zipfian)"
                }
PHASE_MARKERS = {"run": "o", "clean-run": "^", "avg-run": "x", "extend": "D", 
                 "textrow": "^", "textarray":"o", "json": "x", 
                 "extend-textrow": "^", "extend-textarray": "o", "extend-json": "*",
                 "run-uniform": "D", "extend-uniform": "D",
                 "run-zipfian": "P", "extend-zipfian": "P"}

METRICS = [
    # metric_col, folder_name, metric_label
    ("AverageLatency(us)", "avg_latency_us", "Average Latency (us)"),
    ("MinLatency(us)", "min_latency_us", "Min Latency (us)"),
    ("MaxLatency(us)", "max_latency_us", "Max Latency (us)"),
    ("95thPercentileLatency(us)", "p95_latency_us", "P95 Latency (us)"),
    ("99thPercentileLatency(us)", "p99_latency_us", "P99 Latency (us)"),
    ("Throughput(ops/sec)", "throughput_ops_sec", "Throughput (ops/sec)"),
    ("toast_size_in_GiB", "toast_size_GiB", "TOAST Size (GiB)",),# =BP2/(1024*1024*1024)
    ("blks_read","total_blks_read","blocks read"),
    ("usertable_heap_blks_epoch","usertable_heap_blks_epoch","usertable_heap_blks_epoch"),
    ("toast_blks_epoch","toast_blks_epoch","toast_blks_epoch"),
    ("usertable_n_tup_upd","usertable_n_tup_upd","usertable_n_tup_upd"),
    ("usertable_n_tup_upd_epoch","usertable_n_tup_upd_epoch","usertable_n_tup_upd_epoch"),
    ("toast_n_tup_ins","toast_n_tup_ins","toast_n_tup_ins"),
    ("toast_n_tup_ins_epoch","toast_n_tup_ins_epoch","toast_n_tup_ins_epoch"),
    ("write_amplification","write_amplification","write amplification"),
]


METRIC_TITLES = {
    "AverageLatency(us)": "Mean Operation Latency Across Epochs",
    "MinLatency(us)": "Minimum Operation Latency Across Epochs",
    "MaxLatency(us)": "Maximum Operation Latency Across Epochs",
    "95thPercentileLatency(us)": "95th-Percentile Operation Latency Across Epochs",
    "99thPercentileLatency(us)": "99th-Percentile Operation Latency Across Epochs",
    "Throughput(ops/sec)": "Operation Throughput Across Epochs",
    "toast_size_in_GiB": "TOAST Storage Size Across Epochs",
    "blks_read": "Blocks Read",
    "usertable_heap_blks_epoch":"usertable_heap_blks_epoch",
    "toast_blks_epoch":"toast_blks_epoch",
    "usertable_n_tup_upd":"usertable_n_tup_upd",
    "usertable_n_tup_upd_epoch":"usertable_n_tup_upd_epoch",
    "toast_n_tup_ins":"toast_n_tup_ins",
    "toast_n_tup_ins_epoch":"toast_n_tup_ins_epoch",
    "write_amplification": "Write Amplification"
}


def extract_suffix(csv_path: Path) -> str:
    return csv_path.parent.name


def parse_rows(csv_path: Path, metric_col_name: str) -> pd.DataFrame:
    rows = []
    with csv_path.open("r", encoding="utf-8", newline="") as f:
        reader = csv.reader(f)
        header = next(reader, None)
        if not header:
            return pd.DataFrame(columns=["Epoch", "Phase", "Operation", "metric"])

        if metric_col_name not in header:
            return pd.DataFrame(rows) # allow datafiles to be processed which did not collect all metrics
            # raise ValueError(f"{metric_col_name} missing in {csv_path.name}")

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


def add_wrapped_title(fig, title):
    """Keep every title line within the combined plotting area."""
    fig.tight_layout()
    fig.canvas.draw()
    heading = fig.suptitle("", y=0.98, va="top", fontsize=11)
    heading.set_in_layout(False)  # Space is reserved explicitly below.
    font = heading.get_fontproperties()
    # Wrap only when the rendered text exceeds the plotting width.
    title = " ".join(title.split())
    max_width = float("inf")
    for _ in range(4):
        renderer = fig.canvas.get_renderer()
        left = min(ax.get_window_extent(renderer).x0 for ax in fig.axes)
        right = max(ax.get_window_extent(renderer).x1 for ax in fig.axes)
        max_width = min(max_width, (right - left) * 0.98)
        heading.set_x((left + right) / 2 / fig.bbox.width)

        def width(text):
            return renderer.get_text_width_height_descent(text, font, ismath=False)[0]

        lines = []
        for paragraph in title.splitlines():
            line = ""
            for word in paragraph.split():
                if line and width(f"{line} {word}") > max_width:
                    lines.append(line)
                    line = ""
                while width(word) > max_width:
                    split = len(word) - 1
                    while split > 1 and width(word[:split]) > max_width:
                        split -= 1
                    lines.append(word[:split])
                    word = word[split:]
                line = f"{line} {word}".strip()
            if line:
                lines.append(line)
        heading.set_text("\n".join(lines))
        fig.canvas.draw()
        title_height = heading.get_window_extent(fig.canvas.get_renderer()).height
        top = 0.98 - (title_height + 12 * fig.dpi / 72) / fig.bbox.height
        fig.tight_layout(rect=(0, 0, 1, top))
        fig.canvas.draw()
    left = min(ax.get_position().x0 for ax in fig.axes)
    right = max(ax.get_position().x1 for ax in fig.axes)
    heading.set_x((left + right) / 2)
    return heading


def render_plot(
    df: pd.DataFrame,
    metric_ylabel: str,
    phase_order: list[str],
    title: str | None,
    out_path: Path,
    band_df: pd.DataFrame | None = None,
) -> int:
    """Write one figure per operation; return the number of figures written."""
    operations_to_plot = [op for op in OPERATIONS if not df[df["Operation"] == op].empty]

    for operation in operations_to_plot:
        figsize = (6, 4) if title is not None else (6, 3)
        fig, ax = plt.subplots(1, 1, figsize=figsize)

        op_df = df[df["Operation"] == operation]
        plotted_any_phase = False
        for phase in phase_order:
            if phase not in op_df["Phase"].values:
                continue
            phase_df = op_df[op_df["Phase"] == phase]
            by_epoch = phase_df.groupby("Epoch", as_index=False)["metric"].mean().sort_values("Epoch")
            ax.plot(by_epoch["Epoch"], by_epoch["metric"], marker=PHASE_MARKERS.get(phase), markersize=3, label=PHASE_LABELS.get(phase, phase))
            if band_df is not None:
                phase_band = band_df[(band_df["Operation"] == operation) & (band_df["Phase"] == phase)].sort_values("Epoch")
                if not phase_band.empty:
                    ax.fill_between(
                        phase_band["Epoch"],
                        phase_band["lower"],
                        phase_band["upper"],
                        alpha=0.2,
                    )
            plotted_any_phase = True

        if title is not None:
            ax.set_title(operation)
        ax.set_xlabel("Epoch")
        ax.set_ylabel(metric_ylabel)
        ax.grid(True, alpha=0.3)
        if plotted_any_phase:
            ax.legend(fontsize=8)

        out_path_fig = f"{out_path.with_suffix('')}_{operation}.png"
        if title is not None:
            heading = add_wrapped_title(fig, title)
            fig.savefig(out_path_fig, dpi=160, bbox_inches="tight", bbox_extra_artists=(heading,))
        else:
            fig.savefig(out_path_fig, dpi=160, bbox_inches="tight")
        plt.close(fig)

    return len(operations_to_plot)


def make_plot(
    csv_path: Path,
    metric_col_name: str,
    metric_ylabel: str,
    output_dir: Path,
    phase_order: list[str],
    plot_suffix: str,
    with_title: bool = True,
) -> int:
    df = parse_rows(csv_path, metric_col_name)
    if df.empty:
        return 0
    df = df[df["Phase"].isin(phase_order)]
    metric_slug = re.sub(r"[^A-Za-z0-9._-]+", "_", metric_col_name).strip("_")
    out_path = output_dir / f"{csv_path.stem}_{plot_suffix}_epoch_vs_{metric_slug}.png"
    title = individual_title(metric_col_name, csv_path) if with_title else None
    return render_plot(df, metric_ylabel, phase_order, title, out_path)


def experiment_configuration(name, csv_path=None):
    """Decode modern, legacy, and abbreviated experiment names for any backend."""
    name = name.lower()
    match = re.search(r"(light|heavy)_extend-([a-z]+)_(.+?)-([a-z]+)(?:_run\d+.*)?$", name)
    if match:
        level, extension, workload, access = match.groups()
    else:
        match = re.search(r"(light|heavy)_ro([a-z]+)_ext([a-z]+)", name)
        if match:
            level, access, extension = match.groups()
            workload = "readonly"
        else:
            match = re.search(r"(uniform|zipfian)_(light|heavy)_(pure|mixed|spreadrun)", name)
            if not match:
                return None
            extension, level, workload = match.groups()
            access = "unspecified"
            # Legacy filenames omit access distribution; use recorded run metadata.
            if csv_path is not None and csv_path.is_file():
                with csv_path.open(encoding="utf-8", newline="") as stream:
                    distributions = {
                        row.get("Requestdist", "").strip().lower()
                        for row in csv.DictReader(stream)
                        if row.get("Phase", "").lower() in RUN_PHASE_ORDER
                    } - {"", "na"}
                if distributions:
                    access = "/".join(sorted(distributions))
    aliases = {"uni": "Uniform", "zip": "Zipfian", "zipf": "Zipfian"}
    def distribution(value):
        return aliases.get(value, value.replace("_", " ").title())
    workloads = {
        "readonly": "Read-Only Workload", "read-only": "Read-Only Workload",
        "pure": "Read-Only Workload", "mixed": "Mixed Read–Update Workload",
        "spreadrun": "Spread Workload",
    }
    ratio = re.fullmatch(r"readupd(\d+)", workload)
    if ratio and 0 <= int(ratio.group(1)) <= 100:
        reads = int(ratio.group(1))
        workload_label = f"{reads}% Read–{100 - reads}% Update Workload"
    else:
        workload_label = workloads.get(workload, workload.replace("-", " ").replace("_", " ").title() + " Workload")
    return f"{level.title()}, {distribution(extension)} EXTEND, {workload_label}, {distribution(access)} Access"


def experiment_data_type(name):
    """Identify storage representation from backend or value-variant names."""
    name = name.lower()
    # Specific variants take precedence over legacy backend aliases.
    if re.search(r"text_?arrays?|txtarrays?", name):
        return "Text Array"
    if re.search(r"text_?(?:row|scalar)|txtrow", name):
        return "Text Row"
    if re.search(r"jsonb|array_?json|postgresql_json", name):
        return "JSONB"
    if re.search(r"postgresql_array(?:_|$)", name):
        return "Text Array"
    return None

def plot_data_type(suffix_name, csv_paths):
    data_types = set()
    for path in csv_paths:
        for name in [path.stem] + [parent.name for parent in path.parents]:
            data_type = experiment_data_type(name)
            if data_type is not None:
                data_types.add(data_type)
                break
    if not data_types:
        data_type = experiment_data_type(suffix_name)
        if data_type is not None:
            data_types.add(data_type)
    if len(data_types) == 1:
        return next(iter(data_types))
    if data_types:
        return "Multiple Data Types"
    return "Unspecified Data Type"


def aggregation_title(metric_col_name, suffix_name, csv_paths):
    """Apply the same title pattern to every experiment backend and configuration."""
    configurations = set()
    for path in csv_paths:
        configuration = experiment_configuration(path.stem, path)
        if configuration is None:
            # Experiment folders can carry configuration omitted from CSV names.
            for parent in path.parents:
                configuration = experiment_configuration(parent.name, path)
                if configuration is not None:
                    break
        if configuration is not None:
            configurations.add(configuration)
    if not configurations:
        configuration = experiment_configuration(suffix_name)
        if configuration is not None:
            configurations.add(configuration)
    if len(configurations) == 1:
        configuration = next(iter(configurations))
    elif configurations:
        configuration = "Multiple Configurations"
    else:
        configuration = suffix_name.replace("_", " ")
    data_type = plot_data_type(suffix_name, csv_paths)
    return f"{data_type}: {METRIC_TITLES[metric_col_name]} — {configuration}"


def individual_title(metric_col_name, csv_path):
    title = aggregation_title(metric_col_name, extract_suffix(csv_path), [csv_path])
    for name in [csv_path.stem] + [parent.name for parent in csv_path.parents]:
        match = re.search(r"(?:^|_)run(\d+)(?:_|$)", name, re.IGNORECASE)
        if match:
            return f"{title} (Run {match.group(1)})"
    return title


def make_summary_plot(
    csv_paths: list[Path],
    metric_col_name: str,
    metric_ylabel: str,
    output_dir: Path,
    phase_order: list[str],
    plot_suffix: str,
    suffix_name: str,
    with_title: bool = True,
) -> int:
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
        return 0

    metric_slug = re.sub(r"[^A-Za-z0-9._-]+", "_", metric_col_name).strip("_")
    out_path = output_dir / f"{suffix_name}_summary_mean_{plot_suffix}_epoch_vs_{metric_slug}.png"
    title = (
        f"{aggregation_title(metric_col_name, suffix_name, csv_paths)} "
        f"(All Runs: Mean ± 2 SD)"
    ) if with_title else None
    return render_plot(summary_df, metric_ylabel, phase_order, title, out_path, band_df=band_df)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Plot workload CSVs directly inside one experiment directory."
    )
    parser.add_argument(
        'directory', type=Path,
        help='Directory containing all workload CSVs for one experiment configuration',
    )
    parser.add_argument(
        '--no-title', action='store_true',
        help='Omit figure and operation titles (paper style)',
    )
    args = parser.parse_args()
    input_root = args.directory.expanduser().resolve()
    if not input_root.is_dir():
        parser.error(f'Input directory does not exist: {input_root}')
    files = sorted(
        path for path in input_root.glob('*.csv')
        if not path.stem.upper().endswith('IGNORE')
    )
    if not files:
        parser.error(f'No workload CSVs found directly inside {input_root}')
    with_title = not args.no_title
    result_root = RESULTS_DIR / input_root.relative_to(ROOT / "datafiles")
    files_by_suffix: dict[tuple[Path, str], list[Path]] = {}
    individual = 0
    for csv_path in files:
        key = (result_root, extract_suffix(csv_path))
        files_by_suffix.setdefault(key, []).append(csv_path)
        for metric_col, folder_name, metric_label in METRICS:
            for phases, phase_name in ((RUN_PHASE_ORDER, 'run'), (EXTEND_PHASE_ORDER, 'extend')):
                output = result_root / folder_name / phase_name
                output.mkdir(parents=True, exist_ok=True)
                individual += make_plot(csv_path, metric_col, metric_label, output, phases, phase_name, with_title)
    print(f'{input_root.name}: {individual} individual plots')
    # A single CSV already has a plot named with its full source stem and run number.
    # Generate aggregate summaries only when multiple runs contribute.
    summaries = 0
    for (result_root, suffix), files in sorted(files_by_suffix.items()):
        if len(files) < 2:
            continue
        for metric_col, folder_name, metric_label in METRICS:
            for phases, phase_name in ((RUN_PHASE_ORDER, 'run'), (EXTEND_PHASE_ORDER, 'extend')):
                output = result_root / folder_name / phase_name
                output.mkdir(parents=True, exist_ok=True)
                summaries += make_summary_plot(files, metric_col, metric_label, output, phases, phase_name, suffix, with_title)
    # Remove folders left empty by metrics or phases the CSVs do not contain.
    for folder in sorted(result_root.glob('*/*'), reverse=True) + sorted(result_root.glob('*')):
        if folder.is_dir() and not any(folder.iterdir()):
            folder.rmdir()
    print(f'Total generated plots: {individual + summaries} ({summaries} summaries); output root: {result_root}')


if __name__ == "__main__":
    main()
