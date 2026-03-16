return {
  name = "logger",
  description = "Append a timestamped entry to ./logs/activity.log",
  params = {
    entry = { type = "string", required = true, doc = "Log entry text" }
  },
  run = function(params)
    local entry = params.entry or ""
    local logpath = "logs/activity.log"

    local okr, prev = pcall(file.read, logpath)
    if not okr or not prev then prev = "" end

    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local line = string.format("%s - %s\n", timestamp, entry)

    local okw, errw = pcall(file.write, logpath, prev .. line)
    if not okw then
      return { status = "error", error = tostring(errw) }
    end
    return { status = "ok" }
  end
}
