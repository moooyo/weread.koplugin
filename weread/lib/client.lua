local ltn12 = require("ltn12")
local logger = require("weread.lib.logger")
local socketutil = require("socketutil")
local http = require("socket.http")
local Cookie = require("weread.lib.cookie")
local WeRead = require("weread.lib.protocol")

local ok_json, json = pcall(require, "json")
if not ok_json then
    ok_json, json = pcall(require, "rapidjson")
end

-- Keep socket inactivity short while allowing a bounded, steadily progressing
-- transfer. Large image archives need a larger budget than JSON/chapter text.
local DEFAULT_TIMEOUT_SECONDS = 15
local DEFAULT_TOTAL_TIMEOUT_SECONDS = 60
local DEFAULT_FILE_TOTAL_TIMEOUT_SECONDS = 300
local ok_time, monotonic_time = pcall(require, "ui/time")
local function default_now()
    if ok_time and monotonic_time.now and monotonic_time.to_s then
        return monotonic_time.to_s(monotonic_time.now())
    end
    return os.time()
end
local Client = {}
Client.__index = Client

local function header_value(headers, name)
    if type(headers) ~= "table" or type(name) ~= "string" then return nil end
    if headers[name] ~= nil then return headers[name] end
    local target = name:lower()
    if headers[target] ~= nil then return headers[target] end
    for key, value in pairs(headers) do
        if type(key) == "string" and key:lower() == target then return value end
    end
    return nil
end

local function scalar_header_value(headers, name)
    local value = header_value(headers, name)
    if type(value) == "table" then
        if value[1] == nil then return nil end
        return tostring(value[1])
    end
    return value
end

