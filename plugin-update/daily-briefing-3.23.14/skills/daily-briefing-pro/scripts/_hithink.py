#!/usr/bin/env python3
"""每日简报统一行情适配层。

主路径调用同插件的 ``market-query``：
  * 默认 ``auto``：本机远航版/Lumi 可用时走本地 DataHub，失败后尝试扶摇云端；
  * ``local``：只用本机客户端；
  * ``cloud``：只用扶摇 REST API，需要 ``HITHINK_API_KEY``。

行情桥不可用时，按函数粒度降级到 AkShare/东方财富或新浪公开行情。所有操作都是
惰性执行，导入本模块不会启动 PowerShell、联网或读取任何凭据。调用方仍拿到原有
字段，不因上游切换而改变简报 JSON 契约。
"""

from __future__ import annotations

import csv
import importlib
import importlib.util
import json
import math
import os
import re
import shutil
import subprocess
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import urlencode

CN = timezone(timedelta(hours=8))
SH_INDEX = "000001.SH"
SZ_INDEX = "399001.SZ"
POOL_PAGE_SIZE = 200
POOL_KINDS = {
    "limit-up-pool",
    "limit-down-pool",
    "limit-break-pool",
}

SCRIPT_DIR = Path(__file__).resolve().parent
BASE_DIR = SCRIPT_DIR.parent
STOCK_NAMES_PATH = BASE_DIR / "data" / "_stock_names.csv"

_last_source = "未取数"
_market_query_state: bool | None = None
_market_query_retry_at = 0.0
_trade_dates_cache: list[str] | None = None
_last_pool_sources: dict[str, str] = {}


class HithinkError(RuntimeError):
    pass


def _set_source(value: str) -> None:
    global _last_source
    _last_source = value


def source_label() -> str:
    return _last_source


def market_query_script() -> Path | None:
    """定位同一插件内的 market-query 入口，不执行。"""
    override = os.environ.get("THS_MARKET_QUERY_SCRIPT", "").strip()
    candidates = []
    if override:
        candidates.append(Path(override))
    candidates.append(
        SCRIPT_DIR.parents[1] / "market-query" / "scripts" / "market_query.ps1"
    )
    for candidate in candidates:
        if candidate.is_file():
            return candidate.resolve()
    return None


def _akshare_available() -> bool:
    try:
        return importlib.util.find_spec("akshare") is not None
    except (ImportError, ValueError):
        return False


def available() -> bool:
    """只要统一桥或公开行情兜底任一存在，就允许调用方继续。"""
    return market_query_script() is not None or _akshare_available()


def market_query_mode() -> str:
    value = os.environ.get("THS_MARKET_QUERY_MODE", "auto").strip().lower()
    return value if value in {"auto", "local", "cloud"} else "auto"


def reset_runtime_state() -> None:
    """测试和长驻进程显式重连时使用。"""
    global _market_query_state, _market_query_retry_at
    global _trade_dates_cache, _last_pool_sources
    _market_query_state = None
    _market_query_retry_at = 0.0
    _trade_dates_cache = None
    _last_pool_sources = {}


def _safe_message(value: str, limit: int = 600) -> str:
    text = str(value or "").strip()
    text = re.sub(r"(?i)(x-api-key\s*[:=]\s*)\S+", r"\1[redacted]", text)
    text = re.sub(r"(?i)(authorization\s*[:=]\s*bearer\s+)\S+", r"\1[redacted]", text)
    return text[:limit]


def _parse_json_output(raw: str) -> dict:
    text = (raw or "").strip()
    if not text:
        raise HithinkError("market-query 无输出")
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        payload = None
        for position in range(len(text)):
            if text[position] != "{":
                continue
            try:
                payload = json.loads(text[position:])
                break
            except json.JSONDecodeError:
                continue
        if payload is None:
            raise HithinkError(f"market-query 返回非 JSON：{_safe_message(text, 200)}")
    if not isinstance(payload, dict):
        raise HithinkError("market-query 返回值不是 JSON 对象")
    return payload


