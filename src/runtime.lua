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

-- One horizontal workspace on every device; undersized viewports scale it as a unit.
function Runtime.layout(availableWidth, availableHeight, count, universalCount)
    availableWidth = math.max(1, tonumber(availableWidth) or 600)
    availableHeight = math.max(1, tonumber(availableHeight) or 560)
    local width = math.max(700, math.min(1040, availableWidth))
    local height = math.max(340, math.min(720, availableHeight, math.floor(width * 0.7)))
    local scale = math.min(1, availableWidth / width, availableHeight / height)
    count = math.max(0, tonumber(count) or 0)
    local compact = width < 900 or height < 580
    local pad, gap, cardHeight = 20, 12, compact and 144 or 156
    local left = compact and 220 or 256
    local mainWidth = width - left - pad
    local columns = 3
    local cellWidth = math.floor((mainWidth - 8 - gap * (columns - 1)) / columns)
    local function sectionHeight(items)
        local sectionRows = math.ceil(math.max(0, tonumber(items) or 0) / columns)
        return 32 + (sectionRows > 0 and sectionRows * cardHeight + (sectionRows - 1) * gap + 4 or 44)
    end
    local currentHeight, universalHeight = sectionHeight(count), sectionHeight(universalCount)
    local gridContentHeight = currentHeight + 16 + universalHeight
    local mainTop = compact and 64 or 80
    local gridTop, footerY = mainTop + 64, height - 62
    return { width = width, height = height, scale = scale, pad = pad, gap = gap,
        cardHeight = cardHeight, compact = compact, left = left, mainWidth = mainWidth,
        mainTop = mainTop, gridTop = gridTop, columns = columns, cellWidth = cellWidth,
        gridContentHeight = gridContentHeight, currentHeight = currentHeight, universalHeight = universalHeight, footerY = footerY,
        gridHeight = compact and height - gridTop - 20 or footerY - gridTop - 14 }
end

function Runtime.scenario(script)
    if type(script.scenario) ~= "string" then return "场景信息待接口同步" end
    local value = script.scenario:gsub("%s+", " "):match("^%s*(.-)%s*$")
    return value ~= "" and value or "未设置场景"
end

-- 后端日期为 UTC ISO；只调整展示，不参与授权或租约判断。
function Runtime.formatExpiry(value)
    if value == nil then return "长期有效" end
    if type(value) ~= "string" then return "时间待同步" end
    local y, m, d, h, minute, second, tail = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(.-)Z$")
    if not y or (tail ~= "" and not tail:match("^%.%d+$")) then return "时间待同步" end
    y, m, d, h, minute, second = tonumber(y), tonumber(m), tonumber(d), tonumber(h), tonumber(minute), tonumber(second)
    local days = {31, (y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0)) and 29 or 28, 31,30,31,30,31,31,30,31,30,31}
    if y < 1 or m < 1 or m > 12 or d < 1 or d > days[m] or h > 23 or minute > 59 or second > 59 then return "时间待同步" end
    h += 8
    if h >= 24 then
        h -= 24
        d += 1
        if d > days[m] then d, m = 1, m + 1 end
        if m > 12 then m, y = 1, y + 1 end
    end
    if y > 9999 then return "时间待同步" end
    return string.format("%04d-%02d-%02d %02d:%02d", y, m, d, h, minute)
end

function Runtime.deadline(sentAt, remaining)
    assert(type(remaining) == "number" and remaining == remaining and remaining > 0, "租约已失效")
    return sentAt + math.min(remaining, 90)
end

return Runtime
