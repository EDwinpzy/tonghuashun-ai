---
name: market-query
description: '用于通过本机同花顺远航版/Lumi 查询行情：实时报价、日/周/月/分钟K线、分时、逐笔、排行、板块搜索、实时订阅、自选股与自选分组，以及 118 个 DataHub GET 接口和 276 个 DataAccessor 字段。用户说行情查询、查行情、实时报价、K线、分时、逐笔、排行榜、自选股、自选分组或指定同花顺 DataHub 接口时使用。'
metadata:
  legacy:
    trigger_words:
    - 行情查询
    - 查行情
    - 实时报价
    - K线
    - 分时
    - 逐笔
    - 排行榜
    - 自选股
    - 自选分组
    - DataHub
    version: 1.0.0
    author: Codex
    dependencies:
      external_tools:
      - pwsh
---

# 行情查询

直连本机同花顺远航版/Lumi 的行情能力。统一 CLI 输出 UTF-8 JSON，适合继续筛选、计算、落表或交给其他程序使用。

## 前置条件

- Windows 电脑上的同花顺远航版/Lumi 已启动并登录。
- Lumi MCP 桥可用，本机存在 `%USERPROFILE%\lumi\users\*\agent-sdk\opencode\config\opencode.jsonc`。
- 调用端使用 `pwsh`。Token、Cookie 和账号信息只在运行时读取，不写入结果、日志或插件包。
- 若本机有多个 Lumi 用户，可给任意命令追加 `-User <用户名>`。

这不是可脱离客户端独立部署的公开 HTTP API。普通程序不能直接请求 DataHub，实时行情也不能绕过客户端命名管道。

## 能力范围

| 能力 | 命令 | 数据源 |
|---|---|---|
| DataHub 全量目录与详情 | `catalog -Source datahub` | 118 个 GET 契约 |
| DataAccessor 请求目录 | `catalog -Source dataaccessor` | 20 个请求 API |
| 实时订阅目录 | `catalog -Source subscribe` | 6 个订阅 API |
| 字段目录 | `catalog -Source fields` / `fields` | 276 个 FieldID |
| 证券解析 | `search` | `search_securities` |
| 板块解析 | `blocks` | `search_blocks` |
| 实时报价 | `realtime` | `RequestRealtimeDataAsync` |
| 日/周/月/分钟 K 线 | `candle` | `RequestCandleDataAsync` |
| 分时/盘前/盘后/集合竞价 | `trend -Api <variant>` | `Request*TrendDataAsync` |
| 逐笔/盘前/盘后 | `tick -Api <variant>` | `Request*TickDataAsync` |
| 排行榜 | `sort` | `RequestSortDataAsync` |
| 首次推送订阅 | `subscribe` | 6 个 `Subscribe*` |
| DataHub 指定接口 | `datahub-get` | 登录态 `HttpGetAsync` 管道 |
| 自选股 | `watchlist` | `manageSector`, `sectorId=-1` |
| 自选分组列表 | `sectors` | `manageSector`, `operation=query` |
| 指定分组与成分 | `sector` | `manageSector`, `sectorId` 或 `sectorName` |
| 其他只读原生查询 | `call` | 白名单工具 |

完整契约在：

- `references/datahub-apis.md` 和 `references/datahub-apis.csv`
- `references/dataaccessor-apis.md` 和 `references/dataaccessor-apis.csv`
- `references/dataaccessor-subscribe-apis.csv`
- `references/dataaccessor-fields.csv`
- `references/datahub-runtime-failures.md`

## 常用调用

```powershell
pwsh -NoProfile -File scripts/market_query.ps1 search 贵州茅台
pwsh -NoProfile -File scripts/market_query.ps1 realtime 600519 -Fields 10,55,199112
pwsh -NoProfile -File scripts/market_query.ps1 candle 600519 -Period 5 -Count 60 -AdjustType 1
pwsh -NoProfile -File scripts/market_query.ps1 candle 600519 -Period 16 -Count 20
pwsh -NoProfile -File scripts/market_query.ps1 trend 600519
pwsh -NoProfile -File scripts/market_query.ps1 tick 600519 -Count 20
pwsh -NoProfile -File scripts/market_query.ps1 sort -Block 14 -SortField 199112 -SortOrder 1 -Count 20
pwsh -NoProfile -File scripts/market_query.ps1 datahub-get '/api/a-share/prices/snapshot?thscodes=600519.SH'
pwsh -NoProfile -File scripts/market_query.ps1 sectors
pwsh -NoProfile -File scripts/market_query.ps1 watchlist
pwsh -NoProfile -File scripts/market_query.ps1 sector -Target 234
```

多个证券用逗号分隔：

