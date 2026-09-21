#!/usr/bin/env python3
"""Plot cache-hit ratio against p95 latency for TOAST_hypothesis_2.

The "size accounted for" view uses a simple partial-regression treatment:
both p95 latency and cache-hit ratio are residualized against log10(TOAST
total relation size in GiB), then the residuals are plotted against each other.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
import pandas as pd

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.colors import LogNorm


ROOT = Path(__file__).resolve().parents[1]
SUMMARY_PATH = ROOT / "insight" / "TOAST_hypothesis_2_epoch_summary.csv"
OUT_DIR = ROOT / "insight" / "TOAST_hypothesis_2_plots"

VARIANT_LABELS = {
    "vacuum": "VACC",
    "no_vacuum": "NOVACC",
}

COLORS = {
    "vacuum": "#2f6f9f",
    "no_vacuum": "#b85c38",
}


def regress_residual(y: np.ndarray, z: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Return residuals and coefficients for y ~ 1 + z."""

    design = np.column_stack([np.ones(len(z)), z])
    coef = np.linalg.lstsq(design, y, rcond=None)[0]
    return y - design @ coef, coef


def add_fit_line(ax: plt.Axes, x: np.ndarray, y: np.ndarray, color: str) -> tuple[float, float]:
    finite = np.isfinite(x) & np.isfinite(y)
    x = x[finite]
    y = y[finite]
    design = np.column_stack([np.ones(len(x)), x])
    intercept, slope = np.linalg.lstsq(design, y, rcond=None)[0]
    xs = np.linspace(x.min(), x.max(), 100)
    ax.plot(xs, intercept + slope * xs, color=color, linewidth=2.0)
    pred = intercept + slope * x
    ss_res = float(np.sum((y - pred) ** 2))
    ss_tot = float(np.sum((y - y.mean()) ** 2))
    r2 = 1.0 - ss_res / ss_tot if ss_tot else np.nan
    return float(slope), r2


def load_data() -> pd.DataFrame:
    df = pd.read_csv(SUMMARY_PATH)
    denom = df["run_blks_hit_delta"] + df["run_blks_read_delta"]
    df["run_cache_hit_ratio"] = df["run_blks_hit_delta"] / denom.replace(0, np.nan)
    df["run_cache_hit_pct"] = 100.0 * df["run_cache_hit_ratio"]
    df["run_cache_miss_pct"] = 100.0 - df["run_cache_hit_pct"]
    df["toast_total_gib"] = df["toast_total_bytes"] / 1024**3
    df["log10_toast_total_gib"] = np.log10(df["toast_total_gib"].clip(lower=1e-9))
    df["variant_label"] = df["variant"].map(VARIANT_LABELS).fillna(df["variant"])
    keep = [
        "variant",
        "variant_label",
        "epoch",
        "p95_us",
        "run_blks_read_delta",
        "run_blks_hit_delta",
        "run_cache_hit_pct",
        "run_cache_miss_pct",
        "toast_total_gib",
        "log10_toast_total_gib",
    ]
    return df[keep].replace([np.inf, -np.inf], np.nan).dropna()


