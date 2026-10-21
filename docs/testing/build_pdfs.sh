#!/usr/bin/env bash
# Rebuilds the testing PDFs in this folder from their HTML sources, using
# Google Chrome's headless print. Run after editing an .html file:
#
#   docs/testing/build_pdfs.sh
#
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"

for name in Frontend_Use_Cases Repeat_Testing_Guide; do
  "$CHROME" --headless --disable-gpu --no-pdf-header-footer \
    --print-to-pdf="$DIR/$name.pdf" "file://$DIR/$name.html" 2>/dev/null
  echo "wrote $DIR/$name.pdf"
done
