# zp-hub

独立的 Hub 客户端与公共资源构建仓库。界面、搜索、游戏排序、Key 会话客户端、Key 操作页、混淆与 GitHub 发布在此维护；不包含游戏脚本、会员数据库或授权后端，也不依赖相邻源码仓库。

## 仓库边界

| 仓库 | 职责 |
| --- | --- |
| zp-hub | 公共客户端、公共资源包、客户端测试和混淆发布 |
| r-s-zh | 可选游戏源码维护，与 Hub 构建及运行无依赖 |
| zp-sprite-backend | 原脚本大厅数据源与 Hub 配置、会员、Key、HWID 会话及鉴权分发 |

API 继续使用 `https://www.zldelf.cloud/api`，请求路径、Key 格式和会话协议保持原样。客户端运行时从 `/api/hub/catalog` 获取脚本清单，不在构建时读取游戏仓库。

## 目录与版本

- `src`：Lua 客户端、运行时与 Key 页面公共资源。
- `tests`：Python 构建测试、Lua 客户端模拟及可选本地 Key 页联调。
- `VERSION`：Hub 自身版本，独立于脚本大厅记录版本。
- `build.py`：仅生成公共资源及校验元数据。
- `publish.py`：仅生成 GitHub 三个公开附件。
- `.github/workflows/publish-hub.yml`：本仓库构建并发布到 evennext333-ai/zp-hub。

## 本地验证

依赖 Python 3.10 以上、Lune 0.10.5；检查页面脚本语法还需 Node.js。普通构建只使用 Python 标准库，不需要游戏仓库或后端数据库。

```sh
cd /Users/lvjunling/work_space/flutter/persor/zp-hub
python3 -m unittest discover -s tests -p 'test_*.py'
lune run /Users/lvjunling/work_space/flutter/persor/zp-hub/tests/test_runtime.luau
lune run /Users/lvjunling/work_space/flutter/persor/zp-hub/tests/test_client.luau
HUB_TEST_STARVE_WATCHDOG=1 lune run /Users/lvjunling/work_space/flutter/persor/zp-hub/tests/test_client.luau
node --check /Users/lvjunling/work_space/flutter/persor/zp-hub/src/keys.js
node --test /Users/lvjunling/work_space/flutter/persor/zp-hub/tests/test_keys.mjs
```

真实混淆测试需提供 `HUB_PROMETHEUS_DIR` 和可选的 `HUB_LUA_BIN`；未提供工具路径时该项明确跳过，其余测试照常运行。`test_standalone_copy_builds_without_sibling_repositories` 会在临时目录只复制构建器、版本及公共源码后执行构建，检查仓库隔离。

Key 页请求头回归测试在本地与 CI 直接运行；真实 API 的 DOM 模拟联调需设置 `HUB_BROWSER_TEST_ORIGIN` 为隔离本地服务，未设置时明确跳过。夹具需准备 `hub-browser-admin` 和有效 VIP 的 `hub-browser-member` 测试账号（密码 `BrowserFixture123!`），以及大厅里适配测试游戏（universeId=1、placeId=2）的已启用 Hub 脚本。测试从 API 目录读取游戏及脚本 ID，不依赖旧的验证脚本包；这些账号只用于专用本地测试环境。

## 构建公共资源包

```sh
python3 /Users/lvjunling/work_space/flutter/persor/zp-hub/build.py \
  --output /tmp/zp-hub-assets-1.2.0
```

默认 API 是 `https://www.zldelf.cloud/api`，也可显式传 `--api-url`；根地址与 `/api` 前缀都支持，不生成重复 `/api/api`。

输出严格为 `loader.lua`、`keys.html`、`keys.js`、`keys.css` 和 `hub.json`。元数据记录 Hub 版本、API 根地址及四个资源的 SHA256。输出目录须为新目录；异常时不留下半成品。

需要混淆时，先将 Prometheus 检出为 `a98c50165f2a53f6d765a82eee60dfea53803445`，并安装 Lua 5.1，再执行：

```sh
python3 /Users/lvjunling/work_space/flutter/persor/zp-hub/build.py \
  --prometheus-dir /tmp/prometheus \
  --lua-bin lua5.1 \
  --output /tmp/zp-hub-assets-obfuscated-1.2.0
HUB_TEST_LOADER=/tmp/zp-hub-assets-obfuscated-1.2.0/loader.lua \
  lune run /Users/lvjunling/work_space/flutter/persor/zp-hub/tests/test_client.luau
```

变量重命名、字符串和常量变换不启用 VM 或反调试。混淆失败即构建失败，不回退为明文公开附件。构建目录中的 Key 页面、API 地址和完整性元数据均是公开信息，不包含用户凭据。

## 统一界面与 Key 管理

