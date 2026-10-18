# Epoch-metric plots

The analysis script `plot_postgresql_epoch_metrics.py` plots per-epoch latency,
throughput, and storage metrics from the workload CSVs that the experiment
scripts generate (`workload_data.csv`, one row per epoch × phase × operation). It
averages repeated runs into mean ± 2 SD summary plots, and it can overlay
several data types or EXTEND distributions in one figure.

Use `--no-title` to get the untitled figures (which were used in the paper).

## Requirements

- Python 3.10 or newer
- `pandas` and `matplotlib`

```bash
python3 -m venv .venv
.venv/bin/pip install pandas matplotlib
```

## Directory layout

The script treats the folder one level above its own location as the project
root. For this copy, the root is `ycsb-ec2-bundle/`.

- As inputs, the workload CSVs are expected to be inside directory `ycsb-ec2-bundle/datafiles/`.
- As outputs, figures are written to the path matching the experiment settings under `ycsb-ec2-bundle/figures/`.

```
ycsb-ec2-bundle/
├── analysis_scripts/
│   └── plot_postgresql_epoch_metrics.py
├── datafiles/
│   └── <experiment>/             # one experiment configuration
│       ├── <name>_run1.csv       # one CSV per repeated run
│       ├── <name>_run2.csv
│       └── ...
└── figures/                      # created by the script
    └── <experiment>/...
```

## Running the script

Run these from `ycsb-ec2-bundle/`:

```bash
python3 analysis_scripts/plot_postgresql_epoch_metrics.py datafiles/<experiment>
```

```bash
python3 analysis_scripts/plot_postgresql_epoch_metrics.py --no-title datafiles/<experiment>
```

| Argument | Meaning |
|---|---|
| `datafiles/<experiment>` (required) | Folder of workload CSVs for **one** configuration. |
| `--no-title` | No figure titles or operation titles, and a 6×3 in figure instead of 6×4 in. |

- Only `*.csv` files **directly** inside the directory are read. Subfolders
  are ignored.
- A file whose name (without `.csv`) ends in `IGNORE`, such as
  `run3_IGNORE.csv`, is skipped. Use this to leave out a bad run.
- All CSVs in one directory are treated as **repeated runs of the same
  configuration**.

When it finishes, the script prints how many individual and summary plots it
wrote, and the output folder.

## Output

For each metric, the phases recorded in the workload CSVs are split into two groups:

- `run/`: `run`, `clean-run`, and `avg-run`, plus the comparison phases below
- `extend/`: `extend`, plus the comparison phases below

Each group gets **one PNG per operation** found in the data (`READ`, `UPDATE`,
`INSERT`, `EXTEND`):

```
figures/<experiment>/<metric_folder>/<run|extend>/
    <csv_stem>_<run|extend>_epoch_vs_<Metric>_<OP>.png              # one per CSV
    <experiment>_summary_mean_<run|extend>_epoch_vs_<Metric>_<OP>.png  # all CSVs
```

**Summary plots** (`_summary_mean_`) are the ones used in the paper.

- The line is the mean across runs. Each run is first averaged per epoch.
- The shaded band is ± 2 SD across runs.
- They are made only when the directory has **at least 2 CSVs**.

**Titles** (on by default) are built from the folder and file names. Example:
"Text Array: 95th-Percentile Operation Latency Across Epochs — Heavy, Zipfian
EXTEND, Read-Only Workload, Zipfian Access (All Runs: Mean ± 2 SD)".
Individual plots end in "(Run N)" instead.

At the end, the script deletes any output folders left empty because the CSVs
lack that metric or phase.

### Legend labels

| CSV `Phase` | Legend | Marker |
|---|---|---|
| `run` | incr-extend | ● |
| `clean-run` | bulk-loaded | ▲ |
| `avg-run` | equal-avg-size | × |
| `extend` | extend | ◆ |
| `textrow` / `textarray` / `json` | textrow / textarrays / json | ▲ / ● / × |
| `extend-textrow` / `extend-textarray` / `extend-json` | same as the phase name | ▲ / ● / ★ |
| `run-uniform` / `run-zipfian` | incr-extend (uniform) / (zipfian) | ◆ / ✚ |
| `extend-uniform` / `extend-zipfian` | extend (uniform) / (zipfian) | ◆ / ✚ |

Colours come from matplotlib's default cycle in the order above. As a result,
`run`, `clean-run`, and `avg-run` are blue, orange, and green.

### Metrics

