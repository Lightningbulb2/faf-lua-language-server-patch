local files   = require 'files'
local vm      = require 'vm'
local lang    = require 'language'
local guide   = require 'parser.guide'
local await   = require 'await'

local skipCheckClass = {
    ['unknown']       = true,
    ['any']           = true,
    ['table']         = true,
    -- FAForever: FA's Class/ClassUI generic T inference can produce 'function' views
    -- when the class constructor type (fun(specs:T):T|Base) is partially resolved.
    -- The old fa-lua-language-server skipped all of these; we keep the same set to
    -- avoid spurious undefined-field false-positives on FA class method call sites.
    ['nil']           = true,
    ['number']        = true,
    ['integer']       = true,
    ['boolean']       = true,
    ['function']      = true,
    ['userdata']      = true,
    ['lightuserdata'] = true,
}

-- FAForever: names of FA class initialisation methods.
-- Inside these functions the class table is still being constructed, so
-- LuaLS cannot always resolve every sibling method that is defined later
-- in the same table literal.  We skip undefined-field for getfield /
-- getmethod nodes whose innermost enclosing function is one of these.
local faInitMethods = {
    ['__init']      = true,
    ['__post_init'] = true,
}

--- FAForever: returns true when `src` lives inside an FA class init function
--- (or inside any closure nested within one).
---
--- The AST path for a direct call is:
---   src (getmethod/getfield) → call → func (__init function)
---     → tablefield { field='__init', value=func } → table → ...
---
--- For closures inside __init the direct parent function is the closure,
--- not __init itself. We therefore walk ALL ancestor functions until we find
--- one whose tablefield key is '__init' / '__post_init', or until we reach
--- the file root (main chunk).
local function isInsideFAInit(src)
    local obj = src
    for _ = 1, 1000 do
        -- walk up to the next enclosing function
        local fn = guide.getParentFunction(obj)
        if not fn then
            return false
        end
        -- stop at the file root
        if fn.type == 'main' then
            return false
        end
        -- check whether this function IS the __init / __post_init body
        local tf = fn.parent           -- tablefield { field=<key>, value=fn }
        if tf and tf.type == 'tablefield' then
            local field = tf.field     -- the key token; field[1] is its string name
            if field and faInitMethods[field[1]] then
                return true
            end
        end
        -- not a match at this level: continue walking up from the function node
        obj = fn
    end
    return false
end

---@async
return function (uri, callback)
    local ast = files.getState(uri)
    if not ast then
        return
    end

    ---@async
    local function checkUndefinedField(src)
        await.delay()

        if vm.hasDef(src) then
            return
        end
        -- FAForever: suppress inside __init / __post_init bodies (and closures
        -- nested within them) to avoid false-positives on sibling methods that
        -- are defined later in the same class table literal.
        if isInsideFAInit(src) then
            return
        end
        local node = src.node
        if node then
            local ok
            for view in vm.getInfer(node):eachView(uri) do
                if skipCheckClass[view] then
                    return
                end
                ok = true
            end
            if not ok then
                return
            end
        end
        local message = lang.script('DIAG_UNDEF_FIELD', guide.getKeyName(src))
        if     src.type == 'getfield' and src.field then
            callback {
                start   = src.field.start,
                finish  = src.field.finish,
                message = message,
            }
        elseif src.type == 'getmethod' and src.method then
            callback {
                start   = src.method.start,
                finish  = src.method.finish,
                message = message,
            }
        end
    end
    ---@async
    local function checkUndefinedFieldByIndexEnum(src)
        await.delay()
        local isEnum = false
        for _, node in ipairs(vm.compileNode(src.node)) do
            local docs = node.bindDocs
            if docs then
                for _, doc in ipairs(docs) do
                    if doc.type == "doc.enum" then
                        isEnum = true
                        break
                    end
                end
            end
        end
        if not isEnum then
            return
        end
        if vm.hasDef(src) then
            return
        end
        local keyName = guide.getKeyName(src)
        if not keyName then
            return
        end
        local message = lang.script('DIAG_UNDEF_FIELD', guide.getKeyName(src))
        callback {
            start   = src.index.start,
            finish  = src.index.finish,
            message = message,
        }
    end
    guide.eachSourceType(ast.ast, 'getfield',  checkUndefinedField)
    guide.eachSourceType(ast.ast, 'getmethod', checkUndefinedField)
    guide.eachSourceType(ast.ast, 'getindex', checkUndefinedFieldByIndexEnum)
end
