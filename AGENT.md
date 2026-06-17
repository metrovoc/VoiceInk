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

- `main` - primary branch for this fork and the source branch for releases.
- Feature and fix branches should branch from this fork's current `main` unless a task explicitly says otherwise.

## Automation

- `.github/workflows/build-release.yml` - builds and publishes VoiceInk CE releases for this fork.
- Codex automation `voiceink-upstream-learning-review` is learning-only.
  - Fetches upstream read-only.
  - Summarizes upstream changes as product and engineering ideas.
  - Never syncs, rebases, merges, cherry-picks, force-pushes, changes branch defaults, or releases from upstream.

## Git Remotes

- `origin` - metrovoc/VoiceInk, this fork.
- `upstream` - original project, reference only.
