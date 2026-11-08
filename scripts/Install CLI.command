#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
"$HERE/pointswomanctl" install-cli
echo "Try: pointswoman --help"
echo "Press Return to close."
read -r _
