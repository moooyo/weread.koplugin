package.path = "./?.lua;./?/init.lua;" .. package.path
package.preload["logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
local Content = require("weread.lib.content")
local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end
local root = os.tmpname()
os.remove(root)
assert(os.execute("mkdir -p " .. string.format("%q", root .. "/incoming")) == 0)
assert(os.execute("mkdir -p " .. string.format("%q", root .. "/images")) == 0)
local workspace = { incoming_dir = root .. "/incoming", asset_dir = root .. "/images" }
local image = "\255\216\255fixture-image"
local one = '<img src="https://example.test/one.jpg"/>'
local two = one .. '<img src="https://example.test/two.jpg"/>'
local function write(path, data)
    local file = assert(io.open(path, "wb"))
    assert(file:write(data))
    assert(file:close())
end
local function client_for(failures, diagnostic)
    local client = { calls = 0, sleeps = 0 }
    function client:download_to_file(_url, path)
        self.calls = self.calls + 1
        if self.calls <= failures then
            self.last_request_error = diagnostic
            write(path .. ".part", "partial")
            error("injected image failure", 0)
        end
        -- The retry helper must clear the previous diagnostic before this call.
        expect(self.last_request_error == nil, "recovered image inherited an earlier request failure")
        write(path, image)
        return path
    end
    client.retry = { attempts = 3, sleep = function(seconds)
        expect(seconds > 0 and seconds <= 1, "image retry sleep was not bounded")
        client.sleeps = client.sleeps + 1
    end, check_cancelled = function() end }
    return client
end
for _, diagnostic in ipairs({ { kind = "transport_timeout", retryable = true },
    { kind = "transport_error", retryable = true }, { kind = "total_timeout", retryable = true },
    { kind = "short_read", retryable = true }, { kind = "http_error", status = 503, retryable = true } }) do
    local client = client_for(2, diagnostic)
    local body, assets, complete, retry = Content.download_remote_images_to_files(
        client, one, {}, workspace, nil, client.retry)
    expect(client.calls == 3 and client.sleeps == 2 and complete and #assets == 1,
        "transient image failure did not recover within three attempts")
    expect(body:find("../images/", 1, true) and client.last_request_error == nil,
        "recovered image retained its remote reference or stale failure")
    expect(retry.requests == 3 and retry.retries == 2 and retry.recovered_images == 1 and retry.failed_images == 0,
        "image recovery statistics were incorrect")
    expect(io.open(workspace.incoming_dir .. "/remote-000001.bin.part", "rb") == nil,
        "image retries retained a failed partial file")
end
local exhausted = client_for(99, { kind = "http_error", status = 502, retryable = true })
exhausted.retry.attempts = 99
local _, _, complete, retry = Content.download_remote_images_to_files(
    exhausted, one .. one, {}, workspace, nil, exhausted.retry)
expect(exhausted.calls == 3 and exhausted.sleeps == 2 and not complete
    and retry.failed_images == 1, "failed duplicate URL exceeded its three-attempt budget")
local compatibility = client_for(99, { kind = "transport_error", retryable = true })
Content.download_remote_images_to_files(compatibility, one, {}, workspace, nil, { attempts = 3 })
expect(compatibility.calls == 1 and compatibility.sleeps == 0,
    "foreground compatibility mode introduced retry waits without a scheduler")
for _, diagnostic in ipairs({ { kind = "http_error", status = 404, retryable = true },
    { kind = "http_error", status = 500, retryable = false }, { kind = "io_error", retryable = false } }) do
    local client = client_for(99, diagnostic)
    local _, _, finished = Content.download_remote_images_to_files(client, one, {}, workspace, nil, client.retry)
    expect(client.calls == 1 and client.sleeps == 0 and not finished,
        "permanent image failure was retried")
end
for _, diagnostic in ipairs({ { status = 401, retryable = true }, { status = 403, retryable = true },
    { status = 429, retryable = true }, { kind = "authentication", retryable = true },
    { kind = "session", retryable = true }, { kind = "api_error", api_code = -10102, retryable = true } }) do
    local client = client_for(99, diagnostic)
    local ok = pcall(Content.download_remote_images_to_files, client, two, {}, workspace, nil, client.retry)
    expect(not ok and client.calls == 1 and client.sleeps == 0,
        "fatal image failure retried or continued to another image")
end
local cancelled = client_for(99, { kind = "transport_error", retryable = true })
cancelled.retry.sleep = function() error("__weread_worker_cancelled__", 0) end
local ok, err = pcall(Content.download_remote_images_to_files, cancelled, two, {}, workspace, nil, cancelled.retry)
expect(not ok and err == "__weread_worker_cancelled__" and cancelled.calls == 1,
    "cancellation during image retry sleep did not propagate")
expect(io.open(workspace.incoming_dir .. "/remote-000001.bin.part", "rb") == nil,
    "cancelled retry left a partial image")
local unsupported = { calls = 0, download_to_file = function(self, _url, path)
    self.calls = self.calls + 1
    write(path, "not an image")
    return path
end }
local _, _, supported = Content.download_remote_images_to_files(unsupported, one .. one, {}, workspace, nil,
    { attempts = 3, sleep = function() error("unsupported images must not retry") end })
expect(not supported and unsupported.calls == 1, "unsupported image content was retried")
local api_client = { calls = 0, download_to_file = function(self, _url, path)
    self.calls = self.calls + 1
    write(path, '{"errCode":-10102}')
    return path
end, json_decode = function() return { errCode = -10102 } end }
ok = pcall(Content.download_remote_images_to_files, api_client, two, {}, workspace, nil,
    { sleep = function() error("API limit must not retry") end })
expect(not ok and api_client.calls == 1 and api_client.last_request_error.api_code == -10102,
    "HTTP-success API rate limit was mistaken for an ordinary unsupported image")
local recovered = client_for(1, { kind = "transport_timeout", retryable = true })
local state = { workspace = workspace, retry_options = recovered.retry }
Content.finalize_single_chapter_content(recovered, { get = function() return { download_book_images = true } end },
    { book_id = "fixture" }, { chapterUid = 1 }, one, state)
expect(state.resources_complete ~= false and state.image_retry_stats.retries == 1
    and state.image_retry_stats.recovered_images == 1,
    "finalization marked a recovered image as incomplete")
local memory = { calls = 0, get_binary = function(self)
    self.calls = self.calls + 1
    if self.calls == 1 then
        self.last_request_error = { kind = "transport_error", retryable = true }
        error("injected memory image failure", 0)
    end
    return image
end }
local _, memory_assets, memory_complete, memory_retry = Content.download_remote_images(memory, one, {}, nil,
    { sleep = function() end })
expect(memory.calls == 2 and #memory_assets == 1 and memory_complete and memory_retry.recovered_images == 1,
    "memory image mode did not share bounded retry semantics")
assert(os.execute("rm -rf " .. string.format("%q", root)) == 0)
print(("content_image_retry_spec: %d checks"):format(checks))
