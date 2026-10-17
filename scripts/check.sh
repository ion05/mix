#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Compiles the pure parts of the engine with scripts/Checks.swift and runs them.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -swift-version 5 -parse-as-library Mix/Models.swift Mix/Engine/*.swift scripts/Checks.swift -o "$out/checks"
"$out/checks"
echo "checks passed"
