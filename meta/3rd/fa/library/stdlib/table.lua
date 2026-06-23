---@meta
-- FAForever stdlib overrides: removes @deprecated from functions that are
-- NOT deprecated in FA's custom Lua 5.0/5.1 runtime.

--- Returns the number of elements in the table t.
--- In FA's Lua runtime this is equivalent to #t but was the standard
--- way to get table length in Lua 5.0. Not deprecated in FA.
---@generic T
---@param list T[]
---@return integer
---@nodiscard
function table.getn(list) end

--- Calls function f with each key/value pair in table t as arguments.
--- Standard iteration function from Lua 5.0. Not deprecated in FA.
---@generic T
---@param list table
---@param callback fun(key: string, value: T): T|nil
---@return T|nil
function table.foreach(list, callback) end

--- Calls function f with each index/value pair in the sequence in table t.
--- Standard iteration function from Lua 5.0. Not deprecated in FA.
---@generic T
---@param list T[]
---@param callback fun(index: integer, value: T): T|nil
---@return T|nil
function table.foreachi(list, callback) end

--- Returns true if the table has no entries (neither hash nor array part).
--- FA-custom extension to the standard table library.
---@param t table
---@return boolean
---@nodiscard
function table.empty(t) end

--- Returns the number of entries in the hash part of the table (non-integer keys).
--- FA-custom extension equivalent to counting non-integer keys.
---@param t table
---@return integer
---@nodiscard
function table.getsize(t) end
