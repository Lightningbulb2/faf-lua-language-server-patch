---@class diff
---@field start  integer # The number of bytes at the beginning of the replacement
---@field finish integer # The number of bytes at the end of the replacement
---@field text   string  # What to replace

---@param  uri  string # The uri of file
---@param  text string # The content of file
---@return nil|diff[]
function OnSetText(uri, text)
    local diffs = {}

    -- FA uses # as a line comment character (inherited from a custom Lua build).
    -- Replace each # with -- so the parser treats it as a Lua comment.
    for pos in text:gmatch '()#' do
        diffs[#diffs + 1] = {
            start = pos,
            finish = pos,
            text = '--'
        }
    end

    -- FA uses {&N &M} table constructor hints (pre-allocated size hints for the C allocator).
    -- e.g. {&1 &0} means "1 hash slot, 0 array slots". Strip them so the parser sees {}.
    -- Pattern: & followed by digits, possibly preceded by whitespace inside braces.
    for pos, amp, num in text:gmatch '()(&)(%d+)' do
        diffs[#diffs + 1] = {
            start  = pos,
            finish = pos + 1 + #num - 1,
            text   = ''
        }
    end

    return diffs
end
