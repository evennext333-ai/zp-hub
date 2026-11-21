local fs = require("@lune/fs")
local luau = require("@lune/luau")
local rb = require("@lune/roblox")
local serde = require("@lune/serde")
local task = require("@lune/task")
local process = require("@lune/process")
local Runtime = luau.load(fs.readFile("src/runtime.lua"))()
local objects = {}
local function signal()
    local callbacks = {}
    return {
        Connect = function(_, callback)
            local connection = { Connected = true }
            function connection:Disconnect() self.Connected = false end
            table.insert(callbacks, {callback, connection})
            return connection
        end,
        Fire = function()
            for _, entry in ipairs(callbacks) do if entry[2].Connected then entry[1]() end end
        end,
    }
end
local function create(class)
    local item = { ClassName = class, AbsoluteSize = rb.Vector2.new(600, 560), Activated = signal(), Destroying = signal(), signals = {} }
    function item:GetPropertyChangedSignal(name)
        if not self.signals[name] then self.signals[name] = signal() end
        return self.signals[name]
    end
    function item:Destroy()
        if self.destroyed then return end
        self.destroyed = true
        self.Destroying:Fire()
        for _, child in ipairs(objects) do if child.Parent == self then child:Destroy() end end
    end
    table.insert(objects, item)
    return item
end
local function find(text)
    local fallback
    for _, item in ipairs(objects) do
        if not item.destroyed and item.Text and string.find(item.Text, text, 1, true) then
            if item.ClassName == "TextButton" then return item end
            fallback = item
        end
    end
    if fallback then return fallback end
    error("控件缺失：" .. text)
end
local counter = { logins = 0, starts = 0, stops = 0, delete = 0 }
local generation = 0
local hubEnv = { HUB_KEY = "RSH_" .. string.rep("a", 43) }
local http = {
    JSONEncode = function(_, value) return serde.encode("json", value) end,
    JSONDecode = function(_, value) return serde.decode("json", value) end,
    GenerateGUID = function()
        generation += 1
        return string.format("00000000-0000-4000-8000-%012d", generation)
    end,
}
local active = "HS1.fixture"
local services = {
    HttpService = http,
    Players = { LocalPlayer = { WaitForChild = function() return {} end } },
}
local entry = {id="hall-7", gameId="demo", nameZh="授权检查", nameEn="Check", enabled=true, universal=true, lifecycle="managed", placeIds={}, universeIds={}, tags={}, aliases={}}
local server = { delayLoad = 0, delayHeartbeat = 1 }
local taskShim = { wait = task.wait, cancel = task.cancel }
local starts = 0
function taskShim.spawn(callback, ...)
    starts += 1
    if process.env.HUB_TEST_STARVE_WATCHDOG == "1" and starts == 1 then
        return task.spawn(function(...)
            task.wait(2)
            callback(...)
        end, ...)
    end
    return task.spawn(callback, ...)
end
local environment = {
    Runtime = Runtime, API = "https://TARGET", task = taskShim,
    game = { GameId = 1, PlaceId = 2, GetService = function(_, name) return services[name] end },
    getgenv = function() return hubEnv end,
    gethwid = function() return "fixture-device" end,
    Instance = { new = create }, UDim2 = rb.UDim2, UDim = rb.UDim,
    Vector2 = rb.Vector2, Color3 = rb.Color3, Enum = rb.Enum,
    counters = counter,
}
environment.request = function(args)
    if not args.Body then assert(args.Headers["Content-Type"] == nil, "空请求不声明 JSON 正文，保留真实退出请求兼容性") end
    local data
    if args.Url:find("/catalog", 1, true) then
        data = { version = "hall-fixture", scripts = { entry } }
    elseif args.Url:find("/heartbeat", 1, true) then
        local body = serde.decode("json", args.Body)
        task.wait(server.delayHeartbeat)
        data = { sessionId = "fixture", sequence = body.sequence, remainingLeaseSeconds = 90 }
    elseif args.Url:find("/load", 1, true) then
        assert(args.Url:find("/api/hub/scripts/hall-7/load", 1, true), "使用目录返回的大厅脚本 ID")
        task.wait(server.delayLoad)
        data = { id = entry.id, version = "hall-7-r1", source = "local c=...; counters.starts+=1; c.onCleanup(function() counters.stops+=1 end)" }
    elseif args.Method == "DELETE" then
        task.wait(0.1)
        counter.delete += 1
        data = serde.null
    else
        counter.logins += 1
        data = {token=active, sessionId="fixture", remainingLeaseSeconds=0.5, kind="GAME"}
    end
    return { StatusCode = 200, Body = serde.encode("json", {success=true, data=data}) }
end
environment.loadstring = function(source)
    return luau.load(source, { environment = environment })
end
local client = luau.load(fs.readFile(process.env.HUB_TEST_LOADER or "src/client.lua"), { environment = environment })
client()
assert(hubEnv.HUB_KEY == nil, "外部 Key 使用后应清理")
find("校验 Key").Activated:Fire()
task.wait(0.05)
assert(counter.logins == 1)
find("授权检查").Activated:Fire()
task.wait(0.1)
assert(counter.starts == 1)
find("收起 Hub").Activated:Fire()
assert(find("打开 Hub"), "收起后保留恢复入口")
client()
assert(counter.logins == 1, "重复入口不应新登录顶号")
assert(find("收起 Hub"), "重复入口恢复现有界面")
task.wait(1.4)
assert(counter.stops == 1, "心跳挂起时看门狗仍须停止脚本")
assert(find("租约已到期"), "晚到的成功心跳不应恢复已终止会话")
local keyBox
for _, item in ipairs(objects) do if item.PlaceholderText and item.PlaceholderText:find("Key 已清理", 1, true) then keyBox = item end end
assert(keyBox)
keyBox.Text = "RSH_" .. string.rep("b", 43)
find("校验 Key").Activated:Fire()
task.wait(0.05)
server.delayLoad = 0.3
find("授权检查").Activated:Fire()
task.wait(0.05)
find("停止脚本").Activated:Fire()
task.wait(0.35)
assert(counter.starts == 1, "停止后晚到的下载不应再执行")
find("退出 Hub").Activated:Fire()
task.wait(0.2)
assert(not hubEnv.__RSZH_HUB, "退出后释放单实例占位")
assert(counter.delete == 1, "界面关闭后仍须发送退出请求")
client()
assert(hubEnv.__RSZH_HUB)
for _, item in ipairs(objects) do
    if item.Name == "RSZH_Hub" and not item.destroyed then item:Destroy() end
end
assert(not hubEnv.__RSZH_HUB, "界面被外部销毁后也须释放占位")
print("通过：真实客户端模拟登录、单实例、挂起心跳、看门狗、晚到响应与下载、退出清理")
