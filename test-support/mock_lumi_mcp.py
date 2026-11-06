import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def tool_payload(name, args):
    if name == "search_securities":
        keyword = args.get("keyword", "600519")
        market = "USHA" if str(keyword).startswith("6") else "USZA"
        code = "600519" if market == "USHA" else "000001"
        display = "贵州茅台" if code == "600519" else "平安银行"
        return {
            "results": [
                {
                    "keyword": keyword,
                    "hits": [
                        {
                            "security": f"{market}{code}",
                            "name": display,
                            "code": code,
                            "market": market,
                        }
                    ],
                }
            ]
        }
    if name == "search_blocks":
        return {"data": [{"id": 14, "idHex": "e", "name": "沪深A股"}], "total": 1}
    if name == "realtime_query":
        return {
            "USHA600519": {
                "5": "USHA600519",
                "55": "贵州茅台",
                "10": 1449.98,
                "199112": 0.24,
            }
        }
    if name == "candle_query":
        return {
            "USHA600519": [
                {"time": 1762358400, "7": 1400.0, "8": 1460.0, "9": 1390.0, "11": 1449.98, "13": 100, "19": 144998},
                {"time": 1762444800, "7": 1450.0, "8": 1470.0, "9": 1430.0, "11": 1458.0, "13": 120, "19": 174960},
            ]
        }
    if name == "trend_query":
        return {"USHA600519": [{"time": 1762396200, "10": 1449.98, "13": 10, "19": 14499.8}]}
    if name == "tick_query":
        return {"USHA600519": [{"time": 1762396200, "10": 1449.98, "12": 5, "18": 1, "49": 100}]}
    if name == "sort_query":
        return {"total": 1, "items": [{"security": "USHA600519"}]}
    if name == "data_subscribe":
        return {"first_frame": {"USHA600519": {"10": 1449.98}}}
    if name == "manageSector":
        if args.get("sectorId") == "-1":
            return {
                "sectorId": "-1",
                "sectorName": "自选股",
                "stockCount": 2,
                "stocks": [
                    {"market": "USHA", "code": "600519", "name": "贵州茅台"},
                    {"market": "USZA", "code": "000001", "name": "平安银行"},
                ],
            }
        if args.get("sectorId") or args.get("sectorName"):
            return {
                "sectorId": str(args.get("sectorId", "234")),
                "sectorName": str(args.get("sectorName", "医药")),
                "stockCount": 1,
                "stocks": [{"market": "USHA", "code": "600519", "name": "贵州茅台"}],
            }
        return [
            {"sectorId": "-1", "sectorName": "自选股", "stockCount": 2},
            {"sectorId": "234", "sectorName": "医药", "stockCount": 1},
        ]
    if name == "http_get":
        if "failover" in str(args.get("url", "")):
            return {
                "code": 2003,
                "message": "Local permission denied",
                "data": None,
            }
        return {"code": 0, "message": "success", "data": {"item": [{"thscode": "600519.SH"}]}}
    if name == "wencai_query":
        return {"row_count": 1, "datas": [{"code": "600519"}]}
    if name == "indicator_query":
        return {"USHA600519": {"MA20": 1400.0}}
    if name == "read_doc":
        return {"ok": True}
    if name == "search_fields":
        return [{"id": "10", "label": "最新价", "data_type": "realtime"}]
    return {"mock_tool": name, "args": args}


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        request = json.loads(self.rfile.read(length) or b"{}")
        method = request.get("method")

        if method == "initialize":
            self.send_rpc(
                request,
                {
                    "protocolVersion": "2025-03-26",
                    "capabilities": {},
                    "serverInfo": {"name": "mock-lumi", "version": "1.0"},
                },
            )
            return
        if method == "notifications/initialized":
            self.send_response(202)
            self.send_header("mcp-session-id", "mock-session")
            self.end_headers()
            return
        if method == "tools/list":
            self.send_rpc(
                request,
                {
                    "tools": [
                        {"name": "tool_execute", "description": "Mock tool execute"},
                        {"name": "tool_search", "description": "Mock tool search"},
                        {"name": "read_doc", "description": "Mock document reader"},
                    ]
                },
            )
            return
        if method == "tools/call":
            params = request.get("params", {})
            if params.get("name") != "tool_execute":
                self.send_rpc(request, {"content": [], "isError": True})
                return
            arguments = params.get("arguments", {})
            name = arguments.get("name", "")
            args = arguments.get("args", {})
            text = json.dumps({"success": True, "data": tool_payload(name, args)}, ensure_ascii=False)
            self.send_rpc(
                request,
                {"content": [{"type": "text", "text": text}], "isError": False},
            )
            return
        self.send_rpc(request, {})

    def send_rpc(self, request, result):
        payload = {
            "jsonrpc": "2.0",
            "id": request.get("id"),
            "result": result,
        }
        body = (
            "event: message\n"
            f"data: {json.dumps(payload, ensure_ascii=False, separators=(',', ':'))}\n\n"
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("mcp-session-id", "mock-session")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        return


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 64014), Handler).serve_forever()