游戏内 Hub 使用深色底、`#f0644b` 强调色的横版卡片布局；Key 自助网页保留原深色青绿色样式，本轮不修改网页。游戏内保留自动识别排序、搜索、Key 校验、关闭/收起与界面恢复；原脚本零修改，授权失效通过原生断开本局处理，界面关闭与后台授权监控相互独立，窄屏通过滚动访问完整内容。 无正文的 GET/DELETE 请求不再声明 JSON Content-Type，避免服务器按空 JSON 正文拒收；接口路径及授权语义保持原样。

管理员日常 Key 查询、单游戏发放和权益吊销已接入现有 `/Users/lvjunling/work_space/flutter/persor/zldelf-admin` 的「Hub 授权」页面（`/hub/keys`），直接复用后台登录态，不单独登录。

本仓库 Key 网页保留为会员自助与旧链接兼容入口，会员领取/重置仍使用用户端登录态；管理员 JWT 不代替会员授权。网页权益改为可读卡片，服务端文本只作为文本节点渲染；明文 Key 仍仅在生成时显示，不写本地存储。管理后台页面详见 `/Users/lvjunling/work_space/flutter/persor/zldelf-admin/docs/hub-keys.md`。

## 原脚本零修改与会话终止

本节对应 `hub-v1.1.0` 的客户端策略；历史 `hub-v1.0.0` 保留旧行为，不覆盖旧 Release。国内、海外统一使用同一个 GitHub Release 加载入口，以实际 Release 和校验和为准。

- API 返回什么正文，Hub 就编译执行什么正文，不注入代码、不改写环境、不向原脚本传入 `context` 或其他参数，也不把返回函数当作卸载契约。原有远端加载入口及其子脚本保持原语义。
- `Runtime.lifecycle()` 按每轮视图管理 UI，授权控制器、令牌、租约、心跳及看门狗独立于视图存活。授权失效不再宣称已卸载任意游戏脚本，而是调用 `LocalPlayer:Kick()` 显示 Roblox 原生断开提示并结束当前服务器会话；不是关闭 Roblox 进程，也不是回滚服务器已发生的动作。
- 初次 Key 校验失败仅拒绝加载。已登录后的 Key 到期、吊销、重置、会员失效、会话被替换或无效会话，在心跳或加载接口确认后结束本局。短暂网络故障按原协议重试，不立即误踢；独立看门狗在原租约截止时结束本局，失败请求不续期。
- 心跳仍约 30 秒、网络失败重试间隔 3 秒、租约最长 90 秒且不超过权益到期。服务器先使旧会话失效，旧客户端在下一次检查时发现；没有新增实时推送。
- 一个游戏会话最多启动一份游戏脚本，避免原脚本无卸载契约时叠加或假装完成切换；重载或切换应先结束本局再重新进入。编译失败且尚未执行时可重试。开始执行后异常只记录状态，继续授权监控，不自动断开；重试前由用户手动结束本局，避免叠加可能残留的任务。
- 「关闭界面」、执行器清理 UI 或游戏销毁 Hub 窗口，只释放该轮视图及监听，不注销会话、不结束游戏、不清除控制器单例；收起也继续后台校验。仅明确授权失效（含会员到期/吊销/重置）、顶号或原租约耗尽会自动结束本局。
- 重新执行同一个 Hub 加载入口，复用现有控制器与已获取目录：界面仍在时展开，已销毁时重新获取 PlayerGui 并重建视图；不重复登录、启动脚本或创建监控循环。恢复显示最近的会话/运行状态，未提交的输入及搜索在重建时重置。界面重建失败只告警，不影响后台校验；同时恢复的请求只构建一份视图。
- 「结束本局」仍是明确的手动断开操作。关闭界面后需手动结束时，重新执行原入口恢复界面，再点击此按钮；结束后清理会话并尽力注销。
- 界面关闭不取消已请求的登录、下载或编译，可在后台完成。只有控制器已因授权失效/租约耗尽或手动结束而终止时，晚到的正文和新视图才不再启用，收到的晚到登录凭证会尽力注销。一次终止只发起一次 Kick，晚到的心跳不恢复终止状态。
- Kick 报错时停用当前 Hub 加载和续租，并显示/输出立即手动离开本局的提示，不伪报游戏已断开；缺少 Kick 能力时不启动 Hub。

原协议字段 `lifecycle=managed` 继续保留，含义为游戏范围、原始入口和 **Hub 会话终止策略** 已完成接入验收；不要求游戏源码配合清理。`pending` 仍不开放，66 条旧记录不批量自动启用。

发布时使用新版本标签，保留历史 Release，GitHub 统一分发加载器；若更新 Key 页面或维护旧后端加载链接，另行同步公共资源；再给首批验收后的脚本开放 Hub。旧策略的 Hub 单例会提示重新进入游戏，不悄悄复用仍将 UI 销毁视为退出的策略；同策略的后台单例只恢复视图。旧公开版本和被篡改的客户端不因此变成可信执行环境；已下发正文也不支持远程回收。

