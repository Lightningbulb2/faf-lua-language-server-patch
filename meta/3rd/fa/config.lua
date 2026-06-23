-- if not set, the folder name will be used
name    = 'Forged Alliance'
-- match any word to load
words   = {'.'}
-- list of settings to be changed
---@type config.change[]
configs = {
    {
        key    = 'Lua.runtime.version',
        action = 'set',
        -- FAForever: FA uses a custom Lua 5.0/5.1-era runtime.
        -- LuaFA enables FA-specific stdlib stubs (no deprecated table.getn, etc.)
        value  = 'LuaFA',
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
}
-- FA engine globals: moho is the root C++ engine object;
-- arg is the Lua 5.0-style implicit vararg table used by the class system
for _, name in ipairs {'moho', 'arg'} do
    configs[#configs+1] = {
        key    = 'Lua.diagnostics.globals',
        action = 'add',
        value  = name,
    }
end
