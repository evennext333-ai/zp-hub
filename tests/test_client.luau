local fs = require("@lune/fs")
local luau = require("@lune/luau")
local rb = require("@lune/roblox")
local serde = require("@lune/serde")
local datetime = require("@lune/datetime")
local task = require("@lune/task")
local process = require("@lune/process")
local Runtime = luau.load(fs.readFile("src/runtime.lua"))()
local clientSource = fs.readFile(process.env.HUB_TEST_LOADER or "src/client.lua")
local originalSource = "assert(select('#', ...) == 0, '原脚本不接收 Hub 参数'); counters.starts += 1; return function() counters.cleanups += 1 end"
local fixtures, passed = {}, 0
local function untilTrue(callback)
    local deadline = os.clock() + 5
    repeat if callback() then return end; task.wait(0.01) until os.clock() >= deadline
    error("等待条件超时")
end
local function fixture(options)
    options = options or {}
    local objects, threads = {}, {}
    local counter = {logins=0, loads=0, heartbeats=0, deletes=0, loadIds={}, catalogs=0, guiLookups=0, starts=0, cleanups=0, kicks={}, warnings={}, sources={}}
    local server = {nowMillis=datetime.fromIsoDate("2027-04-08T16:00:00Z").unixTimestampMillis,source=options.source or originalSource, lease=options.lease or 90,
        delayLogin=options.delayLogin or 0, delayLoad=options.delayLoad or 0,
        delayHeartbeat=options.delayHeartbeat or 0, loginError=options.loginError,
        loadError=options.loadError, heartbeatError=options.heartbeatError,
        networkHeartbeat=options.networkHeartbeat, invalidHeartbeat=options.invalidHeartbeat, loginNetworkOnce=options.loginNetworkOnce}
    local hubEnv = {}
    if not options.noKey then hubEnv.HUB_KEY=options.externalKey~=nil and options.externalKey or "RSH_" .. string.rep("a",43) end
    if options.legacyHub then hubEnv.__RSZH_HUB={alive=true,focus=function()error("旧实例不应复用")end} end
    local function signal()
        local listeners = {}
        return {
            Connect=function(_, callback)
                local c = {Connected=true}
                function c:Disconnect() self.Connected=false end
                table.insert(listeners,{c,callback});return c
            end,
            Fire=function(_, ...)
                for _, entry in ipairs(table.clone(listeners)) do if entry[1].Connected then entry[2](...) end end
            end,
        }
    end
    local function create(class)
        local native = rb.Instance.new(class)
        local data = {ClassName=class,AbsoluteSize=rb.Vector2.new(600,560),Activated=signal(),InputBegan=signal(),Destroying=signal(),signals={},native=native}
        if options.centeredButtons and class=="TextButton" then data.AnchorPoint=rb.Vector2.new(0.5,0.5) end
        local item = setmetatable({}, {
            __index=function(_,key)
                if data[key]~=nil then return data[key] end
                local ok,value=pcall(function()return native[key]end)
                if ok then return value end
                return nil
            end,
            __newindex=function(_,key,value)
                if server.uiWriteError and key=="Text" then error("fixture UI write error") end
                if key=="Parent" then
                    native.Parent=type(value)=="table" and value.native or nil
                elseif key~="AbsoluteSize" and key~="destroyed" then
                    local ok,err=pcall(function()native[key]=value end)
                    assert(ok,"无效 Roblox 属性："..class.."."..key.." / "..tostring(err))
                end
                data[key]=value
            end,
        })
        data.CaptureFocus=function()counter.focusedKeyInput=true end
        data.MockSetLoaded=function(value)
            data.IsLoaded=value
            if data.signals.IsLoaded then data.signals.IsLoaded:Fire() end
        end
        data.GetPropertyChangedSignal=function(_,name)
            if not data.signals[name] then data.signals[name]=signal() end
            return data.signals[name]
        end
        data.Destroy=function(self)
            if self.destroyed then return end
            self.destroyed=true;self.Destroying:Fire()
            for _,child in ipairs(objects)do if child.Parent==self then child:Destroy()end end
            self.Parent=nil
        end
        table.insert(objects,item);return item
    end
    local function find(text)
        local fallback
        for _, item in ipairs(objects) do
            if not item.destroyed and item.Text and item.Text:find(text,1,true) then
                if item.ClassName=="TextButton" then return item end
                fallback=item
            end
        end
        return assert(fallback,"控件缺失："..text)
    end
    local taskShim = {wait=task.wait,cancel=task.cancel}
    local spawns = 0
    function taskShim.spawn(callback,...)
        spawns += 1
        local thread
        if options.starveWatchdog and process.env.HUB_TEST_STARVE_WATCHDOG=="1" and spawns==1 then
            thread=task.spawn(function(...)task.wait(2);callback(...)end,...)
        else thread=task.spawn(callback,...) end
        table.insert(threads,thread);return thread
    end
    local generation=0
    local player = {WaitForChild=function()
        counter.guiLookups+=1
        if server.guiUnavailable then error("fixture PlayerGui unavailable") end
        if server.guiDelay then task.wait(server.guiDelay) end
        return {}
    end}
    if not options.missingKick then
        function player:Kick(message)
            table.insert(counter.kicks,message)
            if options.kickFails then error("fixture Kick failure") end
        end
    end
    local userInput = {InputChanged=signal(),InputEnded=signal(),WindowFocusReleased=signal()}
    local services = {
        UserInputService=userInput,
        Players={LocalPlayer=player},
        HttpService={JSONEncode=function(_,v)return serde.encode("json",v)end,JSONDecode=function(_,v)return serde.decode("json",v)end,
            GenerateGUID=function()generation+=1;return string.format("00000000-0000-4000-8000-%012d",generation)end},
    }
    local environment = {
        Runtime=Runtime,API="https://TARGET",task=taskShim,counters=counter,
        DateTime={fromIsoDate=function(value)return {UnixTimestampMillis=datetime.fromIsoDate(value).unixTimestampMillis}end,
            now=function()counter.dateReads=(counter.dateReads or 0)+1;return {UnixTimestampMillis=server.nowMillis}end},
        game={GameId=1,PlaceId=2,GetService=function(_,name)return services[name]end},
        getgenv=function()return hubEnv end,gethwid=function()return "fixture-device" end,
        Instance={new=create},UDim2=rb.UDim2,UDim=rb.UDim,Vector2=rb.Vector2,Color3=rb.Color3,Enum=rb.Enum,
        warn=function(message)table.insert(counter.warnings,message)end,
    }
    if options.fastHeartbeats then environment.os=table.clone(os);environment.os.clock=function()return os.clock()*80 end end
    local entry={id="hall-7",gameId="demo",nameZh="授权检查",nameEn="Check",enabled=true,universal=false,lifecycle="managed",placeIds={2},universeIds={1},tags={},aliases={},scenario="授权连接 / 状态检查",shortDescription="不应显示这段简介"}
    environment.request=function(args)
        if not args.Body then assert(args.Headers["Content-Type"]==nil,"空正文请求不声明 JSON") end
        local data, err, status
        if args.Url:find("/catalog",1,true) then
            counter.catalogs+=1
            if options.destroyDuringCatalog then
                for _,o in ipairs(objects)do if o.Name=="RSZH_Hub" and not o.destroyed then o:Destroy()end end
            end
            data={version="hall-fixture",scripts=options.catalog or {entry}}
        elseif args.Url:find("/heartbeat",1,true) then
            counter.heartbeats+=1;local networkFailure=server.networkHeartbeat;task.wait(server.delayHeartbeat)
            if networkFailure then err="NETWORK_ERROR";status=503
            else err=server.heartbeatError end
            local body=serde.decode("json",args.Body)
            data={sessionId=server.invalidHeartbeat and "another-session" or "fixture",sequence=body.sequence,remainingLeaseSeconds=90,kind=options.kind or "GAME",gameId=options.gameId or "demo",entitlementExpiresAt=options.expiresAt}
        elseif args.Url:find("/load",1,true) then
            local id=args.Url:match("/api/hub/scripts/(hall%-%d+)/load$")
            local exists=false
            for _,script in ipairs(options.catalog or {entry})do if script.id==id then exists=true end end
            assert(exists,"仅加载目录中存在的脚本")
            table.insert(counter.loadIds,id)
            counter.loads+=1;task.wait(server.delayLoad);err=server.loadError
            data={id=id,version=id.."-r1",source=server.source}
        elseif args.Method=="DELETE" then counter.deletes+=1;counter.logoutSawKicks=#counter.kicks;data=serde.null
        else
            local body=serde.decode("json",args.Body)
            assert(body.key==(options.expectedKey or "RSH_"..string.rep("a",43)),"仅发送夹具指定 Key")
            counter.logins+=1;task.wait(server.delayLogin);err=server.loginError
            if server.loginNetworkOnce and counter.logins==1 then err="NETWORK_ERROR";status=503 end
            data={token="HS1.fixture",sessionId="fixture",remainingLeaseSeconds=server.lease,kind=options.kind or "GAME",gameId=options.gameId or "demo",entitlementExpiresAt=options.expiresAt}
        end
        if err then return {StatusCode=status or 401,Body=serde.encode("json",{success=false,error={code=err}})} end
        return {StatusCode=200,Body=serde.encode("json",{success=true,data=data})}
    end
    environment.loadstring=function(source)
        table.insert(counter.sources,source)
        local ok,fn=pcall(luau.load,source,{environment=environment})
        if not ok then return nil,fn end
        if options.endDuringCompile then
            for _,o in ipairs(objects)do if o.Text=="结束本局" and not o.destroyed then o.Activated:Fire()end end
        end
        if options.closeDuringCompile then
            for _,o in ipairs(objects)do if o.Name=="RSZH_Hub" and not o.destroyed then o:Destroy()end end
        end
        return fn
    end
    local client=luau.load(clientSource,{environment=environment})
    local f={counter=counter,server=server,env=hubEnv,objects=objects,find=find,client=client,inputService=userInput}
    function f.byName(name)
        for _,item in ipairs(objects) do if item.Name==name and not item.destroyed then return item end end
        error("对象缺失："..name)
    end
    function f.resize(width,height)
        f.byName("RSZH_Hub").AbsoluteSize=rb.Vector2.new(width/0.94,(height+40)/0.9)
        local viewport=f.byName("HubViewport")
        viewport.AbsoluteSize=rb.Vector2.new(width,height)
        viewport:GetPropertyChangedSignal("AbsoluteSize"):Fire()
    end
    function f.click(text)local target=find(text);assert(target.Visible~=false,"点击目标应可见");target.Activated:Fire()end
    function f.play()f.click("授权检查")end
    function f.close()
        local ok,button=pcall(find,"关闭界面")
        if ok then button.Activated:Fire() end
    end
    function f.finish()
        if f.owner and f.owner.alive then f.owner.focus();f.click("结束本局") end
    end
    function f.destroy()for _,o in ipairs(objects)do if o.Name=="RSZH_Hub" and not o.destroyed then o:Destroy()end end end
    counter.clearUI=f.destroy
    function f.cleanup()
        server.guiUnavailable=false;server.guiDelay=nil;server.uiWriteError=false
        pcall(f.finish)
        if f.owner then assert(not f.owner.alive, "手动结束本局应终止控制器") end
        for _,thread in ipairs(threads)do if coroutine.status(thread)~="dead" then pcall(task.cancel,thread)end end
    end
    table.insert(fixtures,f)
    if options.missingKick or options.legacyHub then
        assert(not pcall(client),"缺少 Kick 或旧策略单例时不启动新脚本")
        assert(hubEnv.HUB_KEY==nil,"初始化被拒绝也清理外部 Key")
        return f
    end
    client();f.owner=hubEnv.__RSZH_HUB;assert(hubEnv.HUB_KEY==nil,"外部 Key 使用后清理")
    -- 默认夹具等待无延迟的自动登录；延迟用例保留真实竞态。
    if not options.noKey and server.delayLogin==0 and not options.destroyDuringCatalog then
        untilTrue(function()return f.byName("SessionStatus").Text~="正在校验授权…"end)
    end
    return f
