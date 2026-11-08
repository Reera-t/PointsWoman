#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -x "$HERE/pointswomanctl" ]; then
    "$HERE/pointswomanctl" restore
elif [ -x "$HERE/PointsWoman.app/Contents/MacOS/pointswomanctl" ]; then
    "$HERE/PointsWoman.app/Contents/MacOS/pointswomanctl" restore
else
    echo "Keep this recovery script beside pointswomanctl or PointsWoman.app."
    exit 1
fi
echo "Restoration finished. Press Return to close."
read -r _
