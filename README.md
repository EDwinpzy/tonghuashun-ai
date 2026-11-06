# 同花顺 AI / 远航版行情接口逆向结果

逆向对象：`同花顺远航版`（Lumi）`1.0.69`，安装目录
`C:\应用\同花顺AI版\同花顺远航版`。

证据截止：2026-11-05。本文只记录接口结构、调用方式和运行验证结果，不包含
Cookie、MCP Bearer Token、账号信息或短时下载链接。

GitHub 私有仓库：[EDwinpzy/tonghuashun-ai](https://github.com/EDwinpzy/tonghuashun-ai)。

完整资料导航见 [docs/README.md](docs/README.md)。

## 结论

可以抓取和复用，但要先区分两条链路：

| 链路 | 本质 | 能否被其他程序复用 |
|---|---|---|
| DataHub HTTP API | `https://datahub.10jqka.com.cn/api/...` | 不能普通直连；必须经已登录客户端的 `http_get` 管道代理 |
| DataAccessor | `window.dataAccessor` → IPC → Windows 命名管道 → 客户端 `PipeServer` | 不能脱离客户端直接调用；本机可通过 Lumi MCP 桥复用 |
| 扶摇公网 REST API | `https://fuyao.aicubes.cn/api/...` + `X-api-key` | 可以；需申请同花顺金融数据 API Key |

因此现在有两条可组合的路径：

1. **本地增强通道**：同一台 Windows 电脑运行并登录同花顺远航版/Lumi，MCP
   桥已启动；可取得分时、逐笔、排行、订阅和个人自选分组。
2. **云端冗余通道**：使用同花顺金融数据（扶摇）API Key 直接请求公网
   `/api/...`；可脱离桌面客户端，覆盖行情快照、日 K、标的检索、板块与
   其他 120 个公开 GET 端点。

普通 `Invoke-WebRequest` / `curl` 直接请求 DataHub 仍会返回
`401 Unauthorized`；登录态、签名和管道能力都在客户端进程内。需要完全脱离
客户端时，必须走扶摇公网 API，不能复制或复用 Lumi 的 Cookie、Bearer Token
或本机 MCP 会话。个人自选股和自选分组不属于扶摇公开行情能力，需自建存储。

## 接口规模

| 类别 | 数量 | 说明 |
|---|---:|---|
| DataHub GET 契约 | 118 | A 股、基金、期货、指数、期权、港股、资讯、标的元数据 |
| DataAccessor 请求 API | 20 | 实时、K 线、分时、逐笔、排行、搜索、HTTP 代理 |
| DataAccessor 订阅 API | 6 | 实时、K 线、分时、逐笔增量推送 |
| MCP 顶层工具 | 14 | 通过 `tools/list` 可见，`tool_search`/`tool_execute` 是入口 |
| MCP 动态数据工具 | 15 | 含行情查询、字段搜索、订阅、HTTP、问财等 |
| DataAccessor 字段 | 276 | realtime 260、candle 7、trend 4、tick 5 |

DataHub 分类：A 股 40、基金 33、期货 21、资讯 8、期权 6、指数 5、港股 3、
标的元数据 2。

## 运行验证结果

118 个 DataHub 契约中：

| 状态 | 数量 | 含义 |
|---|---:|---|
| `verified_success` | 109 | 至少一次通过登录态返回 `code=0` |
| `permission_denied` | 2 | 当前账号无高频行情权限 |
| `upstream_unavailable` | 2 | 上游数据源当前不可用，不能据此判定永久失效 |
| `document_example_rejected` | 2 | 文档示例参数被拒；不是行情接口本身失效 |
| `skipped_sensitive_dump` | 3 | 返回短时下载链接，主动跳过 |

未通过的接口：

- `/api/a-share/high-frequency/intraday`
- `/api/a-share/high-frequency/historical`
  - 均返回 `2003 Permission denied`，属于账号/套餐权限。
- `/api/futures/positions/contract-historical`
  - 返回 `5003 Futures finance upstream returned failure status`。
- `/api/news/anomaly/analysis`
  - 返回 `5003 Data source unavailable`。
- `/api/news/notice/detail`
  - 文档示例是占位 `seq`，返回 `3001 Target not found`。
- `/api/news/article/detail`
  - 文档示例是占位 `encoded_seq`，返回 `1002 Invalid parameter format`。

已实测成功的代表性接口：

- A 股行情快照、历史 K 线、集合竞价、资金流、估值、交易日历
- 同花顺/沪深指数快照、历史 K 线、成分股
- 场内基金快照、历史行情、净值
- 期货合约列表/详情、分时、日线、基差、交易日历、仓单、持仓
- 期权合约列表/详情、分时、日线、交易时间轴
- 标的检索、标的列表、龙虎榜、涨停/跌停/炸板池、热股榜

完整状态见 `inventory/datahub-apis.json` 的 `runtimeStatus` /
`runtimeEvidence` 字段，以及 `inventory/datahub-runtime-failures.md`。

## 文件说明

| 文件 | 用途 |
|---|---|
| `inventory/datahub-apis.md` | 118 个 DataHub 接口的可读总表，含参数、响应字段、示例、运行状态 |
| `inventory/datahub-apis.json` | 同上的完整机器可读版本 |
| `inventory/datahub-apis.csv` | 便于 Excel/表格筛选的接口索引 |
| `inventory/datahub-runtime-failures.md` | 未通过验证和主动跳过清单 |
| `inventory/datahub-sample-overrides.json` | 过期/占位合约的替代有效样例 |
| `inventory/dataaccessor-apis.md` | DataAccessor 请求/订阅 API、MCP 工具、市场编码 |
| `inventory/dataaccessor-apis.json` | DataAccessor 完整机器可读目录 |
| `inventory/dataaccessor-apis.csv` | 20 个请求 API 索引 |
| `inventory/dataaccessor-subscribe-apis.csv` | 6 个订阅 API 索引 |
| `inventory/dataaccessor-fields.json` | 276 个字段目录 |
| `inventory/dataaccessor-fields.csv` | 字段目录表格版 |
| `plugin-update/market-query-3.23.13/skills/market-query/references/cloud-apis.md` | 120 个扶摇公网 GET 端点目录 |
| `plugin-update/market-query-3.23.13/skills/market-query/references/cloud-apis.csv` | 扶摇端点、必需参数与可用性表格 |
| `artifacts/docs/` | 从 Lumi 资源库解出的 21 份接口文档 |
| `artifacts/datahub-runtime-matrix-merged.json` | 全量运行验证和重试记录 |
| `tools/lumi-mcp.ps1` | 动态读取本机 MCP 配置并调用 MCP |
| `tools/lumi-query.ps1` | 面向行情查询的统一 CLI |
| `tools/probe-datahub.ps1` | 批量探测 DataHub 样例 |
| `tools/merge-runtime-matrices.ps1` | 合并多轮探测结果，保留成功证据 |
| `tools/build-datahub-inventory.ps1` | 从本地 DataHub 文档重建目录 |
| `tools/build-dataaccessor-inventory.ps1` | 从字段/工具文档重建 DataAccessor 目录 |
| `tools/verify-inventory.ps1` | 校验目录数量；带 `-Live` 时复测关键查询 |

`artifacts/` 与 `logs/` 只保留在本机，不纳入 Git；上表中的 artifacts 条目
用于说明本地证据来源。

## 快速使用

前提：同花顺远航版/Lumi 已启动并登录，MCP 桥可用。

```powershell
# 搜索证券，拿到 market + code
pwsh -NoProfile -File .\tools\lumi-query.ps1 search 贵州茅台

# 实时行情
pwsh -NoProfile -File .\tools\lumi-query.ps1 realtime 600519 -Fields 10,55,199112

# 日 K；Count 是近似数量，客户端可能多返一根
pwsh -NoProfile -File .\tools\lumi-query.ps1 candle 600519 -Period 5 -Count 20 -AdjustType 1

# 5 分钟 K
pwsh -NoProfile -File .\tools\lumi-query.ps1 candle 600519 -Period 16 -Count 20

# 当日分时；输出较大，建议写入文件
pwsh -NoProfile -File .\tools\lumi-query.ps1 trend 600519 > .\artifacts\trend-600519.json

# 最近逐笔
pwsh -NoProfile -File .\tools\lumi-query.ps1 tick 600519 -Count 20

# 板块搜索
pwsh -NoProfile -File .\tools\lumi-query.ps1 blocks 黄金

# 涨幅榜
pwsh -NoProfile -File .\tools\lumi-query.ps1 sort -Block 14 -SortField 199112 -SortOrder 1 -Count 20

# 直接调用 DataHub；只允许 datahub.10jqka.com.cn 的 /api/ GET
pwsh -NoProfile -File .\tools\lumi-query.ps1 datahub-get '/api/a-share/prices/snapshot?thscodes=600519.SH,000001.SZ'
```

K 线周期：`5=日`、`11=周`、`12=月`、`15=1分`、`16=5分`、`17=15分`、
`18=30分`、`19=60分`。复权：`0=不复权`、`1=前复权`、`2=后复权`。

CLI 输出是 UTF-8 JSON，适合被 Python、Node、PowerShell 继续处理。证券代码
可以传代码、中文名或拼音；CLI 会先调用 `search_securities`，不会自行猜测
`market`。

## 其他程序如何接

### 同一台电脑上的程序

推荐两种方式：

1. 直接调用 `tools/lumi-query.ps1`，把 stdout 当 JSON 读。
2. 实现一个最小 MCP 客户端，按 `tools/lumi-mcp.ps1` 的方式连接本机 MCP。

本机 MCP 地址和 Bearer Token 会轮换，不能硬编码。脚本会自动扫描
`%USERPROFILE%\lumi\users\*\agent-sdk\opencode\config\opencode.jsonc`，
选取带 `"lumi"` MCP 配置的最新用户。若有多个账号，可显式传 `-User`。

### 远程服务器或其他设备

不能直接把 `lumi-query.ps1` 拷到服务器运行。DataHub 直连 `401`，实时行情
依赖客户端命名管道；MCP Token 属于本机登录会话。

可选方案：

- 使用同花顺金融数据（扶摇）公网 REST API：申请 API Key，通过
  `X-api-key` 请求 `https://fuyao.aicubes.cn/api/...`。Key 只放在服务端
  环境变量或密钥管理器中，并在自己的服务前增加鉴权、限流和缓存。
- 在每台需要取数的 Windows 机器安装并登录客户端，再各自调用本机 MCP。
- 若必须跨机器共享，可在本机另做一个仅监听 `127.0.0.1` 或内网的代理服务，
  但代理本身仍依赖本机 Lumi 登录态，并需要自行增加鉴权和限流。

不要尝试把 Cookie、Token 或客户端私有签名复制到服务器；它们会失效，也会
把账号凭据暴露给其他程序。

插件中的 `market-query` 技能已经实现双通道：

```powershell
# 默认：本地优先，云端兜底
pwsh -NoProfile -File scripts/market_query.ps1 realtime 600519 -IncludeMeta

# 完全脱离客户端
pwsh -NoProfile -File scripts/market_query.ps1 realtime 600519 -Mode cloud

# 任意已登记扶摇端点
pwsh -NoProfile -File scripts/market_query.ps1 cloud-get '/api/a-share/prices/snapshot' -ArgumentsJson '{"thscodes":"600519.SH"}' -Mode cloud
```

## DataAccessor 关键细节

### 已实测覆盖

| 能力 | 结果 |
|---|---|
| `search_securities` | `600519` → `USHA600519` |
| `realtime_query` | 字段 `10/55/199112` 返回最新价、名称、涨幅 |
| `candle_query` | 日 K（`period=5`）和 5 分钟 K（`period=16`）均返回数据 |
| `trend_query` | 当日分时返回分钟级序列 |
| `tick_query` | 逐笔价格、方向、成交量、成交次数返回正常 |
| `sort_query` | `block=14`、`sortField=199112` 返回全市场排行 |
| `search_blocks` | “黄金”返回多个板块 ID |
| `data_subscribe` | 调用成功并自动退订；实测返回体为空，未观察到有效推送帧 |
| `http_get` | DataHub 快照等接口在登录态下返回 `code=0` |

目录中的 4 个实时变体（盘中/盘前/盘后）来自客户端接口目录，但当前 MCP
`realtime_query` 没有暴露 `api` 变体参数；实际只能稳定使用默认实时入口。
分时和逐笔工具则暴露了 `api` 参数。

### 证券标识

所有行情请求的 `securities[]` 都使用：

```json
{ "market": "USHA", "code": "600519" }
```

`market` 和 `code` 必须来自 `search_securities`，不要凭代码前缀猜。

### 返回键

成功返回的结构通常是：

```json
{
  "USHA600519": {
    "5": "USHA600519",
    "10": 1449.98,
    "55": "贵州茅台",
    "199112": 0.2447
  }
}
```

外层 key 是 `market + code`，内层 key 是**字符串形式的 FieldID**。

### 已观察到的坑

- 实时字段 `11`、`54` 在部分标的上返回字符串 `"NaN"`，解析时要容错。
- 日 K 字段 `1` 可能返回 `20261105` 这类整数日期，展示时间应优先用 `time`。
- 分钟 K 的字段 `1` 可能是 `{datatype,value,IsBad,IsNull}` 对象，不要直接当数字。
- 分时字段 `1` 与 `time` 可能相差 8 小时；实际展示优先使用 `time`。
- 逐笔字段 `1` 实测是**毫秒**时间戳，`time` 是秒；`count:5` 可能返回 6 条。
- K 线 `offset:5` 实测可能返回 6 根，`offset` 更像包含边界的近似上限。
- 排行工具使用 `block=14`（沪深 A 股）、`sortField=199112`（涨跌幅）、
  `sortOrder=1`（降序）已验证；文档中个别 `sortField` 示例与工具说明冲突。
- MCP 的 `data_subscribe` 只等待首帧后自动退订，不能当持续推送通道。持续
  推送需要在 widget/页面里使用 `onSubscribe` / `onPush`，本仓库未验证该路径。
- DataHub 统一信封是 `{code,message,data,request_id}`，业务错误通常仍是
  HTTP 200，需要检查 `code`。

## DataHub 重点行情接口

完整表见 `inventory/datahub-apis.md`。最常用的：

| 用途 | 接口 |
|---|---|
| 标的检索 | `/api/meta/tickers/search` |
| 标的列表 | `/api/meta/tickers/list` |
| A 股快照 | `/api/a-share/prices/snapshot` |
| A 股历史 K 线 | `/api/a-share/prices/historical` |
| A 股集合竞价 | `/api/a-share/auction/snapshot` |
| A 股资金流 | `/api/a-share/capital-flow/snapshot` |
| A 股高频分时 | `/api/a-share/high-frequency/intraday` |
| A 股高频历史 | `/api/a-share/high-frequency/historical` |
| 指数快照 | `/api/a-share-index/prices/snapshot` |
| 指数历史 | `/api/a-share-index/prices/historical` |
| 场内基金快照 | `/api/fund/market/snapshot` |
| 基金净值 | `/api/fund/performance/nav` |
| 期货分时 | `/api/futures/prices/intraday` |
| 期货日线 | `/api/futures/prices/daily` |
| 期货合约列表 | `/api/futures/contracts/list` |
| 期权分时 | `/api/options/prices/intraday` |
| 期权日线 | `/api/options/prices/daily` |
| 期权合约列表 | `/api/options/contracts/list` |

每个接口的必填参数、默认值、响应字段和文档示例都在总表中；不要把示例里的
历史日期或过期合约当成永久有效参数。`datahub-sample-overrides.json` 记录了
本次用于复测的真实合约。

## 重新生成

先启动 Lumi 并确认 MCP 配置存在，然后：

```powershell
# 1. 批量探测文档示例（会跳过敏感 dump）
pwsh -NoProfile -File .\tools\probe-datahub.ps1

# 2. 合并多轮结果，保留至少一次成功的证据
pwsh -NoProfile -File .\tools\merge-runtime-matrices.ps1

# 3. 重建接口目录、CSV 和失败清单
pwsh -NoProfile -File .\tools\build-datahub-inventory.ps1
pwsh -NoProfile -File .\tools\build-dataaccessor-inventory.ps1

# 4. 静态校验 + 关键在线查询
pwsh -NoProfile -File .\tools\verify-inventory.ps1 -Live
```

`build-datahub-inventory.ps1` 默认从本机安装目录读取 DataHub 文档：

```text
C:\应用\同花顺AI版\同花顺远航版\lumi\resources\built-in-skills\datahub-lumi\snapshot\api
```

升级客户端后路径或契约数可能变化。脚本会对“仍为 118 个 GET 契约”做断言，
如果版本升级导致数量变化，应重新核对而不是直接放宽断言。

## 安全与合规

- 本文档和脚本不包含 Cookie、Bearer Token、账号或密码；本地临时抓取的
  `artifacts/session-messages.json` 已由 `.gitignore` 排除，不应提交。
- `tools/lumi-mcp.ps1` 在运行时读取本机配置，不落盘凭据。
- 三个 `/api/dump/market-dumps/*/download-url` 会返回短时签名链接，探测脚本
  主动跳过，避免把敏感 URL 写入产物。
- 这些接口来自客户端内部能力，不是公开 API 合同；请在自己有权使用的账号和
  数据授权范围内使用，不要把抓取结果或凭据重新分发。
- 生产使用前应增加超时、重试、限流和错误码处理；不要把一次 `5003` 当成接口
  永久失效。
