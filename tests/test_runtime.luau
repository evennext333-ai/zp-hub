local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Runtime = luau.load(fs.readFile("src/runtime.lua"))()
for _,case in ipairs({{172800,"剩余 2 天"},{86400,"剩余 1 天"},{86399,"剩余 23 小时"},{3600,"剩余 1 小时"},{3599,"剩余 59 分钟"},{60,"剩余 1 分钟"},{59,"剩余不足 1 分钟"},{0,"已到期"},{-1,"已到期"}}) do
    assert(Runtime.remaining(case[1])==case[2])
end
assert(Runtime.remaining(nil)=="长期有效")
for _,value in ipairs({"bad",0/0,math.huge,-math.huge})do assert(Runtime.remaining(value)=="时间待同步")end
assert(Runtime.expiryDateText(nil, nil) == "长期有效")
assert(Runtime.expiryDateText("2027-04-08T16:05:33.375Z", 1807200333375) == "2027-04-09 00:05")
assert(Runtime.expiryDateText("invalid", "invalid") == "时间待同步")
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
assert(Runtime.deadline(100, 80) == 180 and Runtime.deadline(100, 300) == 400 and Runtime.deadline(100, 500) == 400)
assert(Runtime.deadline(100, 90) == 190 and Runtime.deadline(100, 95) == 195 and Runtime.deadline(100, 299.5) == 399.5)
assert(Runtime.deadline(100, 5) == 105, "临近权益到期的短租约不扩大到300秒")
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
assert(Runtime.compactCount(nil) == "0")
assert(Runtime.compactCount(-5) == "0")
assert(Runtime.compactCount(42) == "42")
assert(Runtime.compactCount(9999) == "9999")
assert(Runtime.compactCount(10000) == "1万")
assert(Runtime.compactCount(12500) == "1.2万" or Runtime.compactCount(12500) == "1.3万")
assert(Runtime.compactCount(20000) == "2万")
assert(Runtime.keyBadgeText({requiresKey = true}) == "🔑 需Key")
assert(Runtime.keyBadgeText({requiresKey = false}) == "免Key")
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
local hotGroups, hotCurrent = Runtime.gameGroups({
    {id="g-a1", gameId="game-a", nameZh="A1", nameEn="A1", loadCount=5, placeIds={}, universeIds={101}, game={id="game-a", nameZh="冷门游戏", nameEn="Cold"}},
    {id="g-c1", gameId="game-c", nameZh="C1", nameEn="C1", loadCount=60, placeIds={}, universeIds={103}, game={id="game-c", nameZh="爆火游戏", nameEn="Hot"}},
    {id="g-c2", gameId="game-c", nameZh="C2", nameEn="C2", loadCount=90, placeIds={}, universeIds={103}, game={id="game-c", nameZh="爆火游戏", nameEn="Hot"}},
    {id="g-b1", gameId="game-b", nameZh="B1", nameEn="B1", loadCount=80, placeIds={}, universeIds={102}, game={id="game-b", nameZh="次热游戏", nameEn="Warm"}},
    {id="g-z1", gameId="game-z", nameZh="Z1", nameEn="Z1", loadCount=0, placeIds={}, universeIds={104}, game={id="game-z", nameZh="零次游戏", nameEn="Zero"}},
    {id="cur-a", gameId="cur", nameZh="当前脚本", nameEn="Cur", loadCount=12, placeIds={10}, universeIds={1}, game={id="cur", nameZh="当前游戏", nameEn="Current"}},
}, 1, 10)
assert(hotGroups[1] == hotCurrent and hotCurrent.totalLoadCount == 12)
assert(hotGroups[2].gameId == "game-c" and hotGroups[2].totalLoadCount == 150 and hotGroups[2].hotRank == 1)
assert(hotGroups[2].scripts[1].id == "g-c2" and hotGroups[2].scripts[2].id == "g-c1", "同游戏内脚本也按执行次数降序排列")
assert(hotGroups[3].gameId == "game-b" and hotGroups[3].totalLoadCount == 80 and hotGroups[3].hotRank == 2)
assert(hotGroups[4].gameId == "game-a" and hotGroups[4].totalLoadCount == 5 and hotGroups[4].hotRank == 4)
assert(hotGroups[5].gameId == "game-z" and hotGroups[5].totalLoadCount == 0 and hotGroups[5].hotRank == nil)
assert(hotCurrent.hotRank == 3)
local compactGallery = Runtime.layout(793, 311, 1, 0, 21, true)
assert(compactGallery.compact and compactGallery.galleryHeight == compactGallery.height - compactGallery.galleryTop - 10)
assert(compactGallery.galleryHeight >= 2 * compactGallery.gameCardHeight + compactGallery.gap + 4, "紧凑模式全部游戏至少完整展示两排")
assert(compactGallery.galleryContentHeight >= 7 * compactGallery.gameCardHeight + 6 * compactGallery.gap + 24)
local desktopGallery = Runtime.layout(1040, 720, 1, 0, 21, true)
assert(not desktopGallery.compact and desktopGallery.galleryHeight == desktopGallery.footerY - desktopGallery.galleryTop - 6)
assert(desktopGallery.galleryContentHeight >= 7 * desktopGallery.gameCardHeight + 6 * desktopGallery.gap + 24)
local client = fs.readFile("src/client.lua")
assert(luau.load("local API='https://TARGET'; local Runtime={};\n" .. client))
print("通过：生命周期、清理异常、晚到资源、搜索排序、租约及 Lua 编译")
