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

        -- Walk the line character-by-character to find the first '--' that is NOT
        -- inside a string literal.  We need this to correctly handle lines like:
        --   local x = "a--b" # comment   →  '--' at col 12 is inside a string,
        --                                    '#' at col 19 should be replaced.
        -- Strategy: skip over quoted-string spans (single or double), tracking the
        -- actual comment start position (or nil if no real comment exists).
        local comment_pos = nil
        local i = 1
        local len = #line
        while i <= len do
            local ch = line:sub(i, i)

            -- Enter a string literal and skip to its closing quote.
            -- We handle \\ and \' / \" escape sequences so we don't exit early.
            if ch == '"' or ch == "'" then
                local quote = ch
                i = i + 1
                while i <= len do
                    local c = line:sub(i, i)
                    if c == '\\' then
                        i = i + 2  -- skip the escaped character
                    elseif c == quote then
                        i = i + 1
                        break
                    else
                        i = i + 1
                    end
                end

            -- Detect '--' outside of any string → real comment start.
            elseif ch == '-' and line:sub(i, i + 1) == '--' then
                comment_pos = i
                break

            else
                i = i + 1
            end
        end

        -- Now scan for '#' characters that appear before the real comment start.
        local search_idx = 1
        while true do
            local hash_pos = line:find("#", search_idx, true)
            if not hash_pos then break end

            -- If the '#' comes after the start of a real '--' comment, stop.
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