```powershell
pwsh -NoProfile -File scripts/market_query.ps1 realtime '600519,000001,300750' -Fields 10,55,199112
```

目录检索与字段检索：

```powershell
pwsh -NoProfile -File scripts/market_query.ps1 catalog -Source datahub -Query 北向 -All
pwsh -NoProfile -File scripts/market_query.ps1 catalog -Source datahub -Query snapshot -Limit 20
pwsh -NoProfile -File scripts/market_query.ps1 fields -DataType realtime -Query 市值 -All
pwsh -NoProfile -File scripts/market_query.ps1 fields -Query 市值 -All
```

订阅与只读原生查询：

```powershell
pwsh -NoProfile -File scripts/market_query.ps1 subscribe -SubscribeApi SubscribeRealtime -Target 600519 -Fields 6,7,8,9,10,13,55,199112,264648 -TimeoutMs 10000
pwsh -NoProfile -File scripts/market_query.ps1 call -Tool wencai_query -ArgumentsJson '{"skillId":"hithink-market-query","query":"今日涨幅前20","limit":20}'
pwsh -NoProfile -File scripts/market_query.ps1 call -Tool indicator_query -ArgumentsJson '{"securities":[{"market":"USHA","code":"600519"}],"period":"day","indicators":["MA5","MA20","MACD","RSI14"],"mode":"latest"}'
```

## 执行规则

1. 除排行、板块搜索和已知 market/code 外，先解析证券。不要凭代码前缀猜 `market`，统一使用 `search` 返回的 `market + code`。
2. K 线周期：`5=日`、`11=周`、`12=月`、`15=1分`、`16=5分`、`17=15分`、`18=30分`、`19=60分`。复权：`0=不复权`、`1=前复权`、`2=后复权`。
3. 分时变体：`RequestIntradayTrendDataAsync`、`RequestTrendDataAsync`、`RequestPreMarketTrendDataAsync`、`RequestPostMarketTrendDataAsync`、`RequestCallAuctionDataAsync`。
4. 逐笔变体：`RequestIntradayTickDataAsync`、`RequestTickDataAsync`、`RequestPreMarketTickDataAsync`、`RequestPostMarketTickDataAsync`。
5. DataHub 统一信封为 `{code,message,data,request_id}`；HTTP 200 仍可能业务失败，必须检查 `code`。`2003` 通常是账号权限，`5003` 是上游暂不可用，不能因一次失败宣称接口永久失效。
6. 三个 `/api/dump/market-dumps/*/download-url` 会返回短时签名链接，CLI 主动拒绝。不得改用其他方式抓取并落盘这些链接。
7. 查询默认只读。`manageSector` 只允许 `operation=query`；不创建、删除、重命名或修改用户自选分组，除非用户后续明确要求并采用单独的写操作流程。
8. 不读取、打印、保存或转发 Cookie、Bearer Token、账号密码、`artifacts/session-messages.json` 等敏感材料。
9. 输出行情时同时说明数据来源、口径和取数时间；盘中、收盘后和历史数据不要混用。结果是行情事实，不是投资建议。

## 已知口径

- `realtime` 外层键是 `market + code`，内层键是字符串 FieldID；部分字段可能返回字符串 `"NaN"`。
- 日 K 的字段 `1` 可能是整数日期，展示时优先用 `time`。
- 分钟 K 的字段 `1` 可能是对象；分时字段 `1` 与 `time` 可能相差 8 小时。展示时间统一优先 `time`。
- 逐笔字段 `1` 实测可能是毫秒时间戳，而 `time` 是秒；`count` 是近似上限，可能多返一条。
- K 线 `offset` 也是近似上限，可能比请求数量多一根。
- `Subscribe*` 在 MCP 中只等待首帧并自动退订，不是持续推送通道。
- DataAccessor 的 `GetCookie` 是敏感登录态辅助接口，不提供调用；`HttpPostAsync` 没有已发布的行情契约，不在只读查询白名单内。

## 失败排查

| 现象 | 处理 |
|---|---|
| 找不到本机 Lumi MCP 配置 | 启动并登录 Lumi，确认 MCP 桥开启；多账号时显式传 `-User`。 |
| 找不到证券 | 换代码、中文名或拼音；先看 `search` 的候选结果。 |
| DataHub 返回 `401` | 不能普通直连，必须通过本脚本的 `datahub-get` 登录态管道。 |
| DataHub 返回 `2003` | 当前账号或套餐无该接口权限。 |
| DataHub 返回 `5003` | 上游暂不可用，稍后重试，不要改写结果。 |
| 订阅返回空 | MCP 只等待首个推送帧；再检查交易时段、Fields 和订阅 API。 |
