# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]


## [2.3.2] - 2026-01-16

### Fixed
- Update packaging process to automatically generate config.json

## [2.3.1] - 2026-01-16

### Fixed
- Removed outdated space placeholder
- The input box lacked the DEL key function

## [2.3.0] - 2026-01-14

### Changed
- UI adjustments
- Several bug fixes

## [2.2.0] - 2026-01-13

### Added
- Window dragging functionality for input window

### Changed
- Default translation mode changed to manual, better suited for LLM characteristics
- Extensive UI adjustments for more natural operation

### Fixed
- Fixed issue where LOL utility functions were not included in the package
- Various minor fixes

## [2.1.0] - 2026-01-12

### Added
- Custom target language selection feature (ALT L shortcut)
- Support for arbitrary language names with automatic LLM recognition
- Persistent configuration file saving for target language

## [2.0.0] - 2026-01-10

### Added
- LLM API integration for higher translation quality
- Support for all OpenAI-compatible API services
- Debounce mechanism to avoid frequent API calls
- Fully configuration-driven - adding new services requires no code changes

### Removed
- WebView2 dependency
- All web-based translation related code
- Traditional translation services (web and API)
- Voice-related features (better AI alternatives available now)

---

**Note**: This is an LLM-powered fork of the original [Real-time Translation Typing](https://github.com/sxzxs/Real-time-translation-typing) project.
