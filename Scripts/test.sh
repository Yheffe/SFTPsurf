#!/bin/bash
# Runs the SFTPsurf self-test suite.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
exec swift run --quiet SelfTest "$@"
