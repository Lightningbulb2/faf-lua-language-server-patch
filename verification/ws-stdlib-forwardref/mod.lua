-- test module using forward reference and stdlib
function CreateUI()
    local s = string.format("%03.1f", 1.5)
    local n = table.getn({1,2,3})
    UpdateUI()
    return s, n
end

function UpdateUI()
end

function StressStdlib(a)
    local x = math.mod(7, 3)
    local u1, u2 = unpack({1, 2})
    table.foreach({a=1}, function(k, v) end)
    table.foreachi({1,2}, function(i, v) end)
    for w in string.gfind("a b", "%a+") do print(w) end
    table.setn(a, 5)
    return x, u1, u2
end
