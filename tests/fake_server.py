#!/usr/bin/env python3
"""A stand-in for the SonarQube Web API and the GitHub REST API, for
tests/commands_test.sh.

    python3 tests/fake_server.py ROUTES LOG PORT_FILE

Listens on 127.0.0.1, on a free port it writes to PORT_FILE, and answers
each request from ROUTES, a JSON list read again for every request:

    [{"method": "GET", "path": "/api/ce/task", "query": {"id": "T1"},
      "responses": [{"status": 200, "json": {...}}, ...]}]

The first route whose method, path and query (every name it lists, with
that value) match answers. A route gives its responses in turn, and keeps
giving the last one. Every request is appended to LOG as one JSON line:
method, path, query, the Authorization header and the body. GET /__reset
starts the turns over and empties LOG.
"""

import http.server
import json
import os
import sys
import urllib.parse

ROUTES, LOG, PORT_FILE = sys.argv[1:4]
TURNS = {}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def answer(self, status, payload):
        data = payload.encode() if isinstance(payload, str) else json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def handle_request(self, method):
        url = urllib.parse.urlsplit(self.path)
        query = {k: v[-1] for k, v in urllib.parse.parse_qs(url.query, keep_blank_values=True).items()}
        if url.path == "/__reset":
            TURNS.clear()
            open(LOG, "w").close()
            self.answer(200, {})
            return
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode("utf-8", "replace") if length else ""
        with open(LOG, "a") as log:
            log.write(json.dumps({
                "method": method, "path": url.path, "query": query,
                "authorization": self.headers.get("Authorization"),
                "accept": self.headers.get("Accept"), "body": body,
            }) + "\n")
        with open(ROUTES) as f:
            routes = json.load(f)
        for index, route in enumerate(routes):
            if route.get("method", "GET") != method or route["path"] != url.path:
                continue
            if any(query.get(k) != v for k, v in route.get("query", {}).items()):
                continue
            turn = TURNS.get(index, 0)
            TURNS[index] = turn + 1
            response = route["responses"][min(turn, len(route["responses"]) - 1)]
            self.answer(response.get("status", 200), response.get("json", response.get("text", "")))
            return
        self.answer(404, {"errors": [{"msg": "no route for %s %s" % (method, url.path)}]})

    def do_GET(self):
        self.handle_request("GET")

    def do_POST(self):
        self.handle_request("POST")


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE + ".tmp", "w") as f:
    f.write(str(server.server_address[1]))
os.replace(PORT_FILE + ".tmp", PORT_FILE)
server.serve_forever()