end
local function check(name,callback)
    local ok,err=pcall(callback)
    for _,f in ipairs(fixtures)do
        local cleanOk,cleanError=pcall(f.cleanup)
        if not cleanOk then ok=false;err=cleanError end
    end
    fixtures={}
    if not ok then warn(name.."："..tostring(err));process.exit(1) end
    passed+=1
end

-- Optional scene export uses synthetic catalog data; no live API or real Key is read.
if process.env.HUB_UI_PREVIEW_DIR then
    check("导出三端布局预览",function()
        local sample={}
        local names={"资源收集助手","地图快捷导航","角色状态面板","画面与性能设置","采集路径标记","通用界面工具"}
        local descriptions={"资源采集 / 日常任务","地图探索 / 快捷导航","角色状态 / 任务追踪","画面调整 / 性能优化","路线标记 / 兴趣点","通用工具 / 界面管理"}
        for index,name in ipairs(names) do table.insert(sample,{id="hall-"..index,gameId="preview",nameZh=name,nameEn="Preview "..index,scenario=descriptions[index],shortDescription="不应显示简介",enabled=true,universal=index>3,game={id="preview",nameZh="游戏布局示例",nameEn="Game Preview"},placeIds=index<=3 and {2} or {},universeIds={},aliases={},tags={}}) end
        local cases={{"pc",1440,900,1040,720},{"tablet",1024,768,962,691},{"phone",844,390,793,311},{"landscape",667,375,627,297},{"pc-member",1440,900,1040,720,"MEMBER"},{"phone-member",844,390,793,311,"MEMBER"},{"phone-game",844,390,793,311,"GAME"}}
        local output=process.env.HUB_UI_PREVIEW_DIR
        fs.writeDir(output)
        for _,screen in ipairs(cases) do
            local f=fixture({catalog=sample,noKey=not screen[6],kind=screen[6],gameId="preview",expiresAt="2027-04-08T16:05:33.375Z"});f.resize(screen[4],screen[5])
            local nodes,ids={},{}
            for index,o in ipairs(f.objects) do ids[o]=index end
            local function dim(value)return value and {value.X.Scale,value.X.Offset,value.Y.Scale,value.Y.Offset} or nil end
            local function color(value)return value and {math.round(value.R*255),math.round(value.G*255),math.round(value.B*255)} or nil end
            for index,o in ipairs(f.objects) do
                if not o.destroyed then
                    local entry={id=index,parent=ids[o.Parent],class=o.ClassName,name=o.Name,text=o.Text,placeholder=o.PlaceholderText,
                        position=dim(o.Position),size=dim(o.Size),visible=o.Visible,background=color(o.BackgroundColor3),textColor=color(o.TextColor3),
                        backgroundTransparency=o.BackgroundTransparency,textTransparency=o.TextTransparency,textSize=o.TextSize,
                        font=o.Font and tostring(o.Font),align=o.TextXAlignment and tostring(o.TextXAlignment),vertical=o.TextYAlignment and tostring(o.TextYAlignment),
                        zIndex=o.ZIndex,order=o.LayoutOrder,scrolling=o.ScrollingEnabled,canvas=dim(o.CanvasSize),cellSize=dim(o.CellSize),cellPadding=dim(o.CellPadding),columns=o.FillDirectionMaxCells,
                        anchor=o.AnchorPoint and {o.AnchorPoint.X,o.AnchorPoint.Y},radius=o.CornerRadius and o.CornerRadius.Offset,stroke=color(o.Color),scale=o.Scale}
                    if o.Name=="HubViewport" then entry.size={0,screen[4],0,screen[5]} end
                    table.insert(nodes,entry)
                end
            end
            fs.writeFile(output.."/"..screen[1]..".json",serde.encode("json",{width=screen[2],height=screen[3],nodes=nodes}))
        end
    end)
