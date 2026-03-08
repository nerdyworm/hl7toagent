---@meta

--- HTTP client available in skill `run` functions.
---
--- Example:
--- ```lua
--- local resp = http.get("https://example.com/api")
--- print(resp.status, resp.body)
--- ```
---@class http
http = {}

---@class HttpResponse
---@field status integer HTTP status code.
---@field body string Response body as a string.

---@class HttpRequestOpts
---@field body? string Request body string.
---@field headers? table<string, string> Request headers.

--- Send an HTTP GET request.
---@param url string The URL to request.
---@return HttpResponse
function http.get(url) end

--- Send an HTTP POST request.
---@param url string The URL to request.
---@param opts? HttpRequestOpts Request options (body, headers).
---@return HttpResponse
function http.post(url, opts) end

--- Send an HTTP PUT request.
---@param url string The URL to request.
---@param opts? HttpRequestOpts Request options (body, headers).
---@return HttpResponse
function http.put(url, opts) end

--- Send an HTTP DELETE request.
---@param url string The URL to request.
---@return HttpResponse
function http.delete(url) end

--- File I/O available in skill `run` functions.
--- All paths are sandboxed to the project directory.
---
--- Example:
--- ```lua
--- file.write("output.txt", "hello")
--- local content, err = file.read("output.txt")
--- ```
---@class file
file = {}

--- Read a file's contents.
---@param path string Path relative to the sandbox directory.
---@return string? content File contents, or nil on error.
---@return string? error Error message if read failed.
function file.read(path) end

--- Write content to a file. Creates parent directories as needed.
---@param path string Path relative to the sandbox directory.
---@param content string The content to write.
---@return boolean? ok True on success, nil on error.
---@return string? error Error message if write failed.
function file.write(path, content) end

--- Append content to a file.
---@param path string Path relative to the sandbox directory.
---@param content string The content to append.
---@return boolean? ok True on success, nil on error.
---@return string? error Error message if append failed.
function file.append(path, content) end

--- Delete a file.
---@param path string Path relative to the sandbox directory.
---@return boolean? ok True on success, nil on error.
---@return string? error Error message if delete failed.
function file.delete(path) end

--- Move (rename) a file. Creates parent directories for destination as needed.
---@param source string Source path relative to the sandbox directory.
---@param destination string Destination path relative to the sandbox directory.
---@return boolean? ok True on success, nil on error.
---@return string? error Error message if move failed.
function file.move(source, destination) end

--- List files in a directory.
---@param path string Path relative to the sandbox directory.
---@return string[]? entries List of filenames, or nil on error.
---@return string? error Error message if listing failed.
function file.list(path) end

--- Email client available in skill `run` functions.
--- Requires `smtp()` to be configured in `config.lua`.
---
--- Example:
--- ```lua
--- local result = email.send({
---     to = "alice@example.com",
---     subject = "Alert",
---     body = "Something happened",
--- })
--- print(result.status, result.message_id)
--- ```
---@class email
email = {}

---@class EmailOpts
---@field to string Recipient email address.
---@field subject? string Email subject line (default: "(no subject)").
---@field body? string Plain text email body (default: "").
---@field thread_id? string Thread ID to attach to the outgoing email. Defaults to the current thread.

---@class EmailResult
---@field status "sent"|"error" Whether the email was sent successfully.
---@field message_id? string The Message-ID of the sent email (on success).
---@field error? string Error message (on failure).

--- Send an email via SMTP.
---@param opts EmailOpts
---@return EmailResult
function email.send(opts) end
