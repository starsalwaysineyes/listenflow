from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
from pathlib import Path
import json,time
mode=Path('work/organization-mock-mode.txt')
mode.write_text('ok')
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def do_POST(self):
  body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
  assert body['stream'] and len(body['messages'])==2
  assert '小林' in body['messages'][1]['content']
  current=mode.read_text().strip()
  if current=='fail':
   self.send_response(503);self.end_headers();return
  self.send_response(200);self.send_header('Content-Type','text/event-stream');self.end_headers()
  result=Path('work/organization-result.txt').read_text()
  if current=='slow': result='未完成的测试预览。'+result*10
  try:
   for i in range(0,len(result),10):
    data={'choices':[{'delta':{'content':result[i:i+10]},'finish_reason':None}]}
    self.wfile.write(('data: '+json.dumps(data,ensure_ascii=False)+'\n\n').encode());self.wfile.flush()
    time.sleep(0.2 if current=='slow' else 0.01)
   self.wfile.write(b'data: [DONE]\n\n');self.wfile.flush()
  except (BrokenPipeError,ConnectionResetError): pass
ThreadingHTTPServer(('127.0.0.1',18764),Handler).serve_forever()
