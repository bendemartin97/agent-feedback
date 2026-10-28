# Changelog

All notable changes to agent-feedback. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- App icon (speech bubble) in Finder and dialogs; the menu bar shows it as a template icon (adapts to light and dark) instead of 📸.

### Removed

- The menu bar screenshot in the README.

## [0.4.0] – 2026-10-28

### Added

- Delivery into an open Codex session with `codex queue`: no model call and no Claude subscription needed; ended Codex sessions still get a background fork.
- Settings window (⌘,): shortcuts, models and CLI paths in one place; replaces the “Change Shortcut” submenu.
- Configurable models in `config.json`: `models.transport` (delivery into a running Claude chat, default `haiku`), `models.claude` and `models.codex` (background runs), plus `efforts` per run type. The settings window lists the current Claude models and the Codex models with their effort levels.

## [0.3.0] – 2026-10-28

### Added

- Codex support: `agent-feedback setup --codex` (or `./install.sh --codex`) links the skill to `~/.agents/skills/feedback` and adds the hooks to `~/.codex/hooks.json`. Codex sessions show up in the picker as “(Codex)”; items for them are worked on by a background fork (`codex exec fork`, sandbox `workspace-write` plus the feedback folder).
- Items record their agent (`agent: claude|codex`) in the frontmatter; older items count as Claude Code.
- README screenshot of the menu bar menu; editor and inbox screenshots show the new toolbar.

### Changed

- The skill names AGENTS.md next to CLAUDE.md as project rules.
- The Homebrew formula lives only in [bendemartin97/homebrew-tap](https://github.com/bendemartin97/homebrew-tap).

## [0.2.0] – 2026-10-28

### Added

- Toolbar above the image with SF Symbols: select, arrow, line, box, ellipse, pen, marker, **pixelate**, number, text; color dots; undo, redo, delete, zoom.
- Image actions: copy (⌘C), save as PNG (⇧⌘S), pin in a floating window, drag into other apps. Each closes the editor without filing an item.
- Text recognition (Vision, German and English): copy the text of the current image from the toolbar, or capture an area straight to the clipboard with **⌃⌥T**.
- Full-screen capture of the screen under the pointer with **⌃⌥⇧S**, also in the editor's “+ Image” menu.
- Each shortcut can be changed separately (menu “Change Shortcut”).
- Homebrew: `brew install bendemartin97/tap/agent-feedback`, `brew services start agent-feedback`.
- `agent-feedback setup [--hooks]` / `agent-feedback unlink` to link hooks and skill; `install.sh` and `uninstall.sh` use it.

### Changed

- Arrows have a filled head that shrinks on short arrows; the selection frame includes the head.
- Arrows are hit along the shaft instead of their bounding box.
- A click without dragging no longer leaves an empty arrow or box behind.
- The sidebar only holds images, session, note and the save buttons.

### Fixed

- Messages to a running session waited for manual confirmation when that session ran with `--dangerously-skip-permissions` or another permission mode. The sender now uses the target session's mode.
- Shortcuts with ⇧ were shown with the shifted character (⇧⌘§ instead of ⇧⌘3).
- `build.sh` failed with “Bootstrap failed: 5” when it restarted the launch agent too early.

## [0.1.0] – 2026-10-27

First version.

- Menu bar app: capture an area or window (⌃⌥S), from the clipboard, a file, drag and drop, or text only.
- Editor with arrow, box, pen, marker, numbers and text; select, move, delete, undo/redo, zoom; several images per item, each with its own context (app, Chrome URL and tab, window size, appearance).
- Pick a running Claude Code session; the item lands in its chat (`SendMessage`), otherwise a background fork works on it.
- Inbox over all feedback folders with status, questions, answers, accept and rework.
- Hooks for session registration and open-item hints; skill `feedback` for the agent side.
- Install and uninstall scripts, tests for hooks and model.

[Unreleased]: https://github.com/bendemartin97/agent-feedback/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/bendemartin97/agent-feedback/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/bendemartin97/agent-feedback/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/bendemartin97/agent-feedback/compare/f0cf96b...v0.2.0
[0.1.0]: https://github.com/bendemartin97/agent-feedback/commit/f0cf96b
