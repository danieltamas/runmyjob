#!/usr/bin/env python3
"""A tiny local log ingestor for scripts/sinks-check.sh: speaks Loki's push and Elasticsearch's _bulk, and writes
every received line as one JSON object per line to the file it was started with.

  sinks-receiver.py loki|elasticsearch <port> <out-file>
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

kind, port, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        rows = loki(body) if kind == "loki" and self.path == "/loki/api/v1/push" else bulk(body) if kind == "elasticsearch" and self.path == "/_bulk" else None
        if rows is None:
            self.send_response(404)
            self.end_headers()
            return
        with open(out, "a") as sink:
            for row in rows:
                sink.write(json.dumps(row) + "\n")
        self.send_response(204 if kind == "loki" else 200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        if kind == "elasticsearch":
            self.wfile.write(b'{"errors":false,"items":[]}')

    def log_message(self, *_):
        pass


def loki(body):
    rows = []
    for stream in json.loads(body)["streams"]:
        for _, line in stream["values"]:
            rows.append({**json.loads(line), "labels": stream["stream"]})
    return rows


def bulk(body):
    lines = body.decode().splitlines()
    return [{"id": json.loads(a)["create"]["_id"], **json.loads(d)} for a, d in zip(lines[0::2], lines[1::2])]


HTTPServer(("127.0.0.1", port), Handler).serve_forever()
