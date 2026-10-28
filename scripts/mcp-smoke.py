"""Feeds an MCP session to `rmj mcp` (argv[1]) and checks every reply: JSON-RPC only on stdout, the schemas
of docs/AGENT-API.md, a bad call is -32602, each answer within 500 ms of the request being sent. The session is read
from stdin, one request per line, and the replies are checked in order. Run by scripts/acceptance.sh."""
import json, subprocess, sys, time

requests = [json.loads(line) for line in sys.stdin.read().splitlines() if line.strip()]
proc = subprocess.Popen([sys.argv[1], "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
replies = {}
slowest = 0.0
for request in requests:
    start = time.monotonic()
    proc.stdin.write(json.dumps(request) + "\n")
    proc.stdin.flush()
    if "id" not in request:
        continue  # a notification gets no reply
    message = json.loads(proc.stdout.readline())  # a non-JSON line on stdout fails here
    slowest = max(slowest, time.monotonic() - start)
    assert message["jsonrpc"] == "2.0" and message["id"] == request["id"], message
    replies[request["id"]] = message
proc.stdin.close()
assert proc.wait(timeout=5) == 0

assert replies[1]["result"]["serverInfo"]["name"] == "rmj"
tools = replies[2]["result"]["tools"]
assert len(tools) == 8, [t["name"] for t in tools]
for tool in tools:
    # The server is read-only by construction: no tool is named for an action.
    assert tool["name"] not in ("run", "rerun", "cancel", "start", "kill", "delete", "write"), tool["name"]
for id in (3, 4, 5):
    result = replies[id]["result"]
    assert not result.get("isError", False), replies[id]
    assert json.loads(result["content"][0]["text"]) == result["structuredContent"], id
assert replies[6]["error"]["code"] == -32602
assert slowest < 0.5, "slowest answer took %.0f ms" % (slowest * 1000)
print("acceptance: mcp ok (%d tools, slowest %.0f ms)" % (len(tools), slowest * 1000))
