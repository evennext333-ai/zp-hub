local Runtime = {}

-- 仅管理 Hub 自己的 UI 资源；游戏脚本原样执行，由断开本局处理授权失效。
function Runtime.lifecycle()
    local cleanups = {}
    local context = { alive = true }
    function context.onCleanup(callback)
        assert(type(callback) == "function", "清理回调应为函数")
        if context.alive then
            table.insert(cleanups, callback)
        else
            pcall(callback)
        end
    end
    function context.override(target, key, value)
        assert(context.alive, "运行已停止")
        local original = target[key]
        target[key] = value
        context.onCleanup(function()
            if target[key] == value then target[key] = original end
        end)
    end
    function context.stop()
        if not context.alive then return end
        context.alive = false
        for i = #cleanups, 1, -1 do
            local ok = pcall(cleanups[i])
            if not ok then warn("[Hub] 一项资源清理失败，请重新加入游戏后重试") end
        end
        table.clear(cleanups)
    end
    return context
end

local function contains(values, value)
    for _, item in ipairs(values or {}) do
        if tostring(item) == tostring(value) then return true end
    end
    return false
end

function Runtime.rank(script, universeId, placeId)
    if contains(script.placeIds, placeId) then return 0 end
    if contains(script.universeIds, universeId) then
        return #(script.placeIds or {}) == 0 and 0 or 1
    end
    return script.universal and 2 or 3
end

function Runtime.search(scripts, query, universeId, placeId)
    local result = {}
    query = string.lower(query or "")
    for _, script in ipairs(scripts) do
        local words = { script.nameZh, script.nameEn, script.id, script.gameId, type(script.scenario) == "string" and script.scenario or "" }
        for _, word in ipairs(script.aliases or {}) do table.insert(words, word) end
        for _, word in ipairs(script.tags or {}) do table.insert(words, word) end
        if string.find(string.lower(table.concat(words, " ")), query, 1, true) then
            table.insert(result, script)
        end
    end
    table.sort(result, function(a, b)
        local ar, br = Runtime.rank(a, universeId, placeId), Runtime.rank(b, universeId, placeId)
        if ar ~= br then return ar < br end
        return a.id < b.id
    end)
    return result
end

-- 格式化脚本执行次数展示
function Runtime.loadCountText(count)
    local n = math.max(0, math.floor(tonumber(count) or 0))
    return "已执行 " .. tostring(n) .. " 次"
end

-- 提取支持的游戏总列表，以及当前游戏的专属与通用脚本分组
function Runtime.gameGroups(scripts, universeId, placeId)
    local currentGame = Runtime.currentGame(scripts, universeId, placeId)
    local currentGid = currentGame and currentGame.id or nil
    local currentScripts, universalScripts = {}, {}
    local byGame, order = {}, {}
    local sorted = Runtime.search(scripts or {}, "", universeId, placeId)
    for _, script in ipairs(sorted) do
        local rank = Runtime.rank(script, universeId, placeId)
        if script.universal then
            table.insert(universalScripts, script)
        elseif rank == 0 then
            if not currentGid and type(script.gameId) == "string" and script.gameId ~= "" then
                currentGid = script.gameId
            end
            table.insert(currentScripts, script)
        end
    end
    for _, script in ipairs(sorted) do
        local rank = Runtime.rank(script, universeId, placeId)
        if not script.universal and rank > 0 then
            local gid = tostring(script.gameId or (type(script.game) == "table" and script.game.id) or "other")
            local group = byGame[gid]
            if not group then
                local g = type(script.game) == "table" and script.game or {}
                local uId = type(script.universeIds) == "table" and tonumber(script.universeIds[1]) or nil
                group = {
                    key = "game:" .. gid,
                    gameId = gid,
                    nameZh = (type(g.nameZh) == "string" and g.nameZh ~= "" and g.nameZh) or gid,
                    nameEn = (type(g.nameEn) == "string" and g.nameEn ~= "" and g.nameEn) or "英文名称未配置",
                    universeId = uId,
                    isCurrent = false,
                    scripts = {},
                }
                byGame[gid] = group
                table.insert(order, group)
            end
            table.insert(group.scripts, script)
        end
    end
    table.sort(order, function(a, b) return tostring(a.gameId) < tostring(b.gameId) end)
    local currentEntry = {
        key = "current",
        gameId = currentGid,
        nameZh = (currentGame and type(currentGame.nameZh) == "string" and currentGame.nameZh ~= "" and currentGame.nameZh) or "当前游戏",
        nameEn = currentGame and ((type(currentGame.nameEn) == "string" and currentGame.nameEn ~= "" and currentGame.nameEn) or "英文名称未配置") or "游戏资料待同步",
        universeId = tonumber(universeId) or 0,
        isCurrent = true,
        scripts = currentScripts,
        universalScripts = universalScripts,
    }
    local list = { currentEntry }
    for _, group in ipairs(order) do
        table.insert(list, group)
    end
    return list, currentEntry
