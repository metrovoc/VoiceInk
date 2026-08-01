#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

assert_build() {
  local version="$1"
  local expected="$2"
  local actual

  actual="$("$script_dir/release-build-number.sh" "$version")"
  if [ "$actual" != "$expected" ]; then
    echo "Expected $version -> $expected, got $actual" >&2
    exit 1
  fi
}

assert_greater() {
  local newer
  local older

  newer="$("$script_dir/release-build-number.sh" "$1")"
  older="$("$script_dir/release-build-number.sh" "$2")"
  if [ "$newer" -le "$older" ]; then
    echo "Expected $1 ($newer) to be greater than $2 ($older)" >&2
    exit 1
  fi
}

assert_build "1.72" "1072000"
assert_build "26.4.11" "26004011"
assert_build "26.6.0" "26006000"
assert_build "v26.6.1" "26006001"
assert_build "26.7.0" "26007000"
assert_build "26.7.1" "26007001"
assert_build "26.7.2" "26007002"

assert_greater "26.6.0" "26.4.11"
assert_greater "26.10.0" "26.6.99"
assert_greater "2.0.0" "1.999.999"

if "$script_dir/release-build-number.sh" "26.1000.0" >/dev/null 2>&1; then
  echo "Expected 26.1000.0 to be rejected" >&2
  exit 1
fi

project_file="$script_dir/../VoiceInk.xcodeproj/project.pbxproj"
expected_marketing_occurrences=2
expected_build_occurrences=2
marketing_occurrences="$(grep -c 'MARKETING_VERSION = 26.7.2;' "$project_file")"
build_occurrences="$(grep -c 'CURRENT_PROJECT_VERSION = 26007002;' "$project_file")"

if [ "$marketing_occurrences" -ne "$expected_marketing_occurrences" ]; then
  echo "Expected both VoiceInk app configurations to use MARKETING_VERSION 26.7.2" >&2
  exit 1
fi

if [ "$build_occurrences" -ne "$expected_build_occurrences" ]; then
  echo "Expected both VoiceInk app configurations to use CURRENT_PROJECT_VERSION 26007002" >&2
  exit 1
fi

echo "Release versioning tests passed."
