<div align="center">
  <img src="VoiceInk/Assets.xcassets/AppIcon.appiconset/256-mac.png" width="180" height="180" />
  <h1>VoiceInk CE</h1>
  <p>Speech-to-text for macOS, based on VoiceInk</p>

  [![License](https://img.shields.io/badge/License-GPL%20v3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
  ![Platform](https://img.shields.io/badge/platform-macOS%2014.4%2B-brightgreen)
  [![GitHub release](https://img.shields.io/github/v/release/metrovoc/VoiceInk)](https://github.com/metrovoc/VoiceInk/releases)
</div>

---

VoiceInk CE is a fork of [VoiceInk](https://github.com/Beingpax/VoiceInk). It started from upstream and has since grown its own implementation, conventions, and direction. This is a personal project I maintain for my own use, with no official support or compatibility guarantee.

## Features

- Accurate local and cloud transcription workflows
- Global keyboard shortcuts and push-to-talk recording
- Personal dictionary, text replacements, and text transform rules
- Optional AI enhancement and prompt workflows
- Power Mode for app- and URL-specific behavior
- History, metrics, audio-file transcription, and audio input configuration

## Get Started

### Download

Use builds from this repository's [Releases](https://github.com/metrovoc/VoiceInk/releases), when available.

### Build From Source

Build instructions are in [BUILDING.md](BUILDING.md).

## Requirements

- macOS 14.4 or later

## Project Resources

- [Changelog](https://github.com/metrovoc/VoiceInk/releases)
- [Feedback and issues](https://github.com/metrovoc/VoiceInk/issues)
- [Documentation](https://github.com/metrovoc/VoiceInk#readme)
- [Build guide](BUILDING.md)

## Contributing

Issues are useful for tracking bugs and regressions. Pull requests aren't expected unless coordinated ahead of time — see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

This project follows the GNU General Public License v3.0. See [LICENSE](LICENSE) for details.

## Acknowledgments

Thanks to Pax and the upstream contributors for creating and open-sourcing [VoiceInk](https://github.com/Beingpax/VoiceInk), which this fork builds on.

### Core Technology

- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) - high-performance inference of OpenAI's Whisper model
- [FluidAudio](https://github.com/FluidInference/FluidAudio) - Parakeet model implementation

### Essential Dependencies

- [Sparkle](https://github.com/sparkle-project/Sparkle) - app updates
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) - user-customizable keyboard shortcuts
- [LaunchAtLogin](https://github.com/sindresorhus/LaunchAtLogin) - launch at login
- [MediaRemoteAdapter](https://github.com/ejbills/mediaremote-adapter) - media playback control during recording
- [Zip](https://github.com/marmelroy/Zip) - file compression and decompression
- [SelectedTextKit](https://github.com/tisfeng/SelectedTextKit) - selected text access on macOS
- [Swift Atomics](https://github.com/apple/swift-atomics) - low-level atomic operations