end

-- One horizontal workspace on every device; undersized viewports scale it as a unit.
function Runtime.layout(availableWidth, availableHeight, count, universalCount, gameNavCount, showUniversal)
    availableWidth = math.max(1, tonumber(availableWidth) or 600)
    availableHeight = math.max(1, tonumber(availableHeight) or 560)
    local width = math.max(700, math.min(1040, availableWidth))
    local height = math.max(340, math.min(720, availableHeight, math.floor(width * 0.7)))
    local scale = math.min(1, availableWidth / width, availableHeight / height)
    count = math.max(0, tonumber(count) or 0)
    universalCount = math.max(0, tonumber(universalCount) or 0)
    gameNavCount = math.max(1, tonumber(gameNavCount) or 1)
    if showUniversal == nil then showUniversal = true end
    local compact = width < 900 or height < 580
    local pad, gap, cardHeight = 20, 12, compact and 148 or 160
    local left = compact and 220 or 256
    local mainWidth = width - left - pad
    local columns = 3
    local cellWidth = math.floor((mainWidth - 8 - gap * (columns - 1)) / columns)
    local function sectionHeight(items)
        local sectionRows = math.ceil(math.max(0, tonumber(items) or 0) / columns)
        return 32 + (sectionRows > 0 and sectionRows * cardHeight + (sectionRows - 1) * gap + 4 or 44)
    end
    local currentHeight = sectionHeight(count)
    local universalHeight = showUniversal and sectionHeight(universalCount) or 0
    local gridContentHeight = showUniversal and (currentHeight + 16 + universalHeight) or currentHeight
    local mainTop = compact and 64 or 76
    local detailHeight = compact and 68 or 76
    local gridTop = mainTop + detailHeight + 8
    local footerY = height - 56
    local navItemHeight = compact and 42 or 46
    local navGap = 6
    local navContentHeight = gameNavCount * navItemHeight + math.max(0, gameNavCount - 1) * navGap
    return { width = width, height = height, scale = scale, pad = pad, gap = gap,
        cardHeight = cardHeight, compact = compact, left = left, mainWidth = mainWidth,
        mainTop = mainTop, detailHeight = detailHeight, gridTop = gridTop, columns = columns, cellWidth = cellWidth,
        gridContentHeight = gridContentHeight, currentHeight = currentHeight, universalHeight = universalHeight, footerY = footerY,
        gridHeight = compact and height - gridTop - 16 or footerY - gridTop - 12,
        navItemHeight = navItemHeight, navGap = navGap, navContentHeight = navContentHeight }
end

function Runtime.scenario(script)
    if type(script.scenario) ~= "string" then return "场景信息待接口同步" end
    local value = script.scenario:gsub("%s+", " "):match("^%s*(.-)%s*$")
    return value ~= "" and value or "未设置场景"
end

-- 此处仅格式化展示，不用于授权或租约判断。
function Runtime.remaining(seconds)
    if seconds == nil then return "长期有效" end
    if type(seconds) ~= "number" or seconds ~= seconds or math.abs(seconds) == math.huge then return "时间待同步" end
    if seconds <= 0 then return "已到期" end
    if seconds >= 86400 then return "剩余 " .. math.floor(seconds / 86400) .. " 天" end
    if seconds >= 3600 then return "剩余 " .. math.floor(seconds / 3600) .. " 小时" end
    if seconds >= 60 then return "剩余 " .. math.floor(seconds / 60) .. " 分钟" end
    return "剩余不足 1 分钟"
end

function Runtime.currentGame(scripts, universeId, placeId)
    local selected, score = nil, math.huge
    for _, script in ipairs(scripts) do
        local rank = Runtime.rank(script, universeId, placeId)
        if not script.universal and rank <= 1 and rank < score and type(script.game) == "table" and script.game.id == script.gameId then
            selected, score = script.game, rank
        end
    end
    return selected
end

function Runtime.deadline(sentAt, remaining)
    assert(type(remaining) == "number" and remaining == remaining and remaining > 0, "租约已失效")
    return sentAt + math.min(remaining, 90)
end

return Runtime