此策略依赖客户端调度与原生 Kick，非让出执行的死循环、执行器 Hook 和客户端篡改属于已知边界；测试使用本地 Kick 替身，不代表真实游戏已断开。如果执行器清理操作同时杀掉后台协程或重置运行环境，不属于仅删除 UI，监控也会受影响。真实执行器、原脚本及其第三方依赖、UI 清理/恢复、到期/顶号/断网原生提示仍须逐项验收。

## 独立部署，只依赖现有 API

Hub 的目录和脚本内容直接来自后端原脚本大厅数据库，不读取游戏仓库，也没有脚本打包、上传发布目录的步骤。配置、上架或修改脚本通过原脚本大厅管理 API 完成。Hub 继续请求 `/api/hub/catalog` 和鉴权后的 `/api/hub/scripts/:id/load`，响应字段和授权协议保持原样。

为保留 Key 页地址及旧后端加载链接兼容，将本仓库公共构建输出部署给后端；国内、海外用户均从 GitHub 加载 Hub，不依赖此目录选择加载入口：

```dotenv
HUB_ENABLED=true
HUB_SECRET=<保留现有至少32字节的密钥>
HUB_PUBLIC_DIR=/srv/zp-hub/public/1.2.0
```

`HUB_PUBLIC_DIR` 只包含本仓库四个公共资源和 `hub.json`；没有游戏脚本或游戏目录清单。后端校验公共文件大小、路径和摘要后托管。只更新公共客户端时切换此目录并重启或滚动发布；修改脚本大厅内容与状态无需重启或重新构建 Hub。

Docker 在原生产配置上叠加后端 `/Users/lvjunling/work_space/flutter/persor/zp-sprite-backend/deploy/docker-compose.hub.yml` 和 `/Users/lvjunling/work_space/flutter/persor/zp-sprite-backend/deploy/docker-compose.hub-public.yml`，设置 `HUB_PUBLIC_HOST_DIR`。不再挂载私有脚本包。仅运行 API 时可省略公共目录；加载器及 Key 页在公共资源尚未部署时返回 503。

后端需应用新增 `hub_config` 增量迁移，并通过原管理 API 给验收后的脚本启用 Hub 配置；普通大厅脚本默认不自动上架。迁移、配置示例与测试见 `/Users/lvjunling/work_space/flutter/persor/zp-sprite-backend/docs/hub-tests.md`。

## GitHub 发布到 zp-hub

源码、标签和 Release 统一在 `evennext333-ai/zp-hub`，主加载地址为：

```text
https://github.com/evennext333-ai/zp-hub/releases/latest/download/loader.lua
```

