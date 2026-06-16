#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <major.minor[.patch]>" >&2
}

if [ "$#" -ne 1 ]; then
  usage
  exit 64
fi

version="${1#v}"

if [[ ! "$version" =~ ^[0-9]+[.][0-9]+([.][0-9]+)?$ ]]; then
  echo "Invalid release version '$1'. Expected major.minor or major.minor.patch." >&2
  exit 65
fi

IFS=. read -r major minor patch <<< "$version"
patch="${patch:-0}"

for component_name in major minor patch; do
  component_value="${!component_name}"
  if [ "$((10#$component_value))" -gt 999 ]; then
    echo "Invalid release version '$1'. $component_name must be <= 999 for monotonic build encoding." >&2
    exit 65
  fi
done

# Sparkle compares CFBundleVersion, not CFBundleShortVersionString. Fixed-width
# semantic encoding preserves display-version ordering across multi-digit patches:
# 26.4.11 -> 26004011, 26.6.0 -> 26006000.
printf "%d\n" "$((10#$major * 1000000 + 10#$minor * 1000 + 10#$patch))"
