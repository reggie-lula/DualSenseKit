#!/usr/bin/env bash

scripts/build.sh
pkill -f './.manual-build/DualSenseKitDemo --headless-server' || true
ls ./
./.manual-build/DualSenseKitDemo --headless-server
