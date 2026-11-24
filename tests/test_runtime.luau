local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Runtime = luau.load(fs.readFile("src/runtime.lua"))()
for _,case in ipairs({{172800,"剩余 2 天"},{86400,"剩余 1 天"},{86399,"剩余 23 小时"},{3600,"剩余 1 小时"},{3599,"剩余 59 分钟"},{60,"剩余 1 分钟"},{59,"剩余不足 1 分钟"},{0,"已到期"},{-1,"已到期"}}) do
    assert(Runtime.remaining(case[1])==case[2])
end
assert(Runtime.remaining(nil)=="长期有效")
for _,value in ipairs({"bad",0/0,math.huge,-math.huge})do assert(Runtime.remaining(value)=="时间待同步")end
local gameInfo={id="demo",nameZh="中文游戏",nameEn="English Game"}
local demo={id="script",gameId="demo",universeIds={1},placeIds={2},game=gameInfo}
assert(Runtime.currentGame({demo},1,2)==gameInfo)
assert(Runtime.currentGame({demo},1,3)==gameInfo,"同游戏其他地图仍可识别游戏身份")
assert(Runtime.currentGame({demo},9,3)==nil)
assert(Runtime.currentGame({{id="common",gameId="demo",universal=true,game=gameInfo}},1,2)==nil)
assert(Runtime.currentGame({{id="wrong",gameId="other",placeIds={2},game=gameInfo}},1,2)==nil)
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
assert(Runtime.loadCountText(nil) == "已执行 0 次")
assert(Runtime.loadCountText(15) == "已执行 15 次")
assert(Runtime.loadCountText(-3) == "已执行 0 次")
assert(Runtime.keyBadgeText({requiresKey = true}) == "脚本需卡密")
assert(Runtime.keyBadgeText({requiresKey = false}) == "脚本免卡密")
assert(Runtime.keyBadgeText({}) == "卡密待同步")
assert(Runtime.keyBadgeText({requiresKey = "false"}) == "卡密待同步")
assert(Runtime.keyBadgeText(nil) == "卡密待同步")
local groups, currentGroup = Runtime.gameGroups({
    {id="other-1", gameId="beta", nameZh="Beta脚本", nameEn="Beta", placeIds={}, universeIds={99}, game={id="beta", nameZh="其他游戏Beta", nameEn="Beta Game"}},
    {id="uni-1", gameId="common", nameZh="通用1", nameEn="Uni1", universal=true, placeIds={}, universeIds={}},
    {id="cur-1", gameId="alpha", nameZh="当前1", nameEn="Cur1", placeIds={10}, universeIds={1}, game={id="alpha", nameZh="当前游戏Alpha", nameEn="Alpha Game"}},
}, 1, 10)
assert(#groups == 2 and groups[1] == currentGroup and currentGroup.isCurrent)
assert(currentGroup.nameZh == "当前游戏Alpha" and #currentGroup.scripts == 1 and #currentGroup.universalScripts == 1)
assert(groups[2].gameId == "beta" and not groups[2].isCurrent and groups[2].nameZh == "其他游戏Beta" and #groups[2].scripts == 1)
local client = fs.readFile("src/client.lua")
assert(luau.load("local API='https://TARGET'; local Runtime={};\n" .. client))
print("通过：生命周期、清理异常、晚到资源、搜索排序、租约及 Lua 编译")
