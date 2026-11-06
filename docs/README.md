# 同花顺 AI 文档索引

根目录 [README](../README.md) 是结论、接口规模、使用命令、运行验证和安全边界的
权威入口。本目录只提供资料导航，不复制会随探测结果变化的接口事实。

## 快速入口

- [项目总览与快速使用](../README.md)
- [DataHub 接口总表](../inventory/datahub-apis.md)
- [DataAccessor 请求与订阅 API](../inventory/dataaccessor-apis.md)
- [未通过验证和主动跳过清单](../inventory/datahub-runtime-failures.md)
- [扶摇公网 GET 端点](../plugin-update/market-query-3.23.13/skills/market-query/references/cloud-apis.md)

## 资料与证据

- [`inventory/`](../inventory/)：可读接口表、CSV 和机器可读 JSON，是接口目录的主要来源。
- `artifacts/docs/`：从 Lumi 资源库解出的原始接口文档快照（仅本地，不纳入 Git）。
  这些文件保留上游相对链接，但当前目录是扁平化导出，部分链接不能直接打开。
- `artifacts/datahub-runtime-matrix-merged.json`：多轮运行验证与重试记录
  （仅本地，不纳入 Git）。
- [`plugin-update/`](../plugin-update/)：交付快照和技能包版本，不等同于可执行源码。

运行状态和权限结论以 `README.md` 的“运行验证结果”及
`inventory/datahub-runtime-failures.md` 为准。单次 `permission_denied`、
`upstream_unavailable` 或占位示例失败，不应被解释为接口永久失效。

## 工具与安全

- [`tools/lumi-query.ps1`](../tools/lumi-query.ps1)：本地优先、云端兜底的行情节查询入口。
- [`tools/verify-inventory.ps1`](../tools/verify-inventory.ps1)：目录静态校验；带 `-Live` 时复测关键查询。
- [`README.md`](../README.md#安全与合规)：凭据、Cookie、短时下载链接和数据授权边界。

运行证据可能包含本机会话状态。不要把 `artifacts/` 中的原始响应、Token、Cookie
或签名下载链接复制到文档、日志或提交记录。
