local wezterm = require("wezterm")

local M = {}

-- Config defaults
local config = {
  poll_interval_secs = 60,
  position = "right", -- "left" or "right"
  icons = {
    bolt = "⚡",
    week = "📅",
  },
}

-- Cached usage data
local cached_data = nil
local last_fetch_time = 0
local consecutive_errors = 0
local last_error = nil
local handler_registered = false
local cached_token = nil

-- Color thresholds (Tokyo Night palette)
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

-- Deep merge: t2 values override t1, recurses into nested tables
local function deep_merge(t1, t2)
  local result = {}
  for k, v in pairs(t1) do
    result[k] = v
  end
  for k, v in pairs(t2) do
    if type(v) == "table" and type(result[k]) == "table" then
      result[k] = deep_merge(result[k], v)
    else
      result[k] = v
    end
  end
  return result
end

-- Credentials file path
local function cred_path()
  local home = os.getenv("USERPROFILE") or os.getenv("HOME") or ""
  return home .. "/.claude/.credentials.json"
end

-- Read credentials file
local function read_credentials()
  local path = cred_path()
  local f = io.open(path, "r")
  if not f then
    f = io.open(path:gsub("/", "\\"), "r")
  end
  if not f then
    return nil, "no credentials file"
  end
  local content = f:read("*a")
  f:close()
  return content, nil
end

-- Read OAuth token and expiry from credentials file
local function get_token()
  local content, err = read_credentials()
  if not content then
    return nil, nil, err
  end

  local token = content:match('"claudeAiOauth"%s*:%s*{[^}]*"accessToken"%s*:%s*"([^"]+)"')
  if not token then
    return nil, nil, "no accessToken in credentials"
  end

  local expires_at = content:match('"expiresAt"%s*:%s*(%d+)')
  return token, tonumber(expires_at), nil
end

-- Read refresh token from credentials file
local function get_refresh_token()
  local content, err = read_credentials()
  if not content then
    return nil, err
  end

  local token = content:match('"claudeAiOauth"%s*:%s*{[^}]*"refreshToken"%s*:%s*"([^"]+)"')
  if not token then
    return nil, "no refreshToken in credentials"
  end

  return token, nil
end

-- Escape a string for use in a gsub replacement (% is special in Lua replacements)
local function gsub_escape(s)
  return s:gsub("%%", "%%%%")
end

-- Refresh the OAuth token and update credentials file.
-- Only called when the token is expired (expiresAt in the past), so Claude Code
-- would also need to refresh before its next request — no conflict.
local function refresh_oauth_token()
  local refresh_token, err = get_refresh_token()
  if not refresh_token then
    return false, err
  end

  local payload = '{"grant_type":"refresh_token","refresh_token":"'
    .. refresh_token
    .. '","client_id":"9d1c250a-e61b-44d9-88ed-5944d1962f5e"}'

  local success, stdout, stderr = wezterm.run_child_process({
    "curl",
    "-s",
    "-m", "10",
    "-w", "\n%{http_code}",
    "-X", "POST",
    "https://console.anthropic.com/v1/oauth/token",
    "-H", "Content-Type: application/json",
    "-d", payload,
  })

  if not success or not stdout or stdout == "" then
    return false, "refresh curl failed"
  end

  local body, http_code = stdout:match("^(.*)\n(%d+)$")
  if tonumber(http_code) ~= 200 then
    return false, "refresh failed (HTTP " .. (http_code or "?") .. ")"
  end

  local ok, data = pcall(wezterm.json_parse, body)
  if not ok or not data or not data.access_token or not data.refresh_token then
    return false, "refresh parse failed"
  end

  -- Read current credentials and replace tokens + expiry
  local content, read_err = read_credentials()
  if not content then
    return false, read_err
  end

  content = content:gsub(
    '("accessToken"%s*:%s*")[^"]+(")',
    "%1" .. gsub_escape(data.access_token) .. "%2"
  )
  content = content:gsub(
    '("refreshToken"%s*:%s*")[^"]+(")',
    "%1" .. gsub_escape(data.refresh_token) .. "%2"
  )
  -- Update expiresAt (seconds from now → milliseconds epoch)
  if data.expires_in then
    local new_expiry = math.floor(os.time() * 1000) + (data.expires_in * 1000)
    content = content:gsub(
      '("expiresAt"%s*:%s*)%d+',
      "%1" .. tostring(new_expiry)
    )
  end

  local path = cred_path()
  local f = io.open(path, "w")
  if not f then
    f = io.open(path:gsub("/", "\\"), "w")
  end
  if not f then
    return false, "cannot write credentials"
  end
  f:write(content)
  f:close()

  wezterm.log_info("claude-usage: OAuth token refreshed successfully")
  return true, nil
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
  -- Back off: 2min, 4min, 8min, 16min, capped at 30min
  local backoff = math.min(120 * (2 ^ (consecutive_errors - 1)), 1800)
  return backoff
