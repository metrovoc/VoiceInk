# VoiceInk Fork

## Project Context
- **Local fork** of [Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk) for personal customizations
- Upstream maintained by original author; we sync and rebase our changes on top

## Branches
- `custom` - **Default branch**, contains our customizations
- `main` - Mirror of upstream/main, auto-synced daily

## Automation
- `.github/workflows/sync-upstream.yml` - Daily sync workflow
  - Syncs `main` from upstream
  - Rebases `custom` onto `main`
  - Uses Claude Code Action (OAuth) to resolve conflicts
  - Creates GitHub issue if manual intervention needed

## Git Remotes
- `origin` - metrovoc/VoiceInk (this fork)
- `upstream` - Beingpax/VoiceInk (original repo)
