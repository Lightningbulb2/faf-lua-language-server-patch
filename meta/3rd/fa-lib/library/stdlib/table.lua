---@meta

-- FA's runtime is based on Lua 5.0, where these functions are first-class
-- citizens rather than deprecated leftovers. The builtin Lua 5.1 meta that
-- LuaFA inherits marks them `---@deprecated`, and LuaLS's `deprecated`
-- diagnostic only fires when *every* definition of a symbol is deprecated —
-- so re-declaring them here (without `---@deprecated`) suppresses the bogus
-- strikethrough/warning for FA code while leaving the builtin docs intact.
--
-- Only functions actually used by the FA codebase are listed; anything else
-- keeps its stock 5.1 deprecation status on purpose.

--- Returns the size of a list. This is the canonical way to get the length
--- of an array-style table in FA (used hundreds of times across the game
--- scripts); FA's Lua 5.0-based runtime fully supports it.
---@generic T
---@param list T[]
---@return integer
---@nodiscard
function table.getn(list) end

--- Executes the given `f` over all elements of `t`.
--- Fully supported by FA's Lua 5.0-based runtime.
---@generic T
---@param t table<any, T>
---@param f fun(key: any, value: T): any
function table.foreach(t, f) end

--- Executes the given `f` over the numeric indices of `t`.
--- Fully supported by FA's Lua 5.0-based runtime.
---@generic T
---@param t T[]
---@param f fun(i: integer, value: T): any
function table.foreachi(t, f) end