local function http_error(client, code, text, headers)
    text = text or ""
    local content_type = tostring(header_value(headers, "content-type") or "unknown")
    local parts = {
        "HTTP " .. tostring(code),
        "content_type=" .. content_type,
        "body_bytes=" .. tostring(#text),
    }
    local looks_like_json = content_type:lower():find("json", 1, true)
        or text:match("^%s*{") ~= nil
        or text:match("^%s*%[") ~= nil
    if looks_like_json and #text <= 65536 then
        local ok, data = pcall(function()
            return client:json_decode(text)
        end)
        if ok and type(data) == "table" then
            local err_code = data.errCode or data.errcode or data.code
            local err_message = data.errMsg or data.errmsg or data.message or data.msg
            if err_code ~= nil then
                table.insert(parts, "error_code=" .. tostring(err_code))
            end
            if err_message ~= nil then
                local message = tostring(err_message):gsub("[%c]+", " "):sub(1, 200)
                table.insert(parts, "error_message=" .. message)
            end
        end
    end
    return table.concat(parts, ", ")
end

local function deepcopy(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for key, item in pairs(value) do
        out[key] = deepcopy(item)
    end
    return out
end

local function table_summary(value)
    if type(value) ~= "table" then
        return type(value)
    end
    local count = 0
    for _key in pairs(value) do
        count = count + 1
    end
    return "table(" .. tostring(count) .. ")"
end

local function log_error(err)
    local text = tostring(err):gsub("[%c]+", " ")
    if #text > 500 then
        return text:sub(1, 500) .. "..."
    end
    return text
end

local function log_response(label, context, text)
    context = context or {}
    text = text or ""
    logger.err(
        label,
        "method=", tostring(context.method or "unknown"),
        "url=", tostring(context.url or "unknown"),
        "api=", tostring(context.api_name or "unknown"),
        "status=", tostring(context.code or "unknown"),
        "content_type=", tostring(header_value(context.headers, "content-type") or "unknown"),
        "body_bytes=", tostring(#text),
        "response_body=", text
    )
end

local function merge_req_opts(default_opts, user_opts)
    default_opts = default_opts or {}
    if not user_opts then
        return deepcopy(default_opts)
    end
    local result = deepcopy(default_opts)
    for k, v in pairs(user_opts) do
        if k == "headers" and type(v) == "table" then
            result.headers = result.headers or {}
            for hk, hv in pairs(v) do
                local target = hk:lower()
                for existing_k, _ in pairs(result.headers) do
                    if type(existing_k) == "string" and existing_k:lower() == target then
                        result.headers[existing_k] = nil
                    end
                end
                result.headers[hk] = deepcopy(hv)
            end
        else
            result[k] = deepcopy(v)
        end
    end
    return result
end

local function is_weread_url(url)
    local authority = tostring(url or ""):match("^https?://([^/]+)")
    if not authority then
        return false
    end
    local host = authority:lower():gsub(":%d+$", "")
    return host == "weread.qq.com" or host:sub(-#".weread.qq.com") == ".weread.qq.com"
end

local function absolute_url(base_url, location)
    if type(location) ~= "string" or location == "" then
        return nil
    end
    if location:match("^https?://") then
        return location
    end
    local scheme, host = tostring(base_url or ""):match("^(https?)://([^/]+)")
    if not scheme then
        return location
    end
    if location:sub(1, 1) == "/" then
        return scheme .. "://" .. host .. location
    end
    local prefix = base_url:match("^(https?://.*/)") or (scheme .. "://" .. host .. "/")
    return prefix .. location
end

local function url_origin(url)
    local scheme, authority = tostring(url or ""):match("^(https?)://([^/]+)")
    if not scheme then
        return nil
    end
    return scheme:lower() .. "://" .. authority:lower()
end

local function clear_cross_origin_headers(headers)
    for key in pairs(headers or {}) do
        local name = tostring(key):lower()
        if name == "authorization" or name == "cookie" or name == "origin" then
            headers[key] = nil
        end
    end
end

function Client:new(settings)
    return setmetatable({
        settings = settings,
        request_sequence = 0,
    }, self)
end

-- Scope callbacks to this client instance, typically inside one subprocess.
-- Restore the returned value after the scoped task, including on failure.
-- cancelled() returns a boolean; on_progress(info) receives start/data/complete
-- events; on_diagnostic(info) receives structured failures without changing the
-- string errors expected by existing callers. Per-request options override the
-- scope. now() is an optional seconds clock for deterministic transport tests.
function Client:set_request_context(context)
    local previous = self.request_context
    self.request_context = context
    return previous
end

local function positive_number(value, fallback)
    value = tonumber(value)
    if value and value > 0 and value < math.huge then return value end
    return fallback
end

function Client:_request_state(opts)
    opts = opts or {}
    local context = self.request_context or {}
    local function option(name)
        if opts[name] ~= nil then return opts[name] end
        return context[name]
    end
    local file_request = option("timeout_profile") == "file"
    local default_total = file_request and DEFAULT_FILE_TOTAL_TIMEOUT_SECONDS
        or DEFAULT_TOTAL_TIMEOUT_SECONDS
    local block, total = DEFAULT_TIMEOUT_SECONDS, default_total
    local timeout = option("timeout")
    if type(timeout) == "table" then
        block = positive_number(timeout[1], block)
        total = positive_number(timeout[2], block)
    elseif type(timeout) == "number" then
        block = positive_number(timeout, block)
    end
    total = positive_number(option("total_timeout"), total)
    local now = option("now") or default_now
    local started = now()
    self.request_sequence = (self.request_sequence or 0) + 1
    self.last_request_error = nil
    return {
        id = self.request_sequence,
        now = now, started_at = started, deadline = started + total,
        block_timeout = block, total_timeout = total,
        cancelled = option("cancelled"), on_progress = option("on_progress"),
        on_diagnostic = option("on_diagnostic"),
        bytes = 0, request_bytes = 0, url = opts.url,
        method = opts.method or (opts.body and "POST" or "GET"),
    }
end

function Client:_request_failure(state, kind, message, retryable, code, headers)
    if state.failure then return state.failure end
    local retry_after = scalar_header_value(headers, "retry-after")
    local failure = {
        event = "error", ok = false, request_id = state.id,
        kind = kind, message = tostring(message), retryable = retryable == true,
        url = state.url, method = state.method, status = code,
        bytes = state.bytes, request_bytes = state.request_bytes,
        elapsed = math.max(0, state.now() - state.started_at),
        block_timeout = state.block_timeout, total_timeout = state.total_timeout,
        retry_after = retry_after,
        retry_after_seconds = tonumber(retry_after),
    }
    state.failure = failure
    self.last_request_error = failure
    if type(state.on_diagnostic) == "function" then
        -- Diagnostics must never interrupt transport cleanup or hide its error.
        pcall(state.on_diagnostic, failure)
    end
    return failure
end

function Client:_check_request(state)
    if state.failure then error(state.failure.message, 0) end
    if type(state.cancelled) == "function" then
        local ok, cancelled = pcall(state.cancelled)
        if not ok or cancelled then
            local message = ok and "request cancelled" or tostring(cancelled)
            self:_request_failure(state, "cancelled", message, false)
            error(message, 0)
        end
    end
    if state.now() >= state.deadline then
        local message = "request total timeout"
        self:_request_failure(state, "total_timeout", message, true)
        error(message, 0)
    end
end

function Client:_request_progress(state, event)
    if type(state.on_progress) ~= "function" then return end
    local ok, err = pcall(state.on_progress, {
        event = event, request_id = state.id, url = state.url,
        method = state.method, bytes = state.bytes,
        request_bytes = state.request_bytes,
        elapsed = math.max(0, state.now() - state.started_at),
        block_timeout = state.block_timeout, total_timeout = state.total_timeout,
    })
    if not ok then
        local kind = tostring(err):find("__weread_worker_cancelled__", 1, true)
            and "cancelled" or "callback_error"
        self:_request_failure(state, kind, err, false)
        error(err, 0)
    end
end

local function transport_failure_kind(message)
    local text = tostring(message):lower()
    if text:find("timeout", 1, true) or text == "wantread" or text == "wantwrite" then
        return "transport_timeout"
    end
    return "transport_error"
end

function Client:json_encode(data)
    if not ok_json then
        error("JSON module is not available")
    end
    if json.encode then
        return json.encode(data)
    end
    return json:encode(data)
end

function Client:json_decode(text)
    if not ok_json then
        error("JSON module is not available")
    end
    if json.decode then
        return json.decode(text)
    end
    return json:decode(text)
end

function Client:decode_http_json(text, context)
    local ok, data = pcall(self.json_decode, self, text)
    if not ok then
        log_response("HTTP JSON decode failed:", context, text)
        error(data, 0)
    end

    if type(data) == "table" then
        local err_code = data.errCode or data.errcode
        local failed_succ = data.succ ~= nil
            and data.succ ~= true
            and tonumber(data.succ) ~= 1
        if (err_code ~= nil and tonumber(err_code) ~= 0) or failed_succ then
            log_response("API response reported an error:", context, text)
        end
    end
    return data
end

function Client:request(opts, state)
    opts = opts or {}
    state = state or self:_request_state(opts)
    state.url = opts.url
    state.method = opts.method or (opts.body and "POST" or "GET")
    state.request_bytes = 0
    self:_check_request(state)
    self:_request_progress(state, "start")
    self:_check_request(state)
    local body = opts.body
    local response
    local headers = {
        ["User-Agent"] = WeRead.USER_AGENT,
        ["Accept"] = "application/json, text/plain, */*"
    }
    local is_handle_cookie = not opts.skip_cookie and is_weread_url(opts.url)

    if is_handle_cookie then
        local cookies = self.settings:get("cookies", {})
        local cookie_header = Cookie.to_header(cookies)
        if cookie_header ~= "" then
            headers["Cookie"] = cookie_header
        end
    end

    if body then
        headers["Content-Length"] = tostring(#body)
    end
    local sink_to_use = opts.sink
    if not sink_to_use then
        response = {}
        -- Own the deadline instead of using socketutil's process-global sink
        -- timeout, which may be reset by a different request.
        sink_to_use = function(chunk)
            if chunk then response[#response + 1] = chunk end
            return 1
        end
    end
    local max_bytes = tonumber(opts.max_bytes)
    local sink_ended = false
    local function end_sink(err)
        if sink_ended then return end
        sink_ended = true
        -- Preserve LTN12's terminal notification for caller-owned file sinks,
        -- including when our guard aborts before the source reaches EOF.
        pcall(sink_to_use, nil, err)
    end
    local function checked_sink(chunk, source_error)
        self:_check_request(state)
        if source_error then
            self:_request_failure(state, transport_failure_kind(source_error),
                source_error, true)
            end_sink(source_error)
            return nil, source_error
        end
        if chunk and max_bytes and state.request_bytes + #chunk > max_bytes then
            local message = "download exceeds size limit"
            self:_request_failure(state, "size_limit", message, false)
            end_sink(message)
            return nil, message
        end
        if chunk == nil then sink_ended = true end
        local accepted, err = sink_to_use(chunk, source_error)
        if not accepted then
            self:_request_failure(state, "sink_error", err or "response sink failed", false)
            end_sink(err or "response sink failed")
            return nil, err or "response sink failed"
        end
        if chunk and #chunk > 0 then
            state.bytes = state.bytes + #chunk
            state.request_bytes = state.request_bytes + #chunk
            self:_request_progress(state, "data")
        end
        self:_check_request(state)
        return accepted
    end
    local function guarded_sink(chunk, source_error)
        local ok, accepted, err = pcall(checked_sink, chunk, source_error)
        if not ok then
            self:_request_failure(state, "sink_error", accepted, false)
            end_sink(accepted)
            -- Return through ltn12.pump rather than throwing out of the sink:
            -- LuaSocket's h.try finalizer then closes the underlying socket.
            return nil, tostring(accepted)
        end
        return accepted, err
    end

    local req_opts = merge_req_opts({
        method = body and "POST" or "GET",
        source = body and ltn12.source.string(body) or nil,
        headers = headers,
    }, opts)
    req_opts.sink = guarded_sink
    -- Redirects are handled explicitly by request_follow so credentials can be
    -- rebuilt for every destination instead of being copied across origins.
    req_opts.redirect = false
    local diagnostic_api = req_opts.diagnostic_api
    req_opts.diagnostic_api = nil
    for _, name in ipairs({ "cancelled", "on_progress", "on_diagnostic", "now",
        "timeout", "total_timeout", "timeout_profile", "max_bytes" }) do
        req_opts[name] = nil
    end

    self:_check_request(state)
    local remaining = state.deadline - state.now()
    -- Socket timeouts bound individual blocking operations. The checks above,
    -- in every sink, and after request() enforce the logical request budget.
    -- Blocking DNS cannot be interrupted here; the subprocess watchdog owns it.
    socketutil:set_timeout(math.min(state.block_timeout, remaining), remaining)
    local results = { pcall(http.request, req_opts) }
    socketutil:reset_timeout()
    local checked, check_error = pcall(self._check_request, self, state)
    if not checked then
        end_sink(check_error)
        error(check_error, 0)
    end
    if not results[1] then
        end_sink(results[2])
        self:_request_failure(state, transport_failure_kind(results[2]), results[2], true)
        logger.err(
            "HTTP transport failed:",
            "method=", tostring(req_opts.method),
            "url=", tostring(req_opts.url),
            "api=", tostring(diagnostic_api or "unknown"),
            "error=", tostring(results[2])
        )
        error(results[2], 0)
    end
    local success, raw_code, resp_headers, status = results[2], results[3], results[4], results[5]
    if status == nil and type(raw_code) == "string" then
        status = raw_code
    end
    if not success then
        local message = status or raw_code or "HTTP transport returned no result"
        end_sink(message)
        self:_request_failure(state, transport_failure_kind(message), message, true)
        error(message, 0)
    end

    local code = tonumber(raw_code)
    local length = tonumber(scalar_header_value(resp_headers, "content-length"))
    if code and code >= 200 and code < 300 and code ~= 204
        and req_opts.method ~= "HEAD" and length and length >= 0
        and not header_value(resp_headers, "transfer-encoding")
        and state.request_bytes ~= length then
        local message = "response length mismatch: expected " .. tostring(length)
            .. ", received " .. tostring(state.request_bytes)
        self:_request_failure(state, "short_read", message, true, code, resp_headers)
        error(message, 0)
    end

    if not opts.sink then response = table.concat(response) end
    if is_handle_cookie and opts.persist_response_cookies ~= false then
        local set_cookie = header_value(resp_headers, "set-cookie")
        if set_cookie then
            self.settings:merge_set_cookie(set_cookie)
        end
    end

    if code and code >= 400 then
        self:_request_failure(state, "http_error", http_error(self, code, response, resp_headers),
            code == 408 or code == 425 or code == 429 or code >= 500, code, resp_headers)
        log_response("HTTP response failed:", {
            method = req_opts.method,
            url = req_opts.url,
            api_name = diagnostic_api,
            code = code,
            headers = resp_headers,
        }, type(response) == "string" and response or "")
    elseif not code then
        self:_request_failure(state, "transport_error", status or "HTTP response unavailable", true)
        log_response("HTTP response unavailable:", {
            method = req_opts.method,
            url = req_opts.url,
            api_name = diagnostic_api,
            code = status or raw_code,
            headers = resp_headers,
        }, type(response) == "string" and response or "")
    end

    if not state.failure then
        self:_request_progress(state, "complete")
        self:_check_request(state)
    end

    return response, code, resp_headers or {}, status
end

function Client:request_follow(opts, max_redirects, state)
    local request_opts = deepcopy(opts or {})
    state = state or self:_request_state(request_opts)
    local on_redirect = request_opts.on_redirect
    request_opts.on_redirect = nil
    max_redirects = max_redirects or request_opts.maxredirects or 5
    request_opts.maxredirects = nil
    local url = request_opts.url

    for _redirect_index = 0, max_redirects do
        request_opts.url = url
        local text, code, headers, status = self:request(request_opts, state)
        local is_redirect = code == 301 or code == 302 or code == 303
            or code == 307 or code == 308
        if not is_redirect then
            return text, code, headers, status, url
        end

        local next_url = absolute_url(url, header_value(headers, "location"))
        if not next_url then
            return text, code, headers, status, url
        end
        if on_redirect then
            on_redirect(url, next_url, code)
        end
        if url_origin(url) ~= url_origin(next_url) then
            clear_cross_origin_headers(request_opts.headers)
        end
        if code == 303 or ((code == 301 or code == 302)
            and request_opts.method ~= "GET" and request_opts.method ~= "HEAD") then
            request_opts.method = "GET"
            request_opts.body = nil
            request_opts.source = nil
            if request_opts.headers then
                for key in pairs(request_opts.headers) do
                    if tostring(key):lower() == "content-length" then
                        request_opts.headers[key] = nil
                    end
                end
            end
        end
        url = next_url
    end
    self:_request_failure(state, "redirect_limit", "Too many redirects", false)
    error("Too many redirects", 0)
end

-- Download a response directly to disk. The sink deliberately stays open when
-- LuaSocket signals end-of-response because request_follow may need to reuse it
-- after a redirect. On every redirect the partial response body is discarded.
function Client:download_to_file(url, path, opts)
    opts = opts or {}
    local part_path = path .. ".part"
    local handle
    local bytes = 0
    local state
    local function fail(kind, message, retryable)
        self:_request_failure(state, kind, message, retryable)
        error(message, 0)
    end
    local function close()
        if not handle then return end
        local current = handle
        handle = nil
        local ok, err = current:close()
        if not ok then fail("io_error", err or "could not close download file", false) end
    end
    local function reopen()
        close()
        local open_err
        handle, open_err = io.open(part_path, "wb")
        if not handle then fail("io_error", open_err or "could not create download file", false) end
        bytes = 0
    end
    local function sink(chunk)
        if not chunk then return 1 end
        local ok, err = handle:write(chunk)
        if not ok then return nil, err end
        bytes = bytes + #chunk
        return 1
    end

    local request_opts = merge_req_opts(opts, {
        url = url,
        method = "GET",
        maxredirects = 5,
        timeout_profile = "file",
        sink = sink,
        on_redirect = function(from, to, code)
            reopen()
            if opts.on_redirect then opts.on_redirect(from, to, code) end
        end,
        headers = {
            ["Accept"] = header_value(opts.headers, "Accept") or opts.accept or "*/*",
            ["Referer"] = header_value(opts.headers, "Referer") or opts.referer or "https://weread.qq.com/",
        },
    })
    request_opts.accept = nil
    request_opts.referer = nil
    state = self:_request_state(request_opts)

    local ok, result, saved_bytes, headers = pcall(function()
        self:_check_request(state)
        reopen()
        local text, code, resp_headers = self:request_follow(request_opts, nil, state)
        if not code or code < 200 or code >= 300 then
            fail("http_error", http_error(self, code, text, resp_headers), false)
        end
        if bytes == 0 then fail("empty_body", "download returned an empty body", true) end
        close()
        self:_check_request(state)
        -- POSIX rename replaces the destination atomically. Never delete an
        -- existing successful download before knowing its replacement is ready.
        local renamed, rename_err = os.rename(part_path, path)
        if not renamed then
            -- Some hosts cannot replace an existing file with rename. Preserve
            -- it in a unique backup and restore it if the second rename fails.
            local existing = io.open(path, "rb")
            if existing then
                existing:close()
                local backup = path .. ".previous-" .. tostring(state.id)
                local suffix = 0
                while true do
                    self:_check_request(state)
                    local occupied = io.open(backup, "rb")
                    if not occupied then break end
                    occupied:close()
                    suffix = suffix + 1
                    backup = path .. ".previous-" .. tostring(state.id) .. "-" .. tostring(suffix)
                end
                local moved = os.rename(path, backup)
                if moved then
                    renamed, rename_err = os.rename(part_path, path)
                    if renamed then
                        os.remove(backup)
                    else
                        local restored, restore_err = os.rename(backup, path)
                        if not restored then
                            rename_err = tostring(rename_err) .. "; previous file preserved at "
                                .. backup .. ": " .. tostring(restore_err)
                        end
                    end
                end
            end
        end
        if not renamed then fail("io_error", rename_err or "could not commit downloaded file", false) end
        return path, bytes, resp_headers
    end)
    if handle then pcall(close) end
    if not ok then
        pcall(os.remove, part_path)
        error(result, 0)
    end
    return result, saved_bytes, headers
end

function Client:post_json(url, data, opts)
    opts = opts or {}
    local referer = header_value(opts.headers, "Referer") or opts.referer
    local req_opts = merge_req_opts(opts, {
        url = url,
        method = "POST",
        body = self:json_encode(data),
        headers = {
            ["Content-Type"] = "application/json;charset=UTF-8",
            ["Origin"] = "https://weread.qq.com",
            ["Referer"] = referer or "https://weread.qq.com/",
        }})
    local text, code, resp_headers = self:request(req_opts)
    if code and code >= 200 and code < 300 then
        return self:decode_http_json(text, {
            method = "POST",
            url = url,
            api_name = opts.diagnostic_api,
            code = code,
            headers = resp_headers,
        }), code, resp_headers
    end
    error(http_error(self, code, text, resp_headers))
end

function Client:get_text(url, opts)
    opts = opts or {}
    local accept = header_value(opts.headers, "Accept") or opts.accept
    local referer = header_value(opts.headers, "Referer") or opts.referer
    local req_opts = merge_req_opts(opts, {
        url = url,
        method = "GET",
        headers = {
            ["Accept"] = accept or "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            ["Referer"] = referer or "https://weread.qq.com/",
        }})
    local text, code, resp_headers = self:request(req_opts)
    if code and code >= 200 and code < 300 then
        return text, code, resp_headers
    end
    error(http_error(self, code, text, resp_headers))
end

function Client:get_public_text(url, opts)
    opts = opts or {}
    local req_opts = merge_req_opts(opts, {
        maxredirects = 5,
        headers = {
            ["Accept"] = header_value(opts.headers, "Accept") or opts.accept or "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            ["Referer"] = header_value(opts.headers, "Referer") or opts.referer or "https://mp.weixin.qq.com/",
        }
    })
    local text, code, resp_headers, _status, final_url = self:request_follow(
        merge_req_opts(req_opts, { url = url, method = "GET" })
    )
    if not code or code < 200 or code >= 300 then
        error(http_error(self, code, text, resp_headers))
    end
    return text, {
        code = code,
        content_type = header_value(resp_headers, "content-type"),
        length = #(text or ""),
        url = final_url or url,
    }
end

function Client:get_binary(url, opts)
    opts = opts or {}
    local req_opts = merge_req_opts(opts, {
        maxredirects = 5,
        timeout_profile = "file",
        headers = {
            ["Accept"] = header_value(opts.headers, "Accept") or opts.accept or "*/*",
            ["Referer"] = header_value(opts.headers, "Referer") or opts.referer or "https://weread.qq.com/",
        }
    })
    local text, code, resp_headers = self:request_follow(
        merge_req_opts(req_opts, { url = url, method = "GET" })
    )
    if code and code >= 200 and code < 300 then
        return text, code, resp_headers
    end
    error(http_error(self, code, text, resp_headers))
end

function Client:renew_cookie()
    local result, code, resp_headers = self:post_json("https://weread.qq.com/web/login/renewal", {
        rq = "%2Fweb%2Fbook%2Fread",
        ql = false,
    }, {
        -- Do not persist renewal cookies until the response explicitly confirms
        -- success; failed renewals must leave the current credential set intact.
        persist_response_cookies = false,
    })
    if not WeRead.is_success_response(result) then
        error("Cookie renewal response did not include succ=1")
    end
    local updates = {}
    local set_cookie = header_value(resp_headers, "set-cookie")
    if set_cookie then
        updates.cookies = Cookie.merge_set_cookie(
            self.settings:get("cookies", {}),
            set_cookie
        )
    end
    local wr_ticket = scalar_header_value(resp_headers, "x-wr-ticket")
    if wr_ticket and wr_ticket ~= "" then
        updates.wr_ticket = wr_ticket
    end
    local wr_wrpa = scalar_header_value(resp_headers, "x-wrpa-0")
    if wr_wrpa and wr_wrpa ~= "" then
        updates.wr_wrpa = wr_wrpa
    end
    self.settings:update_auth(updates, { replace_cookies = true })
    return result, code, resp_headers
end

function Client:gateway(api_name, params)
    local payload = merge_req_opts({
        api_name = api_name,
        skill_version = (params and params.skill_version) or WeRead.SKILL_VERSION
    }, params)

    local api_key = self.settings:get("api_key", "")
    if api_key == "" then
        error("WeRead API key is not configured")
    end
    return self:post_json("https://i.weread.qq.com/api/agent/gateway", payload, {
        diagnostic_api = api_name,
        skip_cookie = true,
        headers = {
            ["Authorization"] = "Bearer " .. api_key,
        },
    })
end

function Client:get_shelf()
    logger.info(
        "shelf sync request:",
        "api=/shelf/sync",
        "skill_version=", WeRead.SKILL_VERSION,
        "auth=api_key",
        "cookies=skipped",
        "params=none"
    )
    local ok, result, code, headers = pcall(
        self.gateway,
        self,
        "/shelf/sync",
        {}
    )
    if not ok then
        logger.err(
            "shelf sync failed:",
            "api=/shelf/sync",
            "skill_version=", WeRead.SKILL_VERSION,
            "error=", log_error(result)
        )
        error(result, 0)
    end

    logger.info(
        "shelf sync completed:",
        "api=/shelf/sync",
        "http_status=", tostring(code or "unknown"),
        "response=", table_summary(result),
        "books=", table_summary(type(result) == "table" and result.books or nil),
        "archive=", table_summary(type(result) == "table" and result.archive or nil),
        "albums=", table_summary(type(result) == "table" and result.albums or nil),
        "mp=", table_summary(type(result) == "table" and result.mp or nil)
    )
    return result, code, headers
end

function Client:get_book_info(book_id)
    return self:gateway("/book/info", { bookId = book_id })
end

function Client:get_book_reviews(book_id, review_list_type, count)
    return self:gateway("/review/list", {
        bookId = book_id,
        reviewListType = review_list_type or 1,
        count = count or 20,
    })
end

function Client:get_progress(book_id)
    return self:gateway("/book/getprogress", { bookId = book_id })
end

function Client:get_web_progress(book_id)
    local url = "https://weread.qq.com/web/book/getProgress?bookId="
        .. WeRead.urlencode(book_id)
        .. "&_=" .. tostring(os.time() * 1000)
    local text, code, headers = self:get_text(url, {
        accept = "application/json, text/plain, */*",
        referer = WeRead.reader_url(book_id),
    })
    return self:decode_http_json(text, {
        method = "GET",
        url = url,
        code = code,
        headers = headers,
    })
end

-- Reading statistics detail.
-- mode: "weekly" | "monthly" | "annually" | "overall"
-- base_time: optional Unix timestamp; server normalizes it to the period start
--            (Monday / 1st of month / Jan 1st). Pass 0/nil for the current period.
function Client:get_read_stats(mode, base_time)
    local params = { mode = mode or "monthly" }
    if base_time and tonumber(base_time) and tonumber(base_time) > 0 then
        params.baseTime = tonumber(base_time)
    end
    return self:gateway("/readdata/detail", params)
end

function Client:get_mp_articles(book_id, max_idx, count, wr_ticket)
    local url = string.format(
        "https://weread.qq.com/web/mp/articles?bookId=%s&maxIdx=%d&count=%d",
        WeRead.urlencode(book_id),
        max_idx or 0,
        count or 100
    )

    local custom_headers = {
        ["Accept"] = "application/json, text/plain, */*",
        ["Referer"] = "https://weread.qq.com/",
    }

    if wr_ticket and wr_ticket ~= "" then
        custom_headers["x-wr-ticket"] = wr_ticket
    end

    local wrpa = self.settings:get("wr_wrpa", "")
    if wrpa ~= "" then
        custom_headers["x-wrpa-0"] = wrpa
    end

    local text, code, resp_headers = self:request({
        url = url,
        method = "GET",
        headers = custom_headers,
    })

    if code and code >= 200 and code < 300 then
        local data = self:decode_http_json(text, {
            method = "GET",
            url = url,
            code = code,
            headers = resp_headers,
        })
        if data.errCode and data.errCode ~= 0 then
            return nil, data.errCode
        end
        return data, nil
    end
    error(http_error(self, code, text, resp_headers))
end

function Client:get_mp_content(review_id, opts)
    opts = opts or {}
    local url = "https://weread.qq.com/web/mp/content?reviewId=" .. WeRead.urlencode(review_id)

    local custom_headers = {
        ["Accept"] = "text/html,application/xhtml+xml,*/*",
        ["Referer"] = opts.referer or "https://weread.qq.com/",
    }
    if not opts.skip_mp_auth_headers then
        local wr_ticket = self.settings:get("wr_ticket", "")
        if wr_ticket ~= "" then custom_headers["x-wr-ticket"] = wr_ticket end

        local wrpa = self.settings:get("wr_wrpa", "")
        if wrpa ~= "" then custom_headers["x-wrpa-0"] = wrpa end
    end

    local text, code, resp_headers = self:request({
        url = url,
        method = "GET",
        headers = custom_headers,
        timeout = opts.timeout,
    })

    if code and code >= 200 and code < 300 then
        return text, {
            code = code,
            content_type = header_value(resp_headers, "content-type"),
            length = #(text or ""),
            url = url,
        }
    end
    error(http_error(self, code, text, resp_headers))
end

function Client:report_read(payload, referer)
    return self:post_json("https://weread.qq.com/web/book/read", payload, {
        referer = referer or "https://weread.qq.com/",
    })
end

function Client:get_chapter_underlines(book_id, chapter_uid)
    if not book_id or tostring(book_id) == "" then
        return false, nil, "empty book_id"
    end
    if not chapter_uid then
        return false, nil, "empty chapter_uid"
    end

    local ok, result = pcall(function()
        return self:gateway("/book/underlines", {
            bookId = tostring(book_id),
            chapterUid = chapter_uid,
        })
    end)
    if not ok then
        return false, nil, tostring(result)
    end
    if type(result) ~= "table" then
        return false, nil, "underlines: gateway returned non-table"
    end
    return true, result
end

function Client:build_chapter_review_batches(ranges)
    local BATCH_SIZE = 30
    local batches = {}
    for batch_start = 1, #(ranges or {}), BATCH_SIZE do
        local batch = {}
        for index = batch_start, math.min(batch_start + BATCH_SIZE - 1, #ranges) do
            batch[#batch + 1] = {
                range = ranges[index],
                maxIdx = 0,
                count = 30,
                synckey = 0,
            }
        end
        batches[#batches + 1] = batch
    end
    return batches
end

function Client:get_chapter_reviews_batch(book_id, chapter_uid, batch)
    if not book_id or tostring(book_id) == "" then
        return false, nil, "empty book_id"
    end
    if not chapter_uid then
        return false, nil, "empty chapter_uid"
    end
    if type(batch) ~= "table" or #batch == 0 then
        return true, { reviews = {} }
    end

    local ok, result = pcall(function()
        return self:gateway("/book/readreviews", {
            bookId = tostring(book_id),
            chapterUid = chapter_uid,
            reviews = batch,
        })
    end)
    if not ok then
        return false, nil, tostring(result)
    end
    if type(result) ~= "table" or type(result.reviews) ~= "table" then
        return false, nil, "readreviews: gateway returned invalid data"
    end
    return true, result
end

function Client:get_chapter_reviews(book_id, chapter_uid, ranges)
    if type(ranges) ~= "table" or #ranges == 0 then
        return true, { reviews = {} }
    end

    local all_reviews = {}
    local batches = self:build_chapter_review_batches(ranges)
    local socket_ok, socket = pcall(require, "socket")

    for batch_index, batch in ipairs(batches) do
        local ok, result = self:get_chapter_reviews_batch(book_id, chapter_uid, batch)
        if ok and type(result) == "table" and type(result.reviews) == "table" then
            for _, review in ipairs(result.reviews) do
                all_reviews[#all_reviews + 1] = review
            end
        end

        if batch_index < #batches and socket_ok and socket.sleep then
            socket.sleep(0.3)
        end
    end

    return true, { reviews = all_reviews }
end

function Client:get_review_comments(review_id, count, opts)
    opts = opts or {}
    if type(review_id) ~= "string" or review_id == "" then
        return false, nil, "empty review_id"
    end

    local comments_count = count or 20
    local url = "https://weread.qq.com/web/review/single"
        .. "?reviewId=" .. WeRead.urlencode(review_id)
        .. "&commentsCount=" .. tostring(comments_count)
        .. "&commentsDirection=" .. tostring(opts.comments_direction or 0)
        .. "&likesCount=" .. tostring(opts.likes_count or 0)
        .. "&synckey=" .. tostring(opts.synckey or 0)

    local ok, text, code, headers = pcall(function()
        return self:get_text(url, {
            accept = "application/json, text/plain, */*",
            referer = opts.referer or "https://weread.qq.com/",
            timeout = opts.timeout,
        })
    end)
    if not ok then
        return false, nil, tostring(text)
    end
    if not text or text == "" then
        return false, nil, "empty response"
    end

    local decode_ok, parsed = pcall(function()
        return self:decode_http_json(text, {
            method = "GET",
            url = url,
            code = code,
            headers = headers,
        })
    end)
    if not decode_ok or type(parsed) ~= "table" then
        return false, text, "invalid JSON"
    end
    return true, parsed, nil
end
return Client
