# zp-hub

独立的国内 Hub 客户端与公共资源构建仓库。界面、搜索、游戏排序、Key 会话客户端、Key 操作页、混淆与 GitHub 发布在此维护；不包含游戏脚本、会员数据库或授权后端，也不依赖相邻源码仓库。

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
  --output /tmp/zp-hub-assets-1.0.0
```

默认 API 是 `https://www.zldelf.cloud/api`，也可显式传 `--api-url`；根地址与 `/api` 前缀都支持，不生成重复 `/api/api`。

输出严格为 `loader.lua`、`keys.html`、`keys.js`、`keys.css` 和 `hub.json`。元数据记录 Hub 版本、API 根地址及四个资源的 SHA256。输出目录须为新目录；异常时不留下半成品。

需要混淆时，先将 Prometheus 检出为 `a98c50165f2a53f6d765a82eee60dfea53803445`，并安装 Lua 5.1，再执行：

```sh
python3 /Users/lvjunling/work_space/flutter/persor/zp-hub/build.py \
  --prometheus-dir /tmp/prometheus \
  --lua-bin lua5.1 \
  --output /tmp/zp-hub-assets-obfuscated-1.0.0
HUB_TEST_LOADER=/tmp/zp-hub-assets-obfuscated-1.0.0/loader.lua \
  lune run /Users/lvjunling/work_space/flutter/persor/zp-hub/tests/test_client.luau
```

变量重命名、字符串和常量变换不启用 VM 或反调试。混淆失败即构建失败，不回退为明文公开附件。构建目录中的 Key 页面、API 地址和完整性元数据均是公开信息，不包含用户凭据。

## 独立部署，只依赖现有 API

Hub 的目录和脚本内容直接来自后端原脚本大厅数据库，不读取游戏仓库，也没有脚本打包、上传发布目录的步骤。配置、上架或修改脚本通过原脚本大厅管理 API 完成。Hub 继续请求 `/api/hub/catalog` 和鉴权后的 `/api/hub/scripts/:id/load`，响应字段和授权协议保持原样。

为保留国内加载器和 Key 页地址，将本仓库公共构建输出直接部署给后端：

```dotenv
HUB_ENABLED=true
HUB_SECRET=<保留现有至少32字节的密钥>
HUB_PUBLIC_DIR=/srv/zp-hub/public/1.0.0
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
4. 检查 `VERSION`，在本仓库创建并推送匹配标签，例如版本 `1.0.0` 对应 `hub-v1.0.0`；也可手动指定已存在的匹配标签。工作流显式检出标签而非默认分支。
5. 测试与混淆完成后，构建任务输出 `hub-server-assets`（四个公共资源和 hub.json，供国内备用入口与 Key 页部署）和 `hub-public`（`loader.lua`、`NOTICE.txt`、`SHA256SUMS`）。两份混淆加载器逐字节一致。
6. 发布任务校验附件白名单与 SHA256，在同一仓库要求标签已经存在，以实际构建提交为来源创建草稿，附件上传成功后才公开并标记为 latest。已存在的 Release 不覆盖，失败后检查草稿和产物，处理后再运行。[GitHub CLI 标签校验说明](https://cli.github.com/manual/gh_release_create)

原 `r-s-zh` 的 Release 不再作为发布目标，不上传、不删除或覆盖那里的历史附件；旧 GitHub URL 也不自动重定向到新地址，应向用户分发新的加载语句。该仓库仅保留游戏源码职责。

## 加载入口与 API 分开

```lua
getgenv().HUB_KEY = "KEY"
loadstring(game:HttpGet("https://github.com/evennext333-ai/zp-hub/releases/latest/download/loader.lua"))()
```

运行流程：GitHub 下载并启动公共 Hub → 请求 `https://www.zldelf.cloud/api` 获取目录、校验 Key 和加载脚本。脚本正文继续复用现有大厅数据库，不从 GitHub 下载游戏源码。

- 主入口：`https://github.com/evennext333-ai/zp-hub/releases/latest/download/loader.lua`，首次成功公开发布后使用。
- API：`https://www.zldelf.cloud/api`，运行接口仍为 `/api/hub/*`。
- Key 页面：`https://www.zldelf.cloud/api/hub/keys`。
- 国内备用加载器：`https://www.zldelf.cloud/api/hub/loader.lua`，需独立部署公共构建目录。
- 原 `/hub/loader.lua`、`/hub/keys` 等后端兼容入口继续保留，不改路由或鉴权协议。

GitHub 首次发布不自动部署国内公共资源，国内资源切换也不自动创建 Release；两边需部署同一版本以避免主备客户端行为差异。国内 GitHub 可达性需实测，主地址失败时可显式改用上述国内备用加载器，但 API 地址不变。

## 当前发布门槛

Hub 不再携带默认游戏清单或验证脚本包。普通大厅脚本默认不自动上架，需逐项配置游戏 ID 并完成真实生命周期、依赖和卸载验收。生产迁移、国内网络、真实执行器、服务器切换及首次同仓库工作流运行仍需逐项验收。

构建工具署名：Based on Prometheus by Elias Oelschner, https://github.com/prometheus-lua/Prometheus
