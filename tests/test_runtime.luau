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
    {id="current", gameId="one", nameZh="中文", nameEn="Current", scenario="自动收集与快捷导航", aliases={"别名"}, tags={"测试"}, placeIds={10}, universeIds={1}},
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
assert(Runtime.search(scripts, "快捷导航", 1, 10)[1].id == "current")
assert(Runtime.scenario({}) == "场景信息待接口同步")
assert(Runtime.scenario({scenario="  多行\n  简介  "}) == "多行 简介")
for _,screen in ipairs({{1040,720,3},{962,691,3},{793,351,3},{627,337,3},{640,300,3}}) do
    for _,count in ipairs({0,1,3,30,500}) do
        local layout=Runtime.layout(screen[1],screen[2],count)
        assert(layout.columns==screen[3] and layout.width>layout.height)
        assert(layout.width*layout.scale<=screen[1]+0.01 and layout.height*layout.scale<=screen[2]+0.01)
        assert(layout.cellWidth*layout.columns+layout.gap*(layout.columns-1)<=layout.mainWidth-8)
        assert(layout.cellWidth>=1 and layout.gridHeight>=48)
        assert(layout.gridContentHeight>=0)
    end
end
assert(Runtime.scenario({scenario="  "}) == "未设置场景")
assert(Runtime.scenario({shortDescription="不要展示简介"}) == "场景信息待接口同步")
local client = fs.readFile("src/client.lua")
assert(luau.load("local API='https://TARGET'; local Runtime={};\n" .. client))
print("通过：生命周期、清理异常、晚到资源、搜索排序、租约及 Lua 编译")