1. 远端使用 `git@github.com:evennext333-ai/zp-hub.git`，主分支为 `main`。推送已审查的源码和工作流后，再推送版本标签触发发布；仅推送 `main` 不会创建 Release，文档地址不是已上线的证明。
2. 主入口供 `game:HttpGet` 匿名访问，发布仓库须公开。公开仓库也会公开明文源码及历史；混淆 Release 附件不隐藏源码。私有仓库的 Release 需要认证，不适合作为这个公开加载入口。发布前先确认源码公开策略。
3. 不再使用跨仓库 PAT 或 `HUB_RELEASE_TOKEN`。构建任务保持 `contents: read`；只有发布任务使用内置 `GITHUB_TOKEN` 和 `contents: write`。发布任务限定在 `evennext333-ai/zp-hub`，其他仓库和 fork 只构建。[GitHub 内置令牌与权限说明](https://docs.github.com/en/actions/tutorials/authenticate-with-github_token)
4. 检查 `VERSION`，在本仓库创建并推送匹配标签，例如版本 `1.2.0` 对应 `hub-v1.2.0`；也可手动指定已存在的匹配标签。工作流显式检出标签而非默认分支。
5. 测试与混淆完成后，构建任务输出 `hub-server-assets`（四个公共资源和 hub.json，供 Key 页部署及旧后端加载链接兼容）和 `hub-public`（`loader.lua`、`NOTICE.txt`、`SHA256SUMS`）。两份混淆加载器逐字节一致。
6. 发布任务校验附件白名单与 SHA256，在同一仓库要求标签已经存在，以实际构建提交为来源创建草稿，附件上传成功后才公开并标记为 latest。已存在的 Release 不覆盖，失败后检查草稿和产物，处理后再运行。[GitHub CLI 标签校验说明](https://cli.github.com/manual/gh_release_create)

原 `r-s-zh` 的 Release 不再作为发布目标，不上传、不删除或覆盖那里的历史附件；旧 GitHub URL 也不自动重定向到新地址，应向用户分发新的加载语句。该仓库仅保留游戏源码职责。

## 加载入口与 API 分开

```lua
getgenv().HUB_KEY = "KEY"
loadstring(game:HttpGet("https://github.com/evennext333-ai/zp-hub/releases/latest/download/loader.lua"))()
```

运行流程：GitHub 下载并启动公共 Hub → 请求 `https://www.zldelf.cloud/api` 获取目录、校验 Key 和加载脚本。脚本正文继续复用现有大厅数据库，不从 GitHub 下载游戏源码。

- 国内、海外唯一推荐加载入口：`https://github.com/evennext333-ai/zp-hub/releases/latest/download/loader.lua`。不按地区切换加载器域名。
- API：`https://www.zldelf.cloud/api`，运行接口仍为 `/api/hub/*`。
- Key 页面：`https://www.zldelf.cloud/api/hub/keys`。
- 旧后端加载链接仅保留兼容，不再作为国内入口分发；现有 API 路由不删除。
- 原 `/hub/loader.lua`、`/hub/keys` 等后端兼容入口继续保留，不改路由或鉴权协议。

GitHub 发布不自动更新后端托管的 Key 页面及兼容资源，后端资源更新也不自动创建 Release。加载入口不做地区判断或自动回退；国内 GitHub 可达性需实测，访问失败时提示网络问题，不切换到 API 域名下载加载器。业务 API 地址仍保持不变。

## 当前发布门槛

Hub 不再携带默认游戏清单或验证脚本包。普通大厅脚本默认不自动上架，需逐项配置游戏 ID 并完成原始入口、依赖和原生断开策略验收，游戏源码保持原样。生产迁移、国内网络、真实执行器、服务器切换及首次同仓库工作流运行仍需逐项验收。

构建工具署名：Based on Prometheus by Elias Oelschner, https://github.com/prometheus-lua/Prometheus


## 三端脚本卡片布局

- PC、平板、手机统一横版「授权侧栏 + 脚本网格」；所有设备每行固定三列，不再按设备自动切换列数。移除竖屏单列和授权区上下堆叠分支。窗口最小逻辑尺寸 700×340，较小视口使用 UIScale 整体缩放，不修改游戏或 PlayerGui 的屏幕方向。
- 游戏内可见品牌统一为 `ZS` / `ZS HUB`（含断开提示和警告前缀），仓库名、加载入口、API 与内部单例标识保留，避免断开兼容性。
- 主色统一为 `#f0644b`（RGB 240/100/75），用于品牌、主按钮、当前游戏标记和强调边框；选中态采用配套深暖色，主要按钮使用深色文字。收起位于标题栏，仅收起后显示浮动恢复按钮。
- 卡片展示脚本名称（两行）、短描述（按窗口显示两至三行）、当前游戏/通用/其他游戏标记与加载动作。当前游戏仍排在最前；新增「全部脚本 / 当前可用」筛选，搜索支持名称、短描述、别名与标签。
- 目录兼容新增可选 `shortDescription`：来自后端现有大厅 `description`，归并空白后最多 100 个 Unicode 字符。旧后端未返回或内容为空时显示「作者暂未填写脚本简介」。名称、简介均关闭 RichText，不当作脚本或 HTML 执行。
- 仅脚本卡片区滚动，窗口不再整窗滚动；横版紧凑窗口缩短授权区与卡片。空状态不放在 UIGridLayout 中，避免占用卡片位置。按钮/输入框至少 44 逻辑像素高，整体缩放后的字体和触控仍需真机验收。
- 本轮采用 Roblox 原生 UIGridLayout，未引入第三方 UI 运行时下载。开源库候选：WindUI（MIT，项目标注 Beta，适合现成 Hub 组件）、Fusion（MIT，适合自定义响应式 UI）。将来引入时需固定版本、离线打包、保留许可证，界面卸载仅释放视图资源。
- API 根地址、目录/加载请求路径、Key、HWID、心跳、租约、原脚本正文和手动结束本局行为均不变。后台仅添加兼容字段，无数据库迁移。旧加载器忽略新字段，新加载器兼容旧目录。
- 测试覆盖 1040×720 PC、962×691 平板、793×351 手机横屏、627×337 小屏手机及 640×300 短窗口，包含缩放边界、长中文标题、缺省简介、空目录、筛选与原授权竞态。当前不维护手机竖屏版。

可选导出使用合成目录数据的控件树，供布局预览工具读取（不是 Roblox 实机截图）：

```sh
HUB_UI_PREVIEW_DIR=/tmp/zp-hub-ui-scenes lune run tests/test_client.luau
```

当前构建版本为 `1.2.0`。本地构建不自动推送、部署或创建 GitHub Release；正式发布时后端短描述字段与新版公共客户端可分别灰度，原入口保持不变。已运行旧 UI 的游戏实例继续使用旧视图，重新进入游戏后再加载新版；不为界面升级打断现有授权会话。
