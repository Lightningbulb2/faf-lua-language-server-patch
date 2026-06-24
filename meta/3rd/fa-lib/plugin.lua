---@class diff
---@field start  integer # The number of bytes at the beginning of the replacement
---@field finish integer # The number of bytes at the end of the replacement
---@field text   string  # What to replace

---@param  uri  string # The uri of file
---@param  text string # The content of file
---@return nil|diff[]
function OnSetText(uri, text)
    local diffs = {}

    -- Iterate line by line to accurately track byte offsets and line-level comments.
    -- gmatch("([^\n]*\n?)") captures the full line including the newline character.
    local offset = 0
    for line in text:gmatch("([^\n]*\n?)") do
        if line == "" then break end

        -- Find the start of a standard Lua comment on this line (if any)
        local comment_pos = line:find("--", 1, true)

        local search_idx = 1
        while true do
            local hash_pos = line:find("#", search_idx, true)
            if not hash_pos then break end

            -- If the '#' comes after '--', it is already commented out. Skip the rest.
            if comment_pos and hash_pos > comment_pos then
                break
            end

            local absolute_pos = offset + hash_pos
            diffs[#diffs + 1] = {
                start = absolute_pos,
                finish = absolute_pos,
                text = '--'
            }

            search_idx = hash_pos + 1
        end

        -- Increment the absolute offset by the exact byte length of the line
        offset = offset + #line
    end


    return diffs
end