def _run_market_query(arguments: list[str], timeout: int = 120) -> dict:
    script = market_query_script()
    if script is None:
        raise HithinkError("找不到同插件的 market-query/scripts/market_query.ps1")
    executable = shutil.which("pwsh") or shutil.which("powershell")
    if not executable:
        raise HithinkError("找不到 PowerShell 7")
    command = [
        executable,
        "-NoProfile",
        "-NonInteractive",
        "-File",
        str(script),
        *arguments,
        "-Mode",
        market_query_mode(),
    ]
    try:
        process = subprocess.run(
            command,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        raise HithinkError(f"market-query 超时：{' '.join(arguments[:2])}") from exc
    except OSError as exc:
        raise HithinkError(f"market-query 启动失败：{_safe_message(str(exc))}") from exc

    if process.returncode != 0:
        detail = process.stderr or process.stdout or f"退出码 {process.returncode}"
        raise HithinkError(f"market-query 失败：{_safe_message(detail)}")
    return _parse_json_output(process.stdout)


def _unwrap_envelope(payload: dict) -> dict:
    if isinstance(payload.get("_meta"), dict) and isinstance(payload.get("data"), dict):
        payload = payload["data"]
    code = payload.get("code")
    if code is not None:
        try:
            code_value = int(code)
        except (TypeError, ValueError):
            code_value = -1
        if code_value != 0:
            message = _safe_message(str(payload.get("message") or "unknown business error"))
            raise HithinkError(f"同花顺接口 code={code}: {message}")
    data = payload.get("data")
    if data is None:
        return {}
    if not isinstance(data, dict):
        raise HithinkError("同花顺接口 data 段不是 JSON 对象")
    return data


def _datahub_get(path: str, timeout: int = 120) -> dict:
    """经 market-query 取 DataHub/扶摇同名路径。"""
    global _market_query_state, _market_query_retry_at
    if os.environ.get("THS_MARKET_QUERY_DISABLE", "").strip() == "1":
        raise HithinkError("market-query 已被 THS_MARKET_QUERY_DISABLE=1 禁用")
    if _market_query_state is False:
        if time.monotonic() < _market_query_retry_at:
            raise HithinkError("market-query 当前不可用，冷却期内使用公开行情兜底")
        _market_query_state = None
    try:
        result = _run_market_query(["datahub-get", path], timeout=timeout)
        data = _unwrap_envelope(result)
    except Exception:
        _market_query_state = False
        try:
            cooldown = max(
                0,
                int(os.environ.get("THS_MARKET_QUERY_RETRY_SECONDS", "120")),
            )
        except ValueError:
            cooldown = 120
        _market_query_retry_at = time.monotonic() + cooldown
        raise
    _market_query_state = True
    _market_query_retry_at = 0.0
    _set_source("同花顺 DataHub/扶摇（market-query）")
    return data


def _load_akshare():
    try:
        return importlib.import_module("akshare")
    except Exception as exc:
        raise HithinkError(f"AkShare 不可用：{_safe_message(str(exc), 200)}") from exc


def _items(payload: dict) -> list[dict]:
    values = payload.get("item") if isinstance(payload, dict) else []
    if not isinstance(values, list):
        return []
    return [row for row in values if isinstance(row, dict)]


def _number(value, default=None):
    try:
        number = float(value)
    except (TypeError, ValueError):
        return default
    return number if math.isfinite(number) else default


def _integer(value, default=0) -> int:
    number = _number(value)
    return int(number) if number is not None else default


def _records(frame) -> list[dict]:
    if frame is None or bool(getattr(frame, "empty", False)):
        return []
    if hasattr(frame, "to_dict"):
        try:
            values = frame.to_dict(orient="records")
            return [row for row in values if isinstance(row, dict)]
        except TypeError:
            pass
    return [row for row in frame if isinstance(row, dict)]


def date_ms(date_str: str) -> int:
    return int(datetime.strptime(date_str, "%Y-%m-%d").replace(tzinfo=CN).timestamp() * 1000)


def end_of_day_ms(date_str: str) -> int:
    dt = datetime.strptime(date_str, "%Y-%m-%d").replace(tzinfo=CN) + timedelta(
        hours=23, minutes=59, seconds=59
    )
    return int(dt.timestamp() * 1000)


def today() -> str:
    return datetime.now(CN).strftime("%Y-%m-%d")


def _normalize_date(value) -> str:
    raw = str(value or "").strip()
    if re.fullmatch(r"\d{8}", raw):
        return f"{raw[:4]}-{raw[4:6]}-{raw[6:]}"
    match = re.search(r"(\d{4})-(\d{2})-(\d{2})", raw)
    return match.group(0) if match else ""


def _date_from_ms(value) -> str:
    try:
        return datetime.fromtimestamp(float(value) / 1000, CN).strftime("%Y-%m-%d")
    except (TypeError, ValueError, OSError, OverflowError):
        return ""


def trade_dates() -> list[str]:
    """交易日序列：DataHub 优先，AkShare 新浪日历兜底。"""
    global _trade_dates_cache
    if _trade_dates_cache:
        return list(_trade_dates_cache)

    primary_error = None
    try:
        payload = _datahub_get("/api/a-share/calendar/trading-days")
        days = sorted(
            {
                day
                for row in _items(payload)
                if (day := _normalize_date(row.get("date")))
            }
        )
        if days:
            _set_source("同花顺 DataHub（market-query）")
            _trade_dates_cache = days
            return list(days)
        primary_error = "DataHub 返回空交易日"
    except Exception as exc:
        primary_error = f"{type(exc).__name__}: {exc}"

    try:
        ak = _load_akshare()
        frame = ak.tool_trade_date_hist_sina()
        records = _records(frame)
        column = "trade_date" if records and "trade_date" in records[0] else None
        days = sorted(
            {
                day
                for row in records
                if (day := _normalize_date(row.get(column) if column else row.get("date")))
            }
        )
        if not days:
            raise HithinkError("AkShare 返回空交易日")
        _set_source("AkShare 交易日历（新浪兜底）")
        _trade_dates_cache = days
        return list(days)
    except Exception as exc:
        raise HithinkError(
            f"交易日历不可用；market-query: {primary_error}；"
            f"AkShare: {type(exc).__name__}: {exc}"
        ) from exc


def latest_trade_date(days: list[str] | None = None) -> str | None:
    days = days or trade_dates()
    past = [day for day in days if day <= today()]
    return past[-1] if past else None


def previous_trade_date(date_str: str, days: list[str] | None = None) -> str | None:
    days = days or trade_dates()
    earlier = [day for day in days if day < date_str]
    return earlier[-1] if earlier else None


def _ths_code(code: str) -> str:
    code = str(code or "").strip()
    if "." in code:
        return code.upper()
    if len(code) != 6 or not code.isdigit():
        return ""
    if code.startswith(("6", "5", "9")):
        return f"{code}.SH"
    if code.startswith(("4", "8")):
        return f"{code}.BJ"
    return f"{code}.SZ"


def _normalize_pool_row(row: dict) -> dict:
    result = dict(row)
    ticker = str(result.get("ticker") or result.get("code") or "").strip()
    if not ticker:
        ticker = str(result.get("thscode") or "").split(".")[0]
    if ticker:
        result["ticker"] = ticker
        result["code"] = ticker
    thscode = _ths_code(str(result.get("thscode") or ticker))
    if thscode:
        result["thscode"] = thscode
        result.setdefault("ts_code", thscode)
    return result


def _normalize_akshare_pool_row(row: dict) -> dict:
    result = {
        "ticker": str(row.get("代码") or "").strip(),
        "name": str(row.get("名称") or "").strip(),
        "last_price": _number(row.get("最新价")),
        "price_change_ratio_pct": _number(row.get("涨跌幅")),
        "turnover": _number(row.get("成交额")),
        "turnover_ratio_pct": _number(row.get("换手率")),
        "limit_up_reason": str(row.get("所属行业") or "").strip(),
    }
    result["code"] = result["ticker"]
    result["thscode"] = _ths_code(result["ticker"])
    result["ts_code"] = result["thscode"]

    board = (
        row.get("连板数")
        if row.get("连板数") is not None
        else row.get("连续跌停")
    )
    if board is not None:
        result["continue_day_cnt"] = max(1, _integer(board, 1))
    result["continue_day_text"] = str(
        row.get("涨停统计") or row.get("连续跌停") or ""
    ).strip()
    result["limit_up_time"] = str(
        row.get("最后封板时间") or ""
    ).strip()
    result["first_limit_time"] = str(row.get("首次封板时间") or "").strip()
    result["last_limit_time"] = str(row.get("最后封板时间") or "").strip()
    open_times = row.get("开板次数")
    if open_times is None:
        open_times = row.get("炸板次数")
    if open_times is not None:
        result["open_times"] = _integer(open_times)
    seal_money = row.get("封板资金")
    if seal_money is None:
        seal_money = row.get("封单资金")
    if seal_money is not None:
        result["seal_money"] = _number(seal_money)
    return _normalize_pool_row(result)


def fetch_pool(kind: str, date_str: str, page_size: int = POOL_PAGE_SIZE) -> list[dict]:
    """分页拉取涨停/跌停/炸板池，返回旧版字段并额外保留 ticker。"""
    if kind not in POOL_KINDS:
        raise HithinkError(f"不支持的股票池类型：{kind}")
    page_size = max(1, min(int(page_size), 200))
    primary_error = None
    try:
        rows: list[dict] = []
        page = 1
        while page <= 30:
            query = urlencode(
                {
                    "date_ms": date_ms(date_str),
                    "page": page,
                    "size": page_size,
                }
            )
            payload = _datahub_get(
                f"/api/a-share/special-data/{kind}?{query}",
                timeout=60,
            )
            batch = [_normalize_pool_row(row) for row in _items(payload)]
            rows.extend(batch)
            pagination = payload.get("pagination") or {}
            pages = _integer(pagination.get("pages") or payload.get("pages"))
            total = _integer(pagination.get("total") or payload.get("total"))
            if not batch or len(batch) < page_size:
                break
            if pages and page >= pages:
                break
            if total and len(rows) >= total:
                break
            page += 1
        label = "同花顺 DataHub（market-query）"
        _last_pool_sources[kind] = label
        _set_source(label)
        return rows
    except Exception as exc:
        primary_error = f"{type(exc).__name__}: {exc}"

    try:
        ak = _load_akshare()
        fetcher = {
            "limit-up-pool": ak.stock_zt_pool_em,
            "limit-down-pool": ak.stock_zt_pool_dtgc_em,
            "limit-break-pool": ak.stock_zt_pool_zbgc_em,
        }[kind]
        frame = fetcher(date=date_str.replace("-", ""))
        rows = [_normalize_akshare_pool_row(row) for row in _records(frame)]
        label = "AkShare/东方财富（公开行情兜底）"
        _last_pool_sources[kind] = label
        _set_source(label)
        return rows
    except Exception as exc:
        raise HithinkError(
            f"{date_str} {kind} 获取失败；market-query: {primary_error}；"
            f"AkShare: {type(exc).__name__}: {exc}"
        ) from exc


def ladder_stats(pool: list[dict]) -> dict:
    """涨停池 -> 首板/二板/三板/四板以上家数与最高板、次高板。"""
    first_board = board2 = board3 = board4p = 0
    levels: set[int] = set()
    for row in pool:
        n = max(1, _integer(row.get("continue_day_cnt"), 1))
        if n <= 1:
            first_board += 1
            continue
        levels.add(n)
        if n == 2:
            board2 += 1
        elif n == 3:
            board3 += 1
        else:
            board4p += 1
    ordered = sorted(levels, reverse=True)
    return {
        "first_board": first_board,
        "board2": board2,
        "board3": board3,
        "board4p": board4p,
        "consecutive": board2 + board3 + board4p,
        "max_board": ordered[0] if ordered else 0,
        "next_board": ordered[1] if len(ordered) > 1 else 0,
    }


def pool_overview(date_str: str) -> dict:
    """一个交易日的盘面事实：涨停/跌停/炸板家数、封板率、炸板率、连板梯队。"""
    limit_up_pool = fetch_pool("limit-up-pool", date_str)
    down_pool = fetch_pool("limit-down-pool", date_str)
    break_pool = fetch_pool("limit-break-pool", date_str)
    stats = ladder_stats(limit_up_pool)
    limit_up = len(limit_up_pool)
    broken = len(break_pool)
    total = limit_up + broken
    sources = {
        "limit_up_pool": _last_pool_sources.get("limit-up-pool", ""),
        "limit_down_pool": _last_pool_sources.get("limit-down-pool", ""),
        "limit_break_pool": _last_pool_sources.get("limit-break-pool", ""),
    }
    return {
        "date": date_str,
        "limit_up": limit_up,
        "limit_down": len(down_pool),
        "broken": broken,
        "seal_rate": round(limit_up / total * 100, 2) if total else None,
        "broken_rate": round(broken / total * 100, 2) if total else None,
        "limit_up_pool": limit_up_pool,
        "sources": sources,
        **stats,
    }


def _sina_prefix(code: str) -> str:
    if code.startswith(("6", "5", "9")):
        return "sh" + code
    if code.startswith(("8", "4")):
        return "bj" + code
    return "sz" + code


def _load_local_codes() -> list[str]:
    if not STOCK_NAMES_PATH.is_file():
        return []
    codes = []
    with STOCK_NAMES_PATH.open(encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            code = str(row.get("code") or "").strip()
            if len(code) == 6 and code.isdigit():
                codes.append(code)
    return codes


def _sina_snapshot(codes: list[str], chunk_size: int = 300) -> dict[str, dict]:
    import ssl
    import urllib.request

    context = ssl.create_default_context()
    result = {}
    headers = {
        "User-Agent": (
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
            "AppleWebKit/537.36 Chrome/126.0.0.0 Safari/537.36"
        ),
        "Referer": "https://finance.sina.com.cn/",
    }
    for start in range(0, len(codes), chunk_size):
        chunk = codes[start : start + chunk_size]
        url = "https://hq.sinajs.cn/list=" + ",".join(_sina_prefix(code) for code in chunk)
        request = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(request, context=context, timeout=25) as response:
            raw = response.read().decode("gbk", "ignore")
        for line in raw.strip().splitlines():
            if '="' not in line:
                continue
            code = line.split("=")[0].split("_")[-1][2:]
            fields = line.split('="', 1)[1].rstrip('";').split(",")
            if len(fields) < 10:
                continue
            prev = _number(fields[2])
            last = _number(fields[3])
            amount = _number(fields[9], 0.0)
            if prev is None or last is None or prev <= 0 or last <= 0:
                continue
            result[code] = {
                "prev": prev,
                "last": last,
                "amount": amount,
                "change": (last / prev - 1.0) * 100.0,
            }
    return result


def market_snapshot() -> dict[str, dict]:
    """全市场个股快照 -> {code: {prev,last,amount,change}}。

    DataHub 优先；桥/云不可用时用新浪批量行情兜底。``change`` 为百分比。
    """
    primary_error = None
    try:
        items: list[dict] = []
        offset = 0
        page_size = 5000
        while offset <= 20000:
            query = urlencode({"limit": page_size, "offset": offset})
            payload = _datahub_get(
                f"/api/a-share/prices/snapshot?{query}",
                timeout=300,
            )
            batch = _items(payload)
            items.extend(batch)
            total = _integer(payload.get("total"))
            if not batch or len(batch) < page_size or (total and len(items) >= total):
                break
            offset += len(batch)
        snapshot = {}
        for row in items:
            code = str(row.get("ticker") or "").strip()
            last = _number(row.get("last_price"))
            prev = _number(row.get("prev_price"))
            if not code or last is None or last <= 0:
                continue
            change = _number(row.get("price_change_ratio_pct"))
            if change is None and prev is not None and prev > 0:
                change = (last / prev - 1.0) * 100.0
            snapshot[code] = {
                "prev": prev if prev is not None else last,
                "last": last,
                "amount": _number(row.get("turnover"), 0.0),
                "change": change if change is not None else 0.0,
            }
        if not snapshot:
            raise HithinkError("DataHub 全市场快照为空")
        _set_source("同花顺 DataHub（market-query）")
        return snapshot
    except Exception as exc:
        primary_error = f"{type(exc).__name__}: {exc}"

    try:
        snapshot = _sina_snapshot(_load_local_codes())
        if not snapshot:
            raise HithinkError("新浪全市场快照为空")
        _set_source("新浪批量行情（公开行情兜底）")
        return snapshot
    except Exception as exc:
        raise HithinkError(
            f"全市场快照获取失败；market-query: {primary_error}；"
            f"新浪: {type(exc).__name__}: {exc}"
        ) from exc


def market_breadth() -> dict | None:
    """全市场涨跌家数 -> {tradable, advance, decline, flat}。"""
    snapshot = market_snapshot()
    advance = sum(1 for row in snapshot.values() if row["last"] > row["prev"])
    decline = sum(1 for row in snapshot.values() if row["last"] < row["prev"])
    return {
        "tradable": len(snapshot),
        "advance": advance,
        "decline": decline,
        "flat": len(snapshot) - advance - decline,
    }


def _akshare_index_symbol(thscode: str) -> str:
    ticker = str(thscode).split(".")[0]
    return ("sh" if str(thscode).upper().endswith(".SH") else "sz") + ticker


def index_history(
    thscode: str,
    start_date: str | None = None,
    end_date: str | None = None,
) -> list[dict]:
    """指数日线，DataHub 优先，AkShare/东方财富公开行情兜底。"""
    end_value = end_date or today()
    try:
        end_dt = datetime.strptime(end_value, "%Y-%m-%d")
    except ValueError as exc:
        raise HithinkError(f"指数结束日期格式无效：{end_value}") from exc
    start_value = start_date or (end_dt - timedelta(days=540)).strftime("%Y-%m-%d")
    try:
        start_dt = datetime.strptime(start_value, "%Y-%m-%d")
    except ValueError as exc:
        raise HithinkError(f"指数开始日期格式无效：{start_value}") from exc
    if start_dt > end_dt:
        raise HithinkError("指数开始日期不能晚于结束日期")

    primary_error = None
    try:
        query = urlencode(
            {
                "thscode": thscode,
                "interval": "1d",
                "start": date_ms(start_value),
                "end": end_of_day_ms(end_value),
            }
        )
        payload = _datahub_get(
            f"/api/a-share-index/prices/historical?{query}",
            timeout=90,
        )
        rows = []
        for row in _items(payload):
            day = _date_from_ms(row.get("date_ms"))
            if not day or not (start_value <= day <= end_value):
                continue
            close = _number(row.get("close_price"))
            if close is None or close <= 0:
                continue
            rows.append(
                {
                    "date": day,
                    "open": _number(row.get("open_price")),
                    "high": _number(row.get("high_price")),
                    "low": _number(row.get("low_price")),
                    "close": close,
                    "volume": _number(row.get("volume")),
                    "turnover": _number(row.get("turnover")),
                }
            )
        if not rows:
            raise HithinkError("DataHub 返回空指数日线")
        _set_source("同花顺 DataHub（market-query）")
        return sorted(rows, key=lambda row: row["date"])
    except Exception as exc:
        primary_error = f"{type(exc).__name__}: {exc}"

    failures = []
    try:
        ak = _load_akshare()
        symbol = _akshare_index_symbol(thscode)
        for source in ("stock_zh_index_daily_em", "stock_zh_index_daily"):
            try:
                fetcher = getattr(ak, source)
                frame = fetcher(symbol=symbol)
                rows = []
                for row in _records(frame):
                    day = _normalize_date(row.get("date") or row.get("日期"))
                    if not day or not (start_value <= day <= end_value):
                        continue
                    close = _number(row.get("close") or row.get("收盘"))
                    if close is None or close <= 0:
                        continue
                    rows.append(
                        {
                            "date": day,
                            "open": _number(row.get("open") or row.get("开盘")),
                            "high": _number(row.get("high") or row.get("最高")),
                            "low": _number(row.get("low") or row.get("最低")),
                            "close": close,
                            "volume": _number(row.get("volume") or row.get("成交量")),
                            "turnover": _number(
                                row.get("amount") or row.get("成交额")
                            ),
                        }
                    )
                if not rows:
                    raise HithinkError("返回区间内无有效日线")
                _set_source("AkShare/东方财富（公开行情兜底）")
                return sorted(rows, key=lambda row: row["date"])
            except Exception as exc:
                failures.append(f"{source}: {type(exc).__name__}: {exc}")
    except Exception as exc:
        failures.append(f"AkShare: {type(exc).__name__}: {exc}")

    raise HithinkError(
        f"{thscode} {start_value}..{end_value} 指数日线获取失败；"
        f"market-query: {primary_error}；公开行情: {' / '.join(failures)}"
    )


def index_turnover(thscode: str, date_str: str) -> float | None:
    """指数单日成交额，与指数历史共用同一套行情源。"""
    rows = index_history(thscode, date_str, date_str)
    value = _number(rows[-1].get("turnover"))
    if value is None:
        raise HithinkError(f"{thscode} {date_str} 指数日线没有成交额字段")
    return value


def _normalize_name(value: str) -> str:
    return re.sub(r"\s+", "", str(value or "")).replace("Ａ", "A").replace("ａ", "a")


def resolve_security(name: str) -> dict:
    """名称/代码 -> 标准证券信息；DataHub 优先，本地代码表兜底。"""
    keyword = str(name or "").strip()
    if not keyword:
        raise HithinkError("证券名称不能为空")
    primary_error = None
    try:
        query = urlencode({"q": keyword, "limit": 5})
        payload = _datahub_get(f"/api/meta/tickers/search?{query}", timeout=60)
        candidates = _items(payload)
        normalized = _normalize_name(keyword)
        picked = next(
            (
                row
                for row in candidates
                if str(row.get("asset_type") or "") == "a-share"
                and _normalize_name(str(row.get("name") or "")) == normalized
            ),
            None,
        )
        if picked is None:
            picked = next(
                (
                    row
                    for row in candidates
                    if str(row.get("asset_type") or "") == "a-share"
                ),
                None,
            )
        if picked is None:
            raise HithinkError(f"DataHub 未匹配到 A 股：{keyword}")
        ticker = str(picked.get("ticker") or "").strip()
        thscode = str(picked.get("thscode") or _ths_code(ticker))
        _set_source("同花顺 DataHub（market-query）")
        return {
            "name": str(picked.get("name") or ""),
            "ticker": ticker,
            "code": ticker,
            "thscode": thscode,
            "asset_type": "a-share",
            "exchange": str(picked.get("exchange") or thscode.split(".")[-1]),
        }
    except Exception as exc:
        primary_error = f"{type(exc).__name__}: {exc}"

    normalized = _normalize_name(keyword)
    try:
        if not STOCK_NAMES_PATH.is_file():
            raise HithinkError("本地股票代码表缺失")
        with STOCK_NAMES_PATH.open(encoding="utf-8") as handle:
            for row in csv.DictReader(handle):
                if _normalize_name(row.get("name")) != normalized:
                    continue
                code = str(row.get("code") or "").strip()
                _set_source("本地 A 股代码表（公开行情兜底）")
                return {
                    "name": keyword,
                    "ticker": code,
                    "code": code,
                    "thscode": _ths_code(code),
                    "asset_type": "a-share",
                    "exchange": _ths_code(code).split(".")[-1],
                }
        raise HithinkError(f"本地代码表未匹配到：{keyword}")
    except Exception as exc:
        raise HithinkError(
            f"证券解析失败：{keyword}；market-query: {primary_error}；"
            f"本地表: {type(exc).__name__}: {exc}"
        ) from exc


def dragon_tiger(board_type: str, date_str: str) -> dict:
    """龙虎榜榜单；board_type 为 all/org/hot_money。"""
    if board_type not in {"all", "org", "hot_money"}:
        raise HithinkError(f"不支持的龙虎榜类型：{board_type}")
    query = urlencode({"date": date_str, "board_type": board_type})
    payload = _datahub_get(
        f"/api/a-share/special-data/dragon-tiger-list?{query}",
        timeout=90,
    )
    _set_source("同花顺 DataHub（market-query）")
    return payload


def call(*args: str, timeout: int = 120) -> dict:
    """兼容旧命令字面量的薄转换层，不再调用外部旧 CLI。"""
    arguments = list(args)
    if arguments[:2] == ["market", "calendar"]:
        return {
            "item": [
                {"date": day.replace("-", "")}
                for day in trade_dates()
            ]
        }
    if arguments[:2] == ["special", "dragon-tiger"]:
        board_type = "all"
        date_str = today()
        if "--board-type" in arguments:
            position = arguments.index("--board-type")
            if position + 1 < len(arguments):
                board_type = arguments[position + 1]
        if "--date" in arguments:
            position = arguments.index("--date")
            if position + 1 < len(arguments):
                date_str = arguments[position + 1]
        return dragon_tiger(board_type, date_str)
    if arguments[:2] == ["index", "history"]:
        thscode = ""
        date_str = today()
        for flag, target in (("--thscode", "thscode"), ("--date", "date")):
            if flag in arguments:
                position = arguments.index(flag)
                if position + 1 < len(arguments):
                    if target == "thscode":
                        thscode = arguments[position + 1]
                    else:
                        date_str = arguments[position + 1]
        if not thscode:
            raise HithinkError("index history 缺少 --thscode")
        value = index_turnover(thscode, date_str)
        return {"item": [{"turnover": value}] if value is not None else []}
    if arguments[:1] == ["symbol"] and "search" in arguments:
        keyword = ""
        if "--q" in arguments:
            position = arguments.index("--q")
            if position + 1 < len(arguments):
                keyword = arguments[position + 1]
        return {"item": [resolve_security(keyword)]}
    raise HithinkError(f"不支持的兼容命令：{' '.join(arguments[:3])}")


def format_turnover_yi(total: float | None) -> str:
    """成交额格式化成「X.XX万亿」/「XXXX亿」。"""
    if not total:
        return ""
    if total >= 1e12:
        return f"{total / 1e12:.2f}万亿"
    return f"{total / 1e8:.0f}亿"
