from __future__ import annotations

import re
from pathlib import Path

import pandas as pd


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "JSON_BLUE"
OUTPUT_DIR = ROOT / "JSON_BLUE_COMBINED"

RAW_METRIC_COLUMNS = [
    "Phase",
    "Epoch",
    "Timestamp",
    "CPU",
    "MemoryKB",
    "DeltaReadBytes",
    "DeltaWriteBytes",
]

PHASE_FILE_PATTERNS = {
    "load": "ycsb_postgresql_arrayjson_*_load.metrics",
    "run": "ycsb_postgresql_arrayjson_*_run.metrics",
    "extend": "ycsb_postgresql_arrayjson_*_extend.metrics",
    "clean-run": "ycsb_backup_postgresql_arrayjson_*_clean-run.metrics",
    "avg-run": "ycsb_backup_postgresql_arrayjson_*_avg-run.metrics",
    "reference": "ycsb_unchange_postgresql_arrayjson_*_reference.metrics",
}

STAT_COLUMNS = [
    "WatcherSamples",
    "WatcherCPU_min",
    "WatcherCPU_q1",
    "WatcherCPU_median",
    "WatcherCPU_q3",
    "WatcherCPU_max",
    "WatcherMemoryKB_min",
    "WatcherMemoryKB_q1",
    "WatcherMemoryKB_median",
    "WatcherMemoryKB_q3",
    "WatcherMemoryKB_max",
]


def extract_run_number(path: Path) -> int | None:
    match = re.search(r"_run(\d+)_", path.name)
    if not match:
        return None
    return int(match.group(1))


def load_phase_metrics(metrics_dir: Path, phase: str) -> pd.DataFrame:
    pattern = PHASE_FILE_PATTERNS[phase]
    files = sorted(metrics_dir.glob(pattern))
    frames: list[pd.DataFrame] = []

    for path in files:
        df = pd.read_csv(path, header=None, names=RAW_METRIC_COLUMNS)
        df["Phase"] = df["Phase"].astype(str).str.lower()
        df["Epoch"] = pd.to_numeric(df["Epoch"], errors="coerce")
        df["CPU"] = pd.to_numeric(df["CPU"], errors="coerce")
        df["MemoryKB"] = pd.to_numeric(df["MemoryKB"], errors="coerce")
        df = df[(df["Phase"] == phase) & df["Epoch"].notna()].copy()
        if not df.empty:
            frames.append(df[["Phase", "Epoch", "CPU", "MemoryKB"]])

    if not frames:
        return pd.DataFrame(columns=RAW_METRIC_COLUMNS)

    return pd.concat(frames, ignore_index=True)


def summarize_metrics(metrics_dir: Path) -> pd.DataFrame:
    if not metrics_dir.exists():
        return pd.DataFrame(columns=["Phase", "Epoch", *STAT_COLUMNS])

    frames = [load_phase_metrics(metrics_dir, phase) for phase in PHASE_FILE_PATTERNS]
    frames = [df for df in frames if not df.empty]
    if not frames:
        return pd.DataFrame(columns=["Phase", "Epoch", *STAT_COLUMNS])

    metrics = pd.concat(frames, ignore_index=True)

    grouped = metrics.groupby(["Phase", "Epoch"], dropna=False)
    summary = grouped.agg(
        WatcherSamples=("CPU", "count"),
        WatcherCPU_min=("CPU", "min"),
        WatcherCPU_q1=("CPU", lambda s: s.quantile(0.25)),
        WatcherCPU_median=("CPU", "median"),
        WatcherCPU_q3=("CPU", lambda s: s.quantile(0.75)),
        WatcherCPU_max=("CPU", "max"),
        WatcherMemoryKB_min=("MemoryKB", "min"),
        WatcherMemoryKB_q1=("MemoryKB", lambda s: s.quantile(0.25)),
        WatcherMemoryKB_median=("MemoryKB", "median"),
        WatcherMemoryKB_q3=("MemoryKB", lambda s: s.quantile(0.75)),
        WatcherMemoryKB_max=("MemoryKB", "max"),
    ).reset_index()
    summary["Epoch"] = summary["Epoch"].astype("Int64")
    return summary


def combine_csv(csv_path: Path) -> Path:
    run = extract_run_number(csv_path)
    if run is None:
        raise ValueError(f"Could not infer run number from {csv_path.name}")

    df = pd.read_csv(csv_path)
    df["Phase"] = df["Phase"].astype(str).str.lower()
    df["Epoch"] = pd.to_numeric(df["Epoch"], errors="coerce").astype("Int64")

    metric_summary = summarize_metrics(SOURCE_DIR / f"run_{run}_metrics")
    combined = df.merge(metric_summary, on=["Phase", "Epoch"], how="left")

    for column in STAT_COLUMNS:
        if column not in combined.columns:
            combined[column] = pd.NA

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    out_path = OUTPUT_DIR / csv_path.name
    combined.to_csv(out_path, index=False)
    return out_path


def main() -> None:
    csv_paths = sorted(SOURCE_DIR.glob("*.csv"))
    if not csv_paths:
        raise RuntimeError(f"No CSV files found in {SOURCE_DIR}")

    written: list[Path] = []
    for csv_path in csv_paths:
        out_path = combine_csv(csv_path)
        written.append(out_path)
        print(f"wrote,{out_path}")

    print(f"total_written,{len(written)}")


if __name__ == "__main__":
    main()
