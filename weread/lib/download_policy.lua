-- Shared bounds and retry decisions for foreground configuration and workers.
local Policy = {
    DEFAULT_CONCURRENCY = 5,
    MAX_CONCURRENCY = 5,
    MAX_ATTEMPTS = 3,
}

function Policy.concurrency(value)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge then
        return Policy.DEFAULT_CONCURRENCY
    end
    return math.max(1, math.min(Policy.MAX_CONCURRENCY, math.floor(value)))
end

function Policy.classify(failure, attempt)
    failure = type(failure) == "table" and failure or { error = tostring(failure or "Download failed") }
    local diagnostic = failure.diagnostic or {}
    local message = tostring(failure.error or diagnostic.message or "Download failed")
    local status = tonumber(diagnostic.status)
    local api_code = tonumber(diagnostic.api_code)
    attempt = tonumber(attempt) or 1
    local cancelled = failure.cancelled or message == "cancelled"
        or diagnostic.kind == "cancelled"
        or message:find("__weread_worker_cancelled__", 1, true) ~= nil
    local network_failure = diagnostic.kind == "transport" or diagnostic.kind == "transport_error"
        or diagnostic.kind == "transport_timeout"
        or diagnostic.kind == "timeout" or diagnostic.kind == "total_timeout"
        or diagnostic.kind == "short_read" or status == 408 or (status and status >= 500)
        or message == "worker_timeout" or message == "worker_no_result"
    local pause = failure.pause == true or cancelled
        or status == 401 or status == 403 or status == 429
        or diagnostic.kind == "authentication" or api_code == -10102
        or (diagnostic.kind == "session" and attempt >= Policy.MAX_ATTEMPTS)
        or (network_failure and attempt >= Policy.MAX_ATTEMPTS)
        or message == "low_memory" or message == "worker_unavailable"
    local retryable = failure.retryable ~= false and diagnostic.retryable ~= false
    if diagnostic.kind == "session" then retryable = true end
    local delay = 0.8 * 2 ^ math.max(0, attempt - 1)
    local retry_after = tonumber(diagnostic.retry_after_seconds)
    if retry_after and retry_after == retry_after and retry_after > 0 then
        if retry_after > 30 then pause = true
        else delay = math.max(delay, retry_after) end
    end
    return {
        retry = not pause and retryable and attempt < Policy.MAX_ATTEMPTS,
        pause = pause == true,
        delay = math.min(delay, 30),
        error = message,
        http_status = status,
        error_kind = type(diagnostic.kind) == "string" and diagnostic.kind or nil,
        api_code = api_code,
    }
end

return Policy
