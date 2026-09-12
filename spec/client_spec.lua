package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local timeout_calls = {}
local reset_count = 0
local requests = {}
local responses = {}
local logs = {}
local fake_time = 0

package.preload["ui/time"] = function()
    return {
        now = function() return fake_time end,
        to_s = function(value) return value end,
    }
end

package.preload["ltn12"] = function()
    return {
        source = {
            string = function(value)
                return function() return value end
            end,
        },
    }
end
package.preload["logger"] = function()
    local function capture(level, ...)
        local parts = { level }
        for i = 1, select("#", ...) do
            parts[#parts + 1] = tostring(select(i, ...))
        end
        logs[#logs + 1] = table.concat(parts, " ")
    end
    return {
        info = function(...) capture("info", ...) end,
        err = function(...) capture("error", ...) end,
    }
end
package.preload["socketutil"] = function()
    return {
        set_timeout = function(_self, block, total)
            timeout_calls[#timeout_calls + 1] = { block, total }
        end,
        reset_timeout = function()
            reset_count = reset_count + 1
        end,
        table_sink = function(target)
            return function(chunk)
                if chunk then target[#target + 1] = chunk end
                return 1
            end
        end,
    }
end
package.preload["socket.http"] = function()
    return {
        request = function(options)
            requests[#requests + 1] = options
            local response = table.remove(responses, 1)
            if response.raise then error(response.raise) end
            if response.run then return response.run(options) end
            if options.sink then
                local accepted, err = options.sink(response.body or "")
                if not accepted then return nil, err end
                accepted, err = options.sink(nil)
                if not accepted then return nil, err end
            end
            return 1, response.code, response.headers or {}, response.status
        end,
    }
end
package.preload["weread.lib.protocol"] = function()
    return {
        USER_AGENT = "WeRead client spec",
        SKILL_VERSION = "test-skill",
        urlencode = function(value)
            return tostring(value):gsub("([^%w%-_%.~])", function(ch)
                return string.format("%%%02X", ch:byte())
            end)
        end,
    }
end

local Client = require("weread.lib.client")
local merged_cookies = {}
local settings = {
    get = function(_self, key, default)
        if key == "cookies" then
            return { wr_skey = "XXX-cookie-value" }
        end
        return default
    end,
    merge_set_cookie = function(_self, value)
        merged_cookies[#merged_cookies + 1] = value
    end,
}
local client = Client:new(settings)

responses[#responses + 1] = {
    body = "ok",
    code = 200,
    headers = { ["Set-Cookie"] = "wr_ticket=new-ticket; Path=/" },
}
local body, code = client:request({
    url = "https://weread.qq.com/web/test",
    timeout = { 3, 7 },
})
expect(body == "ok" and code == 200, "basic request result was wrong")
expect(requests[1].headers.Cookie == "wr_skey=XXX-cookie-value",
    "WeRead cookie was not attached")
expect(timeout_calls[1][1] == 3 and timeout_calls[1][2] == 7,
    "request timeout was not applied")
expect(reset_count == 1, "timeout was not reset after successful request")
expect(merged_cookies[1] == "wr_ticket=new-ticket; Path=/",
    "response cookies were not persisted")

responses[#responses + 1] = { body = "public", code = 200 }
client:request({ url = "https://example.com/public" })
expect(requests[2].headers.Cookie == nil,
    "WeRead cookie leaked to a non-WeRead host")

responses[#responses + 1] = { raise = "transport failed" }
local ok, err = pcall(function()
    client:request({ url = "https://weread.qq.com/web/fail" })
end)
expect(not ok and tostring(err):find("transport failed", 1, true),
    "transport error was not propagated")
expect(reset_count == 3, "timeout was not reset after transport error")

responses[#responses + 1] = {
    body = "",
    code = 303,
    headers = { location = "https://cdn.example.net/book" },
}
responses[#responses + 1] = { body = "book", code = 200 }
local redirected, redirected_code, _, _, final_url = client:request_follow({
    url = "https://weread.qq.com/web/export",
    method = "POST",
    body = "{}",
    headers = {
        Authorization = "Bearer secret",
        Cookie = "manual=secret",
        Origin = "https://weread.qq.com",
        ["Content-Length"] = "2",
    },
})
expect(redirected == "book" and redirected_code == 200,
    "redirected response was not returned")
expect(final_url == "https://cdn.example.net/book",
    "final redirect URL was wrong")
local redirected_request = requests[#requests]
expect(redirected_request.method == "GET" and redirected_request.body == nil,
    "303 redirect did not switch POST to GET")
for key in pairs(redirected_request.headers) do
    local lower = tostring(key):lower()
    expect(lower ~= "authorization" and lower ~= "cookie"
        and lower ~= "origin" and lower ~= "content-length",
        "sensitive/entity header survived a cross-origin 303: " .. lower)
end

responses[#responses + 1] = {
    body = "",
    code = 302,
    headers = { location = "/again" },
}
responses[#responses + 1] = {
    body = "",
    code = 302,
    headers = { location = "/again" },
}
ok, err = pcall(function()
    client:request_follow({ url = "https://weread.qq.com/start" }, 1)
end)
expect(not ok and tostring(err):find("Too many redirects", 1, true),
    "redirect limit was not enforced")

logs = {}
responses[#responses + 1] = {
    body = "{\"errcode\":-202,\"errmsg\":\"raw response\"}",
    code = 499,
    headers = { ["content-type"] = "application/json" },
}
ok, err = pcall(function()
    client:get_text("https://weread.qq.com/web/failing-api")
end)
expect(not ok and tostring(err):find("HTTP 499", 1, true),
    "HTTP error details were not preserved")
local raw_response_log = table.concat(logs, "\n")
expect(raw_response_log:find(
    'response_body= {"errcode":-202,"errmsg":"raw response"}',
    1,
    true
), "HTTP failure log omitted the raw response body")

logs = {}
local gateway_settings = {
    get = function(_self, key, default)
        if key == "api_key" then return "private-api-key" end
        return default
    end,
    merge_set_cookie = function() end,
}
local gateway_client = Client:new(gateway_settings)
gateway_client.json_encode = function() return "{}" end
gateway_client.json_decode = function()
    return { errcode = -202, errmsg = "-202" }
end
responses[#responses + 1] = {
    body = '{"errcode":-202,"errmsg":"-202"}',
    code = 499,
    headers = { ["content-type"] = "application/json" },
}
ok = pcall(function()
    gateway_client:gateway("/shelf/sync", {})
end)
expect(not ok, "gateway HTTP failure was not propagated")
local gateway_failure_log = table.concat(logs, "\n")
expect(gateway_failure_log:find("api= /shelf/sync", 1, true),
    "gateway failure log omitted the logical API name")
expect(requests[#requests].diagnostic_api == nil,
    "diagnostic API metadata leaked into the HTTP request options")

logs = {}
client.json_decode = function(_self, _text)
    return { errcode = -300, errmsg = "application failure" }
end
local application_result = client:decode_http_json(
    '{"errcode":-300,"errmsg":"application failure"}',
    {
        method = "POST",
        url = "https://i.weread.qq.com/api/agent/gateway",
        code = 200,
        headers = { ["content-type"] = "application/json" },
    }
)
expect(application_result.errcode == -300,
    "application error response was not returned to the caller")
local application_error_log = table.concat(logs, "\n")
expect(application_error_log:find(
    'response_body= {"errcode":-300,"errmsg":"application failure"}',
    1,
    true
), "application failure log omitted the raw response body")

logs = {}
client.json_decode = function()
    error("invalid JSON")
end
ok, err = pcall(function()
    client:decode_http_json("<not-json>", {
        method = "GET",
        url = "https://weread.qq.com/web/invalid-json",
        code = 200,
    })
end)
expect(not ok and tostring(err):find("invalid JSON", 1, true),
    "JSON decode failure was not preserved")
local decode_failure_log = table.concat(logs, "\n")
expect(decode_failure_log:find("response_body= <not-json>", 1, true),
    "JSON decode failure log omitted the raw response body")

local shelf_client = Client:new(settings)
shelf_client.gateway = function(_self, api_name, params)
    expect(api_name == "/shelf/sync", "shelf helper used the wrong endpoint")
    expect(type(params) == "table" and next(params) == nil,
        "shelf helper unexpectedly sent parameters")
    return {
        books = { { bookId = "private-book-id", title = "Private title" } },
        archive = {},
        albums = {},
        mp = {},
    }, 200, {}
end
local shelf = shelf_client:get_shelf()
expect(#shelf.books == 1, "shelf helper did not return the response")
local success_log = table.concat(logs, "\n")
expect(success_log:find("api=/shelf/sync", 1, true),
    "shelf diagnostics omitted the endpoint")
expect(success_log:find("skill_version= test-skill", 1, true),
    "shelf diagnostics omitted the skill version")
expect(success_log:find("books= table(1)", 1, true),
    "shelf diagnostics omitted the response shape")
expect(not success_log:find("private-book-id", 1, true)
    and not success_log:find("Private title", 1, true),
    "shelf diagnostics leaked response contents")

logs = {}
shelf_client.gateway = function()
    error("HTTP 499, error_code=-202, error_message=-202")
end
ok, err = pcall(function()
    shelf_client:get_shelf()
end)
expect(not ok and tostring(err):find("error_code=-202", 1, true),
    "shelf helper did not preserve the gateway error")
local failure_log = table.concat(logs, "\n")
expect(failure_log:find("shelf sync failed", 1, true),
    "shelf failure diagnostics were not written")

local review_client = Client:new(settings)
local ok_review, data_review, err_review
ok_review, _, err_review = review_client:get_review_comments("")
expect(not ok_review and err_review == "empty review_id",
    "review comments rejected an empty review_id")

responses[#responses + 1] = {
    body = '{"reviewId":"r1","comments":[{"content":"hi"}],"commentsCount":1}',
    code = 200,
    headers = { ["content-type"] = "application/json" },
}
review_client.json_decode = function(_self, text)
    return { reviewId = "r1", comments = { { content = "hi" } }, commentsCount = 1, _raw = text }
end
local review_request_index = #requests + 1
ok_review, data_review, err_review = review_client:get_review_comments("r1", 60)
expect(ok_review and type(data_review) == "table"
    and data_review.commentsCount == 1 and err_review == nil,
    "review comments did not return parsed data")
local review_request = requests[review_request_index]
local review_url = review_request and review_request.url or ""
expect(review_url:find("/web/review/single?", 1, true)
    and review_url:find("reviewId=r1", 1, true)
    and review_url:find("commentsCount=60", 1, true)
    and review_url:find("commentsDirection=0", 1, true)
    and review_url:find("likesCount=0", 1, true)
    and review_url:find("synckey=0", 1, true),
    "review comments built the wrong URL: " .. tostring(review_url))

responses[#responses + 1] = { body = "not-json", code = 200 }
review_client.json_decode = function()
    error("invalid JSON")
end
ok_review, data_review, err_review = review_client:get_review_comments("r2")
expect(not ok_review and data_review == "not-json" and err_review == "invalid JSON",
    "review comments did not surface JSON decode failures")

responses[#responses + 1] = { body = "", code = 200 }
ok_review, _, err_review = review_client:get_review_comments("r3")
expect(not ok_review and err_review == "empty response",
    "review comments did not reject an empty body")

local download_path = os.tmpname()
os.remove(download_path)
responses[#responses + 1] = {
    body = "redirect-body-must-be-discarded",
    code = 302,
    headers = { location = "https://cdn.example.net/asset" },
}
responses[#responses + 1] = { body = "streamed-asset", code = 200 }
local saved_path, saved_bytes = client:download_to_file(
    "https://weread.qq.com/resource", download_path, { max_bytes = 1024 })
local saved_file = assert(io.open(saved_path, "rb"))
local saved_body = saved_file:read("*a")
saved_file:close()
expect(saved_body == "streamed-asset" and saved_bytes == #saved_body,
    "file download retained a redirect body or returned the wrong size")
os.remove(download_path)

responses[#responses + 1] = { body = "too-large", code = 200 }
ok = pcall(function()
    client:download_to_file(
        "https://weread.qq.com/large", download_path, { max_bytes = 2 })
end)
expect(not ok and io.open(download_path .. ".part", "rb") == nil,
    "oversized file download did not remove its partial output")

local function file_body(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local value = file:read("*a")
    file:close()
    return value
end

local function queue_run(callback)
    responses[#responses + 1] = { run = callback }
end

responses[#responses + 1] = { body = "api", code = 200 }
client:request({ url = "https://example.com/default-budget" })
expect(timeout_calls[#timeout_calls][1] == 15 and timeout_calls[#timeout_calls][2] == 60,
    "ordinary requests do not have separate finite inactivity and total budgets")
responses[#responses + 1] = { body = "binary", code = 200 }
client:get_binary("https://example.com/binary-budget")
expect(timeout_calls[#timeout_calls][1] == 15 and timeout_calls[#timeout_calls][2] == 300,
    "binary requests did not receive the larger finite transfer budget")
responses[#responses + 1] = { body = "legacy", code = 200 }
client:request({ url = "https://example.com/legacy-budget", timeout = { 3, -1 } })
expect(timeout_calls[#timeout_calls][2] > 0,
    "a legacy negative timeout re-enabled an unbounded request")

local diagnostics, progress = {}, {}
local cancelled = false
local old_context = client:set_request_context({
    cancelled = function() return cancelled end,
    on_progress = function(info) progress[#progress + 1] = info end,
    on_diagnostic = function(info) diagnostics[#diagnostics + 1] = info end,
})
expect(old_context == nil and Client:new(settings).request_context == nil,
    "request contexts were shared between client instances")

local started = fake_time
queue_run(function(options)
    for index = 1, 7 do
        fake_time = started + index * 10
        options.sink("x")
    end
    return 1, 200, {}
end)
ok, err = pcall(client.get_text, client, "https://example.com/trickle")
expect(not ok and tostring(err):find("request total timeout", 1, true),
    "a steadily trickling table response escaped the total deadline")
expect(diagnostics[#diagnostics].kind == "total_timeout"
    and diagnostics[#diagnostics].retryable == true,
    "total timeout diagnostics were missing or misclassified")

started = fake_time
queue_run(function(options)
    fake_time = started + 6
    options.sink("redirect")
    return 1, 302, { location = "https://example.com/redirect-final" }
end)
queue_run(function(options)
    expect(timeout_calls[#timeout_calls][1] == 4
        and timeout_calls[#timeout_calls][2] == 4,
        "the redirect did not use the remaining original deadline")
    fake_time = started + 11
    options.sink("late")
    return 1, 200, {}
end)
ok, err = pcall(client.request_follow, client, {
    url = "https://example.com/redirect-first", timeout = { 8, 10 },
})
expect(not ok and tostring(err):find("total timeout", 1, true),
    "redirects each obtained a fresh total timeout")

started = fake_time
queue_run(function(options)
    fake_time = started + 61
    return 1, 204, {}
end)
ok = pcall(client.request, client, { url = "https://example.com/late-no-body" })
expect(not ok and client.last_request_error.kind == "total_timeout",
    "a request returning after its deadline without sink data was accepted")

local before_requests = #requests
cancelled = true
ok = pcall(client.request, client, { url = "https://example.com/cancel-before" })
expect(not ok and #requests == before_requests
    and client.last_request_error.kind == "cancelled"
    and client.last_request_error.retryable == false,
    "pre-request cancellation started transport or was considered retryable")
cancelled = false

local existing = assert(io.open(download_path, "wb"))
existing:write("previous-good-file")
existing:close()
queue_run(function(options)
    options.sink("short")
    return 1, 200, { ["Content-Length"] = "50" }
end)
ok = pcall(client.download_to_file, client,
    "https://example.com/short-file", download_path)
expect(not ok and client.last_request_error.kind == "short_read"
    and client.last_request_error.status == 200,
    "a successful HTTP status hid a truncated file body")
expect(file_body(download_path) == "previous-good-file"
    and file_body(download_path .. ".part") == nil,
    "a truncated replacement removed the previous file or retained a partial file")

queue_run(function(options)
    options.sink("partial")
    return nil, "closed"
end)
ok, err = pcall(client.download_to_file, client,
    "https://example.com/disconnected-file", download_path)
expect(not ok and tostring(err):find("closed", 1, true)
    and client.last_request_error.kind == "transport_error"
    and file_body(download_path .. ".part") == nil,
    "transport short reads were not propagated and cleaned up")

local data_events = 0
queue_run(function(options)
    options.sink("first")
    options.sink("second")
    return 1, 200, {}
end)
ok = pcall(client.download_to_file, client,
    "https://example.com/cancel-file", download_path, {
        on_progress = function(info)
            if info.event == "data" then
                data_events = data_events + 1
                cancelled = true
            end
        end,
    })
expect(not ok and data_events == 1 and client.last_request_error.kind == "cancelled"
    and client.last_request_error.retryable == false,
    "file cancellation did not stop at a chunk boundary")
expect(file_body(download_path .. ".part") == nil
    and file_body(download_path) == "previous-good-file",
    "cancelled file replacement was committed or not cleaned up")
cancelled = false

started = fake_time
queue_run(function(options)
    fake_time = started + 2
    options.sink("first")
    fake_time = started + 5
    options.sink("late")
    return 1, 200, {}
end)
ok = pcall(client.download_to_file, client,
    "https://example.com/file-deadline", download_path, { timeout = { 3, 4 } })
expect(not ok and client.last_request_error.kind == "total_timeout"
    and file_body(download_path .. ".part") == nil,
    "a file sink bypassed the explicit total deadline")

started = fake_time
local transport_closed = false
queue_run(function(options)
    fake_time = started + 5
    local sink_ok, accepted, sink_err = pcall(options.sink, "late")
    expect(sink_ok and accepted == nil and tostring(sink_err):find("total timeout", 1, true),
        "sink cancellation threw past LuaSocket's connection-closing finalizer")
    if not accepted then transport_closed = true; return nil, sink_err end
    return 1, 200, {}
end)
ok = pcall(client.request, client, {
    url = "https://example.com/sink-finalizer", timeout = { 3, 4 },
})
expect(not ok and transport_closed,
    "sink failure did not return through the transport error path")

local terminal_calls, terminal_error = 0, nil
queue_run(function(options)
    options.sink("first")
    local accepted, sink_err = options.sink(nil, "timeout")
    return accepted, sink_err
end)
ok = pcall(client.request, client, {
    url = "https://example.com/source-error",
    sink = function(chunk, sink_err)
        if chunk == nil then terminal_calls = terminal_calls + 1; terminal_error = sink_err end
        return 1
    end,
})
expect(not ok and terminal_calls == 1 and terminal_error == "timeout"
    and client.last_request_error.kind == "transport_timeout",
    "a source read error did not terminate the caller-owned sink exactly once")

terminal_calls, terminal_error = 0, nil
started = fake_time
queue_run(function(options)
    fake_time = started + 5
    local accepted, sink_err = options.sink("late")
    return accepted, sink_err
end)
ok = pcall(client.request, client, {
    url = "https://example.com/guard-ends-sink", timeout = { 3, 4 },
    sink = function(chunk, sink_err)
        if chunk == nil then terminal_calls = terminal_calls + 1; terminal_error = sink_err end
        return 1
    end,
})
expect(not ok and terminal_calls == 1 and tostring(terminal_error):find("total timeout", 1, true),
    "a deadline abort left a caller-owned sink open")

queue_run(function(options)
    options.sink("data")
    return nil, 200, { ["content-length"] = "4" }, "incomplete transport"
end)
ok = pcall(client.download_to_file, client,
    "https://example.com/failed-transport-status", download_path)
expect(not ok and file_body(download_path .. ".part") == nil
    and file_body(download_path) == "previous-good-file",
    "a numeric success status overrode the transport failure result")

responses[#responses + 1] = {
    body = "busy", code = 429, headers = { ["Retry-After"] = "12" },
}
ok, err = pcall(client.get_text, client, "https://example.com/rate-limit")
expect(not ok and tostring(err):find("HTTP 429", 1, true),
    "structured HTTP diagnostics broke existing string errors")
expect(client.last_request_error.kind == "http_error"
    and client.last_request_error.status == 429
    and client.last_request_error.retryable == true
    and client.last_request_error.retry_after == "12"
    and client.last_request_error.retry_after_seconds == 12,
    "rate-limit diagnostics did not retain status and Retry-After")

queue_run(function(options)
    options.sink("data")
    return 1, 200, { ["content-length"] = "4" }
end)
ok = pcall(client.download_to_file, client, "https://example.com/progress-cancel", download_path, {
    on_progress = function(info)
        if info.event == "data" then error("__weread_worker_cancelled__", 0) end
    end,
    on_diagnostic = function() error("observer failed") end,
})
expect(not ok and client.last_request_error.kind == "cancelled"
    and not client.last_request_error.retryable
    and file_body(download_path .. ".part") == nil,
    "worker cancellation or a broken diagnostic observer defeated cleanup")

progress = {}
responses[#responses + 1] = { body = "skip", code = 302,
    headers = { location = "https://example.com/final-file" } }
responses[#responses + 1] = { body = "good", code = 200,
    headers = { ["content-length"] = "4" } }
saved_path, saved_bytes = client:download_to_file(
    "https://example.com/redirect-file", download_path)
expect(file_body(saved_path) == "good" and saved_bytes == 4,
    "a complete replacement or redirect body reset was incorrect")
local final_progress = progress[#progress]
expect(final_progress.event == "complete" and final_progress.bytes == 8
    and final_progress.request_bytes == 4,
    "byte progress did not distinguish logical transfer bytes from the final response")
expect(timeout_calls[#timeout_calls][2] == 300,
    "file downloads did not use their distinct default deadline")
expect(requests[#requests].on_progress == nil and requests[#requests].cancelled == nil
    and requests[#requests].total_timeout == nil and requests[#requests].timeout_profile == nil,
    "request-context controls leaked into LuaSocket options")

local real_rename = os.rename
rawset(os, "rename", function(from, to)
    if from == download_path .. ".part" and to == download_path then
        return nil, "injected commit failure"
    end
    return real_rename(from, to)
end)
responses[#responses + 1] = { body = "replacement", code = 200 }
ok = pcall(client.download_to_file, client,
    "https://example.com/rename-failure", download_path)
rawset(os, "rename", real_rename)
expect(not ok and file_body(download_path) == "good"
    and file_body(download_path .. ".part") == nil,
    "a failed replacement did not restore the previous successful file")

local first_replace = true
rawset(os, "rename", function(from, to)
    if first_replace and from == download_path .. ".part" and to == download_path then
        first_replace = false
        return nil, "destination exists"
    end
    return real_rename(from, to)
end)
responses[#responses + 1] = { body = "good", code = 200 }
ok = pcall(client.download_to_file, client,
    "https://example.com/replace-existing", download_path)
rawset(os, "rename", real_rename)
expect(ok and file_body(download_path) == "good" and file_body(download_path .. ".part") == nil,
    "replacement failed on a host without replace-on-rename")

local real_open = io.open
rawset(io, "open", function(path, mode)
    local file, open_err = real_open(path, mode)
    if file and path == download_path .. ".part" and mode == "wb" then
        return {
            write = function(_self, data) return file:write(data) end,
            close = function()
                file:close()
                return nil, "injected close failure"
            end,
        }
    end
    return file, open_err
end)
responses[#responses + 1] = { body = "unflushed", code = 200 }
ok = pcall(client.download_to_file, client,
    "https://example.com/close-failure", download_path)
rawset(io, "open", real_open)
expect(not ok and client.last_request_error.kind == "io_error"
    and file_body(download_path) == "good" and file_body(download_path .. ".part") == nil,
    "a file close failure was committed or lost the previous file")

responses[#responses + 1] = { body = "", code = 200 }
ok = pcall(client.download_to_file, client, "https://example.com/empty-file", download_path)
expect(not ok and client.last_request_error.kind == "empty_body"
    and file_body(download_path) == "good" and file_body(download_path .. ".part") == nil,
    "an empty response replaced a successful file")

local prior_scope = client:set_request_context(old_context)
expect(type(prior_scope) == "table" and client.request_context == nil,
    "request scope was not restored")
os.remove(download_path)

print(("client_spec: %d checks"):format(checks))
