#!/usr/bin/env bash
set -euo pipefail

scripts/build.sh --demo
pkill -f './.manual-build/DualSenseKitDemo --headless-server' || true
./.manual-build/DualSenseKitDemo --headless-server
