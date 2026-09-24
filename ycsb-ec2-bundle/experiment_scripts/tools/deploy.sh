#!/usr/bin/env bash
#
# tools/deploy.sh — ship the experiment harness to an EC2 host.
#
#   tools/deploy.sh --host [user@]server [--key KEY.pem] [--remote-dir DIR]
#                   [--include-config] [--dry-run]
#
# Primary deploy path: a tarball of the tracked experiment_scripts/ tree, extracted over
# the bundle checkout on the target. It is an overlay, not a replacement — files that only
# exist on the server (untracked conf/db.<backend>.env credentials, analysis/ output, the
# built YCSB jars) survive; harness files are overwritten after a timestamped backup of
# the whole experiment_scripts directory is taken remotely.
#
# Verify what would ship without touching anything:  --dry-run
# Single-file deploys (one scp onto an already-current tree) stay available via
# tools/bundle.sh + scp of experiment.bundle.sh; see README §Deploy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"   # the ycsb-ec2-bundle directory

HOST=""
KEY=""
REMOTE_DIR="/home/ycsb/ycsb-ec2-bundle"
INCLUDE_CONFIG=0
DRY_RUN=0

usage() {
    cat <<USAGE
Usage: tools/deploy.sh --host [user@]server [options]

  --host [user@]server   ssh target (required)
  --key FILE             ssh private key (passed as -i)
  --remote-dir DIR       remote ycsb-ec2-bundle root
                         (default: /home/ycsb/ycsb-ec2-bundle)
  --include-config       also ship untracked conf/db.*.env files (credentials! default: no)
  --dry-run              print the payload and the remote actions, deploy nothing
  -h, --help             this help

Packages tracked experiment_scripts/ files and extracts them over DIR on the target,
after backing up the target's current experiment_scripts there. The ssh user must be
able to write DIR (for a tree owned by another user, log in as that user or use sudo
rules; deploy will then fail cleanly on permissions).
USAGE
}

while (($#)); do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        --host) HOST="${2:?--host needs [user@]server}"; shift 2 ;;
        --key) KEY="${2:?--key needs a file}"; shift 2 ;;
        --remote-dir) REMOTE_DIR="${2:?--remote-dir needs a path}"; shift 2 ;;
        --include-config) INCLUDE_CONFIG=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        *) echo "[deploy] unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ -n "$HOST" ]] || { echo "[deploy] --host is required (see --help)" >&2; exit 2; }
[[ -z "$KEY" || -r "$KEY" ]] || { echo "[deploy] cannot read key: $KEY" >&2; exit 2; }
git -C "$BUNDLE_ROOT" rev-parse --git-dir >/dev/null 2>&1 || {
    echo "[deploy] $BUNDLE_ROOT is not a git checkout; deploy ships tracked files only" >&2
    exit 2
}

# --- build the payload -------------------------------------------------------------------------
cd "$BUNDLE_ROOT"
list="$(mktemp)"
trap 'rm -f "$list" ${TARBALL:-}' EXIT
git -C "$BUNDLE_ROOT" ls-files -z -- experiment_scripts >"$list"
if (( INCLUDE_CONFIG )); then
    # Untracked per-backend endpoint/credential files, never the .example templates again.
    find experiment_scripts/conf -name 'db.*.env' ! -name '*.example' -print0 \
        | grep -zv -x -F -f "$list" >>"$list" || true
fi

TARBALL="$(mktemp "${TMPDIR:-/tmp}/ycsb-harness.XXXXXX.tgz")"
tar czf "$TARBALL" -C "$BUNDLE_ROOT" --null -T "$list"

if (( DRY_RUN )); then
    echo "[deploy] dry run — payload of $TARBALL:"
    tr '\0' '\n' <"$list" | sed 's/^/  /'
    cat <<PLAN
[deploy] remote actions on $HOST:
  cd $REMOTE_DIR                       (must exist; holds the YCSB tree)
  tar czf \$HOME/ycsb_experiment_backup_<utc>.tgz experiment_scripts
  tar xzf <upload> -C .                (overlay; untracked server files survive)
  bash -n experiment.sh && ./experiment.sh --list-backends
PLAN
    exit 0
fi

echo "[deploy] packaged $(tr '\0' '\n' <"$list" | wc -l) files ($(du -h "$TARBALL" | cut -f1))"

# --- ship it ------------------------------------------------------------------------------------
ssh_opts=()
[[ -n "$KEY" ]] && ssh_opts+=(-i "$KEY")
name="$(basename "$TARBALL")"

scp "${ssh_opts[@]}" "$TARBALL" "$HOST:/tmp/$name"

# The remote side runs as the ssh user; paths with single quotes are not supported here.
REMOTE_DIR="$REMOTE_DIR" TARBALL_NAME="$name" ssh "${ssh_opts[@]}" "$HOST" 'bash -s' <<'REMOTE'
set -euo pipefail
cd "$REMOTE_DIR" || { echo "[deploy] remote directory $REMOTE_DIR missing (is the YCSB bundle unpacked there?)"; exit 1; }
ts=$(date -u +%Y%m%dT%H%M%SZ)
if [ -d experiment_scripts ]; then
    backup="$HOME/ycsb_experiment_backup_$ts.tgz"
    tar czf "$backup" experiment_scripts
    echo "[deploy] backed up current experiment_scripts to $backup"
fi
tar xzf "/tmp/$TARBALL_NAME" -C .
echo "[deploy] extracted $(find experiment_scripts -type f | wc -l) harness files into $REMOTE_DIR"
cd experiment_scripts
bash -n experiment.sh
./experiment.sh --list-backends >/dev/null
rm -f "/tmp/$TARBALL_NAME"
echo "[deploy] OK — harness verified on the target (run ./experiment.sh <backend> --check there next)"
REMOTE
