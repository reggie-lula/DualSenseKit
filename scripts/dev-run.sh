#!/usr/bin/env bash

cd /Users/reggie/Documents/DSCoder
scripts/build.sh
pkill -f './.manual-build/DualSenseKitDemo --headless-server' || true
./.manual-build/DualSenseKitDemo --headless-server