def plot_raw_size_encoded(df: pd.DataFrame) -> Path:
    path = OUT_DIR / "cache_hit_ratio_vs_p95_size_encoded_vacc_novacc.png"
    fig, axes = plt.subplots(1, 2, figsize=(13.8, 5.6), sharey=True)
    norm = LogNorm(vmin=max(df["toast_total_gib"].min(), 1e-3), vmax=df["toast_total_gib"].max())

    for ax, (variant, group) in zip(axes, df.groupby("variant", sort=False)):
        group = group.sort_values("epoch")
        sc = ax.scatter(
            group["run_cache_hit_pct"],
            group["p95_us"],
            c=group["toast_total_gib"],
            cmap="viridis",
            norm=norm,
            s=52,
            alpha=0.86,
            edgecolor="white",
            linewidth=0.45,
        )
        ax.plot(
            group["run_cache_hit_pct"],
            group["p95_us"],
            color="#9a9a9a",
            linewidth=0.9,
            alpha=0.35,
            zorder=0,
        )
        for epoch in (1, 25, 50, 75, 100):
            row = group[group["epoch"] == epoch]
            if not row.empty:
                ax.annotate(
                    str(epoch),
                    (float(row["run_cache_hit_pct"].iloc[0]), float(row["p95_us"].iloc[0])),
                    xytext=(4, 4),
                    textcoords="offset points",
                    fontsize=8,
                    color="#333333",
                )

        label = group["variant_label"].iloc[0]
        ax.set_title(f"{label}: p95 vs run-phase cache-hit ratio")
        ax.set_xlabel("Run cache-hit ratio (%)")
        ax.grid(True, color="#e5e5e5", linewidth=0.8)
        x_min = max(98.8, group["run_cache_hit_pct"].min() - 0.08)
        ax.set_xlim(x_min, 100.03)

    axes[0].set_ylabel("P95 latency (us)")
    fig.subplots_adjust(top=0.84, right=0.86, wspace=0.12)
    cax = fig.add_axes([0.89, 0.20, 0.018, 0.60])
    cbar = fig.colorbar(sc, cax=cax)
    cbar.set_label("TOAST total relation size (GiB, log scale)")
    fig.suptitle("TOAST_hypothesis_2: lower cache-hit ratio coincides with higher p95; color encodes data size")
    fig.savefig(path, dpi=180, bbox_inches="tight")
    plt.close(fig)
    return path


def plot_plain_cache_vs_latency(df: pd.DataFrame) -> Path:
    path = OUT_DIR / "plain_cache_hit_ratio_vs_p95_latency_vacc_novacc.png"
    fig, ax = plt.subplots(figsize=(9.2, 6.2))

    for variant, group in df.groupby("variant", sort=False):
        group = group.sort_values("epoch")
        label = group["variant_label"].iloc[0]
        color = COLORS[variant]
        ax.plot(
            group["run_cache_hit_pct"],
            group["p95_us"],
            color=color,
            linewidth=1.0,
            alpha=0.35,
        )
        ax.scatter(
            group["run_cache_hit_pct"],
            group["p95_us"],
            label=label,
            color=color,
            s=46,
            alpha=0.82,
            edgecolor="white",
            linewidth=0.45,
        )
        for epoch in (1, 25, 50, 75, 100):
            row = group[group["epoch"] == epoch]
            if not row.empty:
                ax.annotate(
                    str(epoch),
                    (float(row["run_cache_hit_pct"].iloc[0]), float(row["p95_us"].iloc[0])),
                    xytext=(4, 4),
                    textcoords="offset points",
                    fontsize=8,
                    color="#333333",
                )

    ax.set_title("TOAST_hypothesis_2: plain cache-hit ratio vs p95 latency")
    ax.set_xlabel("Run cache-hit ratio (%)")
    ax.set_ylabel("P95 latency (us)")
    ax.grid(True, color="#e5e5e5", linewidth=0.8)
    ax.legend(title="Variant", frameon=True)
    ax.set_xlim(max(98.8, df["run_cache_hit_pct"].min() - 0.08), 100.03)
    fig.tight_layout()
    fig.savefig(path, dpi=180, bbox_inches="tight")
    plt.close(fig)
    return path


