-- API 与 Runtime 由离线构建注入；首版只有一个国内 API。
local env = (type(getgenv) == "function" and getgenv()) or _G
local existing = env.__RSZH_HUB
if type(existing) == "table" and existing.alive then
    existing.focus()
    return
end
local Http = game:GetService("HttpService")
local Players = game:GetService("Players")
local guiParent = Players.LocalPlayer:WaitForChild("PlayerGui", 10)
assert(guiParent, "玩家界面尚未就绪，请稍后重试")
local requestFn = request or http_request or (syn and syn.request) or (http and http.request)
assert(type(requestFn) == "function", "运行环境需要支持 HTTPS POST 和请求头")
assert(type(loadstring) == "function", "运行环境需要支持 loadstring")
local uiContext = Runtime.lifecycle()
local owner = { alive = true }
local pendingKey = type(env.HUB_KEY) == "string" and env.HUB_KEY or ""
env.HUB_KEY = nil
local token, leaseUntil, sessionId = nil, 0, nil
local current, loading, loginBusy, requestSequence = nil, false, false, 0
local catalog = {}
local errors = {
    HUB_KEY_INVALID = "Key 无效或已重置", HUB_LICENSE_REVOKED = "权益已吊销",
    HUB_LICENSE_EXPIRED = "单游戏权益已到期", HUB_VIP_REQUIRED = "会员已到期或未开通",
    HUB_SESSION_REPLACED = "此 Key 已在其他实例或设备登录", HUB_SESSION_EXPIRED = "会话已过期",
    HUB_GAME_NOT_MATCHED = "此 Key 与当前游戏或地图不匹配", HUB_GAME_NOT_GRANTED = "此 Key 未包含该游戏",
    HUB_SCRIPT_UNAVAILABLE = "脚本尚未上架", HUB_KEY_EXISTS = "已有 Key，遗失后请在领取页重置",
    NETWORK_ERROR = "网络暂时异常", INVALID_RESPONSE = "服务响应异常",
}
local function errorText(code) return errors[code] or tostring(code or "未知错误") end

local function object(className, properties, parent)
    local item = Instance.new(className)
    for key, value in pairs(properties) do item[key] = value end
    item.Parent = parent
    return item
