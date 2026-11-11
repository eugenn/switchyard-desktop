# Application experience

The only application is the Tauri client in `desktop/`. It opens on **Routing**.
This document describes the current UI, not the retired macOS application.

- **Routing**: discover account models, choose a strategy, assign targets,
  review/save configuration and start or stop the local Codex route.
- **Roles**: edit the built-in role library, tags, groups and saved routing drafts.
- **Activity**: inspect live counters and available usage information.
- **Requests**: search/filter recent routing records and inspect the original record.
- **Set up Claude**, within Routing: save an Anthropic API key to the system
  credential vault, enter two model IDs and copy a command that launches Claude
  Code against the local server. There is no Claude Code sign-in.

Configuration preview does not start services or rewrite Codex files. Starting
routing checks the bundled runtime and creates a temporary Codex profile only
after services are ready. Stopping preserves externally modified profiles.
Normal app exit stops owned HTTP services; a Claude Code session started with the
copied command loses its route, because the route is served by that server. Forced-quit recovery and richer host integration are
still open work. See [current status](cross-platform.md).
