# wezterm-quota-limit

A WezTerm plugin that shows your Claude API usage quota directly in the terminal status bar.

![Status bar showing 5-hour and 7-day usage](https://img.shields.io/badge/WezTerm-plugin-blue)

## What it shows

```
⚡ 5h 42%  (2h31m)  📅 7d 18%  (4d12h)
```

- **5-hour window** — current utilization percentage and time until reset
- **7-day window** — current utilization percentage and time until reset
- Color-coded: green (< 50%), yellow (50-79%), red (>= 80%)

## Prerequisites

- [WezTerm](https://wezfurlong.org/wezterm/) with plugin support
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated (OAuth credentials at `~/.claude/.credentials.json`)
- `curl` available on PATH

## Installation

Add to your `~/.wezterm.lua`:

```lua
local wezterm = require("wezterm")
local config = wezterm.config_builder()

local quota = wezterm.plugin.require("https://github.com/EdenGibson/wezterm-quota-limit")
quota.apply_to_config(config)

return config
```

To update the plugin, run in WezTerm:

```
wezterm.plugin.update_all()
```

## Configuration

Pass an options table as the second argument to `apply_to_config`:

```lua
quota.apply_to_config(config, {
  poll_interval_secs = 120,  -- how often to fetch usage (default: 60)
  position = "left",         -- "left" or "right" status bar (default: "right")
  icons = {
    bolt = "⚡",              -- prefix icon
    week = "📅",              -- weekly separator icon
  },
})
```

## How it works

The plugin reads your Claude Code OAuth token from `~/.claude/.credentials.json` and polls the Anthropic usage API every 60 seconds (configurable). Results are cached between polls. The status bar updates on every WezTerm `update-status` event, but only makes a network request when the cache expires.

### Token auto-refresh

If the API returns a 429 (rate limited), 401, or 403, the plugin automatically refreshes the OAuth token using the refresh token from your credentials file. Rate limits on this endpoint are per-access-token, so a fresh token gets a clean rate limit window. The new tokens are persisted back to `~/.claude/.credentials.json`.

### Error handling

- **Exponential backoff** on consecutive errors: 2min, 4min, 8min, 16min, capped at 30min. Resets to normal polling on success.
- **Stale data preservation** — if a fetch fails but previous data exists, the last successful result is shown (not an error).
- **Crash protection** — the status bar handler is wrapped in `pcall` so an unexpected error won't break your WezTerm status bar.

## License

MIT
