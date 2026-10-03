#!/usr/bin/env python3
"""ADR-027-style P5 measurement on APFS clones of SYNTHETIC stores only.

Creates 1,355 Claude logs, 2,761 Codex logs and 337 member rows (164 logs
present, 173 missing) under /private/tmp. Never reads personal stores or runs
Temple. Each run gets APFS clonefiles of this seed, one member append at 4/s,
and one non-member Codex append at 2/s. Logs/counters remain for inspection.
Usage: Scripts/bench-member-engine.py [--seconds 60] [--runs 2]
"""
import argparse
import ctypes
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import threading
import time
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--seconds', type=float, default=60)
parser.add_argument('--runs', type=int, default=2)
parser.add_argument('--cli', type=Path, default=Path('.build/debug/templectl'))
args = parser.parse_args()
cli = args.cli.resolve()
base = Path(tempfile.mkdtemp(prefix='temple-p5-bench-', dir='/private/tmp'))
mountpoint = subprocess.check_output(['df', '-P', str(base)], text=True).splitlines()[-1].split()[-1]
mounts = subprocess.check_output(['mount'], text=True).splitlines()
assert any(f' on {mountpoint} (apfs,' in line for line in mounts), 'APFS required'
libc = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
libc.clonefile.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]
libc.clonefile.restype = ctypes.c_int

def clone(source, destination):
    if libc.clonefile(os.fsencode(source), os.fsencode(destination), 0):
        raise OSError(ctypes.get_errno(), 'clonefile failed', str(source))
    return destination

def environment(directory):
    env = os.environ.copy()
    env.update(TEMPLE_CLAUDE_ROOT=str(directory/'claude'), TEMPLE_CODEX_ROOT=str(directory/'codex'),
               TEMPLE_STATE_DIR=str(directory/'state'))
    return env

seed = base/'seed'
for name in ['claude', 'codex/sessions', 'state']:
    (seed/name).mkdir(parents=True, exist_ok=True)
# Open only the redirected, initially empty database to install the schema.
subprocess.run([str(cli)], env=environment(seed), stdout=subprocess.DEVNULL, check=True)
files = {}
for agent, count in [('claude', 1355), ('codex', 2761)]:
    for index in range(count):
        number = index+1+(10000 if agent == 'codex' else 0)
        sid = str(uuid.UUID(int=number))
        cwd = str(base/'projects'/str(index % 20))
        if agent == 'claude':
            path = seed/'claude'/f'project-{index % 20}'/f'{sid}.jsonl'
            lines = [{'type':'user', 'sessionId':sid, 'cwd':cwd, 'message':{'content':f'Synthetic prompt {index}'}}]
            padding = {'type':'assistant','sessionId':sid,'message':{'content':'x'*800}}
        else:
            path = seed/'codex/sessions/2026/10/03'/f'rollout-2026-10-03T00-00-00-{sid}.jsonl'
            lines = [{'type':'session_meta','payload':{'id':sid,'cwd':cwd,'timestamp':'2026-10-03T00:00:00Z'}},
                     {'type':'event_msg','payload':{'type':'user_message','message':f'Synthetic prompt {index}'}}]
            padding = {'type':'event_msg','payload':{'type':'agent_message','message':'x'*800}}
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('\n'.join(json.dumps(line) for line in lines+[padding]*20)+'\n')
        files[(agent,index)] = (sid,path,cwd)
(seed/'codex/history.jsonl').write_text('\n'.join(json.dumps({'session_id':files[('codex', i)][0], 'ts':i, 'text':f'Synthetic prompt {i}'}) for i in range(2761))+'\n')
(seed/'codex/session_index.jsonl').write_text('')
with sqlite3.connect(seed/'state/temple.sqlite') as db:
    for agent in ['claude','codex']:
        for index in range(82):
            sid,path,cwd=files[(agent,index)]
            db.execute('INSERT INTO session_state (id,agent,transcript_path,joined_at,joined_via) VALUES (?,?,?,?,?)',
                       (sid,agent,str(path),'2026-10-03 00:00:00.000','imported'))
    for index in range(173):
        db.execute('INSERT INTO session_state (id,joined_at,joined_via) VALUES (?,?,?)',
                   (str(uuid.UUID(int=20000+index)),'2026-10-03 00:00:00.000','imported'))