end

check("登录浏览心跳恢复都不预取正文，仅显式点击后加载一次",function()
    local f=fixture({kind="MEMBER"})
    assert(f.counter.logins==1 and f.counter.loads==0 and #f.counter.sources==0 and f.counter.starts==0)
    f.resize(793,311);f.click("收起");f.byName("ToggleHub").Activated:Fire()
    f.close();f.client();untilTrue(function()return f.counter.heartbeats>=1 end)
    assert(f.counter.loads==0 and #f.counter.sources==0 and f.counter.starts==0)
    f.play();untilTrue(function()return f.counter.starts==1 end)
    assert(f.counter.loads==1 and f.counter.sources[1]==originalSource)
    f.play();task.wait(0.03);assert(f.counter.loads==1 and f.counter.starts==1)
end)
check("外部 Key 自动校验且不自动启动脚本",function()
    local f=fixture()
    untilTrue(function()return f.counter.logins==1 and f.byName("SessionStatus").Text:find("授权有效",1,true)end)
    assert(f.counter.loads==0 and f.counter.starts==0 and f.env.HUB_KEY==nil)
    assert(f.byName("KeyInput").Text=="","完整 Key 不回填到界面")
    assert(not f.byName("KeyInput").Visible and not f.byName("ValidateKey").Visible)
    f.play();untilTrue(function()return f.counter.starts==1 end)
end)
check("未登录卡片弹窗仅保留单个按钮且不隐式提交输入的 Key",function()
    local f=fixture({noKey=true})
    assert(f.byName("KeyInput").ClipsDescendants and f.byName("KeyInput").TextTruncate==rb.Enum.TextTruncate.AtEnd,"Key 输入框应裁剪并省略溢出文本")
    f.play()
    assert(f.byName("AuthPromptOverlay").Visible and f.byName("AuthPromptTitle").Text=="请先校验 Key")
    assert(not pcall(f.byName,"AuthPromptLater"),"弹窗仅保留一个按钮")
    assert(f.counter.logins==0 and f.counter.loads==0 and #f.counter.kicks==0)
    assert(f.byName("AuthPromptOverlay").Modal and f.byName("AuthPromptOverlay").ZIndex>f.byName("DragHandle").ZIndex)
    for _,size in ipairs({{627,297},{1040,720}})do
        f.resize(size[1],size[2])
        local prompt,window=f.byName("AuthPrompt"),f.byName("HubWindow")
        assert(prompt.Size.X.Offset<=window.Size.X.Offset and prompt.Size.Y.Offset<=window.Size.Y.Offset)
        assert(f.byName("AuthPromptValidate").Size.Y.Offset>=44 and f.byName("AuthPromptValidate").Size.X.Offset==300)
    end
    f.byName("AuthPromptValidate").Activated:Fire();assert(not f.byName("AuthPromptOverlay").Visible)
    f.byName("KeyInput").Text="RSH_"..string.rep("a",43);f.play()
    assert(f.counter.logins==0 and f.counter.loads==0,"输入了 Key 仍需明确校验")
    f.byName("AuthPromptValidate").Activated:Fire()
    assert(not f.byName("AuthPromptOverlay").Visible and f.counter.focusedKeyInput)
    f.click("校验 Key");untilTrue(function()return f.byName("SessionStatus").Text:find("授权有效",1,true)end)
    f.play();untilTrue(function()return f.counter.starts==1 end)
end)
check("无 Key 打开后重跑带 Key 入口会提交到现有控制器",function()
    local key="RSH_"..string.rep("b",43)
    local f=fixture({noKey=true,expectedKey=key})
    f.close();f.env.HUB_KEY="  "..key.."  ";f.client()
    untilTrue(function()return f.byName("SessionStatus").Text:find("授权有效",1,true)end)
    assert(f.env.__RSZH_HUB==f.owner and f.env.HUB_KEY==nil)
    assert(f.counter.logins==1 and f.counter.catalogs==1 and f.counter.loads==0)
    f.env.HUB_KEY=key;f.client();task.wait(0.03)
    assert(f.counter.logins==1,"有效会话不因重跑入口重复登录")
end)
check("自动校验期间点击卡片只提示等待，成功后关闭提示",function()
    local f=fixture({delayLogin=0.2})
    f.play();assert(f.byName("AuthPromptOverlay").Visible)
    assert(f.byName("AuthPromptTitle").Text=="正在校验 Key")
    f.env.HUB_KEY="RSH_"..string.rep("a",43);f.client()
    untilTrue(function()return f.byName("SessionStatus").Text:find("授权有效",1,true)end)
    assert(not f.byName("AuthPromptOverlay").Visible and f.counter.logins==1 and f.counter.loads==0)
end)
check("外部 Key 校验失败后可手动重试，不因失败误踢",function()
    local f=fixture({loginError="HUB_KEY_INVALID"})
    assert(f.byName("SessionStatus").Text:find("Key 无效",1,true) and #f.counter.kicks==0)
    f.play();assert(f.byName("AuthPromptOverlay").Visible and f.counter.loads==0)
    f.byName("AuthPromptValidate").Activated:Fire()
    f.server.loginError=nil;f.byName("KeyInput").Text="RSH_"..string.rep("a",43)
    f.click("校验 Key");untilTrue(function()return f.byName("SessionStatus").Text:find("授权有效",1,true)end)
    assert(f.counter.logins==2 and f.counter.loads==0 and f.env.HUB_KEY==nil)
end)
check("空白和非字符串外部 Key 不自动登录",function()
    for _,key in ipairs({"  ",123})do
        local f=fixture({externalKey=key});f.play()
        assert(f.counter.logins==0 and f.counter.loads==0 and f.env.HUB_KEY==nil)
        assert(f.byName("AuthPromptOverlay").Visible)
    end
end)
check("等待弹窗在登录失败后关闭并展示真实失败状态",function()
    local f=fixture({delayLogin=0.2,loginError="HUB_KEY_INVALID"})
    f.play();assert(f.byName("AuthPromptOverlay").Visible)
    untilTrue(function()return f.byName("SessionStatus").Text:find("Key 无效",1,true)end)
    assert(not f.byName("AuthPromptOverlay").Visible and #f.counter.kicks==0 and f.counter.loads==0)
end)
check("旧版本单例不静默丢弃重新传入的 Key",function()
    local f=fixture({noKey=true});f.owner.submitKey=nil
    f.env.HUB_KEY="RSH_"..string.rep("a",43);f.client()
    assert(f.counter.logins==0 and #f.counter.warnings==1)
    assert(f.counter.warnings[1]:find("重新进入游戏",1,true) and f.env.HUB_KEY==nil)
end)
check("授权卡片分状态展示，恢复后保留格式化权益",function()
    local f=fixture({kind="MEMBER",expiresAt="2027-04-08T16:05:33.375Z"})
    assert(f.byName("AuthBadge").Text=="已校验" and f.byName("EntitlementKind").Text=="全游戏会员")
    assert(f.byName("ExpiryValue").Text=="剩余 5 分钟")
    assert(f.byName("ExpiryLabel").Text=="剩余有效期")
    assert(not f.byName("KeyInput").Visible and not f.byName("ValidateKey").Visible and not f.byName("SessionStatus").Visible)
    f.destroy();f.client()
    assert(f.byName("ExpiryValue").Text=="剩余 5 分钟" and f.counter.logins==1)
    assert(f.byName("EntitlementKind").Visible and not f.byName("KeyInput").Visible)
    local empty=fixture({noKey=true})
    assert(empty.byName("AuthBadge").Text=="未校验" and empty.byName("KeyInput").Visible)
    assert(not empty.byName("ExpiryValue").Visible and not empty.byName("EntitlementKind").Visible)
    local busy=fixture({delayLogin=0.2})
    assert(busy.byName("AuthBadge").Text=="校验中" and not busy.byName("ValidateKey").Active and not busy.byName("KeyInput").TextEditable)
    untilTrue(function()return busy.byName("AuthBadge").Text=="已校验"end)
end)
check("后续心跳更新权益日期，不重复登录或影响租约",function()
    local options={kind="MEMBER",expiresAt="2027-04-08T16:05:33.375Z",fastHeartbeats=true}
    local f=fixture(options)
    options.expiresAt="2027-05-01T00:00:00.000Z"
    untilTrue(function()return f.byName("ExpiryValue").Text=="剩余 22 天"end)
    assert(f.counter.logins==1 and f.counter.loads==0 and #f.counter.kicks==0)
end)
check("长期会员和单游戏到期展示不改变后台截止时间",function()
    local member=fixture({kind="MEMBER"})
    assert(member.byName("ExpiryValue").Text=="长期有效")
    local game=fixture({expiresAt="2027-04-10T16:00:00.000Z"})
    assert(game.byName("EntitlementKind").Text=="单游戏 · 30 天" and game.byName("ExpiryValue").Text=="剩余 2 天")
end)
local universalCatalog={
    {id="hall-7",gameId="demo",nameZh="授权检查",nameEn="Current",enabled=true,universal=false,placeIds={2},universeIds={1},tags={},aliases={},scenario="当前场景"},
    {id="hall-9",gameId="common",nameZh="通用工具",nameEn="Common",enabled=true,universal=true,placeIds={},universeIds={},tags={},aliases={},scenario="通用场景"},
}
check("全游戏会员手动加载通用脚本，同局仍仅启动一份原脚本",function()
    local f=fixture({kind="MEMBER",catalog=universalCatalog})
    assert(f.counter.loads==0,"登录不自动执行通用脚本")
    f.byName("ScriptCard_hall-9").Activated:Fire();untilTrue(function()return f.counter.starts==1 end)
    assert(f.counter.loadIds[1]=="hall-9" and f.byName("ScriptCard_hall-9").Parent.Name=="UniversalCards")
    f.play();task.wait(0.03);assert(f.counter.loads==1 and f.counter.starts==1)
    local function action(id)
        for _,o in ipairs(f.objects)do if not o.destroyed and o.Name=="CardAction" and o.Parent.Name=="ScriptCard_"..id then return o.Text end end
    end
    assert(action("hall-9")=="运行中" and action("hall-7")=="重新进入后切换")
    f.destroy();f.client();assert(action("hall-9")=="运行中" and f.counter.loads==1)
end)
check("单游戏 Key 的通用项目仍按 gameId 判断，不扩大权益",function()
    local f=fixture({catalog=universalCatalog})
    f.byName("ScriptCard_hall-9").Activated:Fire();task.wait(0.03)
    assert(f.counter.loads==0 and #f.counter.kicks==0 and f.find("此 Key 未包含"))
    local matching=fixture({catalog=universalCatalog,gameId="common"})
    matching.byName("ScriptCard_hall-9").Activated:Fire();untilTrue(function()return matching.counter.starts==1 end)
    assert(matching.counter.loadIds[1]=="hall-9")
end)
check("通用区未校验同样弹窗且不触发请求",function()
    local f=fixture({catalog=universalCatalog,noKey=true})
    f.byName("ScriptCard_hall-9").Activated:Fire()
    assert(f.byName("AuthPromptOverlay").Visible and f.counter.logins==0 and f.counter.loads==0)
end)
check("没有当前游戏时仍可展示并加载通用脚本",function()
    local f=fixture({catalog={universalCatalog[2]},kind="MEMBER"})
    assert(f.byName("CurrentEmpty").Visible and not f.byName("UniversalEmpty").Visible)
    f.byName("ScriptCard_hall-9").Activated:Fire();untilTrue(function()return f.counter.starts==1 end)
end)
for _,mode in ipairs({"close","destroy","collapse"})do
    for _,code in ipairs({"HUB_SESSION_REPLACED","HUB_VIP_REQUIRED","HUB_LICENSE_EXPIRED"})do
        check("不运行脚本时 UI "..mode.." 后仍结束失效授权 "..code,function()
            local f=fixture()
            if mode=="close" then f.close()elseif mode=="destroy" then f.destroy()else f.click("收起")end
            f.server.heartbeatError=code
            untilTrue(function()return #f.counter.kicks==1 end)
            assert(f.counter.starts==0 and #f.counter.kicks==1 and not f.owner.alive)
        end)
    end
end
check("界面刷新异常只关闭视图，不中止后台授权心跳",function()
    local f=fixture({fastHeartbeats=true})
    f.server.uiWriteError=true
    untilTrue(function()return #f.counter.warnings==1 end)
    untilTrue(function()return f.counter.heartbeats>=2 end)
    assert(f.owner.alive and #f.counter.kicks==0 and f.counter.deletes==0)
    f.server.uiWriteError=false;f.client()
    assert(f.byName("AuthBadge").Text=="已校验" and f.counter.logins==1)
end)
check("剩余时间随 UI 计时刷新，壁钟变化不改租约或结束本局",function()
    local f=fixture({expiresAt="2027-04-08T16:02:00Z"})
    assert(f.byName("ExpiryValue").Text=="剩余 2 分钟")
    f.server.nowMillis+=75000
    untilTrue(function()return f.byName("ExpiryValue").Text=="剩余不足 1 分钟"end)
    f.server.nowMillis+=60000
    untilTrue(function()return f.byName("ExpiryValue").Text=="已到期"end)
    assert(#f.counter.kicks==0 and f.owner.alive,"展示时间不代替服务端和单调时钟授权判断")
    f.close();local reads=f.counter.dateReads;task.wait(1.1)
    assert(f.counter.dateReads==reads,"关闭界面后 UI 计时器释放")
    f.client();assert(f.byName("ExpiryValue").Text=="已到期" and f.counter.logins==1)
end)
check("无效日期只提示待同步，不影响授权和脚本加载",function()
    local f=fixture({expiresAt="invalid"})
    assert(f.byName("ExpiryValue").Text=="时间待同步" and f.byName("AuthBadge").Text=="已校验")
    f.play();untilTrue(function()return f.counter.starts==1 end)
end)
check("当前游戏头部使用独立中英文资料和原生图标",function()
    local entry={id="hall-7",gameId="demo",nameZh="授权检查",nameEn="Script",enabled=true,placeIds={2},universeIds={1},scenario="场景",aliases={"不应作为游戏名"},tags={},
        game={id="demo",nameZh="中文游戏",nameEn="English Game",imageUrl="https://tr.rbxcdn.com/icon.png"}}
    local f=fixture({catalog={entry}})
    assert(f.byName("LibraryTitle").Text=="中文游戏" and f.byName("CurrentGameNameEn").Text=="English Game")
    assert(f.byName("CurrentGameImage").Image=="rbxthumb://type=GameIcon&id=1&w=150&h=150")
    assert(f.byName("CurrentGamePlaceholder").Visible,"图片加载前保留占位")
    f.byName("CurrentGameImage").MockSetLoaded(true)
    assert(not f.byName("CurrentGamePlaceholder").Visible,"图像就绪后隐藏占位")
    for _,screen in ipairs({{1040,720},{793,311},{627,297}})do
        f.resize(screen[1],screen[2])
        local image,title,en,status,list=f.byName("CurrentGameImage"),f.byName("LibraryTitle"),f.byName("CurrentGameNameEn"),f.byName("OperationStatus"),f.byName("ScriptGrid")
        assert(image.Position.X.Offset+image.Size.X.Offset<title.Position.X.Offset)
        assert(title.Position.X.Offset+title.Size.X.Offset<=f.byName("ScriptCount").Position.X.Offset)
        assert(en.Position.Y.Offset+en.Size.Y.Offset<=status.Position.Y.Offset and status.Position.Y.Offset+status.Size.Y.Offset<list.Position.Y.Offset)
    end
    f.destroy();f.client();assert(f.byName("LibraryTitle").Text=="中文游戏" and f.counter.catalogs==1)
end)
check("旧目录和未配置游戏名不从脚本标题或通用项猜测",function()
    local f=fixture()
    assert(f.byName("LibraryTitle").Text=="当前游戏" and f.byName("CurrentGameNameEn").Text=="游戏资料待同步")
    assert(f.counter.catalogs==1 and f.counter.loads==0)
end)
check("按钮中心锚点的偏移回归",function()
    local f=fixture({centeredButtons=true})
    for _,size in ipairs({{700,340},{793,351},{1040,720}})do
        f.resize(size[1],size[2])
        for _,name in ipairs({"ValidateKey","CloseView","CollapseView","EndSession"})do
            local item=f.byName(name)
            assert(item.AnchorPoint==rb.Vector2.new(0,0),"位置按左上角计算，必须显式重置锚点："..name)
        end
    end
end)
check("原样执行、分区布局、关闭与单实例恢复",function()
    local f=fixture();local panel=f.byName("HubWindow")
    f.resize(640,320)
    assert(not panel.ScrollingEnabled and f.byName("ScriptGrid").ScrollingEnabled)
    assert(not pcall(f.byName,"ScriptSearch") and not pcall(f.byName,"AllScripts") and not pcall(f.byName,"AvailableScripts"))
    f.play();untilTrue(function()return f.counter.starts==1 end)
    assert(f.counter.sources[1]==originalSource,"正文逐字执行，不注入代码")
    f.play();task.wait(0.02);assert(f.counter.starts==1)
    f.click("收起");assert(f.byName("ToggleHub").Visible and not panel.Visible);f.env.HUB_KEY="RSH_"..string.rep("b",43)
    f.client();assert(f.byName("HubWindow").Visible and not f.byName("ToggleHub").Visible and f.counter.logins==1 and f.env.HUB_KEY==nil)
    f.close()
    assert(#f.counter.kicks==0 and f.counter.deletes==0 and f.owner.alive and f.env.__RSZH_HUB==f.owner)
    f.client();assert(f.find("本局已启动") and f.counter.guiLookups==2)
    assert(f.counter.logins==1 and f.counter.loads==1 and f.counter.starts==1 and f.counter.catalogs==1)
    f.finish();untilTrue(function()return f.counter.deletes==1 end)
    assert(#f.counter.kicks==1 and f.counter.cleanups==0,"返回函数不当作卸载契约")
    assert(not f.env.__RSZH_HUB)
end)
check("PC、平板、手机及横屏布局与触控区域",function()
    local f=fixture()
    for _,size in ipairs({{1040,720,3},{962,691,3},{793,351,3},{627,337,3},{640,300,3}}) do
        f.resize(size[1],size[2])
        local layout=Runtime.layout(size[1],size[2],1)
        local window,list,grid=f.byName("HubWindow"),f.byName("ScriptGrid"),f.byName("CurrentCardLayout")
        assert(grid.ClassName=="UIGridLayout" and grid.FillDirectionMaxCells==size[3])
        local heading,collapse,close=f.byName("Heading"),f.byName("CollapseView"),f.byName("CloseView")
        assert(heading.Position.X.Offset+heading.Size.X.Offset<=collapse.Position.X.Offset)
        assert(collapse.Position.X.Offset+collapse.Size.X.Offset<=close.Position.X.Offset)
        assert(not f.byName("ToggleHub").Visible,"展开时浮动恢复按钮不遮挡内容")
        assert(not window.ScrollingEnabled and list.ScrollingEnabled,"仅卡片区域滚动")
        assert(window.Size.X.Offset>window.Size.Y.Offset and grid.FillDirectionMaxCells==3,"始终使用横版三列")
        assert(window.Size.X.Offset*layout.scale<=size[1]+0.01 and window.Size.Y.Offset*layout.scale<=size[2]+0.01,"小屏整体缩放后位于视口内")
        assert(grid.CellSize.X.Offset>0 and grid.CellSize.Y.Offset==layout.cardHeight)
        local stop=f.byName("EndSession")
        assert(list.Position.Y.Offset+list.Size.Y.Offset<=stop.Position.Y.Offset or list.Position.X.Offset>=stop.Position.X.Offset+stop.Size.X.Offset,"卡片不覆盖结束按钮")
        for _,name in ipairs({"ValidateKey","CloseView","CollapseView","EndSession","ToggleHub"}) do
            assert(f.byName(name).Size.Y.Offset>=44,"触控目标至少44px："..name)
        end
        local footer=f.byName("EndSession")
        local bottom=footer.Position.Y.Offset+footer.Size.Y.Offset
        assert(bottom<=layout.height)
    end
    assert(f.byName("Scenario").Text=="授权连接 / 状态检查")
    assert(f.byName("Scenario").RichText==false)
end)
check("真实属性与缩放锚点几何检查",function()
    local f=fixture({centeredButtons=true})
    for _,size in ipairs({{700,340},{793,351},{1040,720}})do
        f.resize(size[1],size[2])
        local function rect(name)
            local o=f.byName(name)
            local x=o.Position.X.Offset-o.AnchorPoint.X*o.Size.X.Offset
            local y=o.Position.Y.Offset-o.AnchorPoint.Y*o.Size.Y.Offset
            return {x=x,y=y,w=o.Size.X.Offset,h=o.Size.Y.Offset}
        end
        local function apart(a,b)return a.x+a.w<=b.x or b.x+b.w<=a.x or a.y+a.h<=b.y or b.y+b.h<=a.y end
        assert(apart(rect("CollapseView"),rect("CloseView")),"收起和关闭不重叠")
        assert(apart(rect("AuthTitle"),rect("AuthBadge")),"授权标题与状态不重叠")
        assert(apart(rect("KeyInput"),rect("ValidateKey")),"Key 输入与按钮不重叠")
        assert(f.byName("ValidateKey").Style==rb.Enum.ButtonStyle.Custom)
        assert(f.byName("HubWindow").ClassName=="Frame")
        assert(f.byName("RSZH_Hub").DisplayOrder==10000,"Hub 高于普通游戏背包界面")
        assert(f.byName("DragHandle").Position.X.Offset+f.byName("DragHandle").Size.X.Offset<=rect("CollapseView").x,"拖动区域不覆盖操作按钮")
    end
    assert(not pcall(f.byName,"ShortDescription"),"卡片不再创建简介控件")
end)
check("鼠标拖动、触控独占与窗口边界",function()
    local f=fixture({noKey=true});f.resize(1040,720)
    f.byName("RSZH_Hub").AbsoluteSize=rb.Vector2.new(1440,900)
    local handle=f.byName("DragHandle")
    local mouse={UserInputType=rb.Enum.UserInputType.MouseButton1,Position=rb.Vector3.new(100,100,0)}
    handle.InputBegan:Fire(mouse)
    f.inputService.InputChanged:Fire({UserInputType=rb.Enum.UserInputType.MouseMovement,Position=rb.Vector3.new(160,130,0)})
    local host=f.byName("HubViewport")
    assert(host.Position.X.Offset==60 and host.Position.Y.Offset==10)
    f.inputService.InputEnded:Fire(mouse)
    f.inputService.InputChanged:Fire({UserInputType=rb.Enum.UserInputType.MouseMovement,Position=rb.Vector3.new(200,200,0)})
    assert(host.Position.X.Offset==60)
    local touch={UserInputType=rb.Enum.UserInputType.Touch,Position=rb.Vector3.new(100,100,0)}
    handle.InputBegan:Fire(touch)
    f.inputService.InputChanged:Fire({UserInputType=rb.Enum.UserInputType.Touch,Position=rb.Vector3.new(500,500,0)})
    assert(host.Position.X.Offset==60,"其他手指不接管拖动")
    touch.Position=rb.Vector3.new(5000,5000,0);f.inputService.InputChanged:Fire(touch)
    assert(host.Position.X.Offset==192 and host.Position.Y.Offset==42,"不移出屏幕")
    f.inputService.WindowFocusReleased:Fire()
    touch.Position=rb.Vector3.new(0,0,0);f.inputService.InputChanged:Fire(touch)
    assert(host.Position.X.Offset==192)
    f.close();f.inputService.InputChanged:Fire(touch)
    assert(f.counter.logins==0 and #f.counter.kicks==0,"拖动和关闭 UI 不影响授权")
end)
check("ZS 品牌与 f0644b 主题色保持一致",function()
    local f=fixture()
    local accent=rb.Color3.fromRGB(240,100,75)
    assert(f.byName("Brand").Text=="ZS" and f.byName("Heading").Text=="ZS HUB")
    assert(f.byName("Brand").BackgroundColor3==accent)
    assert(f.byName("ValidateKey").BackgroundColor3==accent)
    assert(f.byName("CardAction").TextColor3==accent)
    assert(f.byName("CurrentCardLayout").FillDirectionMaxCells==3 and f.byName("UniversalCardLayout").FillDirectionMaxCells==3)
end)
check("仅显示当前游戏和通用两区，浏览不触发登录或加载",function()
    local scripts={
        {id="hall-8",gameId="other",nameZh="其他游戏工具",nameEn="Other",enabled=true,universal=false,placeIds={},universeIds={99},tags={},aliases={}},
        {id="hall-7",gameId="demo",nameZh="当前游戏工具",nameEn="Current",enabled=true,universal=false,placeIds={2},universeIds={1},scenario="收集物品与快捷导航",tags={},aliases={}},
        {id="hall-9",gameId="common",nameZh="通用工具",nameEn="Common",enabled=true,universal=true,placeIds={2},universeIds={},tags={},aliases={}},
    }
    local f=fixture({catalog=scripts,noKey=true})
    assert(f.byName("ScriptCard_hall-7").Parent.Name=="CurrentCards")
    assert(f.byName("ScriptCard_hall-9").Parent.Name=="UniversalCards","通用优先按标记归类，不重复归当前游戏")
    assert(not pcall(f.byName,"ScriptCard_hall-8") and f.byName("ScriptCount").Text=="2 个脚本")
    assert(f.byName("CurrentCount").Text=="1 个" and f.byName("UniversalCount").Text=="1 个")
    assert(f.byName("UniversalSection").Position.Y.Offset>f.byName("CurrentSection").Position.Y.Offset)
    assert(f.counter.logins==0 and f.counter.loads==0 and #f.counter.kicks==0)
end)
check("分区滚动高度和跨设备授权信息不重叠",function()
    local many={}
    for i=1,30 do
        table.insert(many,{id="hall-"..i,gameId="demo",nameZh="夹具项目"..i,nameEn="Fixture",enabled=true,universal=i>15,placeIds={2},universeIds={},tags={},aliases={}})
    end
    local f=fixture({catalog=many,kind="MEMBER",expiresAt="2027-04-08T16:05:33.375Z"})
    for _,screen in ipairs({{1040,720},{962,691},{793,311},{627,297}})do
        f.resize(screen[1],screen[2])
        local current,universal=f.byName("CurrentSection"),f.byName("UniversalSection")
        assert(current.Position.Y.Offset+current.Size.Y.Offset<universal.Position.Y.Offset)
        assert(universal.Position.Y.Offset+universal.Size.Y.Offset<=f.byName("ScriptGrid").CanvasSize.Y.Offset)
        assert(f.byName("ScriptGrid").CanvasSize.Y.Offset>f.byName("ScriptGrid").Size.Y.Offset)
        assert(f.byName("CurrentCardLayout").FillDirectionMaxCells==3 and f.byName("UniversalCardLayout").FillDirectionMaxCells==3)
        local label,value,note=f.byName("ExpiryLabel"),f.byName("ExpiryValue"),f.byName("GrantNote")
        assert(label.Position.Y.Offset+label.Size.Y.Offset<=value.Position.Y.Offset and value.Position.Y.Offset+value.Size.Y.Offset<=note.Position.Y.Offset)
        assert(note.Position.Y.Offset+note.Size.Y.Offset<=f.byName("Authorization").Size.Y.Offset)
    end
end)
check("空目录、旧 API 缺少场景与长文本均有稳定布局",function()
    local f=fixture({catalog={}})
    assert(f.byName("CurrentEmpty").Visible and f.byName("UniversalEmpty").Visible and f.byName("CurrentEmpty").Parent~=f.byName("CurrentCards"))
    assert(f.byName("ScriptCount").Text=="0 个脚本")
    local long=fixture({catalog={{id="hall-7",gameId="demo",nameZh=string.rep("很长的中文标题",15),nameEn="Long",enabled=true,universal=true,placeIds={},universeIds={},tags={},aliases={}}}})
    long.resize(627,337)
    assert(long.byName("Scenario").Text=="场景信息待接口同步")
    assert(long.byName("ScriptName").TextWrapped and long.byName("ScriptName").TextTruncate==rb.Enum.TextTruncate.AtEnd)
end)
check("原生断开先于尽力注销请求",function()
    local f=fixture();f.play();untilTrue(function()return f.counter.starts==1 end)
    f.finish();untilTrue(function()return f.counter.deletes==1 end)
    assert(f.counter.logoutSawKicks==1,"网络注销不应阻塞 Kick")
end)
check("初次 Key 错误仅拒绝加载",function()
    local f=fixture({loginError="HUB_KEY_INVALID"});f.play();untilTrue(function()return pcall(f.find,"校验未完成")end)
    assert(f.find("校验未完成") and #f.counter.kicks==0 and f.counter.loads==0)
    f.close();assert(#f.counter.kicks==0)
end)
for _,code in ipairs({"HUB_SESSION_REPLACED","HUB_KEY_INVALID","HUB_LICENSE_REVOKED","HUB_LICENSE_EXPIRED","HUB_VIP_REQUIRED","HUB_SESSION_INVALID"})do
    check("心跳失效 "..code,function()
        local f=fixture({heartbeatError=code});f.play();f.close();untilTrue(function()return #f.counter.kicks==1 end)
        assert(not f.env.__RSZH_HUB);task.wait(0.05);assert(#f.counter.kicks==1)
    end)
end
check("过期登录响应仅提示并注销，不误踢",function()
    local f=fixture({lease=0});f.play()
    untilTrue(function()return f.counter.deletes==1 end)
    assert(f.find("登录响应已过期") and #f.counter.kicks==0 and f.counter.starts==0)
end)
check("未加载脚本的已登录会话也在失效时退出本局",function()
    local f=fixture({heartbeatError="HUB_LICENSE_EXPIRED"})
    untilTrue(function()return #f.counter.kicks==1 end);assert(f.counter.starts==0)
end)
check("独立看门狗与晚到心跳不复活",function()
    local f=fixture({lease=0.25,delayHeartbeat=0.7,starveWatchdog=true});f.play();f.destroy()
    untilTrue(function()return #f.counter.kicks==1 end)
    assert(f.counter.kicks[1]:find("租约",1,true));task.wait(0.8)
    assert(#f.counter.kicks==1 and f.counter.logins==1 and not f.env.__RSZH_HUB)
end)
check("短暂网络失败先重试，成功后保留本局",function()
    local f=fixture({lease=4.5,networkHeartbeat=true});f.play();f.close()
    untilTrue(function()return f.counter.heartbeats==1 end)
    assert(#f.counter.kicks==0);f.server.networkHeartbeat=false
    untilTrue(function()return f.counter.heartbeats>=2 end)
    task.wait(0.03);assert(#f.counter.kicks==0 and f.env.__RSZH_HUB.alive)
end)
check("持续断网按原租约结束",function()
    local f=fixture({lease=0.25,networkHeartbeat=true});f.play();f.destroy()
    untilTrue(function()return #f.counter.kicks==1 end);assert(f.counter.kicks[1]:find("租约",1,true))
end)
check("加载接口发现授权失效立刻结束",function()
    local f=fixture({loadError="HUB_SESSION_REPLACED"});f.play()
    untilTrue(function()return #f.counter.kicks==1 end);assert(f.counter.starts==0)
end)
check("游戏权限不匹配不误踢",function()
    local f=fixture({loadError="HUB_GAME_NOT_GRANTED"});f.play()
    untilTrue(function()return pcall(f.find,"加载失败")end)
    assert(#f.counter.kicks==0 and f.counter.starts==0 and f.find("加载失败"))
end)
check("下载期间关闭界面仍完成已请求的后台加载",function()
    local f=fixture({delayLoad=0.3});f.play();untilTrue(function()return f.counter.loads==1 end)
    f.close();untilTrue(function()return f.counter.starts==1 end)
    assert(#f.counter.kicks==0 and f.counter.deletes==0 and f.owner.alive)
    f.client();assert(f.find("运行中") and f.counter.loads==1 and f.counter.logins==1)
end)
check("登录期间关闭界面继续后台授权",function()
    local f=fixture({delayLogin=0.2});f.click("校验 Key");f.close();task.wait(0.3)
    assert(f.counter.deletes==0 and #f.counter.kicks==0 and f.owner.alive)
    f.client();assert(f.find("授权有效"));f.client();task.wait(0.03)
    assert(f.counter.logins==1)
end)
check("重试登录期间关闭界面不注销会话",function()
    local f=fixture({delayLogin=0.1,loginNetworkOnce=true});f.click("校验 Key")
    untilTrue(function()return f.counter.logins==2 end);f.close();task.wait(0.2)
    assert(f.counter.deletes==0 and #f.counter.kicks==0 and f.owner.alive)
    f.client();assert(f.find("授权有效"))
end)
check("编译期间清理界面不取消原脚本",function()
    local f=fixture({closeDuringCompile=true});f.play()
    untilTrue(function()return f.counter.starts==1 end)
    assert(f.counter.deletes==0 and #f.counter.kicks==0 and f.owner.alive)
    f.client();assert(f.find("运行中"))
end)
check("未运行时销毁界面保留已登录会话",function()
    local f=fixture();untilTrue(function()return pcall(f.find,"授权有效")end)
    f.destroy();untilTrue(function()return f.counter.heartbeats==1 end)
    assert(f.counter.deletes==0 and #f.counter.kicks==0 and f.env.__RSZH_HUB==f.owner)
    f.client();assert(f.find("授权有效") and f.counter.logins==1)
end)
check("运行后清理界面只释放视图，仍后台校验",function()
    local f=fixture();f.play();untilTrue(function()return f.counter.starts==1 end)
    f.destroy();untilTrue(function()return f.counter.heartbeats==1 end)
    assert(#f.counter.kicks==0 and f.counter.deletes==0 and f.env.__RSZH_HUB==f.owner)
    f.client();assert(f.find("运行中") and f.counter.starts==1)
end)
check("结束本局按钮明确断开游戏",function()
    local f=fixture();f.click("结束本局");assert(#f.counter.kicks==1)
end)
check("编译失败不误踢且可重试",function()
    local f=fixture({source="local ="});f.play();untilTrue(function()return pcall(f.find,"脚本编译失败")end)
    assert(f.find("脚本编译失败") and #f.counter.kicks==0)
    f.server.source=originalSource;f.play();untilTrue(function()return f.counter.starts==1 end)
end)
check("原脚本报错不自动踢人，后台授权监控继续",function()
    local f=fixture({source="counters.starts += 1; task.wait(0.15); error('fixture script failure')"});f.play();f.close()
    task.wait(0.3);assert(#f.counter.kicks==0 and f.owner.alive and f.counter.starts==1)
    f.client();assert(f.find("脚本启动异常"));f.play();task.wait(0.02);assert(f.counter.starts==1)
    f.finish();assert(#f.counter.kicks==1)
end)
check("原脚本启动挂起不阻止授权监控",function()
    local f=fixture({source="counters.starts += 1; task.wait(0.8)",lease=0.25,delayHeartbeat=1});f.play()
    untilTrue(function()return #f.counter.kicks==1 end);assert(f.counter.starts==1)
end)
check("无效心跳响应不续租",function()
    local f=fixture({invalidHeartbeat=true,lease=0.6});f.play()
    untilTrue(function()return f.counter.heartbeats==1 end);task.wait(0.1);assert(#f.counter.kicks==0)
    untilTrue(function()return #f.counter.kicks==1 end);assert(f.counter.kicks[1]:find("租约",1,true))
end)
check("Kick 报错不伪报成功，停止加载与续租",function()
    local f=fixture({heartbeatError="HUB_SESSION_REPLACED",kickFails=true});f.play()
    untilTrue(function()return #f.counter.warnings==1 end);assert(f.find("请立即手动离开本局"))
    local logins,loads,heartbeats=f.counter.logins,f.counter.loads,f.counter.heartbeats
    f.byName("ValidateKey").Activated:Fire();f.play();task.wait(0.3)
    assert(f.counter.logins==logins and f.counter.loads==loads and f.counter.heartbeats==heartbeats and #f.counter.kicks==1)
end)
check("关闭界面后顶号仍只结束一次本局",function()
    local f=fixture({heartbeatError="HUB_SESSION_REPLACED"});f.play();f.destroy()
    untilTrue(function()return #f.counter.kicks==1 end)
    assert(f.counter.kicks[1]:find("其他实例或设备",1,true));task.wait(0.1);assert(#f.counter.kicks==1)
end)
check("原脚本启动时自行清理 Hub UI 不误踢",function()
    local f=fixture({source="counters.starts += 1; counters.clearUI()"});f.play()
    untilTrue(function()return f.counter.starts==1 end)
    assert(f.owner.alive and #f.counter.kicks==0 and f.counter.deletes==0)
    f.client();assert(f.find("运行中") and f.counter.starts==1 and f.counter.logins==1)
end)
check("多次销毁恢复不重复登录、加载、目录或监控",function()
    local f=fixture();f.play();untilTrue(function()return f.counter.starts==1 end)
    for i=1,5 do if i%2==0 then f.close()else f.destroy()end;f.client()end
    untilTrue(function()return f.counter.heartbeats>=1 end);task.wait(0.3)
    assert(f.counter.heartbeats==1 and f.counter.logins==1 and f.counter.loads==1 and f.counter.starts==1 and f.counter.catalogs==1)
    assert(f.env.__RSZH_HUB==f.owner and #f.counter.kicks==0 and f.counter.deletes==0)
end)
check("界面恢复失败不终止授权，恢复后可继续操作",function()
    local f=fixture();f.play();untilTrue(function()return f.counter.starts==1 end);f.close()
    f.server.guiUnavailable=true;f.client()
    assert(f.owner.alive and #f.counter.kicks==0 and #f.counter.warnings==1)
    untilTrue(function()return f.counter.heartbeats==1 end)
    f.server.guiUnavailable=false;f.client();assert(f.find("运行中"));f.finish()
end)
check("并发恢复界面只创建一份视图",function()
    local f=fixture();f.play();untilTrue(function()return f.counter.starts==1 end);f.close()
    f.server.guiDelay=0.2
    task.spawn(f.client);task.wait(0.03);f.client();task.wait(0.25)
    local active=0;for _,o in ipairs(f.objects)do if o.Name=="RSZH_Hub" and not o.destroyed then active+=1 end end
    assert(active==1 and f.counter.guiLookups==2 and f.counter.logins==1 and f.counter.catalogs==1 and #f.counter.kicks==0)
end)
check("界面恢复等待期间租约仍按时耗尽",function()
    local f=fixture({lease=0.25,networkHeartbeat=true});f.play();untilTrue(function()return f.counter.starts==1 end);f.destroy()
    f.server.guiDelay=0.6;f.client()
    assert(#f.counter.kicks==1 and not f.owner.alive and not f.env.__RSZH_HUB)
    local active=0;for _,o in ipairs(f.objects)do if o.Name=="RSZH_Hub" and not o.destroyed then active+=1 end end
    assert(active==0,"结束后晚到的 UI 不复活")
end)
check("初次目录返回时界面已删除，恢复时复用目录",function()
    local f=fixture({destroyDuringCatalog=true});assert(f.owner.alive and #f.counter.kicks==0)
    f.client();assert(f.find("授权检查") and f.counter.catalogs==1)
end)
check("手动结束后不执行晚到下载",function()
    local f=fixture({delayLoad=0.4});f.play();untilTrue(function()return f.counter.loads==1 end);f.finish()
    task.wait(0.5);assert(f.counter.starts==0 and #f.counter.kicks==1)
end)
check("手动结束后晚到的登录会话仍注销",function()
    local f=fixture({delayLogin=0.2});f.play();f.finish()
    untilTrue(function()return f.counter.deletes==1 end)
    assert(#f.counter.kicks==1 and f.counter.starts==0 and not f.env.__RSZH_HUB)
end)
check("手动结束后晚到的重试登录会话仍注销",function()
    local f=fixture({delayLogin=0.1,loginNetworkOnce=true});f.click("校验 Key")
    untilTrue(function()return f.counter.logins==2 end);f.finish()
    untilTrue(function()return f.counter.deletes==1 end);assert(#f.counter.kicks==1)
end)
check("编译期间手动结束仍拒绝执行函数",function()
    local f=fixture({endDuringCompile=true});f.play();untilTrue(function()return #f.counter.kicks==1 end)
    assert(f.counter.starts==0)
end)
check("界面关闭时 Kick 失败仍输出明确警告",function()
    local f=fixture({heartbeatError="HUB_SESSION_REPLACED",kickFails=true});f.play();f.close()
    untilTrue(function()return #f.counter.warnings==1 end)
    assert(not f.owner.alive and #f.counter.kicks==1 and f.counter.warnings[1]:find("手动离开",1,true))
end)
check("缺少结束游戏能力时不加载",function()
    local f=fixture({missingKick=true});assert(f.counter.logins==0 and f.counter.loads==0)
end)
check("旧策略单例要求重新进入游戏",function()
    local f=fixture({legacyHub=true});assert(f.counter.logins==0 and f.counter.loads==0)
end)
check("支持游戏总列表切换、非当前游戏置灰禁加载与执行次数累加",function()
    local scripts={
        {id="hall-7",gameId="demo",nameZh="当前游戏工具",nameEn="Current",enabled=true,universal=false,placeIds={2},universeIds={1},scenario="当前场景",loadCount=10,
            game={id="demo",nameZh="当前测试游戏",nameEn="Current Game"}},
        {id="hall-8",gameId="other",nameZh="其他游戏工具",nameEn="Other",enabled=true,universal=false,placeIds={99},universeIds={88},scenario="其他场景",loadCount=42,
            game={id="other",nameZh="其他支持游戏",nameEn="Other Supported Game"}},
        {id="hall-9",gameId="common",nameZh="通用辅助工具",nameEn="Common",enabled=true,universal=true,placeIds={},universeIds={},scenario="通用场景",loadCount=5},
    }
    local f=fixture({catalog=scripts,kind="MEMBER"})
    assert(f.byName("GameNavCount").Text=="2 款")
    assert(f.byName("LibraryTitle").Text=="当前测试游戏" and f.byName("GameMatchBadge").Text=="当前游戏")
    local function cardPart(cardId,partName)
        local card=f.byName("ScriptCard_"..cardId)
        for _,o in ipairs(f.objects)do if not o.destroyed and o.Parent==card and o.Name==partName then return o end end
        error("卡片子控件缺失："..cardId.."."..partName)
    end
    assert(cardPart("hall-7","LoadCount").Text=="已执行 10 次")
    assert(cardPart("hall-9","LoadCount").Text=="已执行 5 次")
    -- 切换到左侧支持游戏总列表中的其他游戏
    f.byName("GameNav_other").Activated:Fire()
    assert(f.byName("LibraryTitle").Text=="其他支持游戏" and f.byName("CurrentGameNameEn").Text=="Other Supported Game")
    assert(f.byName("GameMatchBadge").Text=="非当前游戏")
    assert(f.byName("CurrentGameImage").Image=="rbxthumb://type=GameIcon&id=88&w=150&h=150")
    assert(not f.byName("UniversalSection").Visible,"浏览其他专属游戏时隐藏通用分区")
    local otherCard=f.byName("ScriptCard_hall-8")
    assert(not otherCard.Selectable and not otherCard.AutoButtonColor,"非当前游戏卡片置灰禁用交互高亮")
    assert(cardPart("hall-8","CardAction").Text=="非当前游戏")
    assert(cardPart("hall-8","LoadCount").Text=="已执行 42 次")
    -- 点击非当前游戏卡片不会触发加载或编译
    otherCard.Activated:Fire();task.wait(0.03)
    assert(f.counter.loads==0 and f.counter.starts==0 and #f.counter.kicks==0)
    assert(cardPart("hall-8","LoadCount").Text=="已执行 42 次")
    -- 切回当前游戏并执行加载，验证执行次数 +1
    f.byName("GameNav_current").Activated:Fire()
    assert(f.byName("LibraryTitle").Text=="当前测试游戏" and f.byName("UniversalSection").Visible)
    f.byName("ScriptCard_hall-7").Activated:Fire()
    untilTrue(function()return f.counter.starts==1 end)
    assert(cardPart("hall-7","LoadCount").Text=="已执行 11 次")
    -- 销毁并恢复界面后保留递增后的执行次数
    f.destroy();f.client()
    assert(cardPart("hall-7","LoadCount").Text=="已执行 11 次")
end)
print("通过："..passed.." 项界面/监控解耦、原样加载、授权失效断开与竞态回归；Kick 为本地替身")

-- 模拟 Kick 不销毁测试 VM；仅在全部检查通过后结束夹具进程，不宣称回收原脚本任务。
process.exit(0)
