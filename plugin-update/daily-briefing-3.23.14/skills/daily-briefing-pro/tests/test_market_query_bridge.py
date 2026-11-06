import os
import json
import sys
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import pandas as pd

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
import _hithink


class MarketQueryBridgeTests(unittest.TestCase):
    def setUp(self):
        _hithink.reset_runtime_state()

    def tearDown(self):
        _hithink.reset_runtime_state()

    def test_market_query_path_points_to_sibling_skill(self):
        expected = (
            SCRIPTS.parents[1]
            / "market-query"
            / "scripts"
            / "market_query.ps1"
        )
        self.assertEqual(_hithink.market_query_script(), expected.resolve())

    def test_run_market_query_uses_datahub_get_and_mode(self):
        with tempfile.TemporaryDirectory() as temp:
            script = Path(temp) / "market_query.ps1"
            script.write_text("# mock", encoding="utf-8")
            completed = SimpleNamespace(
                returncode=0,
                stdout='{"code":0,"message":"success","data":{"item":[]}}',
                stderr="",
            )
            with (
                patch.object(_hithink, "market_query_script", return_value=script),
                patch.object(_hithink.shutil, "which", return_value="pwsh.exe"),
                patch.object(
                    _hithink.subprocess, "run", return_value=completed
                ) as run,
                patch.dict(os.environ, {"THS_MARKET_QUERY_MODE": "cloud"}),
            ):
                result = _hithink._run_market_query(
                    ["datahub-get", "/api/a-share/calendar/trading-days"]
                )

        command = run.call_args.args[0]
        self.assertEqual(result["data"]["item"], [])
        self.assertEqual(command[:4], ["pwsh.exe", "-NoProfile", "-NonInteractive", "-File"])
        self.assertIn("datahub-get", command)
        self.assertIn("/api/a-share/calendar/trading-days", command)
        self.assertEqual(command[-2:], ["-Mode", "cloud"])

    def test_envelope_rejects_business_error(self):
        with self.assertRaisesRegex(_hithink.HithinkError, "code=1002"):
            _hithink._unwrap_envelope(
                {"code": 1002, "message": "invalid trade date", "data": None}
            )

    def test_trade_dates_uses_datahub_date_fields(self):
        payload = {
            "item": [
                {"date": "20261104"},
                {"date": "20261103"},
                {"date": "20261104"},
            ]
        }
        with patch.object(_hithink, "_datahub_get", return_value=payload):
            days = _hithink.trade_dates()
        self.assertEqual(days, ["2026-11-03", "2026-11-04"])
        self.assertIn("DataHub", _hithink.source_label())

    def test_trade_dates_falls_back_to_akshare_calendar(self):
        ak = SimpleNamespace(
            tool_trade_date_hist_sina=lambda: [
                {"trade_date": "2026-11-03"},
                {"trade_date": "2026-11-04"},
            ]
        )
        with (
            patch.object(
                _hithink,
                "_datahub_get",
                side_effect=_hithink.HithinkError("bridge offline"),
            ),
            patch.object(_hithink, "_load_akshare", return_value=ak),
        ):
            days = _hithink.trade_dates()
        self.assertEqual(days, ["2026-11-03", "2026-11-04"])
        self.assertIn("AkShare", _hithink.source_label())

    def test_fetch_pool_follows_pagination_and_normalizes_codes(self):
        pages = {
            1: {
                "item": [
                    {"thscode": "600519.SH", "name": "贵州茅台", "continue_day_cnt": 1},
                    {"thscode": "000001.SZ", "name": "平安银行", "continue_day_cnt": 2},
                ],
                "pagination": {"page": 1, "pages": 2, "total": 3},
            },
            2: {
                "item": [
                    {"ticker": "300750", "name": "宁德时代", "continue_day_cnt": 3}
                ],
                "pagination": {"page": 2, "pages": 2, "total": 3},
            },
        }
        calls = []

        def fake_get(path, timeout=120):
            calls.append((path, timeout))
            page = int(path.rsplit("page=", 1)[1].split("&", 1)[0])
            return pages[page]

        with patch.object(_hithink, "_datahub_get", side_effect=fake_get):
            rows = _hithink.fetch_pool(
                "limit-up-pool", "2026-11-04", page_size=2
            )

        self.assertEqual(len(rows), 3)
        self.assertEqual(rows[-1]["ticker"], "300750")
        self.assertEqual(rows[-1]["ts_code"], "300750.SZ")
        self.assertEqual(len(calls), 2)
        self.assertIn("date_ms=", calls[0][0])

    def test_fetch_pool_falls_back_to_akshare_for_down_and_break(self):
        seen_dates = []

        class FakeAk:
            @staticmethod
            def stock_zt_pool_em(date):
                return []

            @staticmethod
            def stock_zt_pool_dtgc_em(date):
                seen_dates.append(date)
                return [
                    {
                        "代码": "600000",
                        "名称": "浦发银行",
                        "最新价": 9.1,
                        "涨跌幅": -10.0,
                        "成交额": 1000000,
                        "换手率": 1.2,
                        "连续跌停": 2,
                        "开板次数": 1,
                        "封单资金": 300000,
                        "所属行业": "银行",
                    }
                ]

            @staticmethod
            def stock_zt_pool_zbgc_em(date):
                return [
                    {
                        "代码": "000001",
                        "名称": "平安银行",
                        "最新价": 12.2,
                        "涨跌幅": 5.2,
                        "成交额": 2000000,
                        "换手率": 2.5,
                        "涨停统计": "2天1板",
                        "首次封板时间": "09:45",
                        "最后封板时间": "13:10",
                        "炸板次数": 2,
                        "所属行业": "银行",
                    }
                ]

        with (
            patch.object(
                _hithink,
                "_datahub_get",
                side_effect=_hithink.HithinkError("bridge offline"),
            ),
            patch.object(_hithink, "_load_akshare", return_value=FakeAk()),
        ):
            down = _hithink.fetch_pool("limit-down-pool", "2026-11-04")
            broken = _hithink.fetch_pool("limit-break-pool", "2026-11-04")

        self.assertEqual(down[0]["continue_day_cnt"], 2)
        self.assertEqual(down[0]["open_times"], 1)
        self.assertEqual(broken[0]["continue_day_text"], "2天1板")
        self.assertEqual(broken[0]["first_limit_time"], "09:45")
        self.assertEqual(broken[0]["open_times"], 2)
        self.assertEqual(seen_dates, ["20261104"])
        self.assertIn("AkShare", _hithink.source_label())

    def test_market_snapshot_skips_untradable_and_calculates_change(self):
        payload = {
            "total": 3,
            "item": [
                {
                    "ticker": "600519",
                    "last_price": 120.0,
                    "prev_price": 100.0,
                    "turnover": 5000,
                },
                {
                    "ticker": "000001",
                    "last_price": 0,
                    "prev_price": 10.0,
                    "turnover": 100,
                },
                {
                    "ticker": "300750",
                    "last_price": 101.0,
                    "prev_price": 100.0,
                    "price_change_ratio_pct": 1.0,
                    "turnover": 2000,
                },
            ],
        }
        with patch.object(_hithink, "_datahub_get", return_value=payload):
            snapshot = _hithink.market_snapshot()
        self.assertEqual(set(snapshot), {"600519", "300750"})
        self.assertAlmostEqual(snapshot["600519"]["change"], 20.0)
        self.assertAlmostEqual(snapshot["300750"]["change"], 1.0)

    def test_market_breadth_uses_public_snapshot_fallback(self):
        snapshot = {
            "600000": {"prev": 10.0, "last": 10.2, "amount": 1, "change": 2.0},
            "000001": {"prev": 10.0, "last": 9.8, "amount": 1, "change": -2.0},
            "300750": {"prev": 10.0, "last": 10.0, "amount": 1, "change": 0.0},
        }
        with (
            patch.object(
                _hithink,
                "_datahub_get",
                side_effect=_hithink.HithinkError("bridge offline"),
            ),
            patch.object(_hithink, "_sina_snapshot", return_value=snapshot),
        ):
            breadth = _hithink.market_breadth()
        self.assertEqual(
            breadth, {"tradable": 3, "advance": 1, "decline": 1, "flat": 1}
        )

    def test_index_history_filters_range_and_invalid_rows(self):
        payload = {
            "item": [
                {
                    "date_ms": _hithink.date_ms("2026-11-03"),
                    "open_price": 100,
                    "high_price": 103,
                    "low_price": 99,
                    "close_price": 102,
                    "volume": 1000,
                    "turnover": 500000,
                },
                {
                    "date_ms": _hithink.date_ms("2026-11-04"),
                    "close_price": 0,
                },
                {
                    "date_ms": _hithink.date_ms("2026-10-01"),
                    "close_price": 90,
                },
            ]
        }
        with patch.object(_hithink, "_datahub_get", return_value=payload):
            rows = _hithink.index_history(
                "000001.SH", "2026-11-01", "2026-11-04"
            )
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["date"], "2026-11-03")
        self.assertEqual(rows[0]["close"], 102.0)

    def test_index_history_falls_back_to_eastmoney(self):
        frame = pd.DataFrame(
            [
                {
                    "date": "2026-11-03",
                    "open": "100",
                    "high": "103",
                    "low": "99",
                    "close": "102",
                    "volume": "1000",
                    "amount": "500000",
                }
            ]
        )
        ak = SimpleNamespace(stock_zh_index_daily_em=lambda symbol: frame)
        with (
            patch.object(
                _hithink,
                "_datahub_get",
                side_effect=_hithink.HithinkError("bridge offline"),
            ),
            patch.object(_hithink, "_load_akshare", return_value=ak),
        ):
            rows = _hithink.index_history(
                "000001.SH", "2026-11-01", "2026-11-04"
            )
        self.assertEqual(rows[0]["turnover"], 500000.0)
        self.assertIn("AkShare", _hithink.source_label())

    def test_resolve_security_uses_local_code_table_as_fallback(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "_stock_names.csv"
            path.write_text(
                "code,name\n600519,贵州茅台\n000001,平安银行\n",
                encoding="utf-8",
            )
            with (
                patch.object(
                    _hithink,
                    "_datahub_get",
                    side_effect=_hithink.HithinkError("bridge offline"),
                ),
                patch.object(_hithink, "STOCK_NAMES_PATH", path),
            ):
                result = _hithink.resolve_security("贵州茅台")
        self.assertEqual(result["ticker"], "600519")
        self.assertEqual(result["thscode"], "600519.SH")

    def test_dragon_tiger_preserves_board_type_query(self):
        captured = {}

        def fake_get(path, timeout=120):
            captured["path"] = path
            return {"trade_date": "2026-11-04", "stock_items": []}

        with patch.object(_hithink, "_datahub_get", side_effect=fake_get):
            result = _hithink.dragon_tiger("hot_money", "2026-11-04")
        self.assertEqual(result["trade_date"], "2026-11-04")
        self.assertIn("board_type=hot_money", captured["path"])
        self.assertIn("date=2026-11-04", captured["path"])

    def test_error_messages_redact_api_credentials(self):
        text = _hithink._safe_message(
            "X-api-key: test-api-value Authorization: Bearer test-auth-value"
        )
        self.assertNotIn("test-api-value", text)
        self.assertNotIn("test-auth-value", text)
        self.assertIn("[redacted]", text)

    def test_market_query_failure_uses_cooldown_but_can_retry(self):
        with (
            patch.object(
                _hithink,
                "_run_market_query",
                side_effect=_hithink.HithinkError("offline"),
            ) as run,
            patch.dict(
                os.environ,
                {"THS_MARKET_QUERY_RETRY_SECONDS": "120"},
            ),
        ):
            with self.assertRaises(_hithink.HithinkError):
                _hithink._datahub_get("/api/test")
            with self.assertRaisesRegex(_hithink.HithinkError, "冷却期内"):
                _hithink._datahub_get("/api/test")
        self.assertEqual(run.call_count, 1)

        _hithink.reset_runtime_state()
        success = {"code": 0, "message": "success", "data": {"item": []}}
        with (
            patch.object(
                _hithink,
                "_run_market_query",
                side_effect=[_hithink.HithinkError("offline"), success],
            ) as retry,
            patch.dict(
                os.environ,
                {"THS_MARKET_QUERY_RETRY_SECONDS": "0"},
            ),
        ):
            with self.assertRaises(_hithink.HithinkError):
                _hithink._datahub_get("/api/test")
            self.assertEqual(_hithink._datahub_get("/api/test"), {"item": []})
        self.assertEqual(retry.call_count, 2)

    def test_fetch_index_data_uses_unified_layer_for_a_shares(self):
        import build_briefing

        end = datetime.now().date() - timedelta(days=1)
        rows = [
            {
                "date": (end - timedelta(days=1)).isoformat(),
                "close": 100.0,
                "open": 99.0,
                "high": 101.0,
                "low": 98.0,
                "volume": 1,
                "turnover": 1,
            },
            {
                "date": end.isoformat(),
                "close": 101.0,
                "open": 100.0,
                "high": 102.0,
                "low": 99.0,
                "volume": 1,
                "turnover": 1,
            },
        ]
        frame = pd.DataFrame(rows).rename(columns={"close": "close"})
        fake_ak = SimpleNamespace(
            index_us_stock_sina=lambda symbol: frame,
            index_global_hist_sina=lambda symbol: frame,
            index_global_hist_em=lambda symbol: frame,
        )
        with (
            patch.object(build_briefing._hithink, "index_history", return_value=rows),
            patch.object(
                build_briefing._hithink,
                "source_label",
                return_value="同花顺 DataHub（market-query）",
            ),
            patch.dict(sys.modules, {"akshare": fake_ak}),
        ):
            result = build_briefing.fetch_index_data(end.isoformat())
        self.assertIn("上证", result)
        self.assertIn("科创50", result)
        self.assertEqual(
            result["_sources"]["上证"], "同花顺 DataHub（market-query）"
        )

    def test_docs_do_not_require_retired_cli(self):
        skill = (SCRIPTS.parent / "SKILL.md").read_text(encoding="utf-8")
        active_docs = skill.split("## 更新日志", 1)[0]
        for retired in (
            "hithink-finance",
            "HITHINK_FINANCE_API_KEY",
            "hithink-finance auth login",
        ):
            self.assertNotIn(retired, active_docs)

    def test_plugin_and_skill_versions_are_synchronized(self):
        plugin_root = SCRIPTS.parents[2]
        root = json.loads((plugin_root / "plugin.json").read_text(encoding="utf-8"))
        nested = json.loads(
            (plugin_root / ".codex-plugin" / "plugin.json").read_text(
                encoding="utf-8"
            )
        )
        skill = (SCRIPTS.parent / "SKILL.md").read_text(encoding="utf-8")
        self.assertEqual(root["version"], "3.23.14")
        self.assertEqual(nested["version"], "3.23.14")
        self.assertIn("    version: 3.23.14", skill)


if __name__ == "__main__":
    unittest.main()