reports=[]
for run in range(args.runs):
    directory=base/f'clone-{run+1}'
    shutil.copytree(seed,directory,copy_function=clone)
    # Hints must name the clone, not its seed.
    with sqlite3.connect(directory/'state/temple.sqlite') as db:
        db.execute('UPDATE session_state SET transcript_path=replace(transcript_path,?,?)', (str(seed),str(directory)))
        if run:
            for agent in ['claude','codex']:
                for index in range(82):
                    sid,path,cwd=files[(agent,index)]
                    db.execute('UPDATE session_state SET directory=?,directory_source=?,title=?,last_active_at=? WHERE id=?',
                               (cwd,'transcript',f'Synthetic prompt {index}','2026-10-03 00:00:00.000',sid))
    log=base/f'run-{run+1}.log'
    first=threading.Event()
    samples=[]
    publication_time=[]
    rows_time=[]
    process=subprocess.Popen([str(cli),'--watch','--metrics'],env=environment(directory),stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT,text=True,bufsize=1)
    def monitor():
        with log.open('w') as output:
            for line in process.stdout:
                output.write(line); output.flush()
                if line.startswith('{'):
                    sample=json.loads(line)
                    if sample.get('event')=='metrics': samples.append(sample)
                if line.startswith('durable rows available:'): rows_time.append(float(line.split('elapsed_seconds=')[1]))
                if line.startswith('first engine publication:'):
                    publication_time.append(float(line.split('elapsed_seconds=')[1])); first.set()
    reader=threading.Thread(target=monitor,daemon=True); reader.start()
    if not first.wait(20):
        process.terminate(); process.wait(); raise RuntimeError(f'No first publication; see {log}')
    # Establish a post-startup metrics sample before starting either writer.
    time.sleep(1.2)
    start_sample=samples[-1]
    member=Path(str(files[('codex',0)][1]).replace(str(seed),str(directory)))
    outside=Path(str(files[('codex',100)][1]).replace(str(seed),str(directory)))
    writes=[0,0]
    start=time.monotonic()
    for tick in range(int(args.seconds*4)):
        deadline=start+tick/4
        time.sleep(max(0,deadline-time.monotonic()))
        with member.open('a') as output: output.write(json.dumps({'type':'event_msg','payload':{'type':'agent_message','message':f'member {tick}'}})+'\n')
        writes[0]+=1
        if tick % 2 == 0:
            with outside.open('a') as output: output.write(json.dumps({'type':'event_msg','payload':{'type':'agent_message','message':f'outside {tick}'}})+'\n')
            writes[1]+=1
    # Include delivery of the final write and a final metric interval.
    time.sleep(1.5)
    end_sample=samples[-1]
    process.terminate(); process.wait(timeout=10); reader.join(timeout=10)
    elapsed=end_sample['wall_seconds']-start_sample['wall_seconds']
    report={'run':run+1,'core_state':'upgrade (NULL fields)' if run==0 else 'filled',
            'duration_seconds':elapsed,'member_writes':writes[0],'nonmember_writes':writes[1],
            'startup_parses':start_sample['parses'],'startup_verifications':start_sample['verifications'],
            'startup_publications':start_sample['publications'],
            'steady_parses':end_sample['parses']-start_sample['parses'],
            'steady_verifications':end_sample['verifications']-start_sample['verifications'],
            'steady_publications':end_sample['publications']-start_sample['publications'],
            'steady_observations':end_sample['observations']-start_sample['observations'],
            'cpu_percent_one_core':100*(end_sample['cpu_seconds']-start_sample['cpu_seconds'])/elapsed,
            'open_fds_min':min(s['open_fds'] for s in samples[1:]),'open_fds_max':max(s['open_fds'] for s in samples[1:]),
            'durable_rows_seconds':rows_time[0], 'first_publication_seconds':publication_time[0], 'log':str(log)}
    reports.append(report)
    print(json.dumps(report,sort_keys=True),flush=True)
result={'method':'APFS clonefile, synthetic 1355 Claude + 2761 Codex logs, 337 members (164 present)',
        'base':str(base),'runs':reports}
(base/'results.json').write_text(json.dumps(result,indent=2)+'\n')
print(f'Results: {base}/results.json',flush=True)
