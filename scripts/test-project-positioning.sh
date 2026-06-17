#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail() {
  echo "Project positioning check failed: $*" >&2
  exit 1
}

readme="README.md"
about_view="VoiceInk/Views/AboutView.swift"
managed_docs=(
  "AGENT.md"
  "BUILDING.md"
  "CONTRIBUTING.md"
  "CODE_OF_CONDUCT.md"
  ".github/PULL_REQUEST_TEMPLATE.md"
  ".github/ISSUE_TEMPLATE/bug_report.md"
  ".github/ISSUE_TEMPLATE/feature_request.md"
)

grep -q "https://github.com/Beingpax/VoiceInk" "$readme" \
  || fail "README.md must keep the upstream project link for attribution."

grep -qi "thank you to Pax" "$readme" \
  || fail "README.md must keep the upstream thanks."

if grep -Eiq "Beingpax|Pax|upstream|Original VoiceInk|original project|github.com/Beingpax/VoiceInk" "$about_view"; then
  fail "AboutView must not contain upstream attribution or original-project links."
fi

for path in "${managed_docs[@]}"; do
  if grep -Eiq "Beingpax|Pax|github.com/Beingpax/VoiceInk" "$path"; then
    fail "$path must not contain upstream attribution or original-project links; keep that in README.md."
  fi
done

if grep -Eiq "Contributor Covenant|community leaders|Join our discussions|Start a discussion|Reach out to the maintainers" \
  "CONTRIBUTING.md" "CODE_OF_CONDUCT.md" ".github/PULL_REQUEST_TEMPLATE.md"; then
  fail "Repository governance docs still contain generic community-template language."
fi

echo "Project positioning checks passed."
