local channel  = require 'bee.channel'
local platform = require 'bee.platform'

-- Platform abstraction: bee.epoll on Linux/macOS, bee.select on Windows.
-- Both modules expose create(), event_add(fd, flags), wait(), but use
-- different flag constants (EPOLLIN vs SELECT_READ).
local poller_lib
local POLLIN
if platform.os == 'windows' then
    poller_lib = require 'bee.select'
    POLLIN = poller_lib.SELECT_READ
else
    poller_lib = require 'bee.epoll'
    POLLIN = poller_lib.EPOLLIN
end

local reqPad
local resPad

---@class pub_brave
local m = {}
m.type = 'brave'
m.ability = {}
m.queue = {}

--- 注册成为勇者
---@param id integer
---@param taskChName string
---@param replyChName string
function m.register(id, taskChName, replyChName)
    m.id = id

    reqPad = channel.query(taskChName)
    resPad = channel.query(replyChName)

    assert(reqPad, 'task channel not found: ' .. taskChName)
    assert(resPad, 'reply channel not found: ' .. replyChName)

    if #m.queue > 0 then
        for _, info in ipairs(m.queue) do
            resPad:push(info.name, info.params)
        end
    end
    m.queue = nil

    m.start()
end

--- 注册能力
function m.on(name, callback)
    m.ability[name] = callback
end

--- 报告
function m.push(name, params)
    if m.id and resPad then
        resPad:push(name, params)
    else
        m.queue[#m.queue+1] = {
            name   = name,
            params = params,
        }
    end
end

--- 开始找工作
function m.start()
    -- bee.select.create() takes no args; bee.epoll.create() takes maxevents
    local epfd <close> = assert(
        platform.os == 'windows' and poller_lib.create()
                                  or poller_lib.create(16)
    )
    epfd:event_add(reqPad:fd(), POLLIN)

    m.push('mem', collectgarbage 'count')
    while true do
        for _, event in epfd:wait() do
            if event & POLLIN ~= 0 then
                local ok, name, id, params = reqPad:pop()
                if ok then
                    local ability = m.ability[name]
                    if not ability then
                        resPad:push(id)
                        log.error('Brave can not handle this work: ' .. name)
                        goto CONTINUE
                    end
                    local suc, res = xpcall(ability, log.error, params)
                    if suc then
                        resPad:push(id, res)
                    else
                        resPad:push(id)
                    end
                    m.push('mem', collectgarbage 'count')
                    ::CONTINUE::
                end
            end
        end
    end
end

return m