end
local gui = object("ScreenGui", { Name = "RSZH_Hub", ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, guiParent)
uiContext.onCleanup(function() gui:Destroy() end)
local panel = object("ScrollingFrame", {
    AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.new(0.92, 0, 0.85, 0), BackgroundColor3 = Color3.fromRGB(20, 25, 36),
    CanvasSize = UDim2.fromOffset(0, 438), AutomaticCanvasSize = Enum.AutomaticSize.Y, Visible = true,
    ScrollBarThickness = 4, BorderSizePixel = 0,
}, gui)
object("UISizeConstraint", { MaxSize = Vector2.new(620, 560) }, panel)
object("UICorner", { CornerRadius = UDim.new(0, 12) }, panel)
local function label(text, y, height)
    return object("TextLabel", {
        Position = UDim2.new(0, 16, 0, y), Size = UDim2.new(1, -32, 0, height),
        BackgroundTransparency = 1, Text = text, TextColor3 = Color3.fromRGB(230, 235, 245),
        TextSize = 16, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left,
    }, panel)
end
label("脚本 Hub · 国内版", 10, 30)
label("当前游戏 " .. tostring(game.GameId) .. " / 地图 " .. tostring(game.PlaceId), 44, 28)
local status = label("正在获取正式目录…", 78, 60)
local function input(placeholder, y)
    return object("TextBox", {
        Position = UDim2.new(0, 16, 0, y), Size = UDim2.new(1, -32, 0, 38),
        BackgroundColor3 = Color3.fromRGB(34, 42, 58), TextColor3 = Color3.new(1, 1, 1),
        PlaceholderColor3 = Color3.fromRGB(170, 181, 200), TextSize = 16,
        PlaceholderText = placeholder, Text = "", ClearTextOnFocus = false,
    }, panel)
end
local keyBox = input(pendingKey ~= "" and "已读取外部 Key" or "输入 Key 或设置 HUB_KEY", 144)
local searchBox = input("搜索名称、别名或标签", 238)
local function button(text, x, width)
    return object("TextButton", {
        Position = UDim2.new(x, 16, 0, 192), Size = UDim2.new(width, -24, 0, 36),
        BackgroundColor3 = Color3.fromRGB(47, 82, 140), TextColor3 = Color3.new(1, 1, 1),
        TextSize = 15, Text = text, Selectable = true,
    }, panel)
end
local loginButton, stopButton, exitButton = button("校验 Key", 0, 1/3), button("停止脚本", 1/3, 1/3), button("退出 Hub", 2/3, 1/3)
local toggle = object("TextButton", {
    Position = UDim2.new(1, -128, 0, 12), Size = UDim2.fromOffset(116, 38),
    BackgroundColor3 = Color3.fromRGB(47, 82, 140), TextColor3 = Color3.new(1, 1, 1),
    TextSize = 16, Text = "收起 Hub", Selectable = true,
}, gui)
local list = object("ScrollingFrame", {
    Position = UDim2.new(0, 16, 0, 288), Size = UDim2.new(1, -32, 0, 140),
    BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 6,
    AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(),
}, panel)
object("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, list)
local cards = {}
owner.focus = function() gui.Enabled = true panel.Visible = true toggle.Text = "收起 Hub" end
env.__RSZH_HUB = owner
uiContext.onCleanup(function()
    if env.__RSZH_HUB == owner then env.__RSZH_HUB = nil end
end)
local function connect(signal, callback)
    local connection = signal:Connect(callback)
    uiContext.onCleanup(function() connection:Disconnect() end)
end
local function fitList()
    list.Size = UDim2.new(1, -32, 0, math.max(140, panel.AbsoluteSize.Y - 304))
end
connect(panel:GetPropertyChangedSignal("AbsoluteSize"), fitList)
fitList()
connect(toggle.Activated, function()
    panel.Visible = not panel.Visible
    toggle.Text = panel.Visible and "收起 Hub" or "打开 Hub"
end)
local function setStatus(text)
    if owner.alive then status.Text = text end
end
local function stopScript()
    local running = current
    current = nil
    if running then running.stop() end
end
local function terminate(message)
    token, sessionId, leaseUntil = nil, nil, 0
    stopScript()
    setStatus(message .. "；请重新填写 Key 后校验")
end

local function api(method, path, body, bearer, allowClosed)
    local finished, response = false, nil
    local started = os.clock()
    local thread = task.spawn(function()
        local headers = { ["Content-Type"] = "application/json" }
        if bearer then headers.Authorization = "Bearer " .. bearer end
        local args = { Url = API .. path, Method = method, Headers = headers }
        if body then args.Body = Http:JSONEncode(body) end
        local ok, result = pcall(requestFn, args)
        if ok and type(result) == "table" then response = result end
        finished = true
    end)
    while not finished and (owner.alive or allowClosed) and os.clock() - started < 10 do task.wait(0.05) end
    if not finished then
        pcall(task.cancel, thread)
        return nil, "NETWORK_ERROR", started
    end
    if not response then return nil, "NETWORK_ERROR", started end
    local code = tonumber(response.StatusCode or response.Status or response.status_code) or 0
    if code >= 500 or code == 429 or code == 0 then return nil, "NETWORK_ERROR", started end
    local ok, decoded = pcall(Http.JSONDecode, Http, response.Body or response.body or "")
    if not ok or type(decoded) ~= "table" then return nil, "INVALID_RESPONSE", started end
    if code >= 200 and code < 300 and decoded.success == true then return decoded.data, nil, started end
    return nil, type(decoded.error) == "table" and decoded.error.code or "REQUEST_FAILED", started
end

local function login()
    if token and os.clock() < leaseUntil then return true end
    if loginBusy then return false end
    local key = keyBox.Text ~= "" and keyBox.Text or pendingKey
    key = key:match("^%s*(.-)%s*$")
    if key == "" then setStatus("请先填写 Key") return false end
    local hwidFn = gethwid or getexecutorhwid
    if type(hwidFn) ~= "function" then setStatus("此运行环境缺少 HWID 接口") return false end
    local ok, hwid = pcall(hwidFn)
    if not ok or type(hwid) ~= "string" or #hwid < 1 or #hwid > 512 then
        setStatus("设备标识无效，请检查运行环境")
        return false
    end
    loginBusy = true
    keyBox.Text, pendingKey = "", ""
    keyBox.PlaceholderText = "Key 已清理，请重新填写"
    setStatus("正在校验授权…")
    local body = { key = key, hwid = hwid, requestId = Http:GenerateGUID(false), universeId = game.GameId, placeId = game.PlaceId }
    local data, err, sent = api("POST", "/api/hub/sessions", body)
    if err == "NETWORK_ERROR" and owner.alive then
        data, err, sent = api("POST", "/api/hub/sessions", body)
    end
    body.key, key = nil, nil
    loginBusy = false
    if not owner.alive then return false end
    if not data or type(data.token) ~= "string" or type(data.sessionId) ~= "string" then
        setStatus("校验未完成：" .. errorText(err or "INVALID_RESPONSE"))
        return false
    end
    local valid, deadline = pcall(Runtime.deadline, sent, data.remainingLeaseSeconds)
    if not valid or os.clock() >= deadline then setStatus("登录响应已过期，请重新校验") return false end
    token, sessionId, leaseUntil = data.token, data.sessionId, deadline
    requestSequence = 0
    setStatus("授权有效 · " .. (data.kind == "MEMBER" and "全游戏会员" or "单游戏 30 天") .. " · 到期 " .. tostring(data.entitlementExpiresAt or "长期"))
    return true
end

local function run(script)
    if loading or not owner.alive then return end
    if not script.enabled then setStatus("此脚本仍在适配或游戏内验收阶段") return end
    if not script.universal and Runtime.rank(script, game.GameId, game.PlaceId) > 0 then
        setStatus("此脚本与当前游戏或地图不匹配")
        return
    end
    loading = true
    if not login() then loading = false return end
    stopScript()
    local context = Runtime.lifecycle()
    current = context
    local activeToken = token
    setStatus("正在下载 " .. script.nameZh .. "…")
    local data, err = api("POST", "/api/hub/scripts/" .. script.id .. "/load", {}, activeToken)
    if not owner.alive or not context.alive or token ~= activeToken then loading = false return end
    if os.clock() >= leaseUntil then terminate("运行租约已到期") loading = false return end
    if not data or type(data.source) ~= "string" then
        context.stop()
        setStatus("加载失败：" .. errorText(err or "INVALID_RESPONSE"))
        loading = false
        return
    end
    local fn = loadstring(data.source, "=Hub/" .. script.id)
    if not fn then context.stop() setStatus("脚本编译失败") loading = false return end
    local ok, cleanup = pcall(fn, context)
    if ok and type(cleanup) == "function" then context.onCleanup(cleanup) end
    if not ok then
        context.stop()
        setStatus("脚本启动失败，已执行清理")
    elseif context.alive then
        setStatus("运行中：" .. script.nameZh)
    end
    loading = false
end

local function render()
    for _, card in ipairs(cards) do card:Destroy() end
    table.clear(cards)
    local filtered = Runtime.search(catalog, searchBox.Text, game.GameId, game.PlaceId)
    for index, script in ipairs(filtered) do
        local rank = Runtime.rank(script, game.GameId, game.PlaceId)
        local prefix = rank == 0 and "当前游戏 · " or (script.universal and "通用 · " or "")
        local card = object("TextButton", {
            Size = UDim2.new(1, -8, 0, 56), LayoutOrder = index, TextSize = 16,
            TextColor3 = script.enabled and Color3.new(1, 1, 1) or Color3.fromRGB(160, 170, 190),
            BackgroundColor3 = Color3.fromRGB(34, 42, 58), TextWrapped = true,
            Text = prefix .. script.nameZh .. (script.enabled and "  · 加载" or "  · 待适配"),
            Selectable = true,
        }, list)
        card.Activated:Connect(function() task.spawn(run, script) end)
        table.insert(cards, card)
    end
    if #filtered == 0 then setStatus("没有匹配的脚本") end
end

connect(loginButton.Activated, function() task.spawn(login) end)
connect(stopButton.Activated, function() stopScript() setStatus("脚本已停止，授权会话保持在线") end)
connect(searchBox:GetPropertyChangedSignal("Text"), render)
local function closeHub()
    if not owner.alive then return end
    local oldToken = token
    terminate("已退出")
    owner.alive = false
    uiContext.stop()
    task.spawn(function()
        if oldToken then api("DELETE", "/api/hub/sessions/current", nil, oldToken, true) end
    end)
end
connect(exitButton.Activated, closeHub)
connect(gui.Destroying, closeHub)

-- 看门狗独立于 HTTP 心跳；请求挂起时也按本地截止时间停止。
task.spawn(function()
    while owner.alive do
        if token and os.clock() >= leaseUntil then terminate("授权连接中断，租约已到期") end
        task.wait(0.2)
    end
end)
task.spawn(function()
    local nextHeartbeat = 0
    while owner.alive do
        if token and os.clock() >= nextHeartbeat then
            local activeToken, activeId = token, sessionId
            requestSequence += 1
            local sequence = requestSequence
            local data, err, sent = api("POST", "/api/hub/sessions/heartbeat", { sequence = sequence }, activeToken)
            if owner.alive and token == activeToken and sessionId == activeId then
                if os.clock() >= leaseUntil then
                    terminate("运行租约已到期")
                elseif data and data.sessionId == activeId and data.sequence == sequence then
                    local ok, deadline = pcall(Runtime.deadline, sent, data.remainingLeaseSeconds)
                    if ok and os.clock() < deadline then leaseUntil = deadline else terminate("租约响应已过期") end
                elseif err ~= "NETWORK_ERROR" then
                    terminate("授权已失效：" .. errorText(err or "INVALID_RESPONSE"))
                end
            end
            nextHeartbeat = os.clock() + (err == "NETWORK_ERROR" and 3 or 28 + math.random() * 4)
        end
        task.wait(0.2)
    end
end)
local data, err = api("GET", "/api/hub/catalog")
if data and type(data.scripts) == "table" then
    catalog = data.scripts
    render()
    setStatus("目录已就绪，请校验 Key；灰色脚本仍待适配")
else
    setStatus("目录下载失败：" .. errorText(err))
end
