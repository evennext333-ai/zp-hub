-- API 与 Runtime 由离线构建注入；首版只有一个国内 API。
local env = (type(getgenv) == "function" and getgenv()) or _G
local pendingKey = type(env.HUB_KEY) == "string" and env.HUB_KEY:match("^%s*(.-)%s*$") or ""
env.HUB_KEY = nil
local existing = env.__RSZH_HUB
if type(existing) == "table" and existing.alive then
    assert(existing.policy == "background-v1", "Hub 会话策略已更新，请先重新进入游戏再加载")
    existing.focus()
    if pendingKey ~= "" then
        if type(existing.submitKey) == "function" then existing.submitKey(pendingKey)
        else warn("[ZS Hub] 当前实例为旧版，请重新进入游戏后加载新版并自动校验 Key") end
    end
    pendingKey = ""
    return
end
local Http = game:GetService("HttpService")
local Players = game:GetService("Players")
local player = Players.LocalPlayer
local kickPlayer = player.Kick
assert(type(kickPlayer) == "function", "运行环境需要支持结束当前游戏会话")
local requestFn = request or http_request or (syn and syn.request) or (http and http.request)
assert(type(requestFn) == "function", "运行环境需要支持 HTTPS POST 和请求头")
assert(type(loadstring) == "function", "运行环境需要支持 loadstring")
local owner = { alive = true, policy = "background-v1" }
local token, leaseUntil, sessionId = nil, 0, nil
local scriptStarted, loading, loginBusy, requestSequence = false, false, false, 0
local endSession, login, run, mountUI
local view, mountingUI = nil, false
local statusMessage = "正在获取正式目录…"
local catalog = {}
local loadCounts = {}
local selectedGroupKey = "current"
local currentMode = "detail" -- "detail" (游戏详情+脚本页) 或 "gallery" (全部游戏大画廊海报墙)
local entitlement, activeScriptId, loadingScriptId = nil, nil, nil
local errors = {
    HUB_KEY_INVALID = "Key 无效或已重置", HUB_LICENSE_REVOKED = "权益已吊销",
    HUB_LICENSE_EXPIRED = "单游戏权益已到期", HUB_VIP_REQUIRED = "会员已到期或未开通",
    HUB_SESSION_REPLACED = "此 Key 已在其他实例或设备登录", HUB_SESSION_EXPIRED = "会话已过期",
    HUB_GAME_NOT_MATCHED = "此 Key 与当前游戏或地图不匹配", HUB_GAME_NOT_GRANTED = "此 Key 未包含该游戏",
    HUB_SCRIPT_UNAVAILABLE = "脚本尚未上架", HUB_KEY_EXISTS = "已有 Key，遗失后请在领取页重置",
    NETWORK_ERROR = "网络暂时异常", INVALID_RESPONSE = "服务响应异常",
}
local function errorText(code) return errors[code] or tostring(code or "未知错误") end
local authorizationErrors = {
    HUB_KEY_INVALID = true, HUB_LICENSE_REVOKED = true, HUB_LICENSE_INVALID = true,
    HUB_LICENSE_EXPIRED = true, HUB_VIP_REQUIRED = true, HUB_SESSION_REPLACED = true,
    HUB_SESSION_EXPIRED = true, HUB_SESSION_INVALID = true,
}

local function getScriptLoadCount(script)
    local tracked = loadCounts[script.id]
    if tracked ~= nil then return tracked end
    return math.max(0, math.floor(tonumber(script.loadCount) or 0))
end

local function refreshView()
    if view and view.context.alive then
        local currentView = view
        local ok = pcall(currentView.refresh)
        if not ok then
            currentView.destroy()
            warn("[ZS Hub] 界面更新失败，请重新加载入口；后台授权监控继续")
        end
    end
end

local function setStatus(value)
    statusMessage = value
    refreshView()
end

local function terminate(message)
    endSession(message)
end

