package.path = "./?.lua;./?/init.lua;" .. package.path
local WorkerSettings = require("weread.lib.worker_settings")
local state = { cache = { chapter_download_concurrency = 5, download_book_images = true },
    cookies = { session = "original" }, account = { user_vid = "fixture" } }
local writes = 0
local settings = {
    cache_dir = "/fixture/cache", data_dir = "/fixture/data",
    get = function(_self, key, default) return state[key] or default end,
    set = function(_self, key, value) writes = writes + 1; state[key] = value end,
    flush = function() writes = writes + 1 end,
    update_auth = function(self, credentials)
        self:set("cookies", credentials.cookies)
        self:flush()
    end,
}
local client_class = { request = function(self) return self.settings:get("cookies").session end }
client_class.__index = client_class
local client = setmetatable({ settings = settings, request_context = { stale = true },
    last_request_error = { stale = true }, request_sequence = 7 }, client_class)
local factory = WorkerSettings.job_factory(settings, client)
state.cache.chapter_download_concurrency = 1
state.cookies.session = "new-parent"
settings.cache_dir = "/fixture/moved"
local first, first_client = factory()
local second, second_client = factory()
assert(first:get("cache").chapter_download_concurrency == 5)
assert(first.cache_dir == "/fixture/cache")
assert(first_client:request() == "original" and second_client:request() == "original")
assert(first_client.request_context == nil and first_client.last_request_error == nil)
assert(first_client.request_sequence == 0)
local old_update, old_flush = first.update_auth, first.flush
local auth_result, restore = WorkerSettings.capture(first)
first:update_auth { cookies = { session = "private" } }
assert(auth_result().cookies.session == "private")
assert(second_client:request() == "original" and client:request() == "new-parent")
assert(writes == 0 and first_client.settings ~= second_client.settings)
first:get("cache").download_book_images = false
assert(second:get("cache").download_book_images)
local outer_update, outer_flush = first.update_auth, first.flush
for index = 1, 200 do
    local captured, restore_inner = WorkerSettings.capture(first)
    first:update_auth { cookies = { session = "iteration-" .. index } }
    assert(captured().cookies.session == "iteration-" .. index)
    restore_inner()
    assert(first.update_auth == outer_update and first.flush == outer_flush)
end
restore()
restore()
assert(first.update_auth == old_update and first.flush == old_flush)
assert(auth_result().cookies.session == "iteration-200")
assert(writes == 0)
print("worker_settings_snapshot_spec: frozen job options, private auth and isolated client state passed")
