import subprocess,re,json,sys
from pathlib import Path
rows=subprocess.check_output(['ps','-axo','pid,ppid,comm'],text=True).splitlines()
main=[]
for row in rows:
 if '/outputs/听流-整理版.app/Contents/MacOS/ListenFlow' in row: main.append(int(row.split()[0]))
assert len(main)==1,main
ids=set(main)
for row in rows:
 parts=row.split(None,2)
 if len(parts)>2 and parts[1].isdigit() and int(parts[1]) in main: ids.add(int(parts[0]))
cmd=['top','-l','7','-s','5','-stats','pid,command,cpu,mem,threads,state,time']
for pid in sorted(ids):cmd+=['-pid',str(pid)]
print('Sampling active app and ASR:',sorted(ids),flush=True)
result=subprocess.run(cmd,capture_output=True,text=True,check=True)
output=Path(sys.argv[1])
output.write_text(result.stdout)
records={pid:[] for pid in ids}
for line in result.stdout.splitlines():
 match=re.match(r'^\s*(\d+)\s+(\S+)\s+([\d.]+)\s+(\d+)([MGK])[-+]?\s+',line)
 if match and int(match[1]) in records:
  records[int(match[1])].append({'cpu':float(match[3]),'memory_mib':float(match[4])*{'M':1,'G':1024,'K':1/1024}[match[5]]})
report={}
for pid,samples in records.items():
 samples=samples[1:]
 label='ListenFlow' if pid in main else 'ASR'
 report[label]={'pid':pid,'samples':len(samples),'cpu_mean':sum(s['cpu'] for s in samples)/len(samples),
  'cpu_min':min(s['cpu'] for s in samples),'cpu_max':max(s['cpu'] for s in samples),
  'memory_min_mib':min(s['memory_mib'] for s in samples),'memory_max_mib':max(s['memory_mib'] for s in samples)}
output.with_suffix('.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))
