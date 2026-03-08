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

-- Fetch usage data (synchronous curl call cached at the polling interval)
local function fetch_usage()
  local now = os.time()
  if cached_data and (now - last_fetch_time) < config.poll_interval_secs then
    return cached_data
  end

  local token, err = get_token()
  if not token then
    return { error = err }
  end

  local success, stdout, stderr = wezterm.run_child_process({
    "curl",
    "-s",
    "-m", "5",
    "https://api.anthropic.com/api/oauth/usage",
    "-H", "Authorization: Bearer " .. token,
    "-H", "anthropic-beta: oauth-2025-04-20",
    "-H", "Content-Type: application/json",
  })

  if not success or not stdout or stdout == "" then
    return cached_data or { error = "curl failed" }
  end

  local ok, data = pcall(wezterm.json_parse, stdout)
  if not ok or not data then
    return cached_data or { error = "parse failed" }
  end

  if data.error then
    return cached_data or { error = data.error.message or "api error" }
  end

  cached_data = data
  last_fetch_time = now
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
