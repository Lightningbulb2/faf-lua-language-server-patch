package.path  = package.path
      .. ';./test/?.lua'
      .. ';./test/?/init.lua'
local fs = require 'bee.filesystem'
local sys = require 'bee.sys'
local rootPath = sys.exe_path():parent_path():parent_path():string()
ROOT = fs.path(rootPath)
TEST = true
DEVELOP = true
--FOOTPRINT = true
--TRACE = true
LOGPATH  = LOGPATH  or (ROOT:string() .. '/log')
METAPATH = METAPATH or (ROOT:string() .. '/meta')
TARGET_TEST_NAME = nil

if arg then
   for _, v in pairs(arg) do
       if v:sub(1, 3) == "-n=" or v:sub(1, 7) == "--name=" then
            TARGET_TEST_NAME = v:sub(v:find('=') + 1)
       end
   end
end

--collectgarbage 'generational'
collectgarbage('param', 'minormul', 10)
collectgarbage('param', 'minormajor', 50)

---@diagnostic disable-next-line: duplicate-set-field
io.write = function () end

---@diagnostic disable-next-line: lowercase-global
log = require 'log'
log.init(ROOT, ROOT / 'log' / 'test.log')
log.debug('测试开始')

LOCALE = 'zh-cn'

--dofile((ROOT / 'build_package.lua'):string())
require 'tracy'


local util   = require 'utility'
local files  = require 'files'
local folding = require 'core.folding'
local converter = require 'proto.converter'
local ws     = require 'workspace'

local cases = {
    { name = 'real-file layout regions+content', code = [==[
local ChatInterface = ClassUI(Window) {
}

--#region UI variables
local LayoutHelpers = import("/lua/maui/layouthelpers.lua")
local Group = import("/lua/maui/group.lua").Group

local createdUI = false

local tickTimeHistory = CreateRingQueue(100)
--#endregion


--#region Mod calculations
local function GetTotalSlowdown()
    return 1
end
--#endregion


-- used for keeping track

--#region Player override tracking variables
local playerOverride = false
--#endregion

function OnBeat()
    return 1
end
]==] },
    { name = 'sibling regions with gaps', code = [[
--#region UI variables
local a = 1

local b = 2
--#endregion


--#region Mod calculations
local c = 3
local d = 4
--#endregion

-- used for keeping track

--#region Player override
local e = 5
--#endregion
]] },
    { name = 'control: 2552 without inline comment', code = [[
--[==[ API
- My fantastic description here
--]==]
function TitanUtils_GetRealPosition(id)
	return 1
end
]] },
    { name = 'edge: multi-line trailing long comment', code = [==[
---@param bar integer
function foo(bar) --[[ multi
line trailing ]] local x = bar
  return x
end
]==] },
    { name = 'issue-3220 doc + inline comment', code = [[
---@param bar integer
function foo(bar) -- comment
  local whee = bar + 3
  return whee
end
]] },
    { name = 'issue-2581 comment before and after', code = [[
-- foo
function foo() -- foo
	if a then
		return a
	end
end
]] },
    { name = 'issue-2552 long comment + inline', code = [[
--[==[ API
- My fantastic description here
--]==]
function TitanUtils_GetRealPosition(id) -- Used by me
	-- Even better coding
	return 1
end
]] },
    { name = 'clean multi-line docblock (must fold to one line)', code = [[
---@param a integer
---@param b integer
---@return integer
function add(a, b)
  return a + b
end
]] },
    { name = 'class annotation block only (no statement)', code = [[
---@class MyClass
---@field a integer
---@field b integer
]] },
    { name = 'issue-3220b class + inline comment on local', code = [[
---@class MyClass
local MyClass = { -- comment
    a = 1,
    b = 2,
}
]] },
    { name = 'region markers', code = [[
--#region stuff
local a = 1
local b = 2
--#endregion
]] },
    { name = 'if/elseif/else chain', code = [[
if a then
  print(1)
  print(2)
elseif b then
  print(3)
  print(4)
else
  print(5)
  print(6)
end
]] },
    { name = 'nested function in table (FA spec style)', code = [[
---@class Foo
Foo = Class(Base) {
    ---@param self Foo
    __init = function(self, parent)
        self.x = 1
        self.y = 2
    end,

    ---@param self Foo
    Method = function(self) -- trailing comment
        return self.x
    end,
}
]] },
}

for _, case in ipairs(cases) do
    local uri = 'file:///foldtest_' .. case.name:gsub('%W', '_') .. '.lua'
    files.setText(uri, case.code)
    local state = files.getState(uri)
    local regions = folding(uri)
    print('== ' .. case.name .. ' ==')
    local lines = {}
    for ln in case.code:gmatch('[^\n]*') do lines[#lines+1] = ln end
    if regions then
        table.sort(regions, function(a, b) return a.start < b.start end)
        for _, region in ipairs(regions) do
            local startLine = converter.packPosition(state, region.start).line
            local endLine   = converter.packPosition(state, region.finish).line
            if not region.hideLastLine then
                endLine = endLine - 1
            end
            if startLine < endLine then
                print(('  fold %2d..%-2d kind=%-8s | %s'):format(
                    startLine, endLine, region.kind or '?',
                    (lines[startLine+1] or ''):sub(1, 46)))
            end
        end
    else
        print('  (no regions)')
    end
    files.remove(uri)
end
print('FOLDTEST DONE')
