#!/usr/bin/env bash
# Compatibility entry point.
#
# The runner was refactored: the phase engine lives in lib/lifecycle.sh, the
# PostgreSQL specifics in lib/backends/postgresql_textarray.sh, and all
# configuration is resolved by lib/config.sh. Use the single entry point instead:
#
#   ./experiment.sh postgresql_textarray [options]
#
# This wrapper keeps existing launchers, tmux commands and scp-based deployments
# working; it can be removed once those call experiment.sh directly.
set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/experiment.sh" postgresql_textarray "$@"
