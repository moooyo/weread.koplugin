local M = {}

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do result[key] = copy(item, seen) end
    return result
end

-- Freeze small job configuration once, then create an independent settings
-- overlay and client for each direct child. Authentication mutations remain
-- local to that child, including when a transport test runs tasks in-process.
function M.job_factory(settings, client)
    local frozen, present = {}, {}
    for _, key in ipairs({ "cache", "account", "cookies", "api_key", "wr_ticket", "wr_wrpa", "download_dir" }) do
        frozen[key], present[key] = copy(settings:get(key)), true
    end
    local paths = {}
    for _, key in ipairs({ "cache_dir", "data_dir", "default_cache_dir", "settings_file" }) do
        paths[key] = settings[key]
    end
    return function()
        local values, known = copy(frozen), copy(present)
        local view = setmetatable(copy(paths), { __index = settings })
        function view:get(key, default)
            if not known[key] then
                values[key], known[key] = copy(settings:get(key, default)), true
            end
            if values[key] == nil then return default end
            return values[key]
        end
        function view:set(key, value) values[key], known[key] = value, true end
        function view:delete(key) values[key], known[key] = nil, true end
        function view:flush() end
        local private_client = {}
        for key, value in pairs(client) do private_client[key] = value end
        setmetatable(private_client, getmetatable(client))
        private_client.settings = view
        private_client.request_sequence = 0
        private_client.request_context, private_client.last_request_error = nil, nil
        return view, private_client
    end
end

local function auth_fingerprint(settings)
    if not settings or type(settings.get) ~= "function" then return "" end
    local cookies = settings:get("cookies", {}) or {}
    local keys = {}
    for key in pairs(cookies) do keys[#keys + 1] = tostring(key) end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do
        parts[#parts + 1] = key .. "=" .. tostring(cookies[key])
    end
    parts[#parts + 1] = "ticket=" .. tostring(settings:get("wr_ticket", ""))
    parts[#parts + 1] = "wrpa=" .. tostring(settings:get("wr_wrpa", ""))
    return table.concat(parts, ";")
end

function M.capture(settings)
    local changed = false
    local original_flush = settings.flush
    local silent_flush = function() end
    settings.flush = silent_flush
    local update_auth = settings.update_auth
    local capture_auth
    if type(update_auth) == "function" then
        capture_auth = function(object, credentials, options)
            changed = true
            options = options or {}
            options.flush = false
            return update_auth(object, credentials, options)
        end
        settings.update_auth = capture_auth
    end
    local function result()
        if not changed or type(settings.get) ~= "function" then return nil end
        return {
            cookies = settings:get("cookies", {}),
            wr_ticket = settings:get("wr_ticket", ""),
            wr_wrpa = settings:get("wr_wrpa", ""),
        }
    end
    local restored = false
    local function restore()
        if restored then return end
        restored = true
        if settings.flush == silent_flush then settings.flush = original_flush end
        if capture_auth and settings.update_auth == capture_auth then settings.update_auth = update_auth end
    end
    return result, restore
end

function M.fingerprint(settings)
    return auth_fingerprint(settings)
end

function M.merge(settings, expected_fingerprint, auth)
    if type(auth) ~= "table" then return false end
    if not settings or type(settings.update_auth) ~= "function" then return false end
    if auth_fingerprint(settings) ~= expected_fingerprint then return false end
    settings:update_auth(auth, { replace_cookies = true })
    return true
end

return M
