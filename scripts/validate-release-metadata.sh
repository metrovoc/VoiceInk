#!/usr/bin/env bash
set -euo pipefail

app_path=""
appcast_path=""
expected_version=""
expected_build=""
previous_appcast_url=""
minimum_build="${VOICEINK_MIN_SPARKLE_BUILD:-26412}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat >&2 <<'USAGE'
Usage: validate-release-metadata.sh --app APP --appcast APPCAST --version VERSION --build BUILD [--previous-appcast-url URL]
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app)
      app_path="${2:-}"
      shift 2
      ;;
    --appcast)
      appcast_path="${2:-}"
      shift 2
      ;;
    --version)
      expected_version="${2:-}"
      shift 2
      ;;
    --build)
      expected_build="${2:-}"
      shift 2
      ;;
    --previous-appcast-url)
      previous_appcast_url="${2:-}"
      shift 2
      ;;
    *)
      usage
      exit 64
      ;;
  esac
done

if [ -z "$app_path" ] || [ -z "$appcast_path" ] || [ -z "$expected_version" ] || [ -z "$expected_build" ]; then
  usage
  exit 64
fi

if ! [[ "$expected_build" =~ ^[0-9]+$ ]]; then
  echo "Expected build '$expected_build' is not numeric." >&2
  exit 65
fi

if [ "$expected_build" -lt "$minimum_build" ]; then
  echo "Build $expected_build is below the minimum Sparkle-safe build $minimum_build." >&2
  exit 65
fi

info_plist="$app_path/Contents/Info.plist"
if [ ! -f "$info_plist" ]; then
  echo "Missing app Info.plist at $info_plist" >&2
  exit 66
fi

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$info_plist"
}

xml_value() {
  local tag="$1"
  perl -0ne "print \$1 if m{<$tag>([^<]+)</$tag>}s" "$appcast_path"
}

assert_equal() {
  local label="$1"
  local expected="$2"
  local actual="$3"

  if [ "$actual" != "$expected" ]; then
    echo "$label mismatch: expected '$expected', got '$actual'." >&2
    exit 65
  fi
}

assert_equal "CFBundleShortVersionString" "$expected_version" "$(plist_value CFBundleShortVersionString)"
assert_equal "CFBundleVersion" "$expected_build" "$(plist_value CFBundleVersion)"
assert_equal "sparkle:shortVersionString" "$expected_version" "$(xml_value 'sparkle:shortVersionString')"
assert_equal "sparkle:version" "$expected_build" "$(xml_value 'sparkle:version')"

if [ -n "$previous_appcast_url" ]; then
  previous_appcast="$(mktemp)"
  if curl -fsSL "$previous_appcast_url" -o "$previous_appcast"; then
    previous_build="$(perl -0ne 'print $1 if m{<sparkle:version>([^<]+)</sparkle:version>}s' "$previous_appcast")"
    previous_version="$(perl -0ne 'print $1 if m{<sparkle:shortVersionString>([^<]+)</sparkle:shortVersionString>}s' "$previous_appcast")"

    if [[ "$previous_build" =~ ^[0-9]+$ ]] && [ "$expected_build" -le "$previous_build" ]; then
      echo "Build $expected_build must be greater than previous appcast build $previous_build." >&2
      exit 65
    fi

    previous_version_build="$("$script_dir/release-build-number.sh" "$previous_version" 2>/dev/null || true)"
    expected_version_build="$("$script_dir/release-build-number.sh" "$expected_version")"
    if [[ "$previous_version_build" =~ ^[0-9]+$ ]] && [ "$expected_version_build" -le "$previous_version_build" ]; then
      echo "Display version $expected_version must be greater than previous appcast version $previous_version." >&2
      exit 65
    fi
  else
    echo "Warning: could not fetch previous appcast from $previous_appcast_url; skipping monotonic remote check." >&2
  fi
fi

echo "Release metadata validated: version $expected_version, build $expected_build."
