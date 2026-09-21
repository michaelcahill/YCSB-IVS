#!/usr/bin/env python3
"""Plot runtime from timestamped experiment events (not YCSB latency).

Usage: python plot_postgresql_phase_runtime.py <log-file> --output-dir <output-dir-name>
Requires matplotlib. Missing/mismatched events are errors, never zero durations.
"""
import argparse
import csv
from collections import defaultdict
from datetime import datetime, timezone
import json
from pathlib import Path
import re

LINE = re.compile(r'^\[(.*?) UTC\] \[epoch=(\d+) run=(\d+) phase=([^]]+)\] (.*)$')
EVENT = re.compile(r'^(START|END) (YCSB \S+|VACUUM ANALYZE database=\S+|VACUUM table=\S+)(?: |$)')
PHASES = ['extend', 'run', 'reference', 'clean-run', 'avg-run']


def parse_log(path):
    pending, rows, stamps = {}, [], []
    for lineno, line in enumerate(Path(path).read_text().splitlines(), 1):
        m = LINE.match(line)
        if not m:
            continue
        stamp, epoch, run, phase, message = m.groups()
        stamp = datetime.strptime(stamp, '%Y-%m-%d %H:%M:%S').replace(tzinfo=timezone.utc)
        stamps.append(stamp)
        if message == 'Backing up the database started':
            direction, name = 'START', 'dump-restore'
        elif message == 'Backing up the database finished':
            direction, name = 'END', 'dump-restore'
        else:
            event = EVENT.match(message)
            if not event:
                continue
            direction, name = event.groups()
        key = (int(epoch), int(run), phase, name)
        if direction == 'START':
            if key in pending:
                raise ValueError(f'Line {lineno}: duplicate START {key}')
            pending[key] = stamp
            continue
        if key not in pending:
            raise ValueError(f'Line {lineno}: END without START {key}')
        start = pending.pop(key)
        seconds = (stamp - start).total_seconds()
        if seconds < 0:
            raise ValueError(f'Line {lineno}: negative duration')
        if name.startswith('YCSB '):
            category = name[5:]
        elif name.startswith('VACUUM ANALYZE'):
            category = 'vacuum-total'
        elif name.startswith('VACUUM table='):
            category = 'vacuum-toast' if '.pg_toast.' in name else 'vacuum-usertable'
        else:
            category = name
        status = re.search(r'\bstatus=(\d+)', message)
        rows.append(dict(epoch=int(epoch), run=int(run), phase=phase, category=category,
                         event=name, start=start.isoformat(), end=stamp.isoformat(),
                         seconds=seconds, status=int(status[1]) if status else ''))
    if pending:
        raise ValueError(f'Unfinished events: {list(pending)}')
    if not rows:
        raise ValueError('No completed timestamped events found')
    if stamps != sorted(stamps):
        raise ValueError('Log timestamps are not chronological')
    # Do not assume ten steps per epoch, or confuse run3 with within-epoch run.
    steps = sorted({(r['epoch'], r['run']) for r in rows if r['epoch'] > 0})
    indexes = {step: i + 1 for i, step in enumerate(steps)}
    for row in rows:
        row['iteration'] = indexes.get((row['epoch'], row['run']), 0)
    return rows, (stamps[-1] - stamps[0]).total_seconds()


def write_outputs(rows, elapsed, output):
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    output.mkdir(parents=True, exist_ok=True)
    with (output / 'intervals.csv').open('w', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    groups = defaultdict(list)
    for row in rows:
        groups[row['category']].append(row)
    summary = {name: dict(count=len(rs), total_seconds=sum(r['seconds'] for r in rs),
                         max_seconds=max(r['seconds'] for r in rs)) for name, rs in groups.items()}
    # Table VACUUM intervals are inside vacuum-total; never count them twice.
    accounted = sum(r['seconds'] for r in rows if r['category'] not in ('vacuum-toast', 'vacuum-usertable'))
    summary['wall_time'] = dict(total_seconds=elapsed, accounted_seconds=accounted,
                                uninstrumented_seconds=elapsed - accounted)
    (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    plt.rcParams.update({'font.size': 10, 'axes.spines.top': False, 'axes.spines.right': False})
    colors = ['#2764a5', '#dd6b20', '#269582', '#8860aa', '#b84d68']
    fig, axes = plt.subplots(3, 2, figsize=(13, 10), constrained_layout=True)
    for ax, name, color in zip(axes.flat, PHASES, colors):
        rs = groups.get(name, [])
        ax.plot([r['iteration'] for r in rs], [r['seconds'] for r in rs], color=color, marker='.', ms=3)
        ax.set(title=name, xlabel='Iteration (epoch / step ordered)', ylabel='Wall time (seconds)')
        ax.grid(alpha=.2)
    ax = axes.flat[-1]
    for name in ('vacuum-total', 'vacuum-toast', 'vacuum-usertable'):
        rs = groups.get(name, [])
        ax.plot([r['iteration'] for r in rs], [r['seconds'] for r in rs], label=name)
    ax.set(title='Explicit VACUUM (total includes table intervals)', xlabel='Iteration', ylabel='Wall time (seconds)')
    ax.legend(fontsize=8)
    ax.grid(alpha=.2)
    fig.suptitle('PostgreSQL experiment — timestamp-derived runtimes\nYCSB intervals exclude preparation; timestamps have 1-second resolution')
    fig.savefig(output / 'phase_runtimes.png', dpi=170)
    plt.close(fig)
    fig, axes = plt.subplots(1, 2, figsize=(13, 5), constrained_layout=True)
    for name in ('vacuum-usertable', 'vacuum-toast'):
        rs = groups.get(name, [])
        axes[0].plot([r['iteration'] for r in rs], [r['seconds'] for r in rs], label=name)
    axes[0].set_yscale('symlog', linthresh=1)
    axes[0].set(title='Table VACUUM detail (symlog; zero preserved)', xlabel='Iteration', ylabel='Seconds')
    axes[0].legend()
    budget = {name: item['total_seconds'] for name, item in summary.items()
              if name not in ('wall_time', 'vacuum-toast', 'vacuum-usertable')}
    budget['unlogged work / gaps'] = elapsed - accounted
    budget = dict(sorted(budget.items(), key=lambda pair: pair[1]))
    axes[1].barh(list(budget), [value / 3600 for value in budget.values()], color='#2764a5')
    axes[1].set(title=f'Non-overlapping time budget — {elapsed / 3600:.2f} hours', xlabel='Hours')
    fig.savefig(output / 'vacuum_and_budget.png', dpi=170)
    plt.close(fig)
    print(json.dumps(summary, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log', type=Path)
    parser.add_argument('--output-dir', type=Path)
    args = parser.parse_args()
    rows, elapsed = parse_log(args.log)
    write_outputs(rows, elapsed, args.output_dir or args.log.parent / (args.log.stem + '_runtime'))


if __name__ == '__main__':
    main()
