local files = require "files"
local guide = require "parser.guide"
local util  = require 'utility'
local await = require 'await'

local care = {}

-- Upstream bugs: https://github.com/LuaLS/lua-language-server/issues/2581
-- https://github.com/LuaLS/lua-language-server/issues/3220
-- https://github.com/LuaLS/lua-language-server/issues/2552
-- The doc-binding pass captures a trailing inline comment on the declaration
-- line itself (`function foo(bar) -- comment`) as an extra entry appended to
-- the bound-doc group. Stock folding blindly ends the group's comment fold at
-- the group's *last* entry with hideLastLine = true, which then either
-- swallows the declaration line into the "comment" fold (#2552) or leaves the
-- chevron stranded on the annotation line folding a single line (#3220,
-- #2581). Instead, end the comment fold at the last doc entry that finishes
-- on a line *above* the statement, so the fold covers exactly the doc block:
-- - a clean multi-line docblock still folds down to its first line
--   (hideLastLine = true), unchanged;
-- - a trailing inline comment (even a multi-line `--[[ ]]` one) can never
--   drag the fold onto or past the declaration line;
-- - if nothing in the group sits above the statement (single stray inline
--   comment), the emitted range degenerates to one line and the provider's
--   `startLine < endLine` check drops it.
---@param docs parser.object[]     # bound doc group (bindDocs / bindGroup)
---@param stmtPos integer          # position of the documented statement
---@param results table
local function foldDocGroup(docs, stmtPos, results)
    if not docs or #docs == 0 then
        return
    end
    local stmtRow = guide.rowColOf(stmtPos)
    local lastDoc
    for i = #docs, 1, -1 do
        if guide.rowColOf(docs[i].finish) < stmtRow then
            lastDoc = docs[i]
            break
        end
    end
    if not lastDoc then
        return
    end
    results[#results+1] = {
        start        = docs[1].start,
        finish       = lastDoc.finish,
        kind         = 'comment',
        hideLastLine = true,
    }
end

care['function'] = function (source, _text, results)
        local folding = {
            start  = source.start,
            finish = source.finish,
            kind   = 'region',
        }
        results[#results+1] = folding
        if source.bindDocs then
            foldDocGroup(source.bindDocs, source.start, results)
        end
    end
care['do'] = function (source, _text, results)
        local folding = {
            start  = source.start,
            finish = source.finish,
            kind   = 'region',
        }
        results[#results+1] = folding
    end
care['if'] = function (source, _text, results)
        for i = 1, #source do
            local block = source[i]
            local nblock = source[i + 1]
            results[#results+1] = {
                start  = block.start,
                finish = nblock and nblock.start or source.finish,
                kind   = 'region',
            }
        end
    end
care['loop'] = function (source, _text, results)
        local folding = {
            start  = source.start,
            finish = source.finish,
            kind   = 'region',
        }
        results[#results+1] = folding
    end
care['in'] = function (source, _text, results)
        local folding = {
            start  = source.start,
            finish = source.finish,
            kind   = 'region',
        }
        results[#results+1] = folding
    end
care['while'] = function (source, _text, results)
        local folding = {
            start  = source.start,
            finish = source.finish,
            kind   = 'region',
        }
        results[#results+1] = folding
    end
care['repeat'] = function (source, _text, results)
        local start  = source.start
        local finish = source.keyword[#source.keyword]
        -- must end with 'until'
        if #source.keyword ~= 4 then
            return
        end
        local folding = {
            start  = start,
            finish = finish,
            kind   = 'region',
        }
        results[#results+1] = folding
    end
care['table'] = function (source, _text, results)
        local folding = {
            start  = source.start,
            finish = source.finish,
            kind   = 'region',
        }
        results[#results+1] = folding
    end
care['string'] = function (source, _text, results)
        local folding = {
            start  = source.start,
            finish = source.finish,
            kind   = 'region',
        }
        results[#results+1] = folding
    end
care['comment.short'] = function (source, _text, results, status)
        local ltext = source.text:lower()
        ltext = util.trim(ltext, 'left')
        if     ltext:sub(1, #'region') == 'region'
        or     ltext:sub(1, #'#region') == '#region' then
            if not status.regions then
                status.regions = {}
            end
            status.regions[#status.regions+1] = source
        elseif ltext:sub(1, #'endregion') == 'endregion'
        or     ltext:sub(1, #'#endregion') == '#endregion' then
            if not status.regions then
                status.regions = {}
            end
            local start = table.remove(status.regions)
            if not start then
                return
            end
            -- Upstream ends this fold ON the `--#endregion` line
            -- (hideLastLine = true). VS Code's folding model unions the LSP
            -- ranges with its own indentation-based ranges, and when two
            -- `--#region` blocks are separated only by blank lines, a region
            -- fold that reaches its own `--#endregion` line leaves no
            -- unfolded anchor line between it and the next block -- so
            -- collapsing the first region visually swallows every following
            -- sibling region up to the next non-blank, non-region line.
            -- Ending the fold on the line *before* `--#endregion`
            -- (hideLastLine = false) keeps the `--#endregion` line itself
            -- visible as a separator, which breaks that chaining while still
            -- hiding the region body.
            results[#results+1] = {
                start        = start.start,
                finish       = source.start,
                kind         = 'region',
                hideLastLine = false,
            }
        end
    end
care['comment.long'] = function (source, _text, results)
        local folding = {
            start  = source.start,
            finish = source.finish,
            kind   = 'comment',
        }
        results[#results+1] = folding
    end
care['comment.clong'] = function (source, _text, results)
        local folding = {
            start  = source.start,
            finish = source.finish,
            kind   = 'comment',
        }
        results[#results+1] = folding
    end
care['doc.class'] = function (source, _text, results)
        -- See foldDocGroup above.
        -- Repro: https://github.com/LuaLS/lua-language-server/issues/3220
        --   ---@class MyClass
        --   local MyClass = { -- comment
        --       a = 1,
        --   }
        -- The doc node's own start is the `---@class` line; the statement it
        -- documents (when present) is bindSource. With no bindSource
        -- (annotation-only block) fold the whole group as before.
        if not source.bindGroup or #source.bindGroup == 0 then
            return
        end
        if source.bindSource then
            foldDocGroup(source.bindGroup, source.bindSource.start, results)
        else
            results[#results+1] = {
                start        = source.bindGroup[1].start,
                finish       = source.bindGroup[#source.bindGroup].finish,
                kind         = 'comment',
                hideLastLine = true,
            }
        end
    end
care['doc.alias'] = function (source, _text, results)
        -- See foldDocGroup / the doc.class case above.
        if not source.bindGroup or #source.bindGroup == 0 then
            return
        end
        if source.bindSource then
            foldDocGroup(source.bindGroup, source.bindSource.start, results)
        else
            results[#results+1] = {
                start        = source.bindGroup[1].start,
                finish       = source.bindGroup[#source.bindGroup].finish,
                kind         = 'comment',
                hideLastLine = true,
            }
        end
    end

---@async
return function (uri)
    local state = files.getState(uri)
    local text  = files.getText(uri)
    if not state or not text then
        return nil
    end
    local regions = {}
    local status = {}

    guide.eachSource(state.ast, function (source) ---@async
        local tp = source.type
        if care[tp] then
            await.delay()
            care[tp](source, text, regions)
        end
    end)
    for _, source in ipairs(state.comms) do
        local tp = source.type
        if care[tp] then
            await.delay()
            care[tp](source, text, regions, status)
        end
    end

    return regions
end
