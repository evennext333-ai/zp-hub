local fs = require("@lune/fs")
local luau = require("@lune/luau")
local rb = require("@lune/roblox")
local serde = require("@lune/serde")
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
    local counter = {logins=0, loads=0, heartbeats=0, deletes=0, catalogs=0, guiLookups=0, starts=0, cleanups=0, kicks={}, warnings={}, sources={}}
    local server = {source=options.source or originalSource, lease=options.lease or 90,
        delayLogin=options.delayLogin or 0, delayLoad=options.delayLoad or 0,
        delayHeartbeat=options.delayHeartbeat or 0, loginError=options.loginError,
        loadError=options.loadError, heartbeatError=options.heartbeatError,
        networkHeartbeat=options.networkHeartbeat, invalidHeartbeat=options.invalidHeartbeat, loginNetworkOnce=options.loginNetworkOnce}
    local hubEnv = {HUB_KEY="RSH_" .. string.rep("a",43)}
    if options.legacyHub then hubEnv.__RSZH_HUB={alive=true,focus=function()error("旧实例不应复用")end} end
    local function signal()
        local listeners = {}
        return {
            Connect=function(_, callback)
                local c = {Connected=true}
                function c:Disconnect() self.Connected=false end
                table.insert(listeners,{c,callback});return c
            end,
            Fire=function()
                for _, entry in ipairs(table.clone(listeners)) do if entry[1].Connected then entry[2]() end end
            end,
        }
    end
    local function create(class)
        local item = {ClassName=class,AbsoluteSize=rb.Vector2.new(600,560),Activated=signal(),Destroying=signal(),signals={}}
        function item:GetPropertyChangedSignal(name)
            if not self.signals[name] then self.signals[name]=signal() end
            return self.signals[name]
        end
        function item:Destroy()
            if self.destroyed then return end
            self.destroyed=true;self.Destroying:Fire()
            for _, child in ipairs(objects) do if child.Parent==self then child:Destroy() end end
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
    local services = {
        Players={LocalPlayer=player},
        HttpService={JSONEncode=function(_,v)return serde.encode("json",v)end,JSONDecode=function(_,v)return serde.decode("json",v)end,
            GenerateGUID=function()generation+=1;return string.format("00000000-0000-4000-8000-%012d",generation)end},
    }
    local environment = {
        Runtime=Runtime,API="https://TARGET",task=taskShim,counters=counter,
        game={GameId=1,PlaceId=2,GetService=function(_,name)return services[name]end},
        getgenv=function()return hubEnv end,gethwid=function()return "fixture-device" end,
        Instance={new=create},UDim2=rb.UDim2,UDim=rb.UDim,Vector2=rb.Vector2,Color3=rb.Color3,Enum=rb.Enum,
        warn=function(message)table.insert(counter.warnings,message)end,
    }
    local entry={id="hall-7",gameId="demo",nameZh="授权检查",nameEn="Check",enabled=true,universal=true,lifecycle="managed",placeIds={},universeIds={},tags={},aliases={},shortDescription="检查当前游戏的授权连接与运行状态。"}
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
            data={sessionId=server.invalidHeartbeat and "another-session" or "fixture",sequence=body.sequence,remainingLeaseSeconds=90}
        elseif args.Url:find("/load",1,true) then
            assert(args.Url:find("/api/hub/scripts/hall-7/load",1,true))
            counter.loads+=1;task.wait(server.delayLoad);err=server.loadError
            data={id=entry.id,version="hall-7-r1",source=server.source}
        elseif args.Method=="DELETE" then counter.deletes+=1;counter.logoutSawKicks=#counter.kicks;data=serde.null
        else
            counter.logins+=1;task.wait(server.delayLogin);err=server.loginError
            if server.loginNetworkOnce and counter.logins==1 then err="NETWORK_ERROR";status=503 end
            data={token="HS1.fixture",sessionId="fixture",remainingLeaseSeconds=server.lease,kind="GAME"}
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
    local f={counter=counter,server=server,env=hubEnv,objects=objects,find=find,client=client}
    function f.byName(name)
        for _,item in ipairs(objects) do if item.Name==name and not item.destroyed then return item end end
        error("对象缺失："..name)
    end
    function f.resize(width,height)
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
        server.guiUnavailable=false;server.guiDelay=nil
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
        local descriptions={"将常用采集操作集中到一个入口，减少重复操作。","整理地图位置与传送入口，快速找到下一处目标。","集中查看角色状态与当前任务，重要信息一眼可见。","按需调整画面表现，减少游玩时的视觉干扰。","标记常用路线与兴趣点，让探索更有方向。","跨游戏使用的轻量工具，保持简洁一致的操作。"}
        for index,name in ipairs(names) do table.insert(sample,{id="hall-"..index,gameId="preview",nameZh=name,nameEn="Preview "..index,shortDescription=descriptions[index],enabled=true,universal=index>3,placeIds=index<=3 and {2} or {},universeIds={},aliases={},tags={}}) end
        local cases={{"pc",1440,900,1040,720},{"tablet",1024,768,962,691},{"phone",844,390,793,351},{"landscape",667,375,627,337}}
        local output=process.env.HUB_UI_PREVIEW_DIR
        fs.writeDir(output)
        for _,screen in ipairs(cases) do
            local f=fixture({catalog=sample});f.resize(screen[4],screen[5])
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
                        order=o.LayoutOrder,scrolling=o.ScrollingEnabled,canvas=dim(o.CanvasSize),cellSize=dim(o.CellSize),cellPadding=dim(o.CellPadding),columns=o.FillDirectionMaxCells,
                        anchor=o.AnchorPoint and {o.AnchorPoint.X,o.AnchorPoint.Y},radius=o.CornerRadius and o.CornerRadius.Offset,stroke=color(o.Color),scale=o.Scale}
                    if o.Name=="HubViewport" then entry.size={0,screen[4],0,screen[5]} end
                    table.insert(nodes,entry)
                end
            end
            fs.writeFile(output.."/"..screen[1]..".json",serde.encode("json",{width=screen[2],height=screen[3],nodes=nodes}))
        end
    end)
