---@meta

-- FA's module system injects a `__moduleinfo` table into every module's
-- environment. Modules read it (`import(__moduleinfo.name)`) and assign
-- reload hooks onto it (`function __moduleinfo.OnDirty() ... end`), which
-- previously produced an `undefined-global` for every single use.

---@class ModuleInfo
---@field name string                       # this module's import path
---@field used_by table<string, boolean>    # modules that imported this one
---@field track_imports boolean             # whether import tracking is active
---@field OnDirty fun()?                    # user hook: module was invalidated
---@field OnReload fun(newModule: table)?   # user hook: module was hot-reloaded
__moduleinfo = {}
