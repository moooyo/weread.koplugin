package.path = "./?.lua;./?/init.lua;" .. package.path
local Policy = require("weread.lib.download_policy")

assert(Policy.concurrency(nil) == 5 and Policy.concurrency("invalid") == 5)
assert(Policy.concurrency(0 / 0) == 5 and Policy.concurrency(math.huge) == 5)
assert(Policy.concurrency(10) == 5 and Policy.concurrency(0) == 1)
assert(Policy.concurrency("3.8") == 3)
for _, failure in ipairs({
    { diagnostic = { kind = "transport", retryable = true } },
    { diagnostic = { kind = "transport_timeout", retryable = true } },
    { diagnostic = { status = 503, retryable = true } },
    { error = "worker_timeout" },
}) do
    local first, second, last = Policy.classify(failure, 1), Policy.classify(failure, 2), Policy.classify(failure, 3)
    assert(first.retry and first.delay == 0.8)
    assert(second.retry and second.delay == 1.6)
    assert(not last.retry and last.pause)
end
for _, diagnostic in ipairs({
    { status = 401 }, { status = 403 }, { status = 429 },
    { kind = "authentication" }, { api_code = -10102 },
}) do
    local decision = Policy.classify({ diagnostic = diagnostic }, 1)
    assert(decision.pause and not decision.retry)
end
assert(not Policy.classify({ diagnostic = { status = 404, retryable = false } }, 1).retry)
assert(Policy.classify({ diagnostic = { kind = "session" } }, 1).retry)
assert(Policy.classify({ diagnostic = { kind = "session" } }, 3).pause)
assert(Policy.classify({ cancelled = true }, 1).pause)
assert(Policy.classify({ diagnostic = { status = 503, retry_after_seconds = 7 } }, 1).delay == 7)
assert(Policy.classify({ diagnostic = { status = 503, retry_after_seconds = 120 } }, 1).pause)
local diagnostic_message = "/fixture/content.lua:1635: HTTP 503"
local details = Policy.classify({ error = diagnostic_message,
    diagnostic = { status = 503, kind = "http_status", retryable = true } }, 3)
assert(details.pause and details.http_status == 503 and details.error_kind == "http_status"
    and details.error == diagnostic_message)
assert(Policy.classify({ diagnostic = { api_code = -10102, status = 200 } }, 1).api_code == -10102)
print("download_policy_spec: concurrency bounds, bounded backoff and stop conditions passed")