end

-- Make an API request to the usage endpoint
local function call_usage_api(token)
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
    return nil, nil, "curl failed"
  end

  local body, http_code = stdout:match("^(.*)\n(%d+)$")
  if not body then
    return stdout, nil, nil
  end

  return body, tonumber(http_code), nil
end

-- Fetch usage data (synchronous curl call cached at the polling interval)
local function fetch_usage()
  local now = os.time()
  local interval = current_interval()
  if (now - last_fetch_time) < interval then
    return cached_data or { error = last_error or "waiting..." }
  end

  -- Re-read token from disk each fetch — Claude Code may have refreshed it
  local token, expires_at, err = get_token()
  if not token then
    last_fetch_time = now
    last_error = err
    return cached_data or { error = err }
  end

  -- If the token changed on disk (Claude Code refreshed it), reset error state
  if cached_token and token ~= cached_token then
    consecutive_errors = 0
    last_error = nil
  end
  cached_token = token

  -- If the token is expired, refresh it before calling the API.
  -- Safe because Claude Code also needs to refresh before its next request,
  -- so whoever refreshes first wins and both get the new tokens from disk.
  local now_ms = math.floor(now * 1000)
  if expires_at and now_ms >= expires_at then
    local refreshed = refresh_oauth_token()
    if refreshed then
      token = get_token()
      if token then
        cached_token = token
      end
    end
  end

  local body, status, curl_err = call_usage_api(token)

  if curl_err then
    last_fetch_time = now
    consecutive_errors = consecutive_errors + 1
    last_error = curl_err
    return cached_data or { error = last_error }
  end

  if status == 429 then
    -- Token isn't expired, just rate limited — try refreshing for a new rate limit window
    local refreshed = refresh_oauth_token()
    if refreshed then
      local new_token = get_token()
      if new_token then
        cached_token = new_token
        local body2, status2 = call_usage_api(new_token)
        if body2 and status2 == 200 then
          local ok2, d2 = pcall(wezterm.json_parse, body2)
          if ok2 and d2 and not d2.error then
            cached_data = d2
            last_fetch_time = now
            consecutive_errors = 0
            last_error = nil
            return d2
          end
        end
      end
    end
    -- Refresh didn't help — back off
    last_fetch_time = now
    consecutive_errors = consecutive_errors + 1
    local wait = current_interval()
    last_error = string.format("rate limited (retry in %dm)", math.ceil(wait / 60))
    return cached_data or { error = last_error }
  end

  if status == 401 or status == 403 then
    -- Auth failed — try refreshing
    local refreshed = refresh_oauth_token()
    if refreshed then
      local new_token = get_token()
      if new_token then
        cached_token = new_token
        local body2, status2 = call_usage_api(new_token)
        if body2 and status2 == 200 then
          local ok2, d2 = pcall(wezterm.json_parse, body2)
          if ok2 and d2 and not d2.error then
            cached_data = d2
            last_fetch_time = now
            consecutive_errors = 0
            last_error = nil
            return d2
          end
        end
      end
    end
    last_fetch_time = now
    consecutive_errors = consecutive_errors + 1
    last_error = "auth failed — re-login to Claude Code"
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
    config = deep_merge(config, opts)
  end

  -- Guard against duplicate handler registration
  if handler_registered then
    return
  end
  handler_registered = true

  wezterm.on("update-status", function(window, pane)
    local ok, err = pcall(function()
      local data = fetch_usage()
      local cells = build_cells(data)

      if config.position == "left" then
        window:set_left_status(wezterm.format(cells))
      else
        window:set_right_status(wezterm.format(cells))
      end
    end)
    if not ok then
      wezterm.log_error("claude-usage: " .. tostring(err))
    end
  end)
end

return M
