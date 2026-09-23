#!/usr/bin/env bash
# Compatibility entry point.
#
# This script was a near-complete copy of the authoritative runner (77% identical, the
# difference pure drift). The text-array specifics now live once, in
# lib/backends/postgresql_textarray.sh, and the phase engine once, in lib/lifecycle.sh.
# Use the single entry point instead:
#
#   ./experiment.sh postgresql_textarray [options]
set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/experiment.sh" postgresql_textarray "$@"
