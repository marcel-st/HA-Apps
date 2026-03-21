# Changelog

All notable changes to this add-on are documented in this file.

The format is based on Keep a Changelog and versions follow the add-on version in `config.yaml`.

## [1.2.0] - 2026-03-21

### Changed

- Translated all log messages, errors, and notifications from Dutch to English

## [1.1.0] - 2026-03-21

### Added

- Added structured lifecycle logging for tunnel startup, shutdown, health checks, and rebuilds
- Added active tunnel health checks that verify the SSH control session every minute
- Added remote listener validation to detect a stale reverse tunnel on the remote host
- Added a scheduled tunnel rebuild every 12 hours as preventive maintenance
- Added fallback behavior when the remote host lacks listener inspection tools

### Changed

- Reworked the runtime script to manage the reverse tunnel explicitly instead of relying only on a foreground `autossh` process
- Updated repository and add-on documentation for the 1.1.0 release