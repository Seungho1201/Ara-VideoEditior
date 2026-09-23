#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p TestArtifacts/results
swift test --arch arm64
./scripts/make-fixtures.sh
swift build --arch arm64 --product FrameProbe
binary_dir="$(swift build --arch arm64 --show-bin-path)"
"$binary_dir/FrameProbe" smoke "$PWD/TestArtifacts/fixtures" "$PWD/TestArtifacts/results"
"$binary_dir/FrameProbe" snapshot-roundtrip --chart "$PWD/TestArtifacts/snapshot-color-chart"
python3 scripts/verify-outputs.py
