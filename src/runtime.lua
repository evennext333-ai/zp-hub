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
        local words = { script.nameZh, script.nameEn, script.id, script.gameId, type(script.shortDescription) == "string" and script.shortDescription or "" }
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
function Runtime.layout(availableWidth, availableHeight, count)
    availableWidth = math.max(1, tonumber(availableWidth) or 600)
    availableHeight = math.max(1, tonumber(availableHeight) or 560)
    local width = math.max(700, math.min(1040, availableWidth))
    local height = math.max(340, math.min(720, availableHeight, math.floor(width * 0.7)))
    local scale = math.min(1, availableWidth / width, availableHeight / height)
    count = math.max(0, tonumber(count) or 0)
    local compact = width < 900 or height < 580
    local pad, gap, cardHeight = 20, 12, compact and 156 or 188
    local left = compact and 220 or 256
    local mainWidth = width - left - pad
    local columns = 3
    local cellWidth = math.floor((mainWidth - 8 - gap * (columns - 1)) / columns)
    local rows = math.ceil(count / columns)
    local gridContentHeight = rows > 0 and rows * cardHeight + (rows - 1) * gap + 4 or 100
    local mainTop = compact and 64 or 80
    local gridTop, footerY = mainTop + 100, height - 62
    return { width = width, height = height, scale = scale, pad = pad, gap = gap,
        cardHeight = cardHeight, compact = compact, left = left, mainWidth = mainWidth,
        mainTop = mainTop, gridTop = gridTop, columns = columns, cellWidth = cellWidth,
        gridContentHeight = gridContentHeight, footerY = footerY,
        gridHeight = compact and height - gridTop - 20 or footerY - gridTop - 14 }
end

function Runtime.description(script)
    local value = type(script.shortDescription) == "string" and script.shortDescription:gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
    return value ~= "" and value or "作者暂未填写脚本简介"
end

function Runtime.deadline(sentAt, remaining)
    assert(type(remaining) == "number" and remaining == remaining and remaining > 0, "租约已失效")
    return sentAt + math.min(remaining, 90)
end

return Runtime