def plot_size_adjusted_partial(df: pd.DataFrame) -> tuple[Path, pd.DataFrame]:
    path = OUT_DIR / "cache_hit_ratio_vs_p95_size_adjusted_partial_vacc_novacc.png"
    fig, axes = plt.subplots(1, 2, figsize=(13.8, 5.6), sharey=True)
    rows: list[dict[str, float | str | int]] = []
    epoch_sc = None

    for ax, (variant, group) in zip(axes, df.groupby("variant", sort=False)):
        group = group.sort_values("epoch").copy()
        z = group["log10_toast_total_gib"].to_numpy(dtype=float)
        y = group["p95_us"].to_numpy(dtype=float)
        x = group["run_cache_hit_pct"].to_numpy(dtype=float)
        y_resid, y_coef = regress_residual(y, z)
        x_resid, x_coef = regress_residual(x, z)
        group["p95_residual_us"] = y_resid
        group["cache_hit_residual_pct_points"] = x_resid

        color = COLORS[variant]
        ax.axhline(0, color="#8a8a8a", linewidth=0.9)
        ax.axvline(0, color="#8a8a8a", linewidth=0.9)
        epoch_sc = ax.scatter(
            x_resid,
            y_resid,
            c=group["epoch"],
            cmap="plasma",
            s=52,
            alpha=0.86,
            edgecolor="white",
            linewidth=0.45,
        )
        slope, r2 = add_fit_line(ax, x_resid, y_resid, color)

        pearson = pd.Series(x_resid).corr(pd.Series(y_resid))
        spearman = pd.Series(x_resid).rank().corr(pd.Series(y_resid).rank())
        label = group["variant_label"].iloc[0]
        ax.set_title(f"{label}: size-adjusted partial relationship")
        ax.set_xlabel("Cache-hit ratio residual (percentage points)")
        ax.grid(True, color="#e5e5e5", linewidth=0.8)
        ax.text(
            0.03,
            0.97,
            f"partial r = {pearson:.3f}\nslope = {slope:.0f} us / pct-pt\nR2 = {r2:.3f}",
            transform=ax.transAxes,
            va="top",
            ha="left",
            fontsize=9,
            bbox={"boxstyle": "round,pad=0.35", "facecolor": "white", "edgecolor": "#dddddd", "alpha": 0.9},
        )

        for epoch in (60, 73, 84, 95, 98, 100) if variant == "vacuum" else (65, 74, 83, 86, 97, 100):
            row = group[group["epoch"] == epoch]
            if not row.empty:
                ax.annotate(
                    str(epoch),
                    (
                        float(row["cache_hit_residual_pct_points"].iloc[0]),
                        float(row["p95_residual_us"].iloc[0]),
                    ),
                    xytext=(4, 4),
                    textcoords="offset points",
                    fontsize=8,
                    color="#333333",
                )

        rows.append(
            {
                "variant": label,
                "epochs": len(group),
                "raw_cache_hit_vs_p95_pearson": group["run_cache_hit_pct"].corr(group["p95_us"]),
                "raw_cache_hit_vs_p95_spearman": group["run_cache_hit_pct"].rank().corr(group["p95_us"].rank()),
                "size_adjusted_cache_hit_vs_p95_pearson": pearson,
                "size_adjusted_cache_hit_vs_p95_spearman": spearman,
                "size_adjusted_slope_us_per_cache_hit_pct_point": slope,
                "size_adjusted_r2": r2,
                "p95_size_model_intercept_us": y_coef[0],
                "p95_size_model_slope_us_per_log10_gib": y_coef[1],
                "cache_hit_size_model_intercept_pct": x_coef[0],
                "cache_hit_size_model_slope_pct_per_log10_gib": x_coef[1],
                "toast_total_gib_min": group["toast_total_gib"].min(),
                "toast_total_gib_max": group["toast_total_gib"].max(),
            }
        )

    axes[0].set_ylabel("P95 latency residual after log10(size) control (us)")
    fig.subplots_adjust(top=0.84, right=0.86, wspace=0.12)
    cax = fig.add_axes([0.89, 0.20, 0.018, 0.60])
    cbar = fig.colorbar(epoch_sc, cax=cax)
    cbar.set_label("Epoch")
    cbar.set_ticks([1, 25, 50, 75, 100])
    cbar.set_ticklabels(["1", "25", "50", "75", "100"])
    fig.suptitle("TOAST_hypothesis_2: cache-hit ratio vs p95 after accounting for TOAST data size")
    fig.savefig(path, dpi=180, bbox_inches="tight")
    plt.close(fig)
    return path, pd.DataFrame(rows)


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    df = load_data()
    # Make panel ordering stable: VACC first, NOVACC second.
    order = {"vacuum": 0, "no_vacuum": 1}
    df = df.sort_values(["variant", "epoch"], key=lambda s: s.map(order).fillna(s) if s.name == "variant" else s)

    plain_path = plot_plain_cache_vs_latency(df)
    raw_path = plot_raw_size_encoded(df)
    partial_path, summary = plot_size_adjusted_partial(df)
    derived_path = OUT_DIR / "cache_hit_ratio_p95_size_accounted_points.csv"
    summary_path = OUT_DIR / "cache_hit_ratio_p95_size_accounted_summary.csv"
    df.to_csv(derived_path, index=False)
    summary.to_csv(summary_path, index=False)

    print(plain_path)
    print(raw_path)
    print(partial_path)
    print(derived_path)
    print(summary_path)


if __name__ == "__main__":
    main()
