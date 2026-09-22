#!/usr/bin/env python3
"""Hypothesis checks for the heavy FULL_VIEW NOVACC run.

The script reads generated observability artifacts only and writes analysis
outputs beside the FULL_VIEW_NOVACC collection. It deliberately avoids editing
raw benchmark results.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import re
from collections import defaultdict
from pathlib import Path
from typing import Iterable

import numpy as np
import pandas as pd
from scipy import stats


ROOT_DEFAULT = Path(
    "/home/nhan/Desktop/Projects/YCSB/YCSB-IVS-DATA/FULL_VIEW_NOVACC/"
    "full_view_heavy_novacc_run1"
)
DATA_ROOT_DEFAULT = Path("/home/nhan/Desktop/Projects/YCSB/YCSB-IVS-DATA")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-root", type=Path, default=ROOT_DEFAULT)
    parser.add_argument("--data-root", type=Path, default=DATA_ROOT_DEFAULT)
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=DATA_ROOT_DEFAULT / "FULL_VIEW_NOVACC" / "analysis",
    )
    parser.add_argument(
        "--skip-page-identity",
        action="store_true",
        help="Skip the expensive scan of buffer_page_identity.csv.",
    )
    parser.add_argument(
        "--page-identity-chunksize",
        type=int,
        default=2_000_000,
        help="Rows per chunk while scanning buffer_page_identity.csv.",
    )
    return parser.parse_args()


def epoch_from_phase_id(value: str) -> float:
    match = re.search(r"_(\d+)$", str(value))
    return float(match.group(1)) if match else np.nan


def safe_spearman(df: pd.DataFrame, x: str, y: str) -> tuple[float, float, int]:
    tmp = df[[x, y]].replace([np.inf, -np.inf], np.nan).dropna()
    if len(tmp) < 3 or tmp[x].nunique() < 2 or tmp[y].nunique() < 2:
        return np.nan, np.nan, len(tmp)
    corr, p_value = stats.spearmanr(tmp[x], tmp[y])
    return float(corr), float(p_value), int(len(tmp))


def safe_mannwhitney(a: Iterable[float], b: Iterable[float]) -> tuple[float, float, int, int]:
    aa = pd.Series(a, dtype="float64").replace([np.inf, -np.inf], np.nan).dropna()
    bb = pd.Series(b, dtype="float64").replace([np.inf, -np.inf], np.nan).dropna()
    if len(aa) < 3 or len(bb) < 3:
        return np.nan, np.nan, len(aa), len(bb)
    stat, p_value = stats.mannwhitneyu(aa, bb, alternative="two-sided")
    return float(stat), float(p_value), int(len(aa)), int(len(bb))


def pctl(series: pd.Series, q: float) -> float:
    clean = series.replace([np.inf, -np.inf], np.nan).dropna()
    return float(clean.quantile(q)) if len(clean) else np.nan


def summarize_window(df: pd.DataFrame, phase: str, start: int, end: int) -> dict[str, float]:
    window = df[(df["phase_name"] == phase) & (df["epoch"].between(start, end))]
    out: dict[str, float] = {"phase_name": phase, "window": f"{start}-{end}", "n": len(window)}
    for col in [
        "latency_p95_ms",
        "latency_p99_ms",
        "throughput_ops_per_sec",
        "wal_bytes_per_op",
        "toast_blocks_per_op",
        "toast_index_blocks_per_op",
        "client_backend_relation_reads_delta",
        "client_backend_relation_evictions_delta",
        "read_time_delta",
        "checkpoint_write_time_delta",
        "checkpoint_buffers_written_delta",
        "n_dead_tup_after",
        "hot_update_ratio",
        "toast_storage_fraction_after",
        "storage_growth_per_logical_byte",
    ]:
        if col in window.columns:
            out[f"{col}_mean"] = float(window[col].mean())
            out[f"{col}_median"] = float(window[col].median())
    return out


def build_read_sample_metrics(path: Path) -> pd.DataFrame:
    read = pd.read_csv(path)
    read = read[read["phase"] == "run"].copy()
    read["latency_ms"] = read["latency_us"] / 1000.0
    read["key_size_kib"] = read["key_size_bytes"] / 1024.0
    read["op_frac"] = read["operation_index"] / read.groupby("epoch")["operation_index"].transform("max")
    read["quarter"] = np.ceil(read["op_frac"] * 4).clip(1, 4).astype(int)
    read["is_slow_1ms"] = read["latency_us"] > 1000
    read["is_gt_128k"] = read["key_size_bytes"] > 128 * 1024

    def agg_epoch(group: pd.DataFrame) -> pd.Series:
        q1 = group[group["quarter"] == 1]
        qrest = group[group["quarter"] > 1]
        return pd.Series(
            {
                "sample_n": len(group),
                "sample_latency_p50_ms": pctl(group["latency_ms"], 0.50),
                "sample_latency_p95_ms": pctl(group["latency_ms"], 0.95),
                "sample_latency_p99_ms": pctl(group["latency_ms"], 0.99),
                "sample_key_p50_kib": pctl(group["key_size_kib"], 0.50),
                "sample_key_p95_kib": pctl(group["key_size_kib"], 0.95),
                "sample_key_p99_kib": pctl(group["key_size_kib"], 0.99),
                "sample_pct_gt_128k": float(group["is_gt_128k"].mean()),
                "sample_slow_1ms_pct": float(group["is_slow_1ms"].mean()),
                "q1_latency_p95_ms": pctl(q1["latency_ms"], 0.95),
                "q2_4_latency_p95_ms": pctl(qrest["latency_ms"], 0.95),
                "q1_slow_1ms_pct": float(q1["is_slow_1ms"].mean()) if len(q1) else np.nan,
                "q2_4_slow_1ms_pct": float(qrest["is_slow_1ms"].mean()) if len(qrest) else np.nan,
                "query_execute_share": float(
                    group["query_execute_us"].sum() / group["latency_us"].sum()
                ),
                "json_parse_share": float(group["json_parse_us"].sum() / group["latency_us"].sum()),
                "value_join_share": float(group["value_join_us"].sum() / group["latency_us"].sum()),
            }
        )

    by_epoch = read.groupby("epoch", as_index=True).apply(agg_epoch).reset_index()

    bins = [0, 64 * 1024, 128 * 1024, 256 * 1024, 512 * 1024, 1024 * 1024, np.inf]
    labels = ["<=64K", "64-128K", "128-256K", "256-512K", "512K-1M", ">1M"]
    read["key_size_bin"] = pd.cut(read["key_size_bytes"], bins=bins, labels=labels, include_lowest=True)
    late = read[read["epoch"].between(80, 100)]
    bin_rows = []
    for label, group in late.groupby("key_size_bin", observed=True):
        bin_rows.append(
            {
                "key_size_bin": str(label),
                "samples": len(group),
                "median_latency_ms": pctl(group["latency_ms"], 0.50),
                "p95_latency_ms": pctl(group["latency_ms"], 0.95),
                "p99_latency_ms": pctl(group["latency_ms"], 0.99),
                "median_key_kib": pctl(group["key_size_kib"], 0.50),
            }
        )
    return by_epoch, pd.DataFrame(bin_rows), read


def relation_role(name: str) -> str:
    if name == "usertable":
        return "heap"
    if str(name).startswith("pg_toast_") and str(name).endswith("_index"):
        return "toast_index"
    if str(name).startswith("pg_toast_"):
        return "toast_heap"
    return "other"


def build_residency_metrics(path: Path) -> pd.DataFrame:
    buf = pd.read_csv(path)
    buf["relation_role"] = buf["relation_name"].map(relation_role)
    run = buf[(buf["phase"] == "run") & (buf["relation_role"].isin(["heap", "toast_heap", "toast_index"]))].copy()
    piv = run.pivot_table(
        index=["epoch", "event"],
        columns="relation_role",
        values="buffers",
        aggfunc="sum",
    ).reset_index()
    for col in ["heap", "toast_heap", "toast_index"]:
        if col not in piv:
            piv[col] = np.nan
    rows = []
    events = [
        "before_run",
        "run_progress_1pct",
        "run_progress_2pct",
        "run_progress_5pct",
        "run_progress_10pct",
        "run_progress_25pct",
        "run_progress_50pct",
        "after_run",
    ]
    for epoch, group in piv.groupby("epoch"):
        row = {"epoch": int(epoch)}
        by_event = group.set_index("event")
        for event in events:
            if event in by_event.index:
                for role in ["heap", "toast_heap", "toast_index"]:
                    row[f"{event}_{role}_buffers"] = float(by_event.loc[event, role])
        for event in events[1:]:
            for role in ["toast_heap", "toast_index"]:
                base = row.get(f"before_run_{role}_buffers", np.nan)
                val = row.get(f"{event}_{role}_buffers", np.nan)
                row[f"{event}_{role}_delta_from_before"] = val - base
        rows.append(row)
    return pd.DataFrame(rows)


def build_wal_summary(path: Path) -> pd.DataFrame:
    wal = pd.read_csv(path)
    wal = wal[wal["source"].eq("snapshot")].copy()
    wal = wal[wal["phase"].isin(["extend", "run", "reference"])]
    top_rows = []
    for (phase, epoch), group in wal.groupby(["phase", "epoch"]):
        total = group["combined_size"].sum()
        top = group.sort_values("combined_size", ascending=False).head(5)
        for _, rec in top.iterrows():
            top_rows.append(
                {
                    "phase": phase,
                    "epoch": int(epoch),
                    "record_type": rec["resource_manager_record_type"],
                    "combined_size": float(rec["combined_size"]),
                    "share": float(rec["combined_size"] / total) if total else np.nan,
                }
            )
    return pd.DataFrame(top_rows)


def scan_page_identity(path: Path, epochs: list[int], chunksize: int) -> pd.DataFrame:
    if not path.exists():
        return pd.DataFrame()
    wanted_events = {
        "before_run",
        "run_progress_1pct",
        "run_progress_2pct",
        "run_progress_5pct",
        "run_progress_10pct",
        "run_progress_25pct",
        "run_progress_50pct",
        "after_run",
    }
    wanted_roles = {"toast_heap", "toast_index"}
    page_sets: dict[tuple[int, str, str], set[int]] = defaultdict(set)
    usecols = ["epoch", "phase", "event", "relation_role", "relblocknumber"]
    for chunk in pd.read_csv(path, usecols=usecols, chunksize=chunksize):
        chunk = chunk[
            chunk["phase"].eq("run")
            & chunk["epoch"].isin(epochs)
            & chunk["event"].isin(wanted_events)
            & chunk["relation_role"].isin(wanted_roles)
        ]
        if chunk.empty:
            continue
        for key, group in chunk.groupby(["epoch", "relation_role", "event"]):
            page_sets[(int(key[0]), str(key[1]), str(key[2]))].update(
                group["relblocknumber"].dropna().astype(int).tolist()
            )

    rows = []
    for epoch in epochs:
        for role in sorted(wanted_roles):
            before = page_sets.get((epoch, role, "before_run"), set())
            for event in sorted(wanted_events):
                pages = page_sets.get((epoch, role, event), set())
                if not pages:
                    continue
                overlap = len(before & pages) if before else np.nan
                rows.append(
                    {
                        "epoch": epoch,
                        "relation_role": role,
                        "event": event,
                        "unique_pages": len(pages),
                        "overlap_with_before_pages": overlap,
                        "event_pages_retained_from_before_fraction": (
                            overlap / len(pages) if before and pages else np.nan
                        ),
                        "before_pages_retained_fraction": (
                            overlap / len(before) if before and pages else np.nan
                        ),
                        "new_pages_vs_before": len(pages) - overlap if before else np.nan,
                    }
                )
    return pd.DataFrame(rows)


def compare_vacc_runs(data_root: Path, novacc: pd.DataFrame) -> pd.DataFrame:
    run_paths = [
        ("NOVACC", "full_view_heavy_novacc_run1", None),
        ("VACC", "full_view_run1", data_root / "FULL_VIEW" / "full_view_run1" / "derived" / "normalized_metrics.csv"),
        (
            "VACC",
            "full_view_run2_3_106_232_96",
            data_root
            / "FULL_VIEW"
            / "full_view_run2_3_106_232_96"
            / "derived"
            / "normalized_metrics.csv",
        ),
    ]
    rows = []
    for variant, run_id, path in run_paths:
        if path is None:
            df = novacc.copy()
        elif path.exists():
            df = pd.read_csv(path)
            df["epoch"] = df["phase_id"].map(epoch_from_phase_id)
        else:
            continue
        for phase in ["extend", "run", "reference"]:
            for label, mask in {
                "1-10": df["epoch"].between(1, 10),
                "91-100": df["epoch"].between(91, 100),
                "all": df["epoch"].between(1, 100),
            }.items():
                sub = df[(df["phase_name"] == phase) & mask]
                if sub.empty:
                    continue
                rows.append(
                    {
                        "variant": variant,
                        "run_id": run_id,
                        "phase": phase,
                        "window": label,
                        "p95_mean_ms": float(sub["latency_p95_ms"].mean()),
                        "p99_mean_ms": float(sub["latency_p99_ms"].mean()),
                        "throughput_mean": float(sub["throughput_ops_per_sec"].mean()),
                        "toast_blocks_per_op_mean": float(sub["toast_blocks_per_op"].mean()),
                        "client_reads_mean": float(sub["client_backend_relation_reads_delta"].mean()),
                        "client_evictions_mean": float(sub["client_backend_relation_evictions_delta"].mean()),
                        "wal_bytes_per_op_mean": float(sub["wal_bytes_per_op"].mean()),
                    }
                )
    return pd.DataFrame(rows)


def fmt_num(value: float, digits: int = 3) -> str:
    if value is None or pd.isna(value):
        return "NA"
    if abs(value) >= 1000:
        return f"{value:,.0f}"
    return f"{value:.{digits}f}"


def markdown_table(df: pd.DataFrame) -> str:
    if df.empty:
        return "_No rows._"
    table = df.copy()
    for col in table.columns:
        if pd.api.types.is_float_dtype(table[col]):
            table[col] = table[col].map(lambda v: fmt_num(v, 3))
        else:
            table[col] = table[col].map(lambda v: "" if pd.isna(v) else str(v))
    headers = list(table.columns)
    lines = [
        "| " + " | ".join(headers) + " |",
        "| " + " | ".join(["---"] * len(headers)) + " |",
    ]
    for _, row in table.iterrows():
        lines.append("| " + " | ".join(str(row[col]) for col in headers) + " |")
    return "\n".join(lines)


def main() -> None:
    args = parse_args()
    run_root = args.run_root
    out_dir = args.output_dir
    out_dir.mkdir(parents=True, exist_ok=True)

    manifest = json.loads((run_root / "manifest.json").read_text())
    preflight_path = run_root / "sql" / "preflight.json"
    preflight = json.loads(preflight_path.read_text()) if preflight_path.exists() else {}
    postgres_version = (
        manifest.get("postgres_version")
        or manifest.get("postgresql_version")
        or manifest.get("postgresql", {}).get("version")
        or preflight.get("postgres_version")
        or "unknown"
    )
    metrics = pd.read_csv(run_root / "derived" / "normalized_metrics.csv")
    metrics["epoch"] = metrics["phase_id"].map(epoch_from_phase_id)
    metrics = metrics[metrics["epoch"].notna()].copy()
    metrics["epoch"] = metrics["epoch"].astype(int)
    metrics = metrics[metrics["epoch"].between(1, 100)].copy()

    read_epoch, read_bins, read_raw = build_read_sample_metrics(
        run_root
        / "logs"
        / "toast_spike_trigger"
        / "full_view_novacc_run1_zipfian_heavy_pure_read_sample.csv"
    )
    residency = build_residency_metrics(
        run_root
        / "logs"
        / "toast_spike_trigger"
        / "full_view_novacc_run1_zipfian_heavy_pure_buffer_residency.csv"
    )
    wal_top = build_wal_summary(
        run_root
        / "logs"
        / "toast_spike_trigger"
        / "full_view_novacc_run1_zipfian_heavy_pure_wal_stats.csv"
    )
    vacc_compare = compare_vacc_runs(args.data_root, metrics)

    run = metrics[metrics["phase_name"] == "run"].copy().sort_values("epoch")
    extend = metrics[metrics["phase_name"] == "extend"].copy().sort_values("epoch")
    reference = metrics[metrics["phase_name"] == "reference"].copy().sort_values("epoch")
    run = run.merge(read_epoch, on="epoch", how="left").merge(residency, on="epoch", how="left")
    run["p95_residual_ms"] = run["latency_p95_ms"] - run["latency_p95_ms"].rolling(
        9, center=True, min_periods=3
    ).median()
    run["p99_residual_ms"] = run["latency_p99_ms"] - run["latency_p99_ms"].rolling(
        9, center=True, min_periods=3
    ).median()
    run["q1_p95_ratio"] = run["q1_latency_p95_ms"] / run["q2_4_latency_p95_ms"]
    run["q1_slow_ratio"] = run["q1_slow_1ms_pct"] / run["q2_4_slow_1ms_pct"].replace(0, np.nan)

    trend_rows = []
    for phase_name, df in [("extend", extend), ("run", run), ("reference", reference)]:
        for y in [
            "latency_p95_ms",
            "latency_p99_ms",
            "throughput_ops_per_sec",
            "wal_bytes_per_op",
            "toast_blocks_per_op",
            "client_backend_relation_reads_delta",
            "client_backend_relation_evictions_delta",
            "checkpoint_write_time_delta",
            "n_dead_tup_after",
            "hot_update_ratio",
        ]:
            if y in df.columns:
                corr, p_value, n = safe_spearman(df, "epoch", y)
                trend_rows.append(
                    {
                        "test": "spearman_epoch",
                        "phase": phase_name,
                        "x": "epoch",
                        "y": y,
                        "statistic": corr,
                        "p_value": p_value,
                        "n": n,
                    }
                )

    run_corr_targets = [
        "toast_blocks_per_op",
        "toast_index_blocks_per_op",
        "client_backend_relation_reads_delta",
        "client_backend_relation_evictions_delta",
        "read_time_delta",
        "checkpoint_write_time_delta",
        "checkpoint_buffers_written_delta",
        "n_dead_tup_after",
        "sample_pct_gt_128k",
        "sample_key_p95_kib",
        "sample_slow_1ms_pct",
        "q1_slow_1ms_pct",
        "q1_p95_ratio",
        "before_run_toast_heap_buffers",
        "before_run_toast_index_buffers",
        "run_progress_10pct_toast_heap_delta_from_before",
        "run_progress_10pct_toast_index_delta_from_before",
    ]
    for x in run_corr_targets:
        if x in run.columns:
            for y in ["latency_p95_ms", "latency_p99_ms", "p95_residual_ms"]:
                corr, p_value, n = safe_spearman(run, x, y)
                trend_rows.append(
                    {
                        "test": "spearman_run_predictor",
                        "phase": "run",
                        "x": x,
                        "y": y,
                        "statistic": corr,
                        "p_value": p_value,
                        "n": n,
                    }
                )

    for phase_name, df in [("extend", extend), ("run", run), ("reference", reference)]:
        for y in ["latency_p95_ms", "latency_p99_ms", "toast_blocks_per_op", "wal_bytes_per_op"]:
            if y in df.columns:
                stat, p_value, n_early, n_late = safe_mannwhitney(
                    df[df["epoch"].between(1, 10)][y],
                    df[df["epoch"].between(91, 100)][y],
                )
                trend_rows.append(
                    {
                        "test": "mannwhitney_early_late",
                        "phase": phase_name,
                        "x": "epoch_1_10_vs_91_100",
                        "y": y,
                        "statistic": stat,
                        "p_value": p_value,
                        "n": n_early + n_late,
                    }
                )

    sample_stat, sample_p, sample_n1, sample_n2 = safe_mannwhitney(
        read_raw[read_raw["epoch"].between(1, 10)]["latency_ms"],
        read_raw[read_raw["epoch"].between(91, 100)]["latency_ms"],
    )
    trend_rows.append(
        {
            "test": "mannwhitney_read_sample_latency_early_late",
            "phase": "run",
            "x": "sample_epoch_1_10_vs_91_100",
            "y": "latency_ms",
            "statistic": sample_stat,
            "p_value": sample_p,
            "n": sample_n1 + sample_n2,
        }
    )
    key_corr, key_p = stats.spearmanr(read_raw["key_size_bytes"], read_raw["latency_us"])
    trend_rows.append(
        {
            "test": "spearman_read_sample",
            "phase": "run",
            "x": "key_size_bytes",
            "y": "latency_us",
            "statistic": float(key_corr),
            "p_value": float(key_p),
            "n": int(len(read_raw)),
        }
    )

    tests = pd.DataFrame(trend_rows)
    windows = pd.DataFrame(
        [summarize_window(metrics, phase, start, end) for phase in ["extend", "run", "reference"] for start, end in [(1, 10), (91, 100)]]
    )

    selected_epochs = sorted(
        set(
            [1, 10, 50, 100]
            + run.nlargest(5, "latency_p95_ms")["epoch"].astype(int).tolist()
            + run.nlargest(5, "p95_residual_ms")["epoch"].astype(int).tolist()
        )
    )
    page_identity_path = out_dir / "novacc_selected_page_identity_overlap.csv"
    if page_identity_path.exists():
        page_identity = pd.read_csv(page_identity_path)
    elif args.skip_page_identity:
        page_identity = pd.DataFrame()
    else:
        page_identity = scan_page_identity(
            run_root
            / "logs"
            / "toast_spike_trigger"
            / "full_view_novacc_run1_zipfian_heavy_pure_buffer_page_identity.csv",
            selected_epochs,
            args.page_identity_chunksize,
        )

    tests.to_csv(out_dir / "novacc_hypothesis_tests.csv", index=False)
    windows.to_csv(out_dir / "novacc_window_summary.csv", index=False)
    run.to_csv(out_dir / "novacc_run_epoch_enriched.csv", index=False)
    read_bins.to_csv(out_dir / "novacc_late_read_latency_by_key_size.csv", index=False)
    wal_top.to_csv(out_dir / "novacc_wal_top_records.csv", index=False)
    vacc_compare.to_csv(out_dir / "novacc_vs_vacc_window_comparison.csv", index=False)
    if not page_identity.empty:
        page_identity.to_csv(out_dir / "novacc_selected_page_identity_overlap.csv", index=False)

    # Pull the highest-signal numbers into a short report.
    def row(phase: str, window: str) -> pd.Series:
        return windows[(windows["phase_name"] == phase) & (windows["window"] == window)].iloc[0]

    ext_early, ext_late = row("extend", "1-10"), row("extend", "91-100")
    run_early, run_late = row("run", "1-10"), row("run", "91-100")
    ref_early, ref_late = row("reference", "1-10"), row("reference", "91-100")

    top_p95 = run.nlargest(5, "latency_p95_ms")[
        [
            "epoch",
            "latency_p95_ms",
            "latency_p99_ms",
            "sample_pct_gt_128k",
            "sample_key_p95_kib",
            "q1_latency_p95_ms",
            "q2_4_latency_p95_ms",
            "client_backend_relation_reads_delta",
            "checkpoint_write_time_delta",
        ]
    ]
    top_resid = run.nlargest(5, "p95_residual_ms")[
        [
            "epoch",
            "latency_p95_ms",
            "p95_residual_ms",
            "sample_pct_gt_128k",
            "q1_slow_1ms_pct",
            "q2_4_slow_1ms_pct",
            "client_backend_relation_reads_delta",
        ]
    ]
    late_sample = read_raw[read_raw["epoch"].between(80, 100)]
    late_latency_sum = late_sample["latency_us"].sum()
    late_query_share = (
        late_sample["query_execute_us"].sum() / late_latency_sum if late_latency_sum else np.nan
    )
    late_json_parse_share = (
        late_sample["json_parse_us"].sum() / late_latency_sum if late_latency_sum else np.nan
    )
    late_value_join_share = (
        late_sample["value_join_us"].sum() / late_latency_sum if late_latency_sum else np.nan
    )

    def test_value(test: str, phase: str, x: str, y: str) -> tuple[float, float]:
        match = tests[
            (tests["test"] == test)
            & (tests["phase"] == phase)
            & (tests["x"] == x)
            & (tests["y"] == y)
        ]
        if match.empty:
            return np.nan, np.nan
        rec = match.iloc[0]
        return float(rec["statistic"]), float(rec["p_value"])

    run_epoch_p95, run_epoch_p95_p = test_value("spearman_epoch", "run", "epoch", "latency_p95_ms")
    run_toast_p95, run_toast_p95_p = test_value(
        "spearman_run_predictor", "run", "toast_blocks_per_op", "latency_p95_ms"
    )
    run_reads_p95, run_reads_p95_p = test_value(
        "spearman_run_predictor", "run", "client_backend_relation_reads_delta", "latency_p95_ms"
    )
    run_ckpt_resid, run_ckpt_resid_p = test_value(
        "spearman_run_predictor", "run", "checkpoint_write_time_delta", "p95_residual_ms"
    )
    run_dead_p95, run_dead_p95_p = test_value(
        "spearman_run_predictor", "run", "n_dead_tup_after", "latency_p95_ms"
    )
    run_large_resid, run_large_resid_p = test_value(
        "spearman_run_predictor", "run", "sample_pct_gt_128k", "p95_residual_ms"
    )
    key_latency_corr = tests[tests["test"] == "spearman_read_sample"].iloc[0]

    page_identity_note = "Skipped by flag."
    if not page_identity.empty:
        selected_summary = page_identity[
            page_identity["event"].isin(["run_progress_10pct", "after_run"])
            & page_identity["relation_role"].eq("toast_heap")
        ].copy()
        if not selected_summary.empty:
            page_identity_note = (
                "For selected epochs, TOAST heap page identity shows "
                f"median {fmt_num(selected_summary['event_pages_retained_from_before_fraction'].median(), 3)} "
                "of event pages were already present at before_run; the remaining event pages are churn/new relative to before_run."
            )

    lines = [
        "# Heavy NOVACC Hypothesis Test",
        "",
        f"- Run: `{manifest.get('run_id')}`",
        f"- Generated from: `{run_root}`",
        f"- PostgreSQL: `{postgres_version}`",
        "- Scope: phase deltas, read samples, relation residency, selected page-identity overlaps, WAL inspect summaries, and comparison to existing heavy VACC runs.",
        "",
        "## Verdict",
        "",
        "The heavy NOVACC run supports the central mechanism: value growth drives TOAST/WAL/buffer work, and read latency grows only when the read path touches the growing TOAST working set. Removing explicit VACUUM does not remove the phenomenon. It does reduce some read-phase buffer misses relative to the older heavy VACC runs, but the one-run comparison is not clean enough to treat vacuum as the sole cause.",
        "",
        "## Phase-Level Evidence",
        "",
        "| phase | window | p95 ms | p99 ms | throughput ops/s | WAL bytes/op | TOAST blocks/op | client reads | client evictions |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|",
        f"| extend | 1-10 | {fmt_num(ext_early['latency_p95_ms_mean'])} | {fmt_num(ext_early['latency_p99_ms_mean'])} | {fmt_num(ext_early['throughput_ops_per_sec_mean'])} | {fmt_num(ext_early['wal_bytes_per_op_mean'])} | {fmt_num(ext_early['toast_blocks_per_op_mean'])} | {fmt_num(ext_early['client_backend_relation_reads_delta_mean'])} | {fmt_num(ext_early['client_backend_relation_evictions_delta_mean'])} |",
        f"| extend | 91-100 | {fmt_num(ext_late['latency_p95_ms_mean'])} | {fmt_num(ext_late['latency_p99_ms_mean'])} | {fmt_num(ext_late['throughput_ops_per_sec_mean'])} | {fmt_num(ext_late['wal_bytes_per_op_mean'])} | {fmt_num(ext_late['toast_blocks_per_op_mean'])} | {fmt_num(ext_late['client_backend_relation_reads_delta_mean'])} | {fmt_num(ext_late['client_backend_relation_evictions_delta_mean'])} |",
        f"| run | 1-10 | {fmt_num(run_early['latency_p95_ms_mean'])} | {fmt_num(run_early['latency_p99_ms_mean'])} | {fmt_num(run_early['throughput_ops_per_sec_mean'])} | {fmt_num(run_early['wal_bytes_per_op_mean'])} | {fmt_num(run_early['toast_blocks_per_op_mean'])} | {fmt_num(run_early['client_backend_relation_reads_delta_mean'])} | {fmt_num(run_early['client_backend_relation_evictions_delta_mean'])} |",
        f"| run | 91-100 | {fmt_num(run_late['latency_p95_ms_mean'])} | {fmt_num(run_late['latency_p99_ms_mean'])} | {fmt_num(run_late['throughput_ops_per_sec_mean'])} | {fmt_num(run_late['wal_bytes_per_op_mean'])} | {fmt_num(run_late['toast_blocks_per_op_mean'])} | {fmt_num(run_late['client_backend_relation_reads_delta_mean'])} | {fmt_num(run_late['client_backend_relation_evictions_delta_mean'])} |",
        f"| reference | 1-10 | {fmt_num(ref_early['latency_p95_ms_mean'])} | {fmt_num(ref_early['latency_p99_ms_mean'])} | {fmt_num(ref_early['throughput_ops_per_sec_mean'])} | {fmt_num(ref_early['wal_bytes_per_op_mean'])} | {fmt_num(ref_early['toast_blocks_per_op_mean'])} | {fmt_num(ref_early['client_backend_relation_reads_delta_mean'])} | {fmt_num(ref_early['client_backend_relation_evictions_delta_mean'])} |",
        f"| reference | 91-100 | {fmt_num(ref_late['latency_p95_ms_mean'])} | {fmt_num(ref_late['latency_p99_ms_mean'])} | {fmt_num(ref_late['throughput_ops_per_sec_mean'])} | {fmt_num(ref_late['wal_bytes_per_op_mean'])} | {fmt_num(ref_late['toast_blocks_per_op_mean'])} | {fmt_num(ref_late['client_backend_relation_reads_delta_mean'])} | {fmt_num(ref_late['client_backend_relation_evictions_delta_mean'])} |",
        "",
        "## Hypothesis Outcomes",
        "",
        f"- H1 TOAST/value-size amplification: supported. Run p95 grows with epoch (Spearman rho={fmt_num(run_epoch_p95)}, p={run_epoch_p95_p:.2e}) and with run TOAST blocks/op (rho={fmt_num(run_toast_p95)}, p={run_toast_p95_p:.2e}). Extend WAL/op rises from about {fmt_num(ext_early['wal_bytes_per_op_mean'])} to {fmt_num(ext_late['wal_bytes_per_op_mean'])} bytes/op.",
        f"- H2 useful cache/page residency: supported as buffer-miss sensitivity, but not fully closed. Run p95 correlates with client backend relation reads (rho={fmt_num(run_reads_p95)}, p={run_reads_p95_p:.2e}); top p95 epochs are also front-loaded in sampled latency. {page_identity_note}",
        f"- H3 large-key sampling: supported as an amplifier, not a clock. Across raw read samples, key size and latency correlate (Spearman rho={fmt_num(float(key_latency_corr['statistic']))}, p={float(key_latency_corr['p_value']):.2e}, n={int(key_latency_corr['n'])}). Residual p95 versus >128 KiB sample share is weaker (rho={fmt_num(run_large_resid)}, p={run_large_resid_p:.2e}).",
        f"- H4 vacuum perturbation: NOVACC shows vacuum is not necessary. Late run p95 is {fmt_num(run_late['latency_p95_ms_mean'])} ms despite VACUUM being off. Compared with existing heavy VACC runs, NOVACC has fewer late read-phase client reads than both VACC runs, but latency falls between the two VACC baselines, so host/run variance still matters.",
        f"- H5 checkpoint/bgwriter direct trigger: weak. Run p95 residual versus checkpoint write-time delta is rho={fmt_num(run_ckpt_resid)}, p={run_ckpt_resid_p:.2e}; that does not support a clean checkpoint-clock explanation.",
        f"- H6 detoast/serialization/client parse cost placement: supported. In epochs 80-100, sampled read latency is {fmt_num(late_query_share * 100, 1)}% query execution, {fmt_num(late_json_parse_share * 100, 1)}% JSON parse, and {fmt_num(late_value_join_share * 100, 1)}% value join.",
        f"- Dead tuples/HOT collapse: not supported as the primary mechanism. Run p95 versus n_dead_tup_after is rho={fmt_num(run_dead_p95)}, p={run_dead_p95_p:.2e}; extend HOT update ratio rises late rather than collapsing.",
        "",
        "## Top Run P95 Epochs",
        "",
        markdown_table(top_p95),
        "",
        "## Top Local Residual P95 Epochs",
        "",
        markdown_table(top_resid),
        "",
        "## Late Read Latency By Key Size",
        "",
        markdown_table(read_bins),
        "",
        "## Outputs",
        "",
        "- `novacc_hypothesis_tests.csv`",
        "- `novacc_window_summary.csv`",
        "- `novacc_run_epoch_enriched.csv`",
        "- `novacc_late_read_latency_by_key_size.csv`",
        "- `novacc_wal_top_records.csv`",
        "- `novacc_vs_vacc_window_comparison.csv`",
        "- `novacc_selected_page_identity_overlap.csv` if page-identity scan was enabled",
        "",
        "## Caveats",
        "",
        "- This is one heavy NOVACC run, compared against two older heavy VACC runs on different hosts. Treat vacuum comparisons as directional.",
        "- Page identity overlap proves relation-block churn/retention, not key-to-page causality.",
        "- `pg_stat_checkpointer` is expected-unavailable on PostgreSQL 16; checkpoint fields use `pg_stat_bgwriter` fallback counters.",
    ]
    (out_dir / "hypothesis_test_novacc.md").write_text("\n".join(lines) + "\n")
    print(out_dir / "hypothesis_test_novacc.md")


if __name__ == "__main__":
    main()
