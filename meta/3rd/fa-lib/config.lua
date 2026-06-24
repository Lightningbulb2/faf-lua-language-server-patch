-- if not set, the folder name will be used
name    = 'Forged Alliance'
-- match any word to load 
words   = {'.'}
-- lsit of settings to be changed
---@type config.change[]
configs = {
    {
        key    = 'Lua.runtime.version',
        action = 'set',
        value  = 'Lua 5.1',
    },
    {
        key    = 'Lua.runtime.path',
        action = 'add',
        value  = '/?',
    },
    {
        key    = 'Lua.completion.showWord',
        action = 'set',
        value  = 'Disable',
    },
    {
        key    = 'Lua.runtime.special',
        action = 'prop',
        prop   = 'import',
        value  = 'require',
    },
    {
        key    = 'Lua.runtime.special',
        action = 'prop',
        prop   = 'doscript',
        value  = 'require',
    },
    {
        key    = 'Lua.runtime.nonstandardSymbol',
        action = 'add',
        value  = 'continue',
    },
    {
        key    = 'Lua.runtime.nonstandardSymbol',
        action = 'add',
        value  = '!=',
    },
    {
        key    = 'Lua.completion.requireSeparator',
        action = 'set',
        value  = '/',
    },
    {
        key    = 'Lua.runtime.pathStrict',
        action = 'set',
        value  = false,
    },
    {
        key    = 'Lua.runtime.exportEnvDefault',
        action = 'set',
        value  = true,
    },
    -- FAForever: FA code routinely stores extra fields on engine-typed objects
    -- (Bitmap, Control, Group, etc.) at runtime — e.g. attaching a `textures`
    -- table to a Bitmap drag handle, or caching computed values on a unit.
    -- These are legitimate patterns that the engine relies on; they cannot be
    -- declared in the stub files because the engine C++ type is closed.
    -- inject-field would fire on every such assignment, so we disable it.
    {
        key    = 'Lua.diagnostics.disable',
        action = 'add',
        value  = 'inject-field',
    },
}
for _, name in ipairs {'moho'} do
    configs[#configs+1] = {
        key    = 'Lua.diagnostics.globals',
        action = 'add',
        value  = name,
    }
end
