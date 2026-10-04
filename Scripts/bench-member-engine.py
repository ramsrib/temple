#!/usr/bin/env python3
"""ADR-027-style P5 measurement on APFS clones of SYNTHETIC stores only.

Creates 1,355 Claude logs, 2,761 Codex logs and 337 member rows (164 logs
present, 173 missing, 86 of those still hinting at a pruned path) under
/private/tmp. Never reads personal stores or runs
Temple. Each run gets APFS clonefiles of this seed, one member append at 4/s,
and one non-member Codex append at 2/s. Logs/counters remain for inspection.
Every invocation first rejects a disabled-watcher negative control; measured
runs require active monitoring and delivered member observations.
Usage: Scripts/bench-member-engine.py [--seconds 60] [--runs 2]
"""
import argparse
import ctypes
import json
import math
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
if args.seconds < 4 or args.runs < 1:
    parser.error('Use at least 4 seconds and one measured run')
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
        sid=str(uuid.UUID(int=20000+index))
        # Half the absent rows keep the hint to a transcript since pruned: the
        # shape that once forced a full enumeration on every resolve.
        if index % 2 == 0:
            agent='claude' if index % 4 == 0 else 'codex'
            pruned=(seed/'claude/project-0'/f'{sid}.jsonl' if agent=='claude'
                    else seed/'codex/sessions/2026/10/03'/f'rollout-2026-10-03T00-00-00-{sid}.jsonl')
            db.execute('INSERT INTO session_state (id,agent,transcript_path,joined_at,joined_via) VALUES (?,?,?,?,?)',
                       (sid,agent,str(pruned),'2026-10-03 00:00:00.000','imported'))
        else:
            db.execute('INSERT INTO session_state (id,joined_at,joined_via) VALUES (?,?,?)',
                       (sid,'2026-10-03 00:00:00.000','imported'))

def validate_window(samples, start_sample, end_sample, writes, seconds):
    """Zero work is meaningful only if live member events actually reached the engine."""
    problems = []
    window = [s for s in samples if s['wall_seconds'] >= start_sample['wall_seconds']]
    elapsed = end_sample['wall_seconds'] - start_sample['wall_seconds']
    observations = end_sample['observations'] - start_sample['observations']
    if not window or not all(s.get('monitoring') is True for s in window):
        problems.append('monitoring was not active throughout the measurement')
    # FSEvents/debounce coalesces 4 writes/s; require at least one delivered
    # observation per two seconds, allowing scheduler variance without accepting
    # an idle watcher. More than two observations/write suggests unrelated work.
    minimum = max(1, math.ceil(writes[0] / 8))
    maximum = writes[0] * 2
    if not minimum <= observations <= maximum:
        problems.append(f'member observations {observations} outside [{minimum}, {maximum}]')
    if elapsed < seconds - 1 or len(window) < max(2, int(seconds / 2)):
        problems.append('metrics did not cover the writer interval')
    if any(b['wall_seconds'] - a['wall_seconds'] > 3 for a, b in zip(window, window[1:])):
        problems.append('metrics stalled during the writer interval')
    if problems:
        raise RuntimeError('; '.join(problems))