local function api(method, path, body, bearer, allowClosed)
    local finished, response = false, nil
    local started = os.clock()
    local thread = task.spawn(function()
        local headers = {}
        if body then headers["Content-Type"] = "application/json" end
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

local function logout(oldToken)
    if oldToken then
        task.spawn(function() api("DELETE", "/api/hub/sessions/current", nil, oldToken, true) end)
    end
end

login = function(inputKey)
    if not owner.alive then return false end
    if token then
        if os.clock() < leaseUntil then return true end
        terminate("授权连接中断，租约已到期")
        return false
    end
    if loginBusy then return false end
    local key = type(inputKey) == "string" and inputKey ~= "" and inputKey or pendingKey
    inputKey = nil
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
    pendingKey = ""
    if view then
        view.keyBox.Text = ""
        view.keyBox.PlaceholderText = "请重新输入 Key"
    end
    setStatus("正在校验授权…")
    local body = { key = key, hwid = hwid, requestId = Http:GenerateGUID(false), universeId = game.GameId, placeId = game.PlaceId }
    -- 手动结束本局后仍接收已发出的登录结果，再尽力注销晚到的会话。
    local data, err, sent = api("POST", "/api/hub/sessions", body, nil, true)
    if err == "NETWORK_ERROR" and owner.alive then
        data, err, sent = api("POST", "/api/hub/sessions", body, nil, true)
    end
    body.key, key = nil, nil
    loginBusy = false
    if view then view.dismissAuthPrompt() end
    if not owner.alive then
        if data and type(data.token) == "string" then logout(data.token) end
        return false
    end
    if not data or type(data.token) ~= "string" or type(data.sessionId) ~= "string" then
        setStatus("校验未完成：" .. errorText(err or "INVALID_RESPONSE"))
        return false
    end
    local valid, deadline = pcall(Runtime.deadline, sent, data.remainingLeaseSeconds)
    if not valid or os.clock() >= deadline then
        logout(data.token)
        setStatus("登录响应已过期，请重新校验")
        return false
    end
    token, sessionId, leaseUntil = data.token, data.sessionId, deadline
    entitlement = { kind = data.kind, gameId = data.gameId, expiresAt = data.entitlementExpiresAt }
    requestSequence = 0
    setStatus("授权有效 · " .. (data.kind == "MEMBER" and "全游戏会员" or "单游戏 30 天"))
    return true
end

run = function(script)
    if not owner.alive then return end
    if not token then setStatus("请先校验 Key 后再加载脚本") return end
    if os.clock() >= leaseUntil then terminate("运行租约已到期") return end
    if scriptStarted then setStatus("本局已启动脚本；切换或重载请结束本局后重新进入游戏") return end
    if loading then return end
    if not script.enabled then setStatus("此脚本仍待接入验收") return end
    if not script.universal and Runtime.rank(script, game.GameId, game.PlaceId) > 0 then
        setStatus("此脚本与当前游戏或地图不匹配")
        return
    end
    loading = true
    loadingScriptId = script.id
    local activeToken = token
    setStatus("正在下载 " .. script.nameZh .. "…")
    local data, err = api("POST", "/api/hub/scripts/" .. script.id .. "/load", {}, activeToken)
    if not owner.alive or token ~= activeToken then loading = false return end
    if os.clock() >= leaseUntil then terminate("运行租约已到期") loading = false return end
    if not data or type(data.source) ~= "string" then
        loading = false
        if authorizationErrors[err] then terminate("授权已失效：" .. errorText(err))
        else setStatus("加载失败：" .. errorText(err or "INVALID_RESPONSE")) end
        return
    end
    local nextCount = tonumber(data.loadCount)
    if nextCount and nextCount >= 0 then
        loadCounts[script.id] = math.floor(nextCount)
    else
        loadCounts[script.id] = getScriptLoadCount(script) + 1
    end
    script.loadCount = loadCounts[script.id]
    refreshView()
    local compiled, fn = pcall(loadstring, data.source, "=Hub/" .. script.id)
    if not owner.alive then loading = false return end
    if os.clock() >= leaseUntil then terminate("运行租约已到期") loading = false return end
    if not compiled or type(fn) ~= "function" then loading = false setStatus("脚本编译失败") return end
    -- 原文、运行环境、参数与返回值均保持原语义；启动后通过结束本局终止使用。
    scriptStarted = true
    activeScriptId = script.id
    setStatus("正在启动 " .. script.nameZh .. "；关闭界面仍继续后台校验")
    if not owner.alive then loading = false return end
    local ok = pcall(fn)
    if not ok then
        if owner.alive then setStatus("脚本启动异常，授权监控继续；请手动结束本局后重试") end
    elseif owner.alive then
        setStatus("运行中：" .. script.nameZh .. "；关闭界面仍继续后台校验")
    end
    loading = false
    refreshView()
end

-- UI 的资源作用域仅属于这一轮视图；销毁它不会改变授权控制器。
-- 优先使用独立 UI 容器减少与游戏界面的干扰；容器隔离不替代后台授权。
local function buildView(uiContext)
    local function object(className, properties, parent)
        local item = Instance.new(className)
        if className == "TextButton" then
            item.Style = Enum.ButtonStyle.Custom
            item.AutoButtonColor = false
        end
        if className == "Frame" or className == "ScrollingFrame" or className == "TextLabel" or className == "TextButton" or className == "TextBox" or className == "ImageLabel" then
            item.AnchorPoint = Vector2.new(0, 0)
            item.AutomaticSize = Enum.AutomaticSize.None
            item.SizeConstraint = Enum.SizeConstraint.RelativeXY
            item.Rotation = 0
            item.ZIndex = 2
        end
        if className == "TextLabel" or className == "ImageLabel" then
            item.Active = false
            item.Selectable = false
        end
        for key, value in pairs(properties) do item[key] = value end
        item.Parent = parent
        return item
    end
    local colors = {
        canvas = Color3.fromRGB(15, 18, 25), surface = Color3.fromRGB(24, 29, 39),
        surfaceElevated = Color3.fromRGB(30, 36, 48), surfaceDisabled = Color3.fromRGB(18, 22, 30),
        input = Color3.fromRGB(20, 24, 33), border = Color3.fromRGB(46, 55, 72),
        text = Color3.fromRGB(240, 243, 250), muted = Color3.fromRGB(158, 170, 190),
        disabledText = Color3.fromRGB(98, 108, 126),
        accent = Color3.fromRGB(240, 100, 75), ink = Color3.fromRGB(39, 19, 15),
        success = Color3.fromRGB(115, 205, 166), danger = Color3.fromRGB(244, 164, 164),
    }
    local function rounded(item, radius)
        object("UICorner", { CornerRadius = UDim.new(0, radius or 10) }, item)
        return item
    end
    local function outline(item, color)
        return object("UIStroke", { Color = color or colors.border, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, item)
    end
    local function text(parent, name, value, size, color)
        return object("TextLabel", {
            Name = name, BackgroundTransparency = 1, Text = value, RichText = false,
            TextColor3 = color or colors.text, Font = Enum.Font.Gotham, TextSize = size or 14,
            TextWrapped = true, TextTruncate = Enum.TextTruncate.AtEnd,
            TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
        }, parent)
    end
    local function place(item, x, y, width, height)
        item.AnchorPoint = Vector2.new(0, 0)
        item.Position = UDim2.fromOffset(x, y)
        item.Size = UDim2.fromOffset(width, height)
    end
    local function button(parent, name, value, primary)
        local item = rounded(object("TextButton", {
            Name = name, BackgroundColor3 = primary and colors.accent or colors.surface,
            TextColor3 = primary and colors.ink or colors.text, Font = Enum.Font.GothamMedium,
            TextSize = 13, TextScaled = false, Text = value, Active = true, Selectable = true, AutoButtonColor = false, BorderSizePixel = 0,
        }, parent), 9)
        if not primary then outline(item) end
        return item
    end
    local function input(parent, name, placeholder)
        local field = rounded(object("TextBox", {
            Name = name, BackgroundColor3 = colors.input, TextColor3 = colors.text,
            PlaceholderColor3 = colors.muted, Font = Enum.Font.Gotham, TextSize = 12,
            TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Center,
            PlaceholderText = placeholder, Text = "", ClearTextOnFocus = false, BorderSizePixel = 0,
            ClipsDescendants = true, TextWrapped = false, MultiLine = false,
            TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 6,
        }, parent), 9)
        object("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }, field)
        outline(field)
        return field
    end
    local gui = object("ScreenGui", { Name = "RSZH_Hub", ResetOnSpawn = false, DisplayOrder = 10000, ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, nil)
    uiContext.onCleanup(function() gui:Destroy() end)
    local protectFn = protectgui or (syn and syn.protect_gui)
    if type(protectFn) == "function" then pcall(protectFn, gui) end
    local function attach(provider)
        local ok, parent = pcall(provider)
        if not ok or parent == nil then return false end
        return pcall(function() gui.Parent = parent end)
    end
    local mounted = (type(gethui) == "function" and attach(gethui))
        or (type(get_hidden_gui) == "function" and attach(get_hidden_gui))
        or attach(function() return game:GetService("CoreGui") end)
        or attach(function() return player:WaitForChild("PlayerGui", 10) end)
    assert(mounted, "玩家界面尚未就绪，请重新加载入口恢复界面")
    local guiParent = gui.Parent
    local viewport = object("Frame", {
        Name = "HubViewport", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, -20),
        Size = UDim2.new(0.94, 0, 0.9, -40), BackgroundTransparency = 1, BorderSizePixel = 0,
    }, gui)
    object("UISizeConstraint", { MaxSize = Vector2.new(1040, 720) }, viewport)
    -- The workspace stays horizontal; main stage switches between Current/Game Detail and All Games Gallery.
    local panel = rounded(object("Frame", {
        Name = "HubWindow", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(700, 396), BackgroundColor3 = colors.canvas, BorderSizePixel = 0,
        ClipsDescendants = true, Visible = true,
    }, viewport), 16)
    outline(panel)
    local uiScale = object("UIScale", { Name = "WorkspaceScale", Scale = 1 }, panel)
    local brand = rounded(object("TextLabel", { Name = "Brand", Text = "ZS", BackgroundColor3 = colors.accent,
        Font = Enum.Font.GothamBold, TextSize = 17, TextColor3 = colors.ink, BorderSizePixel = 0 }, panel), 10)
    local heading = text(panel, "Heading", "ZS HUB", 21)
    heading.Font = Enum.Font.GothamBold
    local subtitle = text(panel, "Subtitle", "拖动标题栏移动窗口 · 浏览全部支持游戏与脚本", 12, colors.muted)
    local dragHandle = object("Frame", { Name = "DragHandle", BackgroundTransparency = 1,
        Active = true, Selectable = false, BorderSizePixel = 0, ZIndex = 8 }, panel)
    local closeButton = button(panel, "CloseView", "关闭界面")
    local collapseButton = button(panel, "CollapseView", "收起")

    -- 左侧栏：清爽的访问授权卡片
    local authorization = rounded(object("Frame", { Name = "Authorization", BackgroundColor3 = colors.surface, BorderSizePixel = 0 }, panel), 12)
    outline(authorization)
    local authTitle = text(authorization, "AuthTitle", "访问授权", 13)
    authTitle.Font = Enum.Font.GothamMedium
    local authBadge = text(authorization, "AuthBadge", "未校验", 11, colors.muted)
    authBadge.TextXAlignment = Enum.TextXAlignment.Right
    local status = text(authorization, "SessionStatus", statusMessage, 11, colors.muted)
    local keyBox = input(authorization, "KeyInput", "请输入 Key")
    local loginButton = button(authorization, "ValidateKey", "校验 Key", true)
    loginButton.ZIndex = 6
    local kindLabel = text(authorization, "EntitlementKind", "", 15)
    kindLabel.Font = Enum.Font.GothamBold
    local expiryLabel = text(authorization, "ExpiryLabel", "剩余有效期", 11, colors.muted)
    local expiryValue = text(authorization, "ExpiryValue", "", 13)
    expiryValue.Font = Enum.Font.GothamMedium
    local expiryDateLabel = text(authorization, "ExpiryDateLabel", "到期时间", 11, colors.muted)
    local expiryDateValue = text(authorization, "ExpiryDateValue", "", 12, colors.text)
    expiryDateValue.Font = Enum.Font.GothamMedium
    local grantNote = text(authorization, "GrantNote", "", 11, colors.muted)

    -- 右侧主舞台顶部导航栏：当前游戏 Tab | 全部支持游戏 (N款) Tab + 全局搜索框
    local tabCurrentBtn = rounded(object("TextButton", {
        Name = "TabCurrentGame", BackgroundColor3 = colors.accent, TextColor3 = colors.ink,
        Font = Enum.Font.GothamBold, TextSize = 13, TextScaled = false, Text = "当前游戏",
        Active = true, Selectable = true, AutoButtonColor = false, BorderSizePixel = 0, ZIndex = 6,
    }, panel), 9)
    local tabCurrentStroke = outline(tabCurrentBtn, colors.accent)
    local tabAllGamesBtn = rounded(object("TextButton", {
        Name = "TabAllGames", BackgroundColor3 = colors.surface, TextColor3 = colors.text,
        Font = Enum.Font.GothamBold, TextSize = 13, TextScaled = false, Text = "全部支持游戏",
        Active = true, Selectable = true, AutoButtonColor = false, BorderSizePixel = 0, ZIndex = 6,
    }, panel), 9)
    local tabAllGamesStroke = outline(tabAllGamesBtn, colors.border)
    local navCountLabel = text(panel, "GameNavCount", "1 款", 11, colors.muted)
    navCountLabel.Visible = false
    local gameSearchBox = input(panel, "GameSearchInput", "搜索游戏或脚本名称…")

    -- 右侧视图 1：所选游戏的详情横幅卡片 + 脚本三列网格
    local gameDetailCard = rounded(object("Frame", { Name = "GameDetailCard", BackgroundColor3 = colors.surface, BorderSizePixel = 0 }, panel), 12)
    outline(gameDetailCard)
    local libraryTitle = text(panel, "LibraryTitle", "当前游戏", 16)
    libraryTitle.Font = Enum.Font.GothamBold
    libraryTitle.TextWrapped = false
    local gameNameEn = text(panel, "CurrentGameNameEn", "游戏资料待同步", 12, colors.muted)
    gameNameEn.TextWrapped = false
    local gameMatchBadge = rounded(text(panel, "GameMatchBadge", "当前游戏", 11, colors.accent), 6)
    gameMatchBadge.BackgroundTransparency = 0
    gameMatchBadge.BackgroundColor3 = colors.surfaceElevated
    gameMatchBadge.TextXAlignment = Enum.TextXAlignment.Center
    gameMatchBadge.TextYAlignment = Enum.TextYAlignment.Center
    local backToGalleryBtn = rounded(object("TextButton", {
        Name = "BackToGallery", BackgroundColor3 = colors.surfaceElevated, TextColor3 = colors.accent,
        Font = Enum.Font.GothamMedium, TextSize = 11, TextScaled = false, Text = "← 全部游戏",
        Active = true, Selectable = true, AutoButtonColor = false, BorderSizePixel = 0, Visible = false, ZIndex = 6,
    }, panel), 6)
    outline(backToGalleryBtn, colors.accent)
    local gamePlaceholder = rounded(text(panel, "CurrentGamePlaceholder", "游戏", 12, colors.muted), 9)
    gamePlaceholder.BackgroundTransparency, gamePlaceholder.BackgroundColor3 = 0, colors.surfaceElevated
    gamePlaceholder.TextXAlignment, gamePlaceholder.TextYAlignment = Enum.TextXAlignment.Center, Enum.TextYAlignment.Center
    local gameImage = rounded(object("ImageLabel", { Name = "CurrentGameImage", BackgroundTransparency = 1, BorderSizePixel = 0,
        ScaleType = Enum.ScaleType.Fit, Image = "", ZIndex = 3 }, panel), 9)
    local operationStatus = text(panel, "OperationStatus", "选择脚本后手动加载", 12, colors.muted)
    operationStatus.TextWrapped = false
    local countLabel = text(panel, "ScriptCount", "正在同步目录", 12, colors.muted)
    countLabel.TextXAlignment = Enum.TextXAlignment.Right

    local list = object("ScrollingFrame", {
        Name = "ScriptGrid", BackgroundTransparency = 1, BorderSizePixel = 0,
        ScrollBarThickness = 3, ScrollBarImageColor3 = colors.border,
        ScrollingDirection = Enum.ScrollingDirection.Y, AutomaticCanvasSize = Enum.AutomaticSize.None,
        CanvasSize = UDim2.new(), ClipsDescendants = true,
    }, panel)
    object("UIPadding", { PaddingLeft = UDim.new(0, 2), PaddingRight = UDim.new(0, 2), PaddingTop = UDim.new(0, 2), PaddingBottom = UDim.new(0, 2) }, list)
    local function section(name, title, emptyText)
        local root = object("Frame", { Name = name .. "Section", BackgroundTransparency = 1, BorderSizePixel = 0 }, list)
        local label = text(root, name .. "Title", title, 14)
        label.Font = Enum.Font.GothamMedium
        local count = text(root, name .. "Count", "0 个", 12, colors.muted)
        count.TextXAlignment = Enum.TextXAlignment.Right
        local content = object("Frame", { Name = name .. "Cards", BackgroundTransparency = 1, BorderSizePixel = 0 }, root)
        local grid = object("UIGridLayout", { Name = name .. "CardLayout", CellPadding = UDim2.fromOffset(12, 12),
            FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Left,
            SortOrder = Enum.SortOrder.LayoutOrder }, content)
        local empty = text(root, name .. "Empty", emptyText, 12, colors.muted)
        return { root = root, title = label, count = count, content = content, grid = grid, empty = empty, size = 0 }
    end
    local currentSection = section("Current", "当前游戏", "当前游戏暂无适配脚本")
    local universalSection = section("Universal", "通用脚本", "暂无通用脚本")

    -- 右侧视图 2：全部支持游戏大画廊（3列大图标海报卡片墙）
    local gameNavList = object("ScrollingFrame", {
        Name = "GameNavList", BackgroundTransparency = 1, BorderSizePixel = 0,
        ScrollBarThickness = 3, ScrollBarImageColor3 = colors.border,
        ScrollingDirection = Enum.ScrollingDirection.Y, AutomaticCanvasSize = Enum.AutomaticSize.None,
        CanvasSize = UDim2.new(), ClipsDescendants = true, Visible = false,
    }, panel)
    object("UIPadding", { PaddingLeft = UDim.new(0, 2), PaddingRight = UDim.new(0, 2), PaddingTop = UDim.new(0, 2), PaddingBottom = UDim.new(0, 2) }, gameNavList)
    local gameCardsContainer = object("Frame", {
        Name = "GameCardsContainer", BackgroundTransparency = 1, BorderSizePixel = 0,
    }, gameNavList)
    local gameGalleryGrid = object("UIGridLayout", {
        Name = "GameGalleryLayout", CellPadding = UDim2.fromOffset(12, 12),
        FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Left,
        SortOrder = Enum.SortOrder.LayoutOrder,
    }, gameCardsContainer)
    local gameNavEmpty = text(gameNavList, "GameNavEmpty", "未找到匹配的游戏，请尝试其他搜索关键词", 13, colors.muted)
    gameNavEmpty.Visible = false

    local footerNote = text(panel, "FooterNote", "原脚本独立加载 · 授权在后台持续校验", 12, colors.muted)
    local stopButton = button(panel, "EndSession", "结束本局")
    stopButton.TextColor3 = colors.danger
    local toggle = button(gui, "ToggleHub", "打开 Hub")
    toggle.Visible = false
    toggle.Position = UDim2.new(1, -132, 0, 12)
    toggle.Size = UDim2.fromOffset(116, 44)
    local authPrompt = object("TextButton", { Name = "AuthPromptOverlay", Text = "", AutoButtonColor = false,
        BackgroundColor3 = Color3.fromRGB(0, 0, 0), BackgroundTransparency = 0.3, BorderSizePixel = 0,
        Size = UDim2.fromScale(1, 1), Visible = false, Active = true, Modal = true, ZIndex = 50 }, panel)
    local promptPanel = rounded(object("Frame", { Name = "AuthPrompt", AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(340, 196),
        BackgroundColor3 = colors.surface, BorderSizePixel = 0, Active = true, ZIndex = 51 }, authPrompt), 12)
    outline(promptPanel)
    local promptTitle = text(promptPanel, "AuthPromptTitle", "请先校验 Key", 18)
    promptTitle.Font, promptTitle.ZIndex = Enum.Font.GothamBold, 52
    place(promptTitle, 20, 20, 300, 26)
    local promptBody = text(promptPanel, "AuthPromptBody", "在左侧输入 Key 并完成校验后，再点击脚本加载。", 14, colors.muted)
    promptBody.ZIndex = 52
    place(promptBody, 20, 58, 300, 54)
    local promptValidate = button(promptPanel, "AuthPromptValidate", "知道了", true)
    promptValidate.ZIndex = 52
    place(promptValidate, 20, 132, 300, 44)

    local cards, cardParts = {}, {}
    local navButtons, navParts = {}, {}
    local groups, activeGroup = {}, nil
    local lastViewportW, lastViewportH = 1040, 720
    local currentView = { context = uiContext, status = status, keyBox = keyBox }
    local function closeUI()
        if view == currentView then view = nil end
        uiContext.stop()
    end
    currentView.dismissAuthPrompt = function() authPrompt.Visible = false end
    currentView.destroy = closeUI
    currentView.focus = function() gui.Enabled = true panel.Visible = true toggle.Visible = false end
    local function connect(signal, callback)
        local connection = signal:Connect(function(...)
            if uiContext.alive then callback(...) end
        end)
        uiContext.onCleanup(function() connection:Disconnect() end)
    end
    local inputEpoch = 0
    local function bindClick(btn, callback)
        local lastKind, lastAt = nil, -1
        local touch, touchStart, touchEpoch, scrollPositions
        local function available()
            if not uiContext.alive or btn.Parent == nil or btn.Active == false then return false end
            local node = btn
            while node do
                local class = node.ClassName
                if (class == "ScreenGui" and node.Enabled == false)
                    or ((class == "Frame" or class == "ScrollingFrame" or class == "TextButton") and node.Visible == false) then return false end
                node = node.Parent
            end
            return true
        end
        local function makeTrigger(kind)
            return function()
                if not available() then return end
                local now = os.clock()
                if lastKind ~= nil and lastKind ~= kind and now - lastAt < 0.15 then return end
                lastKind, lastAt = kind, now
                callback()
            end
        end
        -- Native signals disconnect on Destroy; replaced cards are not retained by UI cleanup.
        btn.Activated:Connect(makeTrigger("activated"))
        btn.MouseButton1Click:Connect(makeTrigger("mouse"))
        btn.ChildAdded:Connect(function(child)
            if uiContext.alive and btn.Parent and child.ClassName == "UIScale" then pcall(function() child:Destroy() end) end
        end)
        local fireTouch = makeTrigger("touch")
        local function point(input) return input and input.Position and Vector2.new(input.Position.X, input.Position.Y) end
        local function contains(item, p)
            local pos, size = item.AbsolutePosition, item.AbsoluteSize
            return pos and size and size.X > 0 and size.Y > 0 and p.X >= pos.X and p.Y >= pos.Y
                and p.X < pos.X + size.X and p.Y < pos.Y + size.Y
        end
        btn.InputBegan:Connect(function(input)
            if touch or not input or input.UserInputType ~= Enum.UserInputType.Touch or not available() or not point(input) or not contains(btn, point(input)) then return end
            touch, touchStart, touchEpoch, scrollPositions = input, point(input), inputEpoch, {}
            local node = btn.Parent
            while node do
                if node.ClassName == "ScrollingFrame" then scrollPositions[node] = node.CanvasPosition end
                node = node.Parent
            end
        end)
        btn.InputChanged:Connect(function(input)
            if touch and input == touch and point(input) and (point(input) - touchStart).Magnitude > 8 then touch = nil end
        end)
        btn.InputEnded:Connect(function(input)
            if not input or input ~= touch then return end
            touch = nil
            local p = point(input)
            if not available() or touchEpoch ~= inputEpoch or not p or (p - touchStart).Magnitude > 8 or not contains(btn, p) then return end
            local node = btn.Parent
            while node do
                if (node.ClassName == "Frame" or node.ClassName == "ScrollingFrame") and node.ClipsDescendants and not contains(node, p) then return end
                if node.ClassName == "ScrollingFrame" and node.CanvasPosition ~= scrollPositions[node] then return end
                node = node.Parent
            end
            fireTouch()
        end)
    end
    bindClick(promptValidate, function()
        currentView.dismissAuthPrompt()
        if not loginBusy then pcall(function() keyBox:CaptureFocus() end) end
    end)
    local function notGranted(script)
        return entitlement and entitlement.kind == "GAME" and entitlement.gameId ~= script.gameId
    end
    local function isScriptPlayableInHere(script)
        return script.universal or Runtime.rank(script, game.GameId, game.PlaceId) == 0
    end
    local function requestScript(script)
        if not uiContext.alive or not owner.alive then return end
        if not isScriptPlayableInHere(script) then
            setStatus("非当前游戏脚本已置灰，请进入对应游戏后加载")
            return
        end
        if not token then
            promptTitle.Text = loginBusy and "正在校验 Key" or "请先校验 Key"
            promptBody.Text = loginBusy and "授权正在校验，请稍候。成功后再次点击脚本加载。" or "在左侧输入 Key 并完成校验后，再点击脚本加载。"
            promptValidate.Text = "知道了"
            authPrompt.Visible = true
            return
        end
        if notGranted(script) then setStatus("此 Key 未包含该游戏，请使用覆盖该脚本的 Key") return end
        task.spawn(run, script)
    end
    local function updateRemaining()
        if not entitlement then return end
        local seconds, millis = nil, nil
        if entitlement.expiresAt ~= nil then
            local ok, value = pcall(function()
                local expMillis = DateTime.fromIsoDate(entitlement.expiresAt).UnixTimestampMillis
                millis = expMillis
                return (expMillis - DateTime.now().UnixTimestampMillis) / 1000
            end)
            seconds = ok and value or "invalid"
            if not ok then millis = "invalid" end
        end
        expiryValue.Text = Runtime.remaining(seconds)
        expiryDateValue.Text = Runtime.expiryDateText(entitlement.expiresAt, millis)
    end
    local fit
    connect(gameImage:GetPropertyChangedSignal("IsLoaded"), function() gamePlaceholder.Visible = not gameImage.IsLoaded end)
    currentView.refresh = function()
        status.Text = statusMessage
        local verified = token ~= nil and entitlement ~= nil
        local editable = not verified and owner.alive
        keyBox.Visible, loginButton.Visible, status.Visible = editable, editable, not verified
        loginButton.Active, keyBox.TextEditable = editable and not loginBusy, editable and not loginBusy
        loginButton.Text = loginBusy and "正在校验…" or "校验 Key"
        authBadge.Text = not owner.alive and "已结束" or (verified and "已校验" or (loginBusy and "校验中" or "未校验"))
        authBadge.TextColor3 = verified and colors.success or colors.muted
        kindLabel.Visible, expiryLabel.Visible, expiryValue.Visible = verified, verified, verified
        expiryDateLabel.Visible, expiryDateValue.Visible, grantNote.Visible = verified, verified, verified
        if verified then
            local isMember = entitlement.kind == "MEMBER"
            kindLabel.Text = isMember and "👑 全游戏会员 VIP" or "🎮 单游戏 · 30 天"
            kindLabel.TextColor3 = isMember and colors.accent or colors.text
            updateRemaining()
            grantNote.Text = isMember and "当前游戏及通用脚本\n关闭界面仍持续校验" or "仅限绑定游戏\n关闭界面仍持续校验"
        end
        local inGallery = currentMode == "gallery"
        local isCurrentActive = not inGallery and activeGroup and activeGroup.isCurrent
        tabCurrentBtn.BackgroundColor3 = isCurrentActive and colors.accent or colors.surface
        tabCurrentBtn.TextColor3 = isCurrentActive and colors.ink or colors.text
        tabCurrentStroke.Color = isCurrentActive and colors.accent or colors.border
        local allTabActive = inGallery or (activeGroup and not activeGroup.isCurrent)
        tabAllGamesBtn.BackgroundColor3 = allTabActive and colors.accent or colors.surface
        tabAllGamesBtn.TextColor3 = allTabActive and colors.ink or colors.text
        tabAllGamesStroke.Color = allTabActive and colors.accent or colors.border

        gameDetailCard.Visible = not inGallery
        libraryTitle.Visible = not inGallery
        gameNameEn.Visible = not inGallery
        gameMatchBadge.Visible = not inGallery
        gameImage.Visible = not inGallery
        gamePlaceholder.Visible = not inGallery and not gameImage.IsLoaded
        operationStatus.Visible = not inGallery
        countLabel.Visible = not inGallery
        list.Visible = not inGallery
        backToGalleryBtn.Visible = not inGallery and (activeGroup ~= nil and not activeGroup.isCurrent)
        gameNavList.Visible = inGallery

        local viewingOther = activeGroup and not activeGroup.isCurrent
        if viewingOther then
            operationStatus.Text = "非当前游戏脚本已置灰，请进入对应游戏后加载"
        else
            operationStatus.Text = verified and statusMessage or "先完成 Key 校验，再选择脚本"
        end
        for _, navBtn in ipairs(navButtons) do
            local np = navParts[navBtn]
            local selected = activeGroup and np.group.key == activeGroup.key
            navBtn.BackgroundColor3 = selected and colors.surfaceElevated or colors.surface
            np.stroke.Color = np.group.isCurrent and colors.accent or (selected and colors.accent or colors.border)
            np.bar.Visible = np.group.isCurrent or selected
            np.title.TextColor3 = colors.text
            np.badge.TextColor3 = np.group.isCurrent and colors.accent or colors.muted
        end
        for _, card in ipairs(cards) do
            local parts = cardParts[card]
            local script = parts.script
            local playableHere = isScriptPlayableInHere(script)
            local canInteract = script.enabled and playableHere
            card.Active = canInteract
            card.Selectable = canInteract
            card.AutoButtonColor = false
            card.BackgroundColor3 = playableHere and colors.surface or colors.surfaceDisabled
            local needsKey = script.requiresKey == true
            parts.keyBadge.Text = Runtime.keyBadgeText(script)
            parts.keyBadge.TextColor3 = not playableHere and colors.disabledText or (needsKey and colors.accent or (script.requiresKey == false and colors.success or colors.muted))
            parts.title.TextColor3 = (script.enabled and playableHere) and colors.text or colors.disabledText
            parts.scenario.TextColor3 = playableHere and colors.muted or colors.disabledText
            parts.loadCount.Text = Runtime.loadCountText(getScriptLoadCount(script))
            parts.loadCount.TextColor3 = playableHere and colors.muted or colors.disabledText
            if not playableHere then
                parts.action.Text = "非当前游戏"
                parts.action.TextColor3 = colors.disabledText
            else
                parts.action.Text = not script.enabled and "待上架" or (scriptStarted and (activeScriptId == script.id and "运行中" or "重新进入后切换")
                    or (loading and loadingScriptId == script.id and "正在加载…" or (notGranted(script) and "需匹配权益" or (verified and "加载  →" or "校验后加载"))))
                parts.action.TextColor3 = (not script.enabled or notGranted(script) or (scriptStarted and activeScriptId ~= script.id)) and colors.muted or colors.accent
            end
        end
    end
    local inputService = game:GetService("UserInputService")
    local dragInput, dragStart, dragOrigin, dragOffset, currentLayout = nil, nil, nil, Vector2.new(0, 0), nil
    local function moveWindow(offset)
        local screen = gui.AbsoluteSize
        if not currentLayout or screen.X <= 0 or screen.Y <= 0 then return end
        local limitX = math.max(0, (screen.X - currentLayout.width * currentLayout.scale) / 2 - 8)
        local limitY = math.max(0, (screen.Y - 40 - currentLayout.height * currentLayout.scale) / 2 - 8)
        dragOffset = Vector2.new(math.clamp(offset.X, -limitX, limitX), math.clamp(offset.Y, -limitY, limitY))
        viewport.Position = UDim2.new(0.5, dragOffset.X, 0.5, dragOffset.Y - 20)
    end
    connect(dragHandle.InputBegan, function(input)
        if dragInput or (input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch) then return end
        dragInput, dragStart, dragOrigin = input, Vector2.new(input.Position.X, input.Position.Y), dragOffset
    end)
    connect(inputService.InputChanged, function(input)
        if not panel.Visible then dragInput = nil return end
        if not dragInput then return end
        local mouse = dragInput.UserInputType == Enum.UserInputType.MouseButton1 and input.UserInputType == Enum.UserInputType.MouseMovement
        if not mouse and input ~= dragInput then return end
        moveWindow(dragOrigin + Vector2.new(input.Position.X, input.Position.Y) - dragStart)
    end)
    connect(inputService.InputEnded, function(input)
        if input == dragInput or (dragInput and dragInput.UserInputType == Enum.UserInputType.MouseButton1 and input.UserInputType == Enum.UserInputType.MouseButton1) then dragInput = nil end
    end)
    connect(inputService.WindowFocusReleased, function() dragInput = nil inputEpoch += 1 end)
    fit = function()
        local size = viewport.AbsoluteSize
        if size and size.X >= 100 and size.Y >= 100 then
            lastViewportW, lastViewportH = size.X, size.Y
        elseif gui.AbsoluteSize and gui.AbsoluteSize.X >= 100 and gui.AbsoluteSize.Y >= 100 then
            lastViewportW = math.min(1040, gui.AbsoluteSize.X * 0.94)
            lastViewportH = math.min(720, gui.AbsoluteSize.Y * 0.9 - 40)
        end
        local showUniversal = not activeGroup or activeGroup.isCurrent
        local layout = Runtime.layout(lastViewportW, lastViewportH, currentSection.size, universalSection.size, #navButtons, showUniversal)
        currentLayout = layout
        panel.Size = UDim2.fromOffset(layout.width, layout.height)
        uiScale.Scale = layout.scale
        local w, pad = layout.width, layout.pad
        place(dragHandle, pad, 10, w - pad * 2 - 152, 52)
        place(brand, pad, 16, 38, 38)
        place(heading, pad + 50, 14, math.max(72, w - pad * 2 - 202), 24)
        place(subtitle, pad + 50, 40, math.max(72, w - pad * 2 - 202), 18)
        place(closeButton, w - pad - 88, 16, 88, 44)
        place(collapseButton, w - pad - 140, 16, 44, 44)

        -- 左侧授权卡片（干净充裕的独立侧栏）
        local sidebarWidth = layout.left - pad - 12
        local inner = sidebarWidth - 24
        local authTop = layout.mainTop
        local authHeight = layout.compact and 206 or 232
        place(authorization, pad, authTop, sidebarWidth, authHeight)
        place(authTitle, 12, 12, inner - 54, 20)
        place(authBadge, 12 + inner - 54, 12, 54, 20)
        place(status, 12, layout.compact and 36 or 44, inner, layout.compact and 44 or 48)
        place(keyBox, 12, layout.compact and 88 or 104, inner, 44)
        place(loginButton, 12, layout.compact and 140 or 160, inner, 44)
        place(kindLabel, 12, layout.compact and 38 or 44, inner, 22)
        place(expiryLabel, 12, layout.compact and 66 or 74, inner, 16)
        place(expiryValue, 12, layout.compact and 84 or 92, inner, 20)
        place(expiryDateLabel, 12, layout.compact and 108 or 118, inner, 16)
        place(expiryDateValue, 12, layout.compact and 126 or 136, inner, 20)
        place(grantNote, 12, layout.compact and 154 or 168, inner, 40)

        -- 右侧主舞台顶部：当前游戏 Tab | 全部支持游戏 Tab | 全局搜索框
        local tab1W = layout.compact and 92 or 104
        local tab2W = layout.compact and 146 or 164
        place(tabCurrentBtn, layout.left, layout.mainTop, tab1W, layout.navBarHeight)
        place(tabAllGamesBtn, layout.left + tab1W + 8, layout.mainTop, tab2W, layout.navBarHeight)
        local searchLeft = layout.left + tab1W + tab2W + 16
        local searchW = math.max(120, layout.left + layout.mainWidth - searchLeft)
        place(gameSearchBox, searchLeft, layout.mainTop, searchW, layout.navBarHeight)

        -- 右侧视图 1：游戏详情横幅卡片
        local dTop = layout.detailTop
        place(gameDetailCard, layout.left, dTop, layout.mainWidth, layout.detailHeight)
        place(gamePlaceholder, layout.left + 12, dTop + 10, 44, 44)
        place(gameImage, layout.left + 12, dTop + 10, 44, 44)
        local rightActionsW = (activeGroup and not activeGroup.isCurrent) and 230 or 154
        place(libraryTitle, layout.left + 66, dTop + 6, math.max(80, layout.mainWidth - 66 - rightActionsW), 20)
        if activeGroup and not activeGroup.isCurrent then
            place(backToGalleryBtn, layout.left + layout.mainWidth - 224, dTop + 7, 72, 22)
        end
        place(gameMatchBadge, layout.left + layout.mainWidth - 146, dTop + 7, 64, 20)
        place(countLabel, layout.left + layout.mainWidth - 78, dTop + 8, 66, 20)
        place(gameNameEn, layout.left + 66, dTop + 26, layout.mainWidth - 78, 16)
        place(operationStatus, layout.left + 66, dTop + 42, layout.mainWidth - 78, 16)

        -- 右侧视图 1：脚本三列网格区
        place(list, layout.left, layout.gridTop, layout.mainWidth, layout.gridHeight)
        universalSection.root.Visible = layout.showUniversalSection
        for index, sec in ipairs({currentSection, universalSection}) do
            local height = index == 1 and layout.currentHeight or layout.universalHeight
            local showHeader = index == 1 and layout.showCurrentHeader or true
            local contentTop = showHeader and 26 or 0
            place(sec.root, 0, index == 1 and 0 or layout.currentHeight + 12, layout.mainWidth - 4, height)
            place(sec.title, 0, 0, layout.mainWidth - 100, 20)
            place(sec.count, layout.mainWidth - 96, 0, 88, 20)
            sec.title.Visible = showHeader
            sec.count.Visible = showHeader
            place(sec.content, 0, contentTop, layout.mainWidth - 4, math.max(0, height - contentTop))
            place(sec.empty, 0, contentTop, layout.mainWidth - 8, 44)
            sec.grid.CellSize = UDim2.fromOffset(layout.cellWidth, layout.cardHeight)
            sec.grid.FillDirectionMaxCells = layout.columns
            sec.count.Text = tostring(sec.size) .. " 个"
            sec.empty.Visible = sec.size == 0
        end
        for _, card in ipairs(cards) do
            local parts = cardParts[card]
            parts.title.Position = UDim2.fromOffset(14, layout.compact and 32 or 34)
            parts.title.Size = UDim2.new(1, -28, 0, layout.compact and 32 or 36)
            parts.scenario.Position = UDim2.fromOffset(14, layout.compact and 68 or 74)
            parts.scenario.Size = UDim2.new(1, -28, 0, 28)
            parts.loadCount.Position = UDim2.fromOffset(14, layout.cardHeight - 32)
            parts.loadCount.Size = UDim2.new(0.5, -16, 0, 22)
            parts.action.Position = UDim2.new(0.5, 2, 0, layout.cardHeight - 32)
            parts.action.Size = UDim2.new(0.5, -16, 0, 22)
        end
        list.CanvasSize = UDim2.fromOffset(0, layout.gridContentHeight)
        list.ScrollingEnabled = true

        -- 右侧视图 2：全部支持游戏 3 列大画廊（海报墙）
        place(gameNavList, layout.left, layout.galleryTop, layout.mainWidth, layout.galleryHeight)
        place(gameCardsContainer, 0, 0, layout.mainWidth - 4, layout.galleryContentHeight)
        gameGalleryGrid.CellSize = UDim2.fromOffset(layout.cellWidth, layout.gameCardHeight)
        gameGalleryGrid.FillDirectionMaxCells = layout.columns
        place(gameNavEmpty, 12, 16, layout.mainWidth - 24, 32)
        gameNavEmpty.Visible = #navButtons == 0
        local iconSize = layout.compact and 50 or 58
        for _, navBtn in ipairs(navButtons) do
            local np = navParts[navBtn]
            place(np.bar, 0, 12, 3, layout.gameCardHeight - 24)
            place(np.iconPlaceholder, 12, 12, iconSize, iconSize)
            place(np.icon, 12, 12, iconSize, iconSize)
            local textLeft = 12 + iconSize + 10
            local textW = math.max(50, layout.cellWidth - textLeft - 10)
            place(np.badge, textLeft, 10, textW, 16)
            place(np.title, textLeft, 28, textW, 20)
            place(np.nameEn, textLeft, 48, textW, 16)
            local sW = math.floor((layout.cellWidth - 24) * 0.54)
            place(np.sub, 12, layout.gameCardHeight - 28, sW, 18)
            place(np.enterLabel, 12 + sW, layout.gameCardHeight - 28, layout.cellWidth - 24 - sW, 18)
        end
        gameNavList.CanvasSize = UDim2.fromOffset(0, layout.galleryContentHeight)
        gameNavList.ScrollingEnabled = true

        place(footerNote, layout.left, layout.footerY + 6, layout.mainWidth - 124, 36)
        place(stopButton, layout.compact and pad or w - pad - 112, layout.footerY, layout.compact and sidebarWidth or 112, 44)
        footerNote.Visible = not layout.compact
        moveWindow(dragOffset)
    end
    connect(viewport:GetPropertyChangedSignal("AbsoluteSize"), fit)
    bindClick(collapseButton, function() dragInput = nil panel.Visible = false toggle.Visible = true end)
    bindClick(toggle, function() panel.Visible = true toggle.Visible = false end)

    local renderGroup, renderNav
    local function createCard(script, sec, playableHere)
        sec.size += 1
        local category = script.universal and "通用脚本" or (playableHere and "当前游戏" or "其他游戏")
        local available = script.enabled and playableHere
        local card = rounded(object("TextButton", {
            Name = "ScriptCard_" .. script.id, LayoutOrder = sec.size, Size = UDim2.fromOffset(260, 188),
            Text = script.nameZh, TextTransparency = 1, Active = available, Selectable = available, AutoButtonColor = false,
            BackgroundColor3 = playableHere and colors.surface or colors.surfaceDisabled, BorderSizePixel = 0,
        }, sec.content), 12)
        card.ClipsDescendants = true
        outline(card)
        if not script.universal then
            object("Frame", {
                Name = "CurrentRail", Position = UDim2.fromOffset(0, 12), Size = UDim2.fromOffset(3, 20),
                BackgroundColor3 = playableHere and colors.accent or colors.border, BorderSizePixel = 0,
            }, card)
        end
        local categoryLabel = text(card, "Category", category, 11, playableHere and (not script.universal and colors.accent or colors.muted) or colors.disabledText)
        categoryLabel.Position, categoryLabel.Size = UDim2.fromOffset(14, 10), UDim2.new(1, -86, 0, 16)
        local needsKey = script.requiresKey == true
        local keyBadge = rounded(text(card, "KeyBadge", Runtime.keyBadgeText(script), 10, not playableHere and colors.disabledText or (needsKey and colors.accent or (script.requiresKey == false and colors.success or colors.muted))), 5)
        keyBadge.Font = Enum.Font.GothamMedium
        keyBadge.BackgroundTransparency = 0
        keyBadge.BackgroundColor3 = colors.surfaceElevated
        keyBadge.TextXAlignment = Enum.TextXAlignment.Center
        keyBadge.TextYAlignment = Enum.TextYAlignment.Center
        keyBadge.TextWrapped = false
        keyBadge.Position, keyBadge.Size = UDim2.new(1, -70, 0, 8), UDim2.fromOffset(58, 18)
        local title = text(card, "ScriptName", script.nameZh, 15, available and colors.text or colors.disabledText)
        title.Font = Enum.Font.GothamMedium
        local scenario = text(card, "Scenario", Runtime.scenario(script), 12, playableHere and colors.muted or colors.disabledText)
        local loadCount = text(card, "LoadCount", Runtime.loadCountText(getScriptLoadCount(script)), 11, playableHere and colors.muted or colors.disabledText)
        loadCount.TextYAlignment = Enum.TextYAlignment.Center
        loadCount.TextWrapped = false
        local action = text(card, "CardAction", available and "加载  →" or (not playableHere and "非当前游戏" or "待上架"), 12, available and colors.accent or colors.disabledText)
        action.TextYAlignment = Enum.TextYAlignment.Center
        action.TextXAlignment = Enum.TextXAlignment.Right
        bindClick(card, function()
            requestScript(script)
        end)
        cardParts[card] = { title = title, scenario = scenario, loadCount = loadCount, action = action, keyBadge = keyBadge, script = script }
        table.insert(cards, card)
    end

    renderGroup = function(group, stayInMode)
        activeGroup = group
        selectedGroupKey = group.key
        if not stayInMode then
            currentMode = "detail"
        end
        for _, card in ipairs(cards) do card:Destroy() end
        table.clear(cards)
        table.clear(cardParts)
        currentSection.size, universalSection.size = 0, 0
        local queryText = type(gameSearchBox.Text) == "string" and gameSearchBox.Text:match("^%s*(.-)%s*$") or ""
        local groupSelfMatches = queryText ~= "" and (
            string.find(string.lower(group.nameZh or ""), string.lower(queryText), 1, true) ~= nil
            or string.find(string.lower(group.nameEn or ""), string.lower(queryText), 1, true) ~= nil
            or string.find(string.lower(tostring(group.gameId or "")), string.lower(queryText), 1, true) ~= nil
        )
        if group.isCurrent then
            currentSection.title.Text = "当前游戏脚本"
            currentSection.empty.Text = queryText ~= "" and "没有匹配的当前游戏脚本" or "当前游戏暂无适配脚本"
            universalSection.empty.Text = queryText ~= "" and "没有匹配的通用脚本" or "暂无通用脚本"
            local curList = queryText ~= "" and Runtime.search(group.scripts, queryText, game.GameId, game.PlaceId) or group.scripts
            local displayCur = (queryText == "" or #curList > 0 or not groupSelfMatches) and curList or group.scripts
            for _, script in ipairs(displayCur) do
                createCard(script, currentSection, true)
            end
            local uniRaw = group.universalScripts or {}
            local uniList = queryText ~= "" and Runtime.search(uniRaw, queryText, game.GameId, game.PlaceId) or uniRaw
            for _, script in ipairs(uniList) do
                createCard(script, universalSection, true)
            end
            countLabel.Text = tostring(#cards) .. " 个脚本"
            gameMatchBadge.Text = "当前游戏"
            gameMatchBadge.TextColor3 = colors.accent
        else
            currentSection.title.Text = "支持脚本（非当前游戏 · 仅预览）"
            currentSection.empty.Text = queryText ~= "" and "没有匹配的脚本" or "该游戏暂无脚本"
            local matched = queryText ~= "" and Runtime.search(group.scripts, queryText, game.GameId, game.PlaceId) or group.scripts
            local displayList = (queryText == "" or #matched > 0 or not groupSelfMatches) and matched or group.scripts
            for _, script in ipairs(displayList) do
                createCard(script, currentSection, false)
            end
            countLabel.Text = tostring(#cards) .. " 个脚本"
            gameMatchBadge.Text = "非当前游戏"
            gameMatchBadge.TextColor3 = colors.muted
        end
        libraryTitle.Text = group.nameZh
        gameNameEn.Text = group.nameEn
        local iconUniverse = group.universeId or (group.isCurrent and game.GameId or 0)
        gameImage.Image = (type(iconUniverse) == "number" and iconUniverse > 0) and ("rbxthumb://type=GameIcon&id=" .. tostring(iconUniverse) .. "&w=150&h=150") or ""
        gamePlaceholder.Visible = not gameImage.IsLoaded
        currentView.refresh()
        fit()
    end

    renderNav = function()
        for _, btn in ipairs(navButtons) do btn:Destroy() end
        table.clear(navButtons)
        table.clear(navParts)
        local currentEntry, totalGames
        groups, currentEntry, totalGames = Runtime.gameGroups(catalog, game.GameId, game.PlaceId, gameSearchBox.Text)
        local totalCount = totalGames or #groups
        navCountLabel.Text = tostring(totalCount) .. " 款"
        tabAllGamesBtn.Text = "全部游戏 (" .. tostring(totalCount) .. ")"
        local targetGroup = nil
        for idx, grp in ipairs(groups) do
            if grp.key == selectedGroupKey then targetGroup = grp end
            local navName = grp.isCurrent and "GameNav_current" or ("GameNav_" .. tostring(grp.gameId))
            local btn = rounded(object("TextButton", {
                Name = navName, LayoutOrder = idx, Size = UDim2.fromOffset(220, 112),
                Text = grp.nameZh, TextTransparency = 1, ClipsDescendants = true,
                BackgroundColor3 = colors.surface, BorderSizePixel = 0, Active = true, Selectable = true, AutoButtonColor = false,
            }, gameCardsContainer), 12)
            local stroke = outline(btn)
            local bar = rounded(object("Frame", {
                Name = "ActiveBar", BackgroundColor3 = colors.accent, BorderSizePixel = 0, Visible = grp.isCurrent, Active = false, Selectable = false,
            }, btn), 2)
            local iconPh = rounded(text(btn, "NavIconPlaceholder", "游戏", 12, colors.muted), 9)
            iconPh.BackgroundTransparency, iconPh.BackgroundColor3 = 0, colors.surfaceElevated
            iconPh.TextXAlignment, iconPh.TextYAlignment = Enum.TextXAlignment.Center, Enum.TextYAlignment.Center
            local navUId = grp.universeId or (grp.isCurrent and game.GameId or 0)
            local navIconUri = (type(navUId) == "number" and navUId > 0) and ("rbxthumb://type=GameIcon&id=" .. tostring(navUId) .. "&w=150&h=150") or ""
            local navIcon = rounded(object("ImageLabel", {
                Name = "NavIcon", BackgroundTransparency = 1, BorderSizePixel = 0,
                ScaleType = Enum.ScaleType.Fit, Image = navIconUri, ZIndex = 3,
            }, btn), 9)
            navIcon:GetPropertyChangedSignal("IsLoaded"):Connect(function()
                iconPh.Visible = not navIcon.IsLoaded
            end)
            iconPh.Visible = not navIcon.IsLoaded
            local bLabel = text(btn, "NavBadge", grp.isCurrent and "● 当前游戏" or "支持游戏", 11, grp.isCurrent and colors.accent or colors.muted)
            bLabel.Font = Enum.Font.GothamMedium
            bLabel.TextWrapped = false
            local tLabel = text(btn, "NavTitle", grp.nameZh, 14, colors.text)
            tLabel.Font = Enum.Font.GothamBold
            tLabel.TextWrapped = false
            local enLabel = text(btn, "NavNameEn", grp.nameEn or "", 11, colors.muted)
            enLabel.TextWrapped = false
            local scriptTotal = #grp.scripts + (grp.universalScripts and #grp.universalScripts or 0)
            local sLabel = text(btn, "NavSub", tostring(scriptTotal) .. " 个支持脚本", 11, colors.muted)
            sLabel.TextWrapped = false
            local enterLabel = text(btn, "NavEnter", grp.isCurrent and "进入脚本 →" or "查看详情 →", 11, grp.isCurrent and colors.accent or colors.muted)
            enterLabel.TextXAlignment = Enum.TextXAlignment.Right
            enterLabel.TextWrapped = false
            bindClick(btn, function()
                renderGroup(grp, false)
            end)
            navParts[btn] = {
                group = grp, stroke = stroke, bar = bar, icon = navIcon, iconPlaceholder = iconPh,
                title = tLabel, nameEn = enLabel, sub = sLabel, badge = bLabel, enterLabel = enterLabel,
            }
            table.insert(navButtons, btn)
        end
        if not targetGroup then
            for _, grp in ipairs({currentEntry}) do
                if grp.key == selectedGroupKey then targetGroup = grp end
            end
            if not targetGroup and activeGroup and not activeGroup.isCurrent then
                local allGroups = Runtime.gameGroups(catalog, game.GameId, game.PlaceId, "")
                for _, grp in ipairs(allGroups) do
                    if grp.key == selectedGroupKey then targetGroup = grp end
                end
            end
            targetGroup = targetGroup or currentEntry
        end
        renderGroup(targetGroup, true)
    end

    bindClick(tabCurrentBtn, function()
        local _, currentEntry = Runtime.gameGroups(catalog, game.GameId, game.PlaceId, "")
        renderGroup(currentEntry, false)
    end)
    bindClick(tabAllGamesBtn, function()
        currentMode = "gallery"
        currentView.refresh()
        fit()
    end)
    bindClick(backToGalleryBtn, function()
        currentMode = "gallery"
        currentView.refresh()
        fit()
    end)
    connect(gameSearchBox:GetPropertyChangedSignal("Text"), renderNav)
    if keyBox.FocusLost then
        connect(keyBox.FocusLost, function(enterPressed)
            if enterPressed and loginButton.Active then
                task.spawn(login, keyBox.Text)
            end
        end)
    end
    bindClick(loginButton, function()
        if not loginButton.Active then return end
        task.spawn(login, keyBox.Text)
    end)
    bindClick(stopButton, function() endSession("你已结束本局，请重新进入游戏后使用 Hub") end)
    bindClick(closeButton, closeUI)
    connect(gui.Destroying, closeUI)
    currentView.render = renderNav
    renderNav()
    local remainingTask = task.spawn(function()
        while uiContext.alive do
            local ok = pcall(updateRemaining)
            if not ok then closeUI() warn("[ZS Hub] 界面更新失败，请重新加载入口；后台授权监控继续") return end
            task.wait(1)
        end
    end)
    uiContext.onCleanup(function() pcall(task.cancel, remainingTask) end)
    assert(gui.Parent == guiParent, "界面创建期间已被清理")
    return currentView
end

mountUI = function()
    if not owner.alive or mountingUI then return end
    if view then view.focus() return end
    mountingUI = true
    local context = Runtime.lifecycle()
    local ok, currentView = pcall(buildView, context)
    mountingUI = false
    if not ok then
        context.stop()
        if owner.alive then
            warn("[ZS Hub] 界面创建失败，请重新加载入口；后台授权监控继续")
        end
    elseif owner.alive and context.alive then
        view = currentView
        refreshView()
    else context.stop() end
end

endSession = function(message)
    if not owner.alive then return end
    local oldToken = token
    token, sessionId, leaseUntil = nil, nil, 0
    pendingKey = ""
    if view then view.keyBox.Text = "" end
    owner.alive = false
    local disconnected = pcall(kickPlayer, player, "ZS Hub：" .. message)
    if not disconnected then
        setStatus("结束游戏请求失败，请立即手动离开本局；Hub 已停止加载与续租")
        warn("[ZS Hub] 结束游戏请求失败，请立即手动离开本局")
    end
    logout(oldToken)
    if disconnected then
        if view then view.destroy() end
        if env.__RSZH_HUB == owner then env.__RSZH_HUB = nil end
    end
end
owner.focus = mountUI
owner.submitKey = function(key)
    if owner.alive and not token and not loginBusy then task.spawn(login, key) end
end
env.__RSZH_HUB = owner

-- 看门狗独立于 HTTP 心跳；请求挂起时也按原租约截止时间结束本局。
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
            local renewed = false
            if owner.alive and token == activeToken and sessionId == activeId then
                if os.clock() >= leaseUntil then
                    terminate("运行租约已到期")
                elseif data and data.sessionId == activeId and data.sequence == sequence then
                    local ok, deadline = pcall(Runtime.deadline, sent, data.remainingLeaseSeconds)
                    if ok and os.clock() < deadline then
                        leaseUntil = deadline
                        if data.kind then
                            entitlement = { kind = data.kind, gameId = data.gameId, expiresAt = data.entitlementExpiresAt }
                            refreshView()
                        end
                        renewed = true
                    end
                elseif authorizationErrors[err] then
                    terminate("授权已失效：" .. errorText(err))
                end
            end
            -- 网络及异常响应不续租，沿原截止时间短间隔重试。
            nextHeartbeat = os.clock() + (renewed and 28 + math.random() * 4 or 3)
        end
        task.wait(0.2)
    end
end)
mountUI()
if pendingKey ~= "" then owner.submitKey(pendingKey) end
local data, err = api("GET", "/api/hub/catalog")
if not owner.alive then return end
if data and type(data.scripts) == "table" then
    catalog = data.scripts
    for _, script in ipairs(catalog) do
        if type(script.id) == "string" and loadCounts[script.id] == nil then
            loadCounts[script.id] = math.max(0, math.floor(tonumber(script.loadCount) or 0))
        end
    end
    if view then view.render() end
    if statusMessage == "正在获取正式目录…" then setStatus("目录已就绪；请先校验 Key，再选择脚本加载") end
else
    setStatus("目录下载失败：" .. errorText(err))
end
