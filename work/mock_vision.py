from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
from pathlib import Path
import json,time,base64
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def do_POST(self):
  message=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
  blocks=message['messages'][-1]['content']
  images=[x for x in blocks if x.get('type')=='image_url'] if isinstance(blocks,list) else []
  assert len(images)==1
  value=images[0]['image_url']['url']
  assert value.startswith('data:image/jpeg;base64,')
  assert base64.b64decode(value.split(',',1)[1])[:2]==b'\xff\xd8'
  mode='organized' if '语音转写编辑' in message['messages'][0]['content'] else 'answer'
  Path('work/vision-ui-requests.jsonl').open('a').write(json.dumps({'mode':mode,'images':len(images)})+'\n')
  output=json.loads(Path('work/vision-live-results.json').read_text())[mode]
  self.send_response(200);self.send_header('Content-Type','text/event-stream');self.end_headers()
  try:
   for i in range(0,len(output),8):
    self.wfile.write(('data: '+json.dumps({'choices':[{'delta':{'content':output[i:i+8]},'finish_reason':None}]},ensure_ascii=False)+'\n\n').encode());self.wfile.flush();time.sleep(.035)
   self.wfile.write(b'data: [DONE]\n\n');self.wfile.flush()
  except (BrokenPipeError,ConnectionResetError): pass
ThreadingHTTPServer(('127.0.0.1',18764),Handler).serve_forever()
