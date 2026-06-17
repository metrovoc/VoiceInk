# VoiceInk CE Fork

## What This Is

- VoiceInk CE is an independent fork of VoiceInk. The code started from upstream but has diverged: it now has its own architecture, conventions, and implementation choices.
- This repository is the source of truth. Don't assume upstream's structure, patterns, or APIs still match what's here — read this codebase, not upstream, to understand how things actually work.
- The fork follows upstream's direction and may re-implement features upstream ships, but it does so in this fork's own style.

## Upstream Policy

- Don't fast-forward, reset, rebase, merge, or cherry-pick upstream code by default.
- Pulling upstream code in is a deliberate, case-by-case decision, and anything that lands here is rewritten to fit this fork's conventions, with local tests and normal review.
- New work belongs in this fork's architecture — match the surrounding code here, not upstream's patterns.

## Branches

- `main` - primary branch for this fork and the source branch for releases.
- Feature and fix branches should branch from this fork's current `main` unless a task explicitly says otherwise.

## Git Remotes

- `origin` - metrovoc/VoiceInk, this fork.
- `upstream` - original project, reference only.
