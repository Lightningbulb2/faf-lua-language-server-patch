-- Under LuaFA these must NOT be flagged `deprecated`, even when the fa-lib
-- stdlib/ overrides are not loaded (userThirdParty layout). Fixed at the
-- meta-generation level in script/library.lua.
local a = table.getn({1, 2})
local b = table.foreach({}, function() end)
local c = table.foreachi({}, function() end)
-- These 5.3+ functions ARE correctly invalid/deprecated under LuaFA (5.1):
local d = table.move({}, 1, 2, 1)
