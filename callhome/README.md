# SSH Call Home

Creates a reverse SSH tunnel to an external server, enabling remote access to Home Assistant when the instance is behind NAT or a firewall.

## Highlights

- Automatic reconnects using `autossh`
- Active health checks every minute
- Automatic rebuild when the SSH session or remote listener becomes stale
- Scheduled tunnel rebuild every 12 hours

## Documentation

- Full documentation: [DOCS.md](DOCS.md)
- Changelog and release notes: [CHANGELOG.md](CHANGELOG.md)

## Current release

Version `1.1.0` adds logging, active health verification, automatic reconnection recovery, and scheduled maintenance rebuilds.
