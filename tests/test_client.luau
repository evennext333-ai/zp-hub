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
    local server = {deniedParents=options.deniedParents,guiUnavailable=options.guiUnavailable,nowMillis=datetime.fromIsoDate("2027-04-08T16:00:00Z").unixTimestampMillis,source=options.source or originalSource, lease=options.lease or 300,
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
        local data = {ClassName=class,AbsolutePosition=rb.Vector2.new(0,0),AbsoluteSize=rb.Vector2.new(600,560),Activated=signal(),MouseButton1Click=signal(),MouseButton1Up=signal(),FocusLost=signal(),InputBegan=signal(),InputChanged=signal(),InputEnded=signal(),ChildAdded=signal(),Destroying=signal(),signals={},native=native}
        if options.centeredButtons and class=="TextButton" then data.AnchorPoint=rb.Vector2.new(0.5,0.5) end
        local item = setmetatable({}, {
            __index=function(_,key)
                if data[key]~=nil then return data[key] end
                local ok,value=pcall(function()return native[key]end)
                if ok then return value end
                return nil
            end,
            __newindex=function(self,key,value)
                if server.uiWriteError and key=="Text" then error("fixture UI write error") end
                if key=="Parent" then
                    if value~=nil then
                        assert(type(value)=="table" and (value.native or value.fixtureParent),"Parent must be an Instance")
                        if server.deniedParents and server.deniedParents[value.Name] then error("fixture parent permission denied") end
                    end
                    native.Parent=type(value)=="table" and value.native or nil
                elseif key~="AbsolutePosition" and key~="AbsoluteSize" and key~="destroyed" then
                    local ok,err=pcall(function()native[key]=value end)
                    assert(ok,"无效 Roblox 属性："..class.."."..key.." / "..tostring(err))
                end
                data[key]=value
                if key=="Parent" and type(value)=="table" and value.ChildAdded then
                    value.ChildAdded:Fire(self)
                end
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
    local playerGui = {Name="PlayerGui",ClassName="PlayerGui",fixtureParent=true}
    local player = {WaitForChild=function()
        counter.guiLookups+=1
        if server.guiUnavailable then error("fixture PlayerGui unavailable") end
        if server.guiDelay then task.wait(server.guiDelay) end
        return playerGui
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
        getgenv=function()return hubEnv end,gethwid=function()
            if options.hwidThrows then error("fixture HWID error") end
            return options.hwidValue~=nil and options.hwidValue or "fixture-device"
        end,
        identifyexecutor=function()return "fixture-executor" end,
        Instance={new=create},UDim2=rb.UDim2,UDim=rb.UDim,Vector2=rb.Vector2,Color3=rb.Color3,Enum=rb.Enum,
        warn=function(message)table.insert(counter.warnings,message)end,
    }
    if options.withHui then
        local huiContainer = {Name="HiddenGui",ClassName="Folder",fixtureParent=true}
        environment.gethui = function() counter.huiLookups = (counter.huiLookups or 0) + 1; if options.huiThrows then error("fixture gethui error") end;return options.huiInvalid and "invalid-parent" or huiContainer end
        environment.huiContainer = huiContainer
    end
    if options.withHidden then
        environment.get_hidden_gui=function()return {Name="SecondaryHiddenGui",ClassName="Folder",fixtureParent=true}end
    end
    if options.withCoreGui then
        local coreContainer = {Name="CoreGui",ClassName="CoreGui",fixtureParent=true}
        services.CoreGui = coreContainer
        environment.coreContainer = coreContainer
    end
    if options.alternateHwid then environment.getexecutorhwid=environment.gethwid end
    if options.noHwid or options.alternateHwid then environment.gethwid=nil end
    local clockShift = 0
    environment.os=table.clone(os)
    environment.os.clock=function()return os.clock()*(options.fastHeartbeats and 80 or 1)+clockShift end
    local entry={id="hall-7",gameId="demo",nameZh="授权检查",nameEn="Check",enabled=true,universal=false,lifecycle="managed",placeIds={2},universeIds={1},tags={},aliases={},scenario="授权连接 / 状态检查",shortDescription="不应显示这段简介"}
    if options.fallbackApi then environment.FALLBACK_API = options.fallbackApi end
    counter.urls = {}
    counter.requests = {}
    environment.request=function(args)
        table.insert(counter.urls, args.Url)
        table.insert(counter.requests, args)
        if options.transport then
            local response = options.transport(args)
            if response then return response end
        end
        if options.primaryNetworkDown and (not options.fallbackApi or args.Url:find(options.fallbackApi, 1, true) ~= 1) then
            return { StatusCode = 0, Body = "" }
        end
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
            data={sessionId=server.invalidHeartbeat and "another-session" or "fixture",sequence=body.sequence,remainingLeaseSeconds=300,kind=options.kind or "GAME",gameId=options.gameId or "demo",entitlementExpiresAt=options.expiresAt}
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
            counter.lastHwid=body.hwid
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
    function f.advanceClock(seconds) clockShift += seconds end
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
        server.guiUnavailable=false;server.guiDelay=nil;server.uiWriteError=false;server.deniedParents=nil
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
        for index,name in ipairs(names) do table.insert(sample,{id="hall-"..index,gameId="preview",nameZh=name,nameEn="Preview "..index,scenario=descriptions[index],shortDescription="不应显示简介",requiresKey=index%3==1,enabled=true,universal=index>3,game={id="preview",nameZh="游戏布局示例",nameEn="Game Preview"},placeIds=index<=3 and {2} or {},universeIds={},aliases={},tags={}}) end
        for i=1,4 do table.insert(sample,{id="hall-"..(i+10),gameId="other-"..i,nameZh="游戏工具"..i,nameEn="Other Script "..i,requiresKey=i%2==0,enabled=true,universal=false,game={id="other-"..i,nameZh="其他示例游戏"..i,nameEn="Other Game "..i},placeIds={100+i},universeIds={200+i},scenario="浏览预览 / 状态检查",aliases={},tags={}})end
        local cases={{"pc",1440,900,1040,720},{"tablet",1024,768,962,691},{"phone",844,390,793,311},{"landscape",667,375,627,297},{"pc-member",1440,900,1040,720,"MEMBER"},{"phone-member",844,390,793,311,"MEMBER"},{"phone-game",844,390,793,311,"GAME"}}
        table.insert(cases,{"pc-gallery",1440,900,1040,720,"MEMBER","gallery"})
        table.insert(cases,{"phone-gallery",844,390,793,311,"MEMBER","gallery"})
        local output=process.env.HUB_UI_PREVIEW_DIR
        fs.writeDir(output)
        for _,screen in ipairs(cases) do
            local f=fixture({catalog=sample,noKey=not screen[6],kind=screen[6],gameId="preview",expiresAt="2027-04-08T16:05:33.375Z"});f.resize(screen[4],screen[5])
            if screen[7]=="gallery" then f.byName("TabAllGames").Activated:Fire() end
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

check("独立容器可用时不等待 PlayerGui，且实际挂载到该容器",function()
    local f=fixture({withHui=true,withCoreGui=true,guiUnavailable=true})
    assert(f.byName("RSZH_Hub").Parent.Name=="HiddenGui")
    assert(f.counter.guiLookups==0 and f.counter.huiLookups==1)
end)
check("gethui 异常或挂载受限时逐级尝试第二隐藏容器和 PlayerGui",function()
    local a=fixture({withHui=true,huiThrows=true,withHidden=true,withCoreGui=true})
    assert(a.byName("RSZH_Hub").Parent.Name=="SecondaryHiddenGui")
    local b=fixture({withHui=true,huiInvalid=true,withCoreGui=true,deniedParents={CoreGui=true}})
    assert(b.byName("RSZH_Hub").Parent.Name=="PlayerGui")
    local c=fixture({withHui=true,withHidden=true,withCoreGui=true,deniedParents={HiddenGui=true,SecondaryHiddenGui=true}})
    assert(c.byName("RSZH_Hub").Parent.Name=="CoreGui")
end)
check("挂载完全失败时释放未挂载的 ScreenGui 并保留后台控制器",function()
    local f=fixture({withHui=true,withHidden=true,withCoreGui=true})
    f.destroy();f.server.deniedParents={HiddenGui=true,SecondaryHiddenGui=true,CoreGui=true,PlayerGui=true}
    f.client()
    assert(f.owner.alive and #f.counter.kicks==0)
    for _,o in ipairs(f.objects)do if o.ClassName=="ScreenGui" then assert(o.destroyed,"挂载失败不遗留空根界面")end end
    f.server.deniedParents=nil;f.owner.focus()
    assert(f.byName("RSZH_Hub").Parent.Name=="HiddenGui" and f.counter.logins==1)
end)
check("鼠标移出后的 Up 不执行动作，原生完整点击仍可用",function()
    local f=fixture()
    local stop=f.byName("EndSession")
    stop.InputBegan:Fire({UserInputType=rb.Enum.UserInputType.MouseButton1,Position=rb.Vector3.new(50,50,0)})
    stop.MouseButton1Up:Fire(900,900)
    assert(f.owner.alive and #f.counter.kicks==0)
    stop.MouseButton1Click:Fire();assert(#f.counter.kicks==1)
end)
check("原始触控释放仅接受同一手指，移出和返回滑动均不误触",function()
    local f=fixture()
    local card=f.byName("ScriptCard_hall-7")
    card.AbsolutePosition=rb.Vector2.new(0,0);card.AbsoluteSize=rb.Vector2.new(100,100)
    local a={UserInputType=rb.Enum.UserInputType.Touch,Position=rb.Vector3.new(50,50,0)}
    card.InputBegan:Fire(a)
    card.InputEnded:Fire({UserInputType=rb.Enum.UserInputType.Touch,Position=rb.Vector3.new(50,50,0)});task.wait(0.02)
    assert(f.counter.loads==0,"第二根手指结束不触发第一根手指")
    a.Position=rb.Vector3.new(130,50,0);card.InputChanged:Fire(a)
    a.Position=rb.Vector3.new(50,50,0);card.InputEnded:Fire(a);task.wait(0.02)
    assert(f.counter.loads==0,"滑出再返回不当成点击")
    local edge={UserInputType=rb.Enum.UserInputType.Touch,Position=rb.Vector3.new(98,50,0)}
    card.InputBegan:Fire(edge);edge.Position=rb.Vector3.new(102,50,0);card.InputEnded:Fire(edge);task.wait(0.02)
    assert(f.counter.loads==0,"轻微移动但释放在按钮外也不点击")
    local tap={UserInputType=rb.Enum.UserInputType.Touch,Position=rb.Vector3.new(50,50,0)}
    card.InputBegan:Fire(tap);tap.Position=rb.Vector3.new(53,51,0);card.InputEnded:Fire(tap)
    untilTrue(function()return f.counter.starts==1 end)
    assert(f.counter.loads==1)
end)
check("焦点丢失、视图隐藏、禁用或滚动后的触控释放不执行",function()
    for _,mode in ipairs({"focus","hidden","disabled","scroll"})do
        local f=fixture();local card=f.byName("ScriptCard_hall-7")
        local tap={UserInputType=rb.Enum.UserInputType.Touch,Position=rb.Vector3.new(50,50,0)}
        card.InputBegan:Fire(tap)
        if mode=="focus" then f.inputService.WindowFocusReleased:Fire()
        elseif mode=="hidden" then f.byName("HubWindow").Visible=false
        elseif mode=="disabled" then card.Active=false
        else f.byName("ScriptGrid").CanvasPosition=rb.Vector2.new(0,10)end
        card.InputEnded:Fire(tap);task.wait(0.02)
        assert(f.counter.loads==0 and #f.counter.kicks==0,mode)
    end
end)
check("卡密提示缺失时显示待同步且免卡密项目仍要求 Hub Key",function()
    local f=fixture({noKey=true})
    assert(f.byName("KeyBadge").Text=="卡密待同步")
    f.byName("ScriptCard_hall-7").Activated:Fire()
    assert(f.byName("AuthPrompt").Visible and f.counter.logins==0 and f.counter.loads==0)
    local free=fixture({noKey=true,catalog={{id="hall-7",gameId="demo",nameZh="免卡密夹具",nameEn="Keyless fixture",requiresKey=false,enabled=true,universal=false,placeIds={2},universeIds={1},aliases={},tags={}}}})
    assert(free.byName("KeyBadge").Text=="免Key")
    free.byName("ScriptCard_hall-7").Activated:Fire()
    assert(free.byName("AuthPrompt").Visible and free.counter.logins==0 and free.counter.loads==0)
end)

check("缺少真实 HWID 时不以执行器名称或账号替代设备校验",function()
    local f=fixture({noHwid=true})
    assert(f.counter.logins==0 and f.counter.loads==0 and #f.counter.kicks==0)
    assert(f.byName("SessionStatus").Text=="此运行环境缺少 HWID 接口")
    assert(f.env.HUB_KEY==nil and f.owner.alive)
end)
check("保留原 HWID 备选接口及原样请求值",function()
    local f=fixture({alternateHwid=true,hwidValue=" fixture-device "})
    assert(f.counter.logins==1 and f.counter.lastHwid==" fixture-device ")
    assert(f.counter.loads==0 and #f.counter.kicks==0)
end)
check("异常或越界 HWID 不请求登录且不误踢",function()
    for _,options in ipairs({{hwidThrows=true},{hwidValue=""},{hwidValue=7},{hwidValue=string.rep("a",513)}}) do
        local f=fixture(options)
        assert(f.counter.logins==0 and f.counter.loads==0 and #f.counter.kicks==0)
        assert(f.byName("SessionStatus").Text=="设备标识无效，请检查运行环境")
    end
end)
check("按下触屏或鼠标不加载脚本，释放兼容事件只执行一次",function()
    local f=fixture()
    local card=f.byName("ScriptCard_hall-7")
    card.InputBegan:Fire({UserInputType=rb.Enum.UserInputType.Touch})
    card.InputBegan:Fire({UserInputType=rb.Enum.UserInputType.MouseButton1})
    task.wait(0.18)
    assert(f.counter.loads==0 and f.counter.starts==0,"按下与滑动不视为点击")
    card.MouseButton1Click:Fire();card.Activated:Fire()
    untilTrue(function()return f.counter.starts==1 end)
    assert(f.counter.loads==1 and f.counter.logins==1)
end)
check("校验与结束按钮仅在释放事件触发且兼容事件去重",function()
    local f=fixture({noKey=true})
    f.byName("KeyInput").Text="RSH_"..string.rep("a",43)
    local validate,stop=f.byName("ValidateKey"),f.byName("EndSession")
    validate.InputBegan:Fire({UserInputType=rb.Enum.UserInputType.Touch})
    stop.InputBegan:Fire({UserInputType=rb.Enum.UserInputType.MouseButton1})
    task.wait(0.18)
    assert(f.counter.logins==0 and #f.counter.kicks==0 and f.owner.alive)
    validate.Activated:Fire();validate.MouseButton1Click:Fire()
    untilTrue(function()return f.counter.logins==1 end)
    assert(f.counter.loads==0)
    stop.MouseButton1Click:Fire();stop.Activated:Fire()
    assert(#f.counter.kicks==1 and not f.owner.alive)
end)
check("回车显式校验 Key 而普通失焦不校验不加载",function()
    local f=fixture({noKey=true})
    local input=f.byName("KeyInput")
    input.Text="RSH_"..string.rep("a",43)
    input.FocusLost:Fire(false);task.wait(0.03)
    assert(f.counter.logins==0)
    input.FocusLost:Fire(true)
    untilTrue(function()return f.counter.logins==1 end)
    assert(f.counter.loads==0 and #f.counter.kicks==0)
end)
check("重跑入口只恢复现有控制器而不尝试局部热更新",function()
    local f=fixture()
    f.owner.uiVersion="old-fixture"
    f.owner.closeView=function()error("不应主动关闭现有控制器界面")end
    local owner=f.owner
    f.client()
    assert(f.env.__RSZH_HUB==owner and f.counter.logins==1 and f.counter.loads==0)
end)
check("重复导航销毁的卡片不会响应残留事件",function()
    local f=fixture()
    local old=f.byName("ScriptCard_hall-7")
    f.byName("TabAllGames").Activated:Fire()
    f.byName("GameNav_current").Activated:Fire()
    assert(old.destroyed and old.Parent==nil)
    old.Activated:Fire();old.MouseButton1Click:Fire();task.wait(0.03)
    assert(f.counter.loads==0 and f.counter.starts==0)
end)
check("未校验授权错误可显示两行且各控件不重叠",function()
    local f=fixture({noHwid=true})
    for _,size in ipairs({{700,340},{793,311},{627,297},{1040,720}}) do
        f.resize(size[1],size[2])
        local status,input,button=f.byName("SessionStatus"),f.byName("KeyInput"),f.byName("ValidateKey")
        assert(status.Size.Y.Offset>=28,"紧凑模式保留两行状态空间")
        assert(status.Position.Y.Offset+status.Size.Y.Offset<=input.Position.Y.Offset)
        assert(input.Position.Y.Offset+input.Size.Y.Offset<=button.Position.Y.Offset)
        assert(button.Position.Y.Offset+button.Size.Y.Offset<=f.byName("Authorization").Size.Y.Offset)
        local auth,window=f.byName("Authorization"),f.byName("HubWindow")
        assert(auth.Position.Y.Offset+auth.Size.Y.Offset<=window.Size.Y.Offset)
    end
end)

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
    local accent=rb.Color3.fromRGB(240,100,75)
    assert(f.byName("AuthBadge").Text=="已校验" and f.byName("EntitlementKind").Text=="👑 全游戏会员 VIP")
    assert(f.byName("EntitlementKind").TextColor3==accent)
    assert(f.byName("ExpiryValue").Text=="剩余 5 分钟")
    assert(f.byName("ExpiryLabel").Text=="剩余有效期")
    assert(f.byName("ExpiryDateLabel").Text=="到期时间" and f.byName("ExpiryDateValue").Text=="2027-04-09 00:05")
    assert(not f.byName("KeyInput").Visible and not f.byName("ValidateKey").Visible and not f.byName("SessionStatus").Visible)
    f.destroy();f.client()
    assert(f.byName("ExpiryValue").Text=="剩余 5 分钟" and f.byName("ExpiryDateValue").Text=="2027-04-09 00:05" and f.counter.logins==1)
    assert(f.byName("EntitlementKind").Visible and not f.byName("KeyInput").Visible)
    local empty=fixture({noKey=true})
    assert(empty.byName("AuthBadge").Text=="未校验" and empty.byName("KeyInput").Visible)
    assert(not empty.byName("ExpiryValue").Visible and not empty.byName("ExpiryDateValue").Visible and not empty.byName("EntitlementKind").Visible)
    local busy=fixture({delayLogin=0.2})
    assert(busy.byName("AuthBadge").Text=="校验中" and not busy.byName("ValidateKey").Active and not busy.byName("KeyInput").TextEditable)
    untilTrue(function()return busy.byName("AuthBadge").Text=="已校验"end)
end)
check("后续心跳更新权益日期，不重复登录或影响租约",function()
    local options={kind="MEMBER",expiresAt="2027-04-08T16:05:33.375Z",fastHeartbeats=true}
    local f=fixture(options)
    options.expiresAt="2027-05-01T00:00:00.000Z"
    untilTrue(function()return f.byName("ExpiryValue").Text=="剩余 22 天"end)
    assert(f.byName("ExpiryDateValue").Text=="2027-05-01 08:00")
    assert(f.counter.logins==1 and f.counter.loads==0 and #f.counter.kicks==0)
end)
check("长期会员和单游戏到期展示不改变后台截止时间",function()
    local member=fixture({kind="MEMBER"})
    assert(member.byName("ExpiryValue").Text=="长期有效" and member.byName("ExpiryDateValue").Text=="长期有效")
    local game=fixture({expiresAt="2027-04-10T16:00:00.000Z"})
    assert(game.byName("EntitlementKind").Text=="🎮 单游戏 · 30 天" and game.byName("ExpiryValue").Text=="剩余 2 天" and game.byName("ExpiryDateValue").Text=="2027-04-11 00:00")
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
        for _,name in ipairs({"ValidateKey","CloseView","CollapseView","EndSession","ToggleHub","TabCurrentGame","TabAllGames","GameSearchInput"}) do
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
check("卡片填充控件不叠加默认边框",function()
    local f=fixture({noKey=true})
    for _,name in ipairs({"CardAction","KeyBadge","GameMatchBadge"}) do
        local item=f.byName(name)
        assert(item.BackgroundTransparency==0)
        assert(item.BorderSizePixel==0,"自定义圆角控件应移除原生边框："..name)
    end
end)
check("三端紧凑与标准卡片字段和加载区域不重叠",function()
    local scripts={
        {id="hall-7",gameId="demo",nameZh=string.rep("长标题",12),nameEn="Long title",enabled=true,requiresKey=true,placeIds={2},universeIds={},tags={},aliases={},scenario="场景字段"},
        {id="hall-9",gameId="common",nameZh="通用工具",nameEn="Common",enabled=true,universal=true,requiresKey=false,placeIds={},universeIds={},tags={},aliases={},scenario="通用场景"},
    }
    local f=fixture({catalog=scripts,noKey=true})
    for _,size in ipairs({{1040,720},{962,691},{900,580},{900,579},{899,629},{793,311},{627,297},{640,300}})do
        f.resize(size[1],size[2])
        local cell=f.byName("CurrentCardLayout").CellSize
        local title,scenario,count,action=f.byName("ScriptName"),f.byName("Scenario"),f.byName("LoadCount"),f.byName("CardAction")
        assert(title.Position.Y.Offset+title.Size.Y.Offset<=scenario.Position.Y.Offset)
        assert(scenario.Position.Y.Offset+scenario.Size.Y.Offset<=count.Position.Y.Offset)
        assert(count.Position.Y.Offset+count.Size.Y.Offset+4<=action.Position.Y.Offset)
        assert(action.Position.Y.Offset+action.Size.Y.Offset<=cell.Y.Offset-8)
        local actionWidth=action.Size.X.Scale*cell.X.Offset+action.Size.X.Offset
        assert(action.Position.X.Offset>=8 and action.Position.X.Offset+actionWidth<=cell.X.Offset-8)
        local list=f.byName("ScriptGrid")
        assert(list.Size.Y.Offset>=24+cell.Y.Offset+4,"首排卡片及滚动区域内边距完整显示")
        assert(list.Position.Y.Offset+list.Size.Y.Offset<=f.byName("HubWindow").Size.Y.Offset-8)
        local footer=f.byName("FooterNote")
        if footer.Visible then assert(list.Position.Y.Offset+list.Size.Y.Offset<=footer.Position.Y.Offset)end
    end
    assert(f.counter.logins==0 and f.counter.loads==0,"布局调整不发起授权或正文请求")
end)
check("加载 CTA 的校验和运行状态保留单次按需加载",function()
    local f=fixture({noKey=true})
    assert(f.byName("CardAction").Text=="🔑 校验后加载")
    f.byName("ScriptCard_hall-7").Activated:Fire()
    assert(f.counter.logins==0 and f.counter.loads==0 and f.find("请先校验 Key"))
    f.env.HUB_KEY="RSH_"..string.rep("a",43)
    f.client()
    untilTrue(function()return f.byName("CardAction").Text=="▶ 点击加载"end)
    f.byName("ScriptCard_hall-7").Activated:Fire()
    untilTrue(function()return f.counter.starts==1 end)
    assert(f.byName("CardAction").Text=="运行中")
    assert(f.byName("CardAction").TextColor3==rb.Color3.fromRGB(115,205,166))
    f.byName("ScriptCard_hall-7").Activated:Fire()
    task.wait(0.02)
    assert(f.counter.loads==1 and f.counter.starts==1 and f.counter.sources[1]==originalSource)
end)
check("游戏画廊双语标题、图片和底栏在三端边界内分离",function()
    local scripts={{id="hall-7",gameId="demo",nameZh="当前工具",nameEn="Current Tool",scenario="当前场景",enabled=true,placeIds={2},universeIds={},tags={},aliases={},game={id="demo",nameZh=string.rep("当前游戏长标题",8),nameEn="Long Current Game"}}}
    for i=1,20 do table.insert(scripts,{id="hall-"..(i+10),gameId="other-"..i,nameZh="其他工具"..i,nameEn="Other Tool",enabled=true,placeIds={100+i},universeIds={},tags={},aliases={},game={id="other-"..i,nameZh=string.rep("其他游戏长标题",8),nameEn="Long Other Game"}})end
    local f=fixture({catalog=scripts,noKey=true})
    f.byName("TabAllGames").Activated:Fire()
    for _,size in ipairs({{1040,720},{962,691},{900,580},{900,579},{899,629},{793,311},{627,297},{640,300}})do
        f.resize(size[1],size[2])
        local grid=f.byName("GameGalleryLayout")
        local cell=grid.CellSize
        assert(grid.FillDirectionMaxCells==3 and cell.X.Offset>0)
        for _,id in ipairs({"GameNav_current","GameNav_other-1"})do
            local nav=f.byName(id)
            local parts={}
            for _,node in ipairs(f.objects)do if not node.destroyed and node.Parent==nav then parts[node.Name]=node end end
            for _,name in ipairs({"NavIcon","NavBadge","NavTitle","NavNameEn","NavSub","NavEnter"})do
                local part=parts[name]
                assert(part.Position.X.Offset>=0 and part.Position.Y.Offset>=0)
                assert(part.Position.X.Offset+part.Size.X.Offset<=cell.X.Offset)
                assert(part.Position.Y.Offset+part.Size.Y.Offset<=cell.Y.Offset)
            end
            assert(parts.NavTitle.TextWrapped and parts.NavTitle.Size.Y.Offset>=30)
            assert(parts.NavBadge.Position.Y.Offset+parts.NavBadge.Size.Y.Offset<=parts.NavTitle.Position.Y.Offset)
            assert(parts.NavTitle.Position.Y.Offset+parts.NavTitle.Size.Y.Offset<=parts.NavNameEn.Position.Y.Offset)
            assert(parts.NavNameEn.Position.Y.Offset+parts.NavNameEn.Size.Y.Offset<=parts.NavSub.Position.Y.Offset)
            assert(parts.NavIcon.Position.X.Offset+parts.NavIcon.Size.X.Offset<=parts.NavTitle.Position.X.Offset)
            assert(parts.NavIcon.Position.Y.Offset+parts.NavIcon.Size.Y.Offset<=parts.NavSub.Position.Y.Offset)
        end
        local list=f.byName("GameNavList")
        local rows=math.ceil(21/3)
        assert(list.CanvasSize.Y.Offset>=rows*cell.Y.Offset+(rows-1)*12,"末行画廊卡片滚动范围完整")
        assert(list.Size.Y.Offset>=cell.Y.Offset+4,"至少一排游戏卡片完整可见")
    end
    assert(f.counter.logins==0 and f.counter.loads==0,"浏览画廊和调整尺寸只读元数据")
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
        local label,value,dateLabel,dateValue,note=f.byName("ExpiryLabel"),f.byName("ExpiryValue"),f.byName("ExpiryDateLabel"),f.byName("ExpiryDateValue"),f.byName("GrantNote")
        assert(label.Position.Y.Offset+label.Size.Y.Offset<=value.Position.Y.Offset and value.Position.Y.Offset+value.Size.Y.Offset<=dateLabel.Position.Y.Offset)
        assert(dateLabel.Position.Y.Offset+dateLabel.Size.Y.Offset<=dateValue.Position.Y.Offset and dateValue.Position.Y.Offset+dateValue.Size.Y.Offset<=note.Position.Y.Offset)
        assert(note.Position.Y.Offset+note.Size.Y.Offset<=f.byName("Authorization").Size.Y.Offset)
        local auth,stop=f.byName("Authorization"),f.byName("EndSession")
        assert(auth.Position.Y.Offset+auth.Size.Y.Offset<stop.Position.Y.Offset,"左侧授权卡片与底部结束本局按钮不重叠")
        local collapse,tabCur=f.byName("CollapseView"),f.byName("TabCurrentGame")
        assert(collapse.Position.Y.Offset+collapse.Size.Y.Offset+8<=tabCur.Position.Y.Offset,"顶部收起按钮与下方导航栏保持至少 8px 间距")
        local grid=f.byName("ScriptGrid")
        local firstRowRequired=(f.byName("CurrentTitle").Visible and 24 or 0)+f.byName("CurrentCardLayout").CellSize.Y.Offset
        assert(grid.Size.Y.Offset>=firstRowRequired,"带通用脚本分区的混排模式下首排脚本卡片也须 100% 完整展示")
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
check("关闭界面后跨过90秒网络故障仍沿300秒原租约运行",function()
    local f=fixture({networkHeartbeat=true});f.play();f.close()
    untilTrue(function()return f.counter.heartbeats>=1 end)
    f.advanceClock(95);task.wait(0.1)
    assert(f.owner.alive and #f.counter.kicks==0 and f.counter.starts==1)
    f.advanceClock(206)
    untilTrue(function()return #f.counter.kicks==1 end)
    assert(not f.owner.alive and not f.env.__RSZH_HUB)
end)
check("跨过90秒后明确顶号错误仍立即结束而非等满租约",function()
    local f=fixture({heartbeatError="HUB_SESSION_REPLACED"});f.close();f.advanceClock(95)
    untilTrue(function()return #f.counter.kicks==1 end)
    assert(not f.owner.alive and f.counter.kicks[1]:find("授权",1,true))
end)
check("请求跨过10秒仍等待，超过20秒才触发幂等重试",function()
    local f=fixture({noKey=true,delayLogin=1.5})
    f.owner.submitKey("RSH_"..string.rep("a",43))
    untilTrue(function()return f.counter.logins==1 end)
    f.advanceClock(11);task.wait(0.1)
    assert(f.counter.logins==1 and f.byName("SessionStatus").Text=="正在校验授权…")
    f.advanceClock(10)
    untilTrue(function()return f.counter.logins==2 end)
    assert(#f.counter.kicks==0)
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
        {id="hall-7",gameId="demo",nameZh="当前游戏工具",nameEn="Current",enabled=true,universal=false,placeIds={2},universeIds={1},scenario="当前场景",loadCount=10,requiresKey=true,
            game={id="demo",nameZh="当前测试游戏",nameEn="Current Game"}},
        {id="hall-8",gameId="other",nameZh="其他游戏工具",nameEn="Other",enabled=true,universal=false,placeIds={99},universeIds={88},scenario="其他场景",loadCount=42,requiresKey=true,
            game={id="other",nameZh="其他支持游戏",nameEn="Other Supported Game"}},
        {id="hall-9",gameId="common",nameZh="通用辅助工具",nameEn="Common",enabled=true,universal=true,placeIds={},universeIds={},scenario="通用场景",loadCount=5,requiresKey=false},
    }
    local f=fixture({catalog=scripts,kind="MEMBER"})
    assert(f.byName("GameNavCount").Text=="2 款" and f.byName("TabAllGames").Text=="全部游戏 (2)")
    assert(f.byName("GameSearchInput").PlaceholderText=="搜索游戏或脚本名称…")
    assert(f.byName("LibraryTitle").Text=="当前测试游戏" and f.byName("GameMatchBadge").Text=="当前游戏")
    assert(f.byName("ScriptGrid").Visible and not f.byName("GameNavList").Visible,"默认展示当前游戏详情与脚本")
    local function cardPart(cardId,partName)
        local card=f.byName("ScriptCard_"..cardId)
        for _,o in ipairs(f.objects)do if not o.destroyed and o.Parent==card and o.Name==partName then return o end end
        error("卡片子控件缺失："..cardId.."."..partName)
    end
    local function navPart(navId,partName)
        local nav=f.byName(navId)
        for _,o in ipairs(f.objects)do if not o.destroyed and o.Parent==nav and o.Name==partName then return o end end
        error("导航子控件缺失："..navId.."."..partName)
    end
    assert(navPart("GameNav_current","NavIcon").Image=="rbxthumb://type=GameIcon&id=1&w=150&h=150")
    assert(navPart("GameNav_other","NavIcon").Image=="rbxthumb://type=GameIcon&id=88&w=150&h=150")
    assert(navPart("GameNav_current","NavTitle").TextWrapped and navPart("GameNav_current","NavTitle").Size.Y.Offset>=30,"全部游戏卡片标题支持两行换行展示")
    assert(cardPart("hall-7","LoadCount").Text=="已执行 10 次")
    assert(cardPart("hall-7","KeyBadge").Text=="🔑 需Key")
    assert(cardPart("hall-9","LoadCount").Text=="已执行 5 次")
    assert(cardPart("hall-9","KeyBadge").Text=="免Key")
    -- 点击顶部「全部游戏」Tab 切换到 3 列全部游戏大画廊
    f.byName("TabAllGames").Activated:Fire()
    assert(f.byName("GameNavList").Visible and not f.byName("ScriptGrid").Visible and not f.byName("GameDetailCard").Visible)
    assert(f.byName("GameGalleryLayout").FillDirectionMaxCells==3)
    -- 测试全局游戏搜索框过滤大画廊与脚本列表
    local searchBox=f.byName("GameSearchInput")
    searchBox.Text="其他支持"
    searchBox:GetPropertyChangedSignal("Text"):Fire()
    assert(not pcall(f.byName,"GameNav_current") and pcall(f.byName,"GameNav_other"),"按搜索词过滤游戏大卡片")
    searchBox.Text="不存在的关键词"
    searchBox:GetPropertyChangedSignal("Text"):Fire()
    assert(f.byName("GameNavEmpty").Visible,"无匹配游戏时展示空状态")
    f.byName("TabCurrentGame").Activated:Fire()
    assert(f.byName("CurrentEmpty").Visible and f.byName("UniversalEmpty").Visible,"无匹配脚本时显示空提示而非回退全量")
    searchBox.Text=""
    searchBox:GetPropertyChangedSignal("Text"):Fire()
    assert(pcall(f.byName,"GameNav_current") and pcall(f.byName,"GameNav_other"))
    -- 模拟真机 AbsoluteSize 瞬时归零，验证点击进入其他游戏详情不会缩小界面
    f.resize(1040,720)
    f.byName("TabAllGames").Activated:Fire()
    f.byName("HubViewport").AbsoluteSize=rb.Vector2.new(0,0)
    f.byName("RSZH_Hub").AbsoluteSize=rb.Vector2.new(0,0)
    f.byName("GameNav_other").Activated:Fire()
    assert(f.byName("WorkspaceScale").Scale==1,"视口瞬时为 0 时保留上一次有效尺寸，不缩小界面")
    assert(f.byName("ScriptGrid").Visible and not f.byName("GameNavList").Visible and f.byName("BackToGallery").Visible)
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
    -- 点击「← 全部游戏」返回大画廊，再点击「当前游戏」Tab 切回当前游戏并执行加载，验证执行次数 +1
    f.byName("BackToGallery").Activated:Fire()
    assert(f.byName("GameNavList").Visible)
    f.byName("TabCurrentGame").Activated:Fire()
    assert(f.byName("LibraryTitle").Text=="当前测试游戏" and f.byName("UniversalSection").Visible)
    f.byName("ScriptCard_hall-7").Activated:Fire()
    untilTrue(function()return f.counter.starts==1 end)
    assert(cardPart("hall-7","LoadCount").Text=="已执行 11 次")
    -- 销毁并恢复界面后保留递增后的执行次数
    f.destroy();f.client()
    assert(cardPart("hall-7","LoadCount").Text=="已执行 11 次")
end)
check("独立容器挂载、按钮缩放清理与同指触控释放兼容",function()
    local fHui=fixture({withHui=true,withCoreGui=true})
    assert(fHui.counter.guiLookups==0 and fHui.counter.huiLookups==1,"优先挂载到 gethui 隔离容器，避免被游戏 PlayerGui 脚本劫持")
    local fCore=fixture({withCoreGui=true,noKey=true})
    assert(fCore.counter.guiLookups==0)
    local validate=fCore.byName("ValidateKey")
    assert(validate.AutoButtonColor==false,"关闭原生自动变色效果")
    -- 模拟游戏脚本向按钮强行注入 UIScale 试图在点击时缩小按钮
    local rogueScale=rb.Instance.new("UIScale")
    assert(rogueScale.ClassName=="UIScale")
    local fakeScale={ClassName="UIScale",destroyed=false,Destroy=function(self)self.destroyed=true end}
    validate.ChildAdded:Fire(fakeScale)
    assert(fakeScale.destroyed,"外部向按钮注入的 UIScale 应被立即销毁，防止点击缩小")
    -- 模拟移动端执行器仅触发 InputBegan + InputEnded（不触发 Activated）的场景
    fCore.byName("KeyInput").Text="RSH_"..string.rep("a",43)
    local tap={UserInputType=rb.Enum.UserInputType.Touch,Position=rb.Vector3.new(50,50,0)}
    validate.InputBegan:Fire(tap)
    assert(fCore.counter.logins==0,"仅按下时不触发")
    tap.Position=rb.Vector3.new(54,52,0);validate.InputEnded:Fire(tap)
    untilTrue(function()return fCore.counter.logins==1 end)
    -- 模拟按下后大幅滑动（超过24px），释放时不误触点击
    local tabAll=fCore.byName("TabAllGames")
    local slide={UserInputType=rb.Enum.UserInputType.Touch,Position=rb.Vector3.new(100,100,0)}
    tabAll.InputBegan:Fire(slide)
    slide.Position=rb.Vector3.new(160,160,0);tabAll.InputChanged:Fire(slide);tabAll.InputEnded:Fire(slide)
    assert(not fCore.byName("GameNavList").Visible,"大幅滑动释放不误触按钮")
    -- 正常原地释放切换 Tab
    local tabTap={UserInputType=rb.Enum.UserInputType.Touch,Position=rb.Vector3.new(100,100,0)}
    tabAll.InputBegan:Fire(tabTap)
    tabTap.Position=rb.Vector3.new(102,101,0);tabAll.InputEnded:Fire(tabTap)
    assert(fCore.byName("GameNavList").Visible,"触控原地释放正常切换全部游戏画廊")
end)
check("主入口网络不可达时自动切换海外 Cloudflare 备用入口并记住可用线路",function()
    local fallback="https://zs-hub-api.zs-hub-edge.workers.dev"
    local f=fixture({fallbackApi=fallback,primaryNetworkDown=true})
    untilTrue(function()return f.counter.logins==1 and f.counter.catalogs==1 end)
    assert(f.find("授权有效") and #f.counter.kicks==0)
    f.play()
    untilTrue(function()return f.counter.starts==1 end)
    assert(f.counter.loads==1 and #f.counter.kicks==0)
    local loadUrl
    for _,url in ipairs(f.counter.urls) do
        if url:find("/load",1,true) then loadUrl=url end
    end
    assert(loadUrl and loadUrl:find(fallback,1,true)==1,"切换成功后后续加载直走可用备用入口")
end)
local edge = "https://zs-hub-api.zs-hub-edge.workers.dev"
local function isEdge(args) return args.Url:find(edge, 1, true) == 1 end
check("入口返回 HTML 错误页时回退，明确授权错误不跨线路重试",function()
    local f=fixture({fallbackApi=edge,transport=function(args)
        if not isEdge(args) then return {StatusCode=403,Body="<html>edge denied</html>"} end
    end})
    untilTrue(function()return f.counter.logins==1 and f.counter.catalogs==1 end)
    f.play();untilTrue(function()return f.counter.starts==1 end)
    assert(isEdge(f.counter.requests[#f.counter.requests]))
    local attempts=0
    local denied=fixture({fallbackApi=edge,transport=function(args)
        if args.Url:find("/sessions",1,true) and args.Method=="POST" then
            attempts+=1
            return {StatusCode=401,Body=serde.encode("json",{success=false,error={code="HUB_KEY_INVALID"}})}
        end
    end})
    assert(attempts==1 and denied.find("Key 无效") and #denied.counter.kicks==0)
end)
check("429 不换线路或自动重试，保留明确的限流提示",function()
    local attempts=0
    local f=fixture({fallbackApi=edge,transport=function(args)
        if args.Url:find("/sessions",1,true) and args.Method=="POST" then
            attempts+=1
            return {StatusCode=429,Body="too many requests"}
        end
    end})
    task.wait(0.1)
    assert(attempts==1 and f.find("请求过于频繁") and f.counter.logins==0 and #f.counter.kicks==0)
end)
check("双线路合计20秒预算且登录重试复用同一请求ID",function()
    local calls={}
    local f=fixture({noKey=true,fallbackApi=edge,transport=function(args)
        if args.Url:find("/sessions",1,true) and args.Method=="POST" then
            table.insert(calls,args)
            task.wait(3)
            return {StatusCode=0,Body=""}
        end
    end})
    f.owner.submitKey("RSH_"..string.rep("a",43))
    untilTrue(function()return #calls==1 end)
    f.advanceClock(12.1);untilTrue(function()return #calls==2 end)
    assert(isEdge(calls[2]))
    f.advanceClock(7);task.wait(0.08);assert(#calls==2)
    f.advanceClock(1.1);untilTrue(function()return #calls>=3 end)
    assert(serde.decode("json",calls[1].Body).requestId==serde.decode("json",calls[3].Body).requestId)
end)
check("登录成功与目录在途失败交错后补取目录",function()
    local catalogAttempts=0
    local f=fixture({fallbackApi=edge,transport=function(args)
        if args.Url:find("/catalog",1,true) then
            catalogAttempts+=1
            if catalogAttempts<=2 then task.wait(0.15);return {StatusCode=503,Body=""} end
        elseif args.Url:find("/sessions",1,true) and args.Method=="POST" then
            task.wait(0.02)
        end
    end})
    untilTrue(function()return f.counter.catalogs==1 end)
    assert(catalogAttempts==3 and f.counter.logins==1 and f.find("授权有效"))
end)
print("通过："..passed.." 项界面/监控解耦、原样加载、授权失效断开与竞态回归；Kick 为本地替身")

-- 模拟 Kick 不销毁测试 VM；仅在全部检查通过后结束夹具进程，不宣称回收原脚本任务。
process.exit(0)
