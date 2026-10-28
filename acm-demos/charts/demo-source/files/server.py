import os, subprocess
from http.server import BaseHTTPRequestHandler, SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory='/tmp/content', **kwargs)
    def git(self):
        u = urlsplit(self.path)
        env = os.environ.copy()
        env.update(GIT_PROJECT_ROOT='/tmp/content', GIT_HTTP_EXPORT_ALL='1', PATH_INFO=u.path,
                   QUERY_STRING=u.query, REQUEST_METHOD=self.command,
                   CONTENT_TYPE=self.headers.get('Content-Type', ''),
                   CONTENT_LENGTH=self.headers.get('Content-Length', '0'),
                   REMOTE_USER='demo')
        body = self.rfile.read(int(env['CONTENT_LENGTH']))
        out = subprocess.run(['/usr/libexec/git-core/git-http-backend'], input=body,
                             env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False).stdout
        headers, sep, payload = out.partition(b'\r\n\r\n')
        if not sep:
            self.send_error(502); return
        lines = headers.decode('latin-1').split('\r\n')
        status = next((int(x.split(':', 1)[1].strip().split()[0]) for x in lines if x.lower().startswith('status:')), 200)
        self.send_response(status)
        for line in lines:
            if ':' in line:
                k, v = line.split(':', 1)
                if k.lower() not in ('status', 'transfer-encoding', 'connection', 'content-length'):
                    self.send_header(k, v.strip())
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
    def do_GET(self):
        if urlsplit(self.path).path.startswith('/git/'):
            self.git()
        else:
            super().do_GET()
    def do_POST(self):
        if urlsplit(self.path).path.startswith('/git/'):
            self.git()
        else:
            self.send_error(404)
ThreadingHTTPServer(('', 8080), Handler).serve_forever()