| CSV column | Output folder | Source |
|---|---|---|
| `AverageLatency(us)` | `avg_latency_us` | experiment CSV |
| `MinLatency(us)` | `min_latency_us` | experiment CSV |
| `MaxLatency(us)` | `max_latency_us` | experiment CSV |
| `95thPercentileLatency(us)` | `p95_latency_us` | experiment CSV |
| `99thPercentileLatency(us)` | `p99_latency_us` | experiment CSV |
| `Throughput(ops/sec)` | `throughput_ops_sec` | experiment CSV |
| `blks_read` | `total_blks_read` | experiment CSV |
| `usertable_n_tup_upd` | `usertable_n_tup_upd` | experiment CSV |
| `toast_n_tup_ins` | `toast_n_tup_ins` | experiment CSV |
| `toast_size_in_GiB` | `toast_size_GiB` | **derived**: `toast_size_in_bytes / 1024³` |
| `usertable_heap_blks_epoch` | `usertable_heap_blks_epoch` | **derived** |
| `toast_blks_epoch` | `toast_blks_epoch` | **derived** |
| `usertable_n_tup_upd_epoch` | `usertable_n_tup_upd_epoch` | **derived** |
| `toast_n_tup_ins_epoch` | `toast_n_tup_ins_epoch` | **derived** |
| `write_amplification` | `write_amplification` | **derived** |

The experiment scripts **do not write the derived columns**. To plot them, add
them to the CSVs first.

- The `*_epoch` columns appear to be per-epoch differences of the cumulative
  counters.
- How `write_amplification` was defined is not recorded here. Check with
  whoever made the paper figures.

If a CSV lacks one of these columns, that metric is skipped.

---

## Examples

The two examples below show the two kinds of plots the script can make.

- **Example 1** compares how the data was loaded (incr-extend, bulk-loaded,
  and equal-avg-size) for one data type.
- **Example 2** compares data types (textrow, textarrays, and json) in the
  same figure.

### Example 1: incr-extend vs bulk-loaded vs equal-avg-size (under one experiment configuration)

**Goal:** see how READ latency grows over the epochs for text arrays, and how
the incrementally extended table compares with a bulk-loaded copy and an
equal-average-size copy.

These three lines come straight from the `run`, `clean-run`, and `avg-run`
phases of a normal experiment, so no preparation is needed.

1. Put each repeated run's `workload_data.csv` in one folder (for example, `textarray_heavy_extend-uniform_readonly-zipfian`), with one file
   per run.

2. Run the script to generate the plots:

   ```bash
   python3 analysis_scripts/plot_postgresql_epoch_metrics.py datafiles/textarray_heavy_extend-uniform_readonly-zipfian
   ```

**Result:** in `figures/textarray_heavy_extend-uniform_readonly-zipfian/`, the most useful files are the summary plots in each metric's `run/` folder. For
example:

- Average READ latency:
  `avg_latency_us/run/textarray_heavy_extend-uniform_readonly-zipfian_summary_mean_run_epoch_vs_AverageLatency_us_READ.png`
- P95 READ latency: the matching file under `p95_latency_us/run/`

Each summary plot has three lines (incr-extend, bulk-loaded, and
equal-avg-size). Each line shows the mean across the runs, with a ± 2 SD band.
The `extend/` folders hold the matching plots of EXTEND latency.

### Example 2: textrow vs textarrays vs json (compare various data types)

**Goal:** compare READ latency, and EXTEND latency, across the three data
types in one figure.

The script draws one line for each `Phase` value in the folder it plots. To
get one line per data type, prepare the input CSVs before plotting:

1. For each run, combine the rows from the text-row, text-array, and JSON CSVs
   into one CSV. Use the same file name pattern as in Example 1, for example
   `run1.csv`, `run2.csv`, and so on.
2. In each combined CSV, rename the `Phase` values to the **comparison
   phases** below:

   | Phase in each data type's own CSV | Rename to |
   |---|---|
   | `run` (text row / text array / JSON) | `textrow` / `textarray` / `json` |
   | `extend` (text row / text array / JSON) | `extend-textrow` / `extend-textarray` / `extend-json` |

3. Delete the rows of every other phase (`clean-run`, `avg-run`, ...).
   Otherwise they also appear in the figure, as bulk-loaded and
   equal-avg-size.
4. Put the combined CSVs in one folder, for example `datafiles/datatype_cmp/`.
5. Plot that folder:

   ```bash
   python3 analysis_scripts/plot_postgresql_epoch_metrics.py datafiles/datatype_cmp
   ```

**Result:** the plots are in `figures/datatype_cmp/`.

- Average READ latency, with one line each for textrow, textarrays, and json:
  `avg_latency_us/run/datatype_cmp_summary_mean_run_epoch_vs_AverageLatency_us_READ.png`
- Average EXTEND latency, with one line each for extend-textrow,
  extend-textarray, and extend-json:
  `avg_latency_us/extend/datatype_cmp_summary_mean_extend_epoch_vs_AverageLatency_us_EXTEND.png`

To compare uniform and Zipfian EXTEND instead, use the same steps but rename
the phases to `run-uniform`/`run-zipfian` and
`extend-uniform`/`extend-zipfian`.

## Notes

- The ± 2 SD band can go below zero when runs vary a lot. It is not clipped.
- With titles on, combined comparison CSVs get a data-type label guessed from
  the folder name, or "Multiple Data Types". That label doesn't describe the
  comparison itself, so use `--no-title` for these plots.