reports=[]
negative_control=None
# The disabled watcher must fail the SAME acceptance check as a measured run.
for run in range(-1, args.runs):
    disabled = run == -1
    label = 'disabled-watcher' if disabled else f'run-{run+1}'
    seconds = 4 if disabled else args.seconds
    directory=base/f'clone-{label}'
    shutil.copytree(seed,directory,copy_function=clone)
    # Hints must name the clone, not its seed.
    with sqlite3.connect(directory/'state/temple.sqlite') as db:
        db.execute('UPDATE session_state SET transcript_path=replace(transcript_path,?,?)', (str(seed),str(directory)))
        if run != 0:
            for agent in ['claude','codex']:
                for index in range(82):
                    sid,path,cwd=files[(agent,index)]
                    db.execute('UPDATE session_state SET directory=?,directory_source=?,title=?,last_active_at=? WHERE id=?',
                               (cwd,'transcript',f'Synthetic prompt {index}','2026-10-03 00:00:00.000',sid))
    log=base/f'{label}.log'
    samples=[]
    publication_time=[]
    rows_time=[]
    condition=threading.Condition()
    reader_done=False
    reader_errors=[]
    command=[str(cli),'--watch','--metrics']
    if disabled: command.append('--benchmark-disable-watcher')
    process=subprocess.Popen(command,env=environment(directory),stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT,text=True,bufsize=1)
    def monitor():
        global reader_done
        try:
            with log.open('w') as output:
                for line in process.stdout:
                    output.write(line); output.flush()
                    with condition:
                        if line.startswith('{'):
                            sample=json.loads(line)
                            if sample.get('event')=='metrics': samples.append(sample)
                        if line.startswith('durable rows available:'):
                            rows_time.append(float(line.split('elapsed_seconds=')[1]))
                        if line.startswith('first engine publication:'):
                            publication_time.append(float(line.split('elapsed_seconds=')[1]))
                        condition.notify_all()
        except Exception as error:
            reader_errors.append(str(error))
        finally:
            with condition:
                reader_done=True
                condition.notify_all()
    reader=threading.Thread(target=monitor,daemon=True); reader.start()
    def require_running():
        if process.poll() is not None or reader_done or reader_errors:
            raise RuntimeError(f'Premature CLI/metrics exit ({process.poll()}): {reader_errors}; see {log}')
    def wait_for_sample(predicate, timeout=20):
        with condition:
            ready=condition.wait_for(lambda: reader_done or reader_errors or predicate(), timeout)
            require_running()
            if not ready:
                raise RuntimeError(f'Metrics deadline exceeded; see {log}')
            return samples[-1]
    try:
        # A publication plus a subsequent metrics sample proves startup finished.
        start_sample=wait_for_sample(lambda: publication_time and samples and
                                    samples[-1]['wall_seconds'] > publication_time[0])
        member=Path(str(files[('codex',0)][1]).replace(str(seed),str(directory)))
        outside=Path(str(files[('codex',100)][1]).replace(str(seed),str(directory)))
        writes=[0,0]
        start=time.monotonic()
        for tick in range(int(seconds*4)):
            deadline=start+tick/4
            time.sleep(max(0,deadline-time.monotonic()))
            require_running()
            with member.open('a') as output:
                output.write(json.dumps({'type':'event_msg','payload':{'type':'agent_message','message':f'member {tick}'}})+'\n')
            writes[0]+=1
            if tick % 2 == 0:
                with outside.open('a') as output:
                    output.write(json.dumps({'type':'event_msg','payload':{'type':'agent_message','message':f'outside {tick}'}})+'\n')
                writes[1]+=1
        # Allow final FSEvents delivery, then require a fresh metric sample.
        end_sample=wait_for_sample(lambda: samples[-1]['wall_seconds'] >=
                                  start_sample['wall_seconds'] + seconds + 1, timeout=5)
        require_running()
        if disabled:
            try:
                validate_window(samples, start_sample, end_sample, writes, seconds)
            except RuntimeError as error:
                negative_control={'accepted':False,'reason':str(error),'member_writes':writes[0],
                                  'nonmember_writes':writes[1],
                                  'steady_observations':end_sample['observations']-start_sample['observations'],
                                  'monitoring':end_sample['monitoring'],'log':str(log)}
                print(json.dumps({'negative_control':negative_control},sort_keys=True),flush=True)
                continue
            raise RuntimeError('Disabled-watcher negative control was incorrectly accepted')
        validate_window(samples, start_sample, end_sample, writes, seconds)
        elapsed=end_sample['wall_seconds']-start_sample['wall_seconds']
        window=[s for s in samples if s['wall_seconds'] >= start_sample['wall_seconds']]
        report={'run':run+1,'core_state':'upgrade (NULL fields)' if run==0 else 'filled',
                'duration_seconds':elapsed,'member_writes':writes[0],'nonmember_writes':writes[1],
                'monitoring':all(s['monitoring'] for s in window),
                'startup_parses':start_sample['parses'],'startup_verifications':start_sample['verifications'],
                'startup_publications':start_sample['publications'],
                'startup_enumerations':start_sample.get('enumerations'),
                'steady_enumerations':end_sample.get('enumerations',0)-start_sample.get('enumerations',0),
                'steady_parses':end_sample['parses']-start_sample['parses'],
                'steady_verifications':end_sample['verifications']-start_sample['verifications'],
                'steady_publications':end_sample['publications']-start_sample['publications'],
                'steady_observations':end_sample['observations']-start_sample['observations'],
                'cpu_percent_one_core':100*(end_sample['cpu_seconds']-start_sample['cpu_seconds'])/elapsed,
                'open_fds_min':min(s['open_fds'] for s in window),'open_fds_max':max(s['open_fds'] for s in window),
                'durable_rows_seconds':rows_time[0], 'first_publication_seconds':publication_time[0], 'log':str(log)}
        reports.append(report)
        print(json.dumps(report,sort_keys=True),flush=True)
    finally:
        if process.poll() is None: process.terminate()
        process.wait(timeout=10); reader.join(timeout=10)
result={'method':'APFS clonefile, synthetic 1355 Claude + 2761 Codex logs, 337 members (164 present, 86 absent but hinted)',
        'durable_rows_seconds_definition':'CLI SQLite open and sessionStates read; not sidebar paint',
        'base':str(base),'negative_control':negative_control,'runs':reports}
(base/'results.json').write_text(json.dumps(result,indent=2)+'\n')
print(f'Results: {base}/results.json',flush=True)
