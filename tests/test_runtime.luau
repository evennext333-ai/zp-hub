local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Runtime = luau.load(fs.readFile("src/runtime.lua"))()
local context = Runtime.lifecycle()
local events = {}
local target = { value = 1 }
context.onCleanup(function() table.insert(events, 1) end)
context.onCleanup(function() error("one cleanup fails") end)
context.override(target, "value", 2)
context.stop()
context.stop()
assert(not context.alive and target.value == 1 and #events == 1)
context.onCleanup(function() table.insert(events, 2) end)
assert(#events == 2, "停止后的启动结果也须清理")
local newer = Runtime.lifecycle()
newer.override(target, "value", 3)
target.value = 4
newer.stop()
assert(target.value == 4, "旧资源不覆盖新包装")
local scripts = {
    {id="other", gameId="other", nameZh="其他", nameEn="OTHER", tags={}, aliases={}, placeIds={}, universeIds={2}},
    {id="universal", gameId="demo", nameZh="通用", nameEn="Universal", universal=true, tags={}, aliases={}, placeIds={}, universeIds={}},
    {id="current", gameId="one", nameZh="中文", nameEn="Current", aliases={"别名"}, tags={"测试"}, placeIds={10}, universeIds={1}},
}
local sorted = Runtime.search(scripts, "", 1, 10)
assert(sorted[1].id == "current" and sorted[2].id == "universal")
assert(Runtime.search(scripts, "CURRENT", 1, 10)[1].id == "current")
assert(Runtime.search(scripts, "别名", 1, 10)[1].id == "current")
assert(#Runtime.search(scripts, "[", 1, 10) == 0, "搜索按字面匹配")
assert(Runtime.rank(scripts[3], 1, 11) == 1)
assert(Runtime.deadline(100, 80) == 180 and Runtime.deadline(100, 200) == 190)
assert(not pcall(Runtime.deadline, 100, 0))
assert(not pcall(Runtime.deadline, 100, 0/0))
local client = fs.readFile("src/client.lua")
assert(luau.load("local API='https://TARGET'; local Runtime={};\n" .. client))
print("通过：生命周期、清理异常、晚到资源、搜索排序、租约及 Lua 编译")
