import json
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


SNAPSHOT = {
    "600519.SH": {
        "thscode": "600519.SH",
        "ticker": "600519",
        "name": "贵州茅台",
        "volume": 3098875,
        "turnover": 3937375200,
        "last_price": 1277.8,
        "price_change": 21.8,
        "price_change_ratio_pct": 1.735669,
        "open_price": 1252.08,
        "high_price": 1282,
        "low_price": 1250.21,
        "prev_price": 1256,
    },
    "000001.SZ": {
        "thscode": "000001.SZ",
        "ticker": "000001",
        "name": "平安银行",
        "volume": 1000000,
        "turnover": 12000000,
        "last_price": 12.0,
        "price_change": 0.1,
        "price_change_ratio_pct": 0.84,
        "open_price": 11.9,
        "high_price": 12.1,
        "low_price": 11.8,
        "prev_price": 11.9,
    },
}


def envelope(data, code=0, message="success"):
    return {
        "code": code,
        "message": message,
        "request_id": "mock-request",
        "data": data,
    }


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.headers.get("X-api-key") != "mock-secret-key":
            self.send_json(envelope(None, 2003, "Invalid or revoked API key"))
            return

        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)

        if parsed.path == "/api/meta/tickers/search":
            keyword = query.get("q", [""])[0]
            asset_type = query.get("asset_type", [""])[0]
            if asset_type == "a-share-index":
                item = {
                    "thscode": "886042.TI",
                    "ticker": "886042",
                    "name": "光伏设备",
                    "exchange": "TI",
                    "asset_type": "a-share-index",
                    "currency": "CNY",
                    "list_date": None,
                    "end_date": None,
                    "last_trade_date": None,
                    "last_delivery_date": None,
                }
            else:
                thscode = "000001.SZ" if keyword.startswith("000001") else "600519.SH"
                item = {
                    "thscode": thscode,
                    "ticker": thscode.split(".")[0],
                    "name": "平安银行" if thscode.startswith("000001") else "贵州茅台",
                    "exchange": thscode.split(".")[1],
                    "asset_type": "a-share",
                    "currency": "CNY",
                    "list_date": "1991-04-03",
                    "end_date": None,
                    "last_trade_date": None,
                    "last_delivery_date": None,
                }
            self.send_json(
                envelope(
                    {
                        "timestamp": int(datetime.now(timezone.utc).timestamp() * 1000),
                        "item": [item],
                    }
                )
            )
            return

        if parsed.path == "/api/a-share/prices/snapshot":
            codes = [
                item
                for item in query.get("thscodes", ["600519.SH"])[0].split(",")
                if item in SNAPSHOT
            ]
            items = []
            for code in codes:
                item = dict(SNAPSHOT[code])
                item.pop("name", None)
                items.append(item)
            self.send_json(
                envelope(
                    {
                        "timestamp": int(datetime.now(timezone.utc).timestamp() * 1000),
                        "total": len(SNAPSHOT),
                        "item": items,
                    }
                )
            )
            return

        if parsed.path == "/api/a-share/prices/historical":
            self.send_json(
                envelope(
                    {
                        "timestamp": 1762358400000,
                        "item": [
                            {
                                "date_ms": 1762272000000,
                                "open_price": 1200.0,
                                "high_price": 1260.0,
                                "low_price": 1190.0,
                                "close_price": 1250.0,
                                "volume": 100000,
                                "turnover": 125000000,
                            },
                            {
                                "date_ms": 1762358400000,
                                "open_price": 1250.0,
                                "high_price": 1282.0,
                                "low_price": 1240.0,
                                "close_price": 1277.8,
                                "volume": 120000,
                                "turnover": 153336000,
                            },
                        ],
                    }
                )
            )
            return

        if parsed.path == "/api/a-share-index/constituents/ths-stock-list":
            self.send_json(
                envelope(
                    {
                        "timestamp": 1762358400000,
                        "item": [
                            {"thscode": "600519.SH", "ticker": "600519", "name": "贵州茅台"},
                            {"thscode": "000001.SZ", "ticker": "000001", "name": "平安银行"},
                        ],
                    }
                )
            )
            return

        self.send_json(
            envelope(
                {
                    "timestamp": 1762358400000,
                    "path": parsed.path,
                    "query": {key: values for key, values in query.items()},
                    "item": [],
                }
            )
        )

    def send_json(self, payload, status=200):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        return


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 64015), Handler).serve_forever()
