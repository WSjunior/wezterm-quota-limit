local wezterm = require("wezterm")

local M = {}

-- Config defaults
local config = {
  poll_interval_secs = 60,
  position = "right", -- "left" or "right"
  icons = {
    bolt = "⚡",
    clock = "⏱",
    week = "📅",
  },
}

-- Cached usage data
local cached_data = nil
local last_fetch_time = 0
local consecutive_errors = 0
local last_error = nil

-- Color thresholds
local function usage_color(pct)
  if pct >= 80 then
    return { Foreground = { Color = "#f7768e" } } -- red
  elseif pct >= 50 then
    return { Foreground = { Color = "#e0af68" } } -- yellow
  else
    return { Foreground = { Color = "#9ece6a" } } -- green
  end
end

local function dim()
  return { Foreground = { Color = "#565f89" } }
end

local function bright()
  return { Foreground = { Color = "#c0caf5" } }
end

-- Read OAuth token from credentials file
local function get_token()
  local home = os.getenv("USERPROFILE") or os.getenv("HOME") or ""
  local cred_path = home .. "/.claude/.credentials.json"

  local f = io.open(cred_path, "r")
  if not f then
    -- Try Windows-style path
    cred_path = home .. "\\.claude\\.credentials.json"
    f = io.open(cred_path, "r")
  end
  if not f then
    return nil, "no credentials file"
  end

  local content = f:read("*a")
  f:close()

  -- Extract accessToken from claudeAiOauth
  local token = content:match('"claudeAiOauth"%s*:%s*{[^}]*"accessToken"%s*:%s*"([^"]+)"')
  if not token then
    return nil, "no accessToken in credentials"
  end

  return token, nil
end

-- Format time remaining until reset
local function time_until(reset_str)
  if not reset_str then
    return "?"
  end

  -- Parse ISO 8601: 2026-03-08T04:59:59.000000+00:00
  local year, month, day, hour, min, sec =
    reset_str:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not year then
    return "?"
  end

  local reset_time = os.time({
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = tonumber(hour),
    min = tonumber(min),
    sec = tonumber(sec),
  })

  -- reset_str is UTC, os.time gives local — adjust
  local now_local = os.time()
  local now_utc = os.time(os.date("!*t", now_local))
  local diff = reset_time - now_utc

  if diff <= 0 then
    return "now"
  elseif diff < 3600 then
    return string.format("%dm", math.floor(diff / 60))
  elseif diff < 86400 then
    return string.format("%dh%dm", math.floor(diff / 3600), math.floor((diff % 3600) / 60))
  else
    return string.format("%dd%dh", math.floor(diff / 86400), math.floor((diff % 86400) / 3600))
  end
end

-- Calculate how long to wait before next fetch (exponential backoff on errors)
local function current_interval()
  if consecutive_errors == 0 then
    return config.poll_interval_secs
  end
  -- Back off: 2min, 4min, 8min, capped at 10min
  local backoff = math.min(120 * (2 ^ (consecutive_errors - 1)), 600)
  return backoff
end

-- Fetch usage data (synchronous curl call cached at the polling interval)
local function fetch_usage()
  local now = os.time()
  local interval = current_interval()
  if (now - last_fetch_time) < interval then
    return cached_data or { error = last_error or "waiting..." }
  end

  local token, err = get_token()
  if not token then
    last_fetch_time = now
    last_error = err
    return cached_data or { error = err }
  end

  local success, stdout, stderr = wezterm.run_child_process({
    "curl",
    "-s",
    "-m", "5",
    "-w", "\n%{http_code}",
    "https://api.anthropic.com/api/oauth/usage",
    "-H", "Authorization: Bearer " .. token,
    "-H", "anthropic-beta: oauth-2025-04-20",
    "-H", "Content-Type: application/json",
  })

  if not success or not stdout or stdout == "" then
    last_fetch_time = now
    consecutive_errors = consecutive_errors + 1
    last_error = "curl failed"
    return cached_data or { error = last_error }
  end

  -- Split response body from HTTP status code appended by -w
  local body, http_code = stdout:match("^(.*)\n(%d+)$")
  if not body then
    body = stdout
    http_code = nil
  end

  local status = tonumber(http_code)

  if status == 429 then
    last_fetch_time = now
    consecutive_errors = consecutive_errors + 1
    local wait = current_interval()
    last_error = string.format("rate limited (retry in %dm)", math.ceil(wait / 60))
    return cached_data or { error = last_error }
  end

  if status == 401 or status == 403 then
    last_fetch_time = now
    consecutive_errors = consecutive_errors + 1
    last_error = "token expired — re-auth Claude Code"
    return cached_data or { error = last_error }
  end

  local ok, data = pcall(wezterm.json_parse, body)
  if not ok or not data then
    last_fetch_time = now
    consecutive_errors = consecutive_errors + 1
    last_error = "parse failed"
    return cached_data or { error = last_error }
  end

  if data.error then
    last_fetch_time = now
    consecutive_errors = consecutive_errors + 1
    last_error = data.error.message or "api error"
    return cached_data or { error = last_error }
  end

  -- Success — reset error state
  cached_data = data
  last_fetch_time = now
  consecutive_errors = 0
  last_error = nil
  return data
end

-- Build status bar cells
local function build_cells(data)
  local cells = {}

  if data.error then
    table.insert(cells, dim())
    table.insert(cells, { Text = " " .. config.icons.bolt .. " Claude: " })
    table.insert(cells, { Foreground = { Color = "#f7768e" } })
    table.insert(cells, { Text = tostring(data.error) .. " " })
    return cells
  end

  -- 5-hour window
  local five_pct = data.five_hour and data.five_hour.utilization or 0
  local five_reset = data.five_hour and data.five_hour.resets_at

  -- 7-day window
  local seven_pct = data.seven_day and data.seven_day.utilization or 0
  local seven_reset = data.seven_day and data.seven_day.resets_at

  -- Icon
  table.insert(cells, dim())
  table.insert(cells, { Text = " " .. config.icons.bolt .. " " })

  -- 5h usage
  table.insert(cells, bright())
  table.insert(cells, { Text = "5h " })
  table.insert(cells, usage_color(five_pct))
  table.insert(cells, { Text = string.format("%.0f%%", five_pct) })
  table.insert(cells, dim())
  table.insert(cells, { Text = " (" .. time_until(five_reset) .. ")" })

  -- Separator
  table.insert(cells, dim())
  table.insert(cells, { Text = "  " .. config.icons.week .. " " })

  -- 7d usage
  table.insert(cells, bright())
  table.insert(cells, { Text = "7d " })
  table.insert(cells, usage_color(seven_pct))
  table.insert(cells, { Text = string.format("%.0f%%", seven_pct) })
  table.insert(cells, dim())
  table.insert(cells, { Text = " (" .. time_until(seven_reset) .. ") " })

  return cells
end

function M.apply_to_config(c, opts)
  if opts then
    for k, v in pairs(opts) do
      config[k] = v
    end
  end

  wezterm.on("update-status", function(window, pane)
    local data = fetch_usage()
    local cells = build_cells(data)

    if config.position == "left" then
      window:set_left_status(wezterm.format(cells))
    else
      window:set_right_status(wezterm.format(cells))
    end
  end)
end

return M
