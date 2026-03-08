return {
    name = "notice",
    description = "Notifies admins about a message that needs to be handled",
    run = function(params)
        local timestamp = os.date("%Y%m%d_%H%M%S")
        local filename = "notice_" .. timestamp .. ".txt"
        local content = "Processed message at " .. timestamp .. "\n" .. (params.message or "no message")

        local ok, err = file.write(filename, content)
        if ok then
            return { status = "logged", file = filename }
        else
            return { status = "error", reason = err }
        end
    end
}
