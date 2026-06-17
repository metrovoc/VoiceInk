# VoiceInk CE Fork

## Project Context

- VoiceInk CE is a personal-use fork of the original VoiceInk project.
- Starting with `v26.6.2`, this repository is formally diverged from upstream.
- Upstream remains valuable as a learning and product-reference source, but it is no longer a branch to sync or rebase onto.

## Upstream Policy

- Do not fast-forward, reset, rebase, merge, or cherry-pick upstream code by default.
- Treat upstream work as prompts for local design: "they added this capability; how should VoiceInk CE implement it?"
- Any implementation belongs in this fork's architecture, with local tests and normal review.
- Direct code reuse requires an explicit human decision.

## Branches

- `custom` - primary branch for this fork and the source branch for releases.
- `main` - retained only as the original upstream-line branch; do not use it for VoiceInk CE work.
- Feature and fix branches should branch from this fork's current `custom` unless a task explicitly says otherwise.

## Automation

- `.github/workflows/observe-upstream.yml` - learning-only upstream observer.
  - Fetches upstream read-only.
  - Creates an issue summarizing upstream changes as implementation ideas.
  - Never syncs, rebases, merges, force-pushes, or releases from upstream.
- `.github/workflows/build-release.yml` - builds and publishes VoiceInk CE releases for this fork.

## Git Remotes

- `origin` - metrovoc/VoiceInk, this fork.
- `upstream` - original project, reference only.
