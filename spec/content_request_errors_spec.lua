package.path = "./?.lua;./?/init.lua;" .. package.path
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
local Content = require("weread.lib.content")
local response = {}
local client = {
    request = function(self) self.last_request_error = nil; return '{"fixture":true}', 200 end,
    json_encode = function() return "{}" end,
    json_decode = function() return response end,
}
local book, chapter = { book_id = "fixture", psvts = "fixture-page" }, { chapterUid = 1 }
for _, case in ipairs({ { -2013, "authentication", false }, { -2010, "session", true },
    { -2012, "session", true }, { -999, "api_error", false } }) do
    response = { errCode = case[1], errMsg = "private response must not enter the exception" }
    local ok, err = pcall(Content.fetch_chapter_shard, client, {}, book, chapter, "/web/book/chapter/e_0")
    assert(not ok and not tostring(err):find("private response", 1, true))
    assert(client.last_request_error.kind == case[2] and client.last_request_error.retryable == case[3])
    assert(client.last_request_error.api_code == case[1])
end
response = { bookId = "fixture", code = 0 }
assert(Content.fetch_chapter_shard(client, {}, book, chapter, "/web/book/chapter/e_0") == '{"fixture":true}')
assert(client.last_request_error == nil, "format metadata was misclassified as failure")

local fixture = require("spec.fixtures.content_decoder_cases")[2]
local original_refresh, original_cache = Content.refresh_reader_state, Content.cache_annotation_source
Content.refresh_reader_state = function() end
Content.cache_annotation_source = function() end
local function scripted_client(errors)
    local scripted = { calls = {} }
    function scripted:request(options)
        local endpoint = options.url:match("([^/]+)$")
        self.calls[endpoint] = (self.calls[endpoint] or 0) + 1
        self.endpoint = endpoint
        self.last_request_error = nil
        local failure = errors[endpoint]
        if failure and failure.api_code then return '{"error":true}', 200 end
        if failure and failure.status then
            self.last_request_error = { kind = "http_error", status = failure.status, retryable = true }
            return "", failure.status
        end
        if failure and failure.exception then error(failure.exception, 0) end
        return endpoint == "t_0" and fixture.single or "{}", 200
    end
    function scripted:json_encode() return "{}" end
    function scripted:json_decode()
        return { errCode = errors[self.endpoint].api_code, errMsg = "private response" }
    end
    return scripted
end
local txt_book = { book_id = "fixture", psvts = "fixture-page", _content_format = "txt" }
for _, failure in ipairs({ { api_code = -2013 }, { api_code = -2010 }, { api_code = -2012 },
    { status = 401 }, { status = 403 }, { status = 429 }, { status = 500 },
    { exception = "unclassified transport failure" } }) do
    local scripted = scripted_client({ t_1 = failure })
    local ok, err = pcall(Content.fetch_single_chapter_source, scripted, {}, txt_book, chapter, {})
    assert(not ok and not tostring(err):find("private response", 1, true),
        "failed TXT shard was silently treated as optional empty content")
    assert(scripted.calls.t_0 == 1 and scripted.calls.t_1 == 1 and scripted.calls.e_2 == nil,
        "CSS fetching hid the original TXT shard failure")
    if not failure.exception then assert(scripted.last_request_error, "TXT diagnostic was lost") end
end
local optional = scripted_client({})
local text = Content.fetch_single_chapter_source(optional, {}, txt_book, chapter, {})
assert(text:find("<p>a</p>", 1, true) and optional.calls.e_2 == 1,
    "optional empty TXT shard or stylesheet compatibility changed")
for _, failure in ipairs({ { api_code = -2013 }, { api_code = -2010 }, { api_code = -2012 },
    { status = 401 }, { status = 403 }, { status = 429 }, { status = 500 } }) do
    local scripted = scripted_client({ e_2 = failure })
    local ok = pcall(Content.fetch_single_chapter_source, scripted, {}, txt_book, chapter, {})
    assert(not ok and scripted.last_request_error and scripted.calls.e_2 == 1,
        "optional CSS fetching swallowed a structured request failure")
end
Content.refresh_reader_state, Content.cache_annotation_source = original_refresh, original_cache
print("content_request_errors_spec: auth/session/HTTP propagation and optional empty shards passed")
