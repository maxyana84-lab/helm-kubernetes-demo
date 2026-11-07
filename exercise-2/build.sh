#!/usr/bin/env bash
# Builds the dependency chain: trtech-lib -> services -> platform.
# Run from the exercise-2 directory. Generated *.tgz files are git-ignored.
set -euo pipefail
cd "$(dirname "$0")"
helm package trtech-lib                       # trtech-lib-0.1.0.tgz
for s in services/*/; do helm dependency update "$s"; done   # pulls trtech-lib into each service
helm dependency update platform               # packages the 4 services into platform/charts/
helm dependency build platform                # verify against Chart.lock
ls -1 platform/charts
