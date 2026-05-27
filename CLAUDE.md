# VoiceInk Fork

## Project Context
- **Local fork** of [Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk) for personal customizations
- Upstream maintained by original author; we sync and rebase our changes on top

## Branches
- `custom` - **Default branch**, contains our customizations
- `main` - Mirror of upstream/main, updated by local Codex Automation

## Automation
- Local Codex Automation runs the upstream sync every two weeks
  - Mirrors `main` from upstream
  - Rebases `custom` onto `main` in a local worktree
  - Uses local macOS/Xcode checks before updating the fork
- `.github/workflows/build-release.yml` remains available for release builds

## Git Remotes
- `origin` - metrovoc/VoiceInk (this fork)
- `upstream` - Beingpax/VoiceInk (original repo)
