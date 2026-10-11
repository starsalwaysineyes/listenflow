from http.server import HTTPServer,BaseHTTPRequestHandler
import json
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def do_POST(self):
  body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
  assert self.path=='/v1/chat/completions'
  assert body['stream'] is True
  assert any('Friday release' in x['content'] for x in body['messages'])
  self.send_response(200);self.send_header('Content-Type','text/event-stream');self.end_headers()
  for text in ['周五','发布。','[00:03]']:
   msg={'choices':[{'delta':{'content':text},'finish_reason':None}]}
   self.wfile.write(('data: '+json.dumps(msg,ensure_ascii=False)+'\n\n').encode());self.wfile.flush()
  self.wfile.write(b'data: [DONE]\n\n')
HTTPServer(('127.0.0.1',18763),Handler).handle_request()
