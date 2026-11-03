"""A registry that answers badly, for guard_test.sh's "the existence check errors" cases.

Run: python3 -I registry_stub.py <port-file>. It binds a free port on 127.0.0.1, writes the port
to <port-file>, and serves until killed. The first path segment after /v2/ picks the failure:

  /v2/e500/...      HTTP 500 on every request (curl retries it, then gives up)
  /v2/html404/...   HTTP 404 with an HTML page: not a registry's "unknown manifest" answer
  /v2/denied/...    HTTP 401 with a Bearer challenge whose token endpoint answers 403
  /v2/notchart/...  HTTP 200 with a manifest that has no Helm chart layer (a container image)
"""
import http.server
import json
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, body, ctype="application/json", headers=()):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        port = self.server.server_address[1]
        if self.path.startswith("/token"):
            return self.reply(403, json.dumps({"errors": [{"code": "DENIED", "message": "denied"}]}))
        parts = self.path.split("/")
        mode = parts[2] if len(parts) > 2 else ""
        if mode == "e500":
            return self.reply(500, "internal error", "text/plain")
        if mode == "html404":
            return self.reply(404, "<html><body>Not Found</body></html>", "text/html")
        if mode == "denied":
            challenge = f'Bearer realm="http://127.0.0.1:{port}/token",service="stub",scope="repository:denied:pull"'
            return self.reply(401, json.dumps({"errors": [{"code": "UNAUTHORIZED"}]}),
                              headers=[("WWW-Authenticate", challenge)])
        if mode == "notchart":
            manifest = {
                "schemaVersion": 2,
                "mediaType": "application/vnd.oci.image.manifest.v1+json",
                "config": {"mediaType": "application/vnd.oci.image.config.v1+json",
                           "digest": "sha256:" + "0" * 64, "size": 2},
                "layers": [{"mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
                            "digest": "sha256:" + "1" * 64, "size": 2}],
            }
            return self.reply(200, json.dumps(manifest), "application/vnd.oci.image.manifest.v1+json")
        return self.reply(404, json.dumps({"errors": [{"code": "NAME_UNKNOWN"}]}))


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