end

check("原样执行、搜索布局、关闭与单实例恢复",function()
    local f=fixture();local panel,search
    for _,o in ipairs(f.objects)do
        if o.Name=="HubWindow" then panel=o end
        if o.Name=="ScriptSearch" then search=o end
    end
    assert(panel and search);f.resize(640,320)
    assert(not panel.ScrollingEnabled and f.byName("ScriptGrid").ScrollingEnabled)
    search.Text="没有这个脚本";search:GetPropertyChangedSignal("Text"):Fire();assert(f.find("没有匹配的脚本").Visible~=false)
    search.Text="";search:GetPropertyChangedSignal("Text"):Fire()
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
        local window,list,grid=f.byName("HubWindow"),f.byName("ScriptGrid"),f.byName("CardLayout")
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
        for _,name in ipairs({"ValidateKey","CloseView","CollapseView","EndSession","AllScripts","AvailableScripts","ToggleHub"}) do
            assert(f.byName(name).Size.Y.Offset>=44,"触控目标至少44px："..name)
        end
        local footer=f.byName("EndSession")
        local bottom=footer.Position.Y.Offset+footer.Size.Y.Offset
        assert(bottom<=layout.height)
    end
    assert(f.byName("ShortDescription").Text=="检查当前游戏的授权连接与运行状态。")
    assert(f.byName("ShortDescription").RichText==false)
end)
check("ZS 品牌与 f0644b 主题色保持一致",function()
    local f=fixture()
    local accent=rb.Color3.fromRGB(240,100,75)
    assert(f.byName("Brand").Text=="ZS" and f.byName("Heading").Text=="ZS HUB")
    assert(f.byName("Brand").BackgroundColor3==accent)
    assert(f.byName("ValidateKey").BackgroundColor3==accent)
    assert(f.byName("CardAction").TextColor3==accent)
    assert(f.byName("AllScripts").TextColor3==accent)
    f.click("当前可用");assert(f.byName("AvailableScripts").TextColor3==accent)
end)
check("名称、简介搜索与当前可用筛选不触发登录或脚本加载",function()
    local scripts={
        {id="hall-8",gameId="other",nameZh="其他游戏工具",nameEn="Other",enabled=true,universal=false,placeIds={},universeIds={99},shortDescription="仅其他游戏适用",tags={},aliases={}},
        {id="hall-7",gameId="demo",nameZh="当前游戏工具",nameEn="Current",enabled=true,universal=false,placeIds={2},universeIds={1},shortDescription="收集物品与快捷导航",tags={},aliases={}},
        {id="hall-9",gameId="common",nameZh="通用工具",nameEn="Common",enabled=true,universal=true,placeIds={},universeIds={},tags={},aliases={}},
    }
    local f=fixture({catalog=scripts})
    assert(f.byName("ScriptCard_hall-7").LayoutOrder==1)
    assert(f.byName("ScriptCard_hall-9").LayoutOrder==2)
    assert(f.byName("ScriptCard_hall-8").LayoutOrder==3)
    f.click("当前可用")
    assert(not pcall(f.byName,"ScriptCard_hall-8") and f.byName("ScriptCount").Text=="2 个脚本")
    assert(f.byName("ScriptCard_hall-9").Selectable)
    f.click("全部脚本");assert(f.byName("ScriptCount").Text=="3 个脚本")
    local search=f.byName("ScriptSearch")
    search.Text="快捷导航";search:GetPropertyChangedSignal("Text"):Fire()
    assert(f.byName("ScriptCount").Text=="1 个脚本")
    assert(f.byName("ScriptCard_hall-7"))
    assert(f.counter.logins==0 and f.counter.loads==0 and #f.counter.kicks==0)
end)
check("空目录、旧 API 缺少简介与长文本均有稳定布局",function()
    local f=fixture({catalog={}})
    assert(f.byName("EmptyState").Visible and f.byName("EmptyState").Parent~=f.byName("ScriptGrid"))
    assert(f.byName("ScriptCount").Text=="0 个脚本")
    local long=fixture({catalog={{id="hall-7",gameId="demo",nameZh=string.rep("很长的中文标题",15),nameEn="Long",enabled=true,universal=true,placeIds={},universeIds={},tags={},aliases={}}}})
    long.resize(627,337)
    assert(long.byName("ShortDescription").Text=="作者暂未填写脚本简介")
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
    local f=fixture({heartbeatError="HUB_LICENSE_EXPIRED"});f.click("校验 Key")
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
    f.client();assert(f.find("授权有效"));f.click("校验 Key");task.wait(0.03)
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
    local f=fixture();f.click("校验 Key");untilTrue(function()return pcall(f.find,"授权有效")end)
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
    f.click("校验 Key");f.play();task.wait(0.3)
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
print("通过："..passed.." 项界面/监控解耦、原样加载、授权失效断开与竞态回归；Kick 为本地替身")

-- 模拟 Kick 不销毁测试 VM；仅在全部检查通过后结束夹具进程，不宣称回收原脚本任务。
process.exit(0)
