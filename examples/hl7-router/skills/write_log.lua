return {
  name = "write_log",
  description = "Write a processing log entry to a timestamped file",
  run = function(params)
    local timestamp = os.date("%Y%m%d_%H%M%S")
    local filename = "logs/log_" .. timestamp .. ".txt"
    local content = "Processed at " .. timestamp .. "\n" .. (params.message or "no message")

    local ok, err = file.write(filename, content)
    if ok then
      return { status = "logged", file = filename }
    else
      return { status = "error", reason = err }
    end
  end
}
