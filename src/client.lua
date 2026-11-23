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
local function buildView(uiContext)
    local guiParent = player:WaitForChild("PlayerGui", 10)
    assert(guiParent, "玩家界面尚未就绪，请重新加载入口恢复界面")
    local function object(className, properties, parent)
        local item = Instance.new(className)
        if className == "TextButton" then item.Style = Enum.ButtonStyle.Custom end
        if className == "Frame" or className == "ScrollingFrame" or className == "TextLabel" or className == "TextButton" or className == "TextBox" or className == "ImageLabel" then
            item.AnchorPoint = Vector2.new(0, 0)
            item.AutomaticSize = Enum.AutomaticSize.None
            item.SizeConstraint = Enum.SizeConstraint.RelativeXY
            item.Rotation = 0
            item.ZIndex = 2
        end
        for key, value in pairs(properties) do item[key] = value end
        item.Parent = parent
        return item
    end
    local colors = {
        canvas = Color3.fromRGB(15, 18, 25), surface = Color3.fromRGB(24, 29, 39),
        input = Color3.fromRGB(20, 24, 33), border = Color3.fromRGB(46, 55, 72),
        text = Color3.fromRGB(240, 243, 250), muted = Color3.fromRGB(158, 170, 190),
        accent = Color3.fromRGB(240, 100, 75), ink = Color3.fromRGB(39, 19, 15),
        danger = Color3.fromRGB(244, 164, 164),
    }
    local function rounded(item, radius)
        object("UICorner", { CornerRadius = UDim.new(0, radius or 10) }, item)
        return item
    end
    local function outline(item, color)
        object("UIStroke", { Color = color or colors.border, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, item)
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
            TextSize = 13, TextScaled = false, Text = value, Selectable = true, AutoButtonColor = true, BorderSizePixel = 0,
        }, parent), 9)
        if not primary then outline(item) end
        return item
    end
    local function input(parent, name, placeholder)
        local field = rounded(object("TextBox", {
            Name = name, BackgroundColor3 = colors.input, TextColor3 = colors.text,
            PlaceholderColor3 = colors.muted, Font = Enum.Font.Gotham, TextSize = 14,
            TextXAlignment = Enum.TextXAlignment.Left, PlaceholderText = placeholder,
            Text = "", ClearTextOnFocus = false, BorderSizePixel = 0,
        }, parent), 9)
        object("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12) }, field)
        outline(field)
        return field
    end
    local gui = object("ScreenGui", { Name = "RSZH_Hub", ResetOnSpawn = false, DisplayOrder = 10000, ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, guiParent)
    uiContext.onCleanup(function() gui:Destroy() end)
    local viewport = object("Frame", {
        Name = "HubViewport", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, -20),
        Size = UDim2.new(0.94, 0, 0.9, -40), BackgroundTransparency = 1, BorderSizePixel = 0,
    }, gui)
    object("UISizeConstraint", { MaxSize = Vector2.new(1040, 720) }, viewport)
    -- The workspace stays horizontal; only the card grid scrolls.
    local panel = rounded(object("Frame", {
        Name = "HubWindow", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(700, 340), BackgroundColor3 = colors.canvas, BorderSizePixel = 0,
        ClipsDescendants = true, Visible = true,
    }, viewport), 16)
    outline(panel)
    local uiScale = object("UIScale", { Name = "WorkspaceScale", Scale = 1 }, panel)
    local brand = rounded(object("TextLabel", { Name = "Brand", Text = "ZS", BackgroundColor3 = colors.accent,
        Font = Enum.Font.GothamBold, TextSize = 17, TextColor3 = colors.ink, BorderSizePixel = 0 }, panel), 10)
    local heading = text(panel, "Heading", "ZS HUB", 21)
    heading.Font = Enum.Font.GothamBold
    local subtitle = text(panel, "Subtitle", "拖动标题栏移动窗口", 12, colors.muted)
    local dragHandle = object("Frame", { Name = "DragHandle", BackgroundTransparency = 1,
        Active = true, Selectable = false, BorderSizePixel = 0, ZIndex = 8 }, panel)
    local closeButton = button(panel, "CloseView", "关闭界面")
    local collapseButton = button(panel, "CollapseView", "收起")
    local authorization = rounded(object("Frame", { Name = "Authorization", BackgroundColor3 = colors.surface, BorderSizePixel = 0 }, panel), 12)
    outline(authorization)
    local authTitle = text(authorization, "AuthTitle", "访问授权", 13)
    local authBadge = text(authorization, "AuthBadge", "未校验", 11, colors.muted)
    authBadge.TextXAlignment = Enum.TextXAlignment.Right
    local status = text(authorization, "SessionStatus", statusMessage, 12, colors.muted)
    local keyBox = input(authorization, "KeyInput", "请输入 Key")
    local loginButton = button(authorization, "ValidateKey", "校验 Key", true)
    local kindLabel = text(authorization, "EntitlementKind", "", 16)
    kindLabel.Font = Enum.Font.GothamMedium
    local expiryLabel = text(authorization, "ExpiryLabel", "剩余有效期", 11, colors.muted)
    local expiryValue = text(authorization, "ExpiryValue", "", 14)
    local grantNote = text(authorization, "GrantNote", "", 12, colors.muted)
    local libraryTitle = text(panel, "LibraryTitle", "脚本库", 18)
    libraryTitle.Font = Enum.Font.GothamBold
    libraryTitle.TextSize, libraryTitle.TextWrapped = 16, false
    local gameNameEn = text(panel, "CurrentGameNameEn", "游戏资料待同步", 12, colors.muted)
    gameNameEn.TextWrapped = false
    local gamePlaceholder = rounded(text(panel, "CurrentGamePlaceholder", "游戏", 12, colors.muted), 9)
    gamePlaceholder.BackgroundTransparency, gamePlaceholder.BackgroundColor3 = 0, colors.surface
    gamePlaceholder.TextXAlignment, gamePlaceholder.TextYAlignment = Enum.TextXAlignment.Center, Enum.TextYAlignment.Center
    local gameImage = rounded(object("ImageLabel", { Name = "CurrentGameImage", BackgroundTransparency = 1, BorderSizePixel = 0,
        ScaleType = Enum.ScaleType.Fit, Image = "", ZIndex = 3 }, panel), 9)
    local operationStatus = text(panel, "OperationStatus", "选择脚本后手动加载", 12, colors.muted)
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
    local promptLater = button(promptPanel, "AuthPromptLater", "稍后")
    promptLater.ZIndex = 52
    place(promptLater, 20, 132, 112, 44)
    local promptValidate = button(promptPanel, "AuthPromptValidate", "去校验 Key", true)
    promptValidate.ZIndex = 52
    place(promptValidate, 144, 132, 176, 44)
    local cards, cardParts = {}, {}
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
    connect(promptLater.Activated, currentView.dismissAuthPrompt)
    connect(promptValidate.Activated, function()
        currentView.dismissAuthPrompt()
        if not loginBusy then pcall(function() keyBox:CaptureFocus() end) end
    end)
    local function notGranted(script)
        return entitlement and entitlement.kind == "GAME" and entitlement.gameId ~= script.gameId
    end
    local function requestScript(script)
        if not uiContext.alive or not owner.alive then return end
        if not token then
            promptTitle.Text = loginBusy and "正在校验 Key" or "请先校验 Key"
            promptBody.Text = loginBusy and "授权正在校验，请稍候。成功后再次点击脚本加载。" or "在左侧输入 Key 并完成校验后，再点击脚本加载。"
            promptValidate.Text = loginBusy and "知道了" or "去校验 Key"
            authPrompt.Visible = true
            return
        end
        if notGranted(script) then setStatus("此 Key 未包含该游戏，请使用覆盖该脚本的 Key") return end
        task.spawn(run, script)
    end
    local function updateRemaining()
        if not entitlement then return end
        local seconds = nil
        if entitlement.expiresAt ~= nil then
            local ok, value = pcall(function()
                return (DateTime.fromIsoDate(entitlement.expiresAt).UnixTimestampMillis - DateTime.now().UnixTimestampMillis) / 1000
            end)
            seconds = ok and value or "invalid"
        end
        expiryValue.Text = Runtime.remaining(seconds)
    end
    connect(gameImage:GetPropertyChangedSignal("IsLoaded"), function() gamePlaceholder.Visible = not gameImage.IsLoaded end)
    currentView.refresh = function()
        status.Text = statusMessage
        local verified = token ~= nil and entitlement ~= nil
        local editable = not verified and owner.alive
        keyBox.Visible, loginButton.Visible, status.Visible = editable, editable, not verified
        loginButton.Active, keyBox.TextEditable = editable and not loginBusy, editable and not loginBusy
        loginButton.Text = loginBusy and "正在校验…" or "校验 Key"
        authBadge.Text = not owner.alive and "已结束" or (verified and "已校验" or (loginBusy and "校验中" or "未校验"))
        authBadge.TextColor3 = verified and Color3.fromRGB(115, 205, 166) or colors.muted
        kindLabel.Visible, expiryLabel.Visible, expiryValue.Visible, grantNote.Visible = verified, verified, verified, verified
        if verified then
            kindLabel.Text = entitlement.kind == "MEMBER" and "全游戏会员" or "单游戏 · 30 天"
            updateRemaining()
            grantNote.Text = entitlement.kind == "MEMBER" and "当前游戏及通用脚本\n关闭界面仍持续校验" or "仅限绑定游戏\n关闭界面仍持续校验"
        end
        operationStatus.Text = verified and statusMessage or "先完成 Key 校验，再选择脚本"
        for _, card in ipairs(cards) do
            local parts = cardParts[card]
            local script = parts.script
            parts.action.Text = not script.enabled and "待上架" or (scriptStarted and (activeScriptId == script.id and "运行中" or "重新进入后切换")
                or (loading and loadingScriptId == script.id and "正在加载…" or (notGranted(script) and "需匹配权益" or (verified and "加载  →" or "校验后加载"))))
            parts.action.TextColor3 = (not script.enabled or notGranted(script) or (scriptStarted and activeScriptId ~= script.id)) and colors.muted or colors.accent
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
    connect(inputService.WindowFocusReleased, function() dragInput = nil end)
    local function fit()
        local size = viewport.AbsoluteSize
        local layout = Runtime.layout(size.X, size.Y, currentSection.size, universalSection.size)
        currentLayout = layout
        panel.Size = UDim2.fromOffset(layout.width, layout.height)
        uiScale.Scale = layout.scale
        local w, pad = layout.width, layout.pad
        place(dragHandle, pad, 10, w - pad * 2 - 152, 56)
        place(brand, pad, 18, 38, 38)
        place(heading, pad + 50, 16, math.max(72, w - pad * 2 - 202), 26)
        place(subtitle, pad + 50, 46, math.max(72, w - pad * 2 - 202), 20)
        place(closeButton, w - pad - 88, 18, 88, 44)
        place(collapseButton, w - pad - 140, 18, 44, 44)
        local inner = layout.compact and 156 or 188
        local top = layout.compact and 10 or 14
        place(authorization, pad, 80, inner + 28, layout.compact and 196 or 224)
        place(authTitle, 14, top, inner - 58, 22)
        place(authBadge, 14 + inner - 58, top + 2, 58, 20)
        place(status, 14, layout.compact and 36 or 48, inner, layout.compact and 46 or 52)
        place(keyBox, 14, layout.compact and 92 or 112, inner, 44)
        place(loginButton, 14, layout.compact and 144 or 168, inner, 44)
        place(kindLabel, 14, layout.compact and 44 or 50, inner, 24)
        place(expiryLabel, 14, layout.compact and 78 or 90, inner, 18)
        place(expiryValue, 14, layout.compact and 102 or 114, inner, 24)
        place(grantNote, 14, layout.compact and 140 or 158, inner, 40)
        place(gamePlaceholder, layout.left, layout.mainTop, 44, 44)
        place(gameImage, layout.left, layout.mainTop, 44, 44)
        place(libraryTitle, layout.left + 56, layout.mainTop, layout.mainWidth - 168, 24)
        place(gameNameEn, layout.left + 56, layout.mainTop + 26, layout.mainWidth - 56, 18)
        place(countLabel, layout.left + layout.mainWidth - 100, layout.mainTop + 4, 100, 20)
        place(operationStatus, layout.left, layout.mainTop + 48, layout.mainWidth, 18)
        place(list, layout.left, layout.gridTop, layout.mainWidth, layout.gridHeight)
        for index, section in ipairs({currentSection, universalSection}) do
            local height = index == 1 and layout.currentHeight or layout.universalHeight
            place(section.root, 0, index == 1 and 0 or layout.currentHeight + 16, layout.mainWidth - 4, height)
            place(section.title, 0, 0, layout.mainWidth - 100, 22)
            place(section.count, layout.mainWidth - 96, 2, 88, 20)
            place(section.content, 0, 32, layout.mainWidth - 4, height - 32)
            place(section.empty, 0, 32, layout.mainWidth - 8, 44)
            section.grid.CellSize = UDim2.fromOffset(layout.cellWidth, layout.cardHeight)
            section.grid.FillDirectionMaxCells = layout.columns
            section.count.Text = tostring(section.size) .. " 个"
            section.empty.Visible = section.size == 0
        end
        for _,card in ipairs(cards) do
            local parts = cardParts[card]
            parts.title.Position = UDim2.fromOffset(14, layout.compact and 34 or 36)
            parts.title.Size = UDim2.new(1, -28, 0, layout.compact and 32 or 36)
            parts.scenario.Position = UDim2.fromOffset(14, layout.compact and 72 or 78)
            parts.scenario.Size = UDim2.new(1, -28, 0, 30)
            parts.action.Position = UDim2.fromOffset(14, layout.cardHeight - 34)
            parts.action.Size = UDim2.new(1, -28, 0, 24)
        end
        list.CanvasSize = UDim2.fromOffset(0, layout.gridContentHeight)
        list.ScrollingEnabled = true
        place(footerNote, pad, layout.footerY + 4, w - pad * 2 - 124, 40)
        place(stopButton, layout.compact and pad or w - pad - 112, layout.footerY, layout.compact and 184 or 112, 44)
        footerNote.Visible = not layout.compact
        moveWindow(dragOffset)
    end
    connect(viewport:GetPropertyChangedSignal("AbsoluteSize"), fit)
    connect(collapseButton.Activated, function() dragInput = nil panel.Visible = false toggle.Visible = true end)
    connect(toggle.Activated, function() panel.Visible = true toggle.Visible = false end)
    local function render()
        for _, card in ipairs(cards) do card:Destroy() end
        table.clear(cards)
        table.clear(cardParts)
        currentSection.size, universalSection.size = 0, 0
        local found = Runtime.search(catalog, "", game.GameId, game.PlaceId)
        for _, script in ipairs(found) do
            local rank = Runtime.rank(script, game.GameId, game.PlaceId)
            local section = script.universal and universalSection or (rank == 0 and currentSection or nil)
            if section then
                section.size += 1
                local category = script.universal and "通用脚本" or "当前游戏"
                local available = script.enabled
                local card = rounded(object("TextButton", {
                    Name = "ScriptCard_" .. script.id, LayoutOrder = section.size, Size = UDim2.fromOffset(260, 188),
                    Text = script.nameZh, TextTransparency = 1, Selectable = available, AutoButtonColor = available,
                    BackgroundColor3 = colors.surface, BorderSizePixel = 0,
                }, section.content), 12)
                card.ClipsDescendants = true
                outline(card)
                if not script.universal then
                    object("Frame", { Name = "CurrentRail", Position = UDim2.fromOffset(0, 12), Size = UDim2.fromOffset(3, 20), BackgroundColor3 = colors.accent, BorderSizePixel = 0 }, card)
                end
                local categoryLabel = text(card, "Category", category, 11, rank == 0 and colors.accent or colors.muted)
                categoryLabel.Position, categoryLabel.Size = UDim2.fromOffset(14, 12), UDim2.new(1, -28, 0, 16)
                local title = text(card, "ScriptName", script.nameZh, 15, script.enabled and colors.text or colors.muted)
                title.Font = Enum.Font.GothamMedium
                local scenario = text(card, "Scenario", Runtime.scenario(script), 12, colors.muted)
                local action = text(card, "CardAction", available and "加载  →" or (script.enabled and "切换游戏后使用" or "待上架"), 12, available and colors.accent or colors.muted)
                action.TextYAlignment = Enum.TextYAlignment.Center
                action.TextXAlignment = Enum.TextXAlignment.Right
                card.Activated:Connect(function()
                    requestScript(script)
                end)
                cardParts[card] = { title = title, scenario = scenario, action = action, script = script }
                table.insert(cards, card)
            end
        end
        countLabel.Text = tostring(#cards) .. " 个脚本"
        local currentGame = Runtime.currentGame(catalog, game.GameId, game.PlaceId)
        libraryTitle.Text = currentGame and type(currentGame.nameZh) == "string" and currentGame.nameZh ~= "" and currentGame.nameZh or "当前游戏"
        gameNameEn.Text = currentGame and type(currentGame.nameEn) == "string" and currentGame.nameEn ~= "" and currentGame.nameEn or "英文名称未配置"
        if not currentGame then gameNameEn.Text = "游戏资料待同步" end
        gameImage.Image = game.GameId > 0 and ("rbxthumb://type=GameIcon&id=" .. tostring(game.GameId) .. "&w=150&h=150") or ""
        gamePlaceholder.Visible = not gameImage.IsLoaded
        currentView.refresh()
        fit()
    end
    connect(loginButton.Activated, function() task.spawn(login, keyBox.Text) end)
    connect(stopButton.Activated, function() endSession("你已结束本局，请重新进入游戏后使用 Hub") end)
    connect(closeButton.Activated, closeUI)
    connect(gui.Destroying, closeUI)
    currentView.render = render
    render()
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
    if view then view.render() end
    if statusMessage == "正在获取正式目录…" then setStatus("目录已就绪；请先校验 Key，再选择脚本加载") end
else
    setStatus("目录下载失败：" .. errorText(err))
end
