"""Full hook entry-point regression tests, using only temporary synthetic CLI processes."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
ID = '12345678-1234-1234-1234-123456789012'
LAUNCHER = r'''
import json, os, pathlib, runpy, subprocess, sys
expected=json.loads(os.environ['FIXTURE_EXPECTED']); index=0
case=pathlib.Path(os.environ['FIXTURE_ROOT'])
def audit(event,args):
    global index
    bad=False
    if event=='subprocess.Popen':
        exe,argv,cwd,env=args
        want=expected[index] if index<len(expected) else None
        bad=want is None or not (exe==want[0] or (os.name=='nt' and exe is None))
        if not bad:
            bad=not (list(argv)==want if isinstance(argv,(list,tuple)) else os.name=='nt' and argv==subprocess.list2cmdline(want))
        if not bad:index+=1
    elif event.startswith('socket.') or event in ('os.system','os.exec','os.posix_spawn'):bad=True
    if bad:
        (case/'denied').write_text(event,encoding='utf-8')
        raise SystemExit(91)
sys.addaudithook(audit)
sys.argv=[os.environ['FIXTURE_HOOK'],os.environ['FIXTURE_EVENT']]
runpy.run_path(sys.argv[0],run_name='__main__')
assert index==len(expected), (index,expected)
'''
SPY = r'''import json,os,sys
from pathlib import Path
root=Path(os.environ['FIXTURE_ROOT']);spec=json.loads((root/'response.json').read_text(encoding='utf-8'))
with (root/'calls').open('a',encoding='utf-8') as f:f.write(json.dumps(sys.argv[1:])+'\n')
sub=sys.argv[1]
if sub=='remember':
    (root/'written.json').write_text(json.dumps({'id':'12345678-1234-1234-1234-123456789012','title':sys.argv[4],'content':sys.argv[2]}),encoding='utf-8')
    doc=spec.get('remember',{'status':'ok','summary':{'id':'12345678-1234-1234-1234-123456789012'}})
elif sub=='show':
    entry=json.loads((root/'written.json').read_text(encoding='utf-8'));entry.update(spec.get('entry_patch',{}))
    for key in spec.get('entry_remove',[]):entry.pop(key,None)
    doc=spec.get('show',{'status':'ok','summary':{'id':'12345678-1234-1234-1234-123456789012'},'details':{'entry':entry}})
elif sub=='list':doc={'status':'ok','details':[]}
elif sub=='recall':doc={'status':'skip','details':[]}
else:raise SystemExit(5)
print(json.dumps(doc));sys.exit(2 if doc.get('status')=='warn' else 0)
'''

class ReceiptFlow(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='receipt-flow-');self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.spy=self.root/'spy.py';self.spy.write_text(SPY,encoding='utf-8')
        self.engine=self.root/('stub.cmd' if os.name=='nt' else 'stub')
        self.engine.write_text(f'@echo off\n"{sys.executable}" "{self.spy}" %*\n' if os.name=='nt' else f'#!{sys.executable}\n'+SPY,encoding='utf-8');self.engine.chmod(0o700)
        self.launcher=self.root/'launcher.py';self.launcher.write_text(LAUNCHER,encoding='utf-8')
        self.env={k:v for k,v in os.environ.items() if k.upper() in {'PATH','SYSTEMROOT','SYSTEMDRIVE','WINDIR','PATHEXT','TEMP','TMP','COMSPEC'}}
        self.env.update(HOME=str(self.root/'home'),USERPROFILE=str(self.root/'home'),XDG_CONFIG_HOME=str(self.root/'config'),XDG_DATA_HOME=str(self.root/'data'),RESPITE_CONFIG=str(self.root/'config.json'),RESPITE_LOG=str(self.root/'log'),RESPITE_TURN_STATE=str(self.root/'turns'),RESPITE_NUDGE_STATE=str(self.root/'counter'),RESPITE_PENDING_NUDGE=str(self.root/'pending'),FIXTURE_ROOT=str(self.root),FIXTURE_HOOK=str(ROOT/'hooks/respire.py'),PYTHONUTF8='1',PYTHONDONTWRITEBYTECODE='1')
        for key in ('QODER_PLUGIN_DATA','KIMI_PLUGIN_DATA'):self.env[key]=str(self.root/'plugin-data')
        (self.root/'config.json').write_text(json.dumps({'rsrs':str(self.engine),'skip_prefixes':['Recap:']}),encoding='utf-8')
    def calls(self):
        path=self.root/'calls'
        return [json.loads(x) for x in path.read_text(encoding='utf-8').splitlines()] if path.exists() else []
    def call(self,event='UserPromptSubmit',prompt='store: 42',spec=None,expected=None,session='A',active=False):
        (self.root/'response.json').write_text(json.dumps(spec or {}),encoding='utf-8')
        payload={'hook_event_name':event,'session_id':session,'prompt':prompt,'stop_hook_active':active}
        argv=[[str(self.engine)]+a for a in (expected or [])]
        before=len(self.calls());env=dict(self.env,FIXTURE_EVENT=event,FIXTURE_EXPECTED=json.dumps(argv))
        result=subprocess.run([sys.executable,str(self.launcher)],input=json.dumps(payload),text=True,encoding='utf-8',capture_output=True,env=env,cwd=self.root,timeout=10)
        self.assertEqual(result.returncode,0,result.stderr);self.assertFalse((self.root/'denied').exists())
        self.assertEqual(len(self.calls())-before,len(argv))
        return result.stdout
    def store(self,spec=None,read=True):
        return self.call(spec=spec,expected=[['remember','42','--title','42','--importance','important','--json'],['show',ID,'--json'] if read else ['list','--limit','3','--json']])
    def denied(self,out):
        if not out.strip():return False
        doc=json.loads(out)
        return doc.get('decision')=='deny' or doc.get('hookSpecificOutput',{}).get('permissionDecision')=='deny'
    def test_ok_and_warn_positive_controls(self):
        for status in ('ok','warn'):
            out=self.store({'remember':{'status':status,'summary':{'id':ID}}})
            self.assertIn('Saved',out);self.assertIn('verified by read-back',out)
    def test_malformed_warning_metadata_keeps_saved(self):
        for errors in (42, None, {}, 'not a list'):
            out = self.store({'remember': {'status': 'warn', 'summary': {'id': ID}, 'errors': errors}})
            self.assertIn('Saved with warnings', out)
            self.assertIn('verified by read-back', out)

    def test_invalid_ids_are_unknown_not_saved(self):
        for value in (12345678,None,True,[],{},'a-------','--------','abcdef01-0000-4','abcdef01','f'*15):
            for status in ('ok','warn'):
                with self.subTest(value=value,status=status):
                    out=self.store({'remember':{'status':status,'summary':{'id':value}}},read=False)
                    self.assertIn('unknown',out);self.assertNotIn('Saved',out);self.assertIn('resend',out.lower())
    def test_identity_and_native_types_are_required(self):
        for spec in ({'entry_patch':{'id':'e'*16}},{'entry_remove':['id']},{'entry_patch':{'title':42}},{'entry_patch':{'content':42}},{'entry_patch':{'title':['42']}},{'entry_patch':{'content':['42']}},{'entry_patch':{'content':{'value':'42'}}},{'entry_patch':{'content':'42 changed tail'}}):
            out=self.store(spec);self.assertIn('Saved',out);self.assertIn('DIFFERENT',out);self.assertNotIn('verified by read-back',out)
    def test_bad_details_preserve_committed_receipt(self):
        for value in ([{}],'not an entry',42,None):
            for status in ('ok','warn'):
                out=self.store({'remember':{'status':status,'summary':{'id':ID}},'show':{'status':'ok','details':value}})
                self.assertIn('Saved',out);self.assertIn('Read-back unavailable',out);self.assertNotIn('verified by read-back',out)
    def test_written_receipt_does_not_skip_or_repeat_stop(self):
        self.store();self.assertTrue(self.denied(self.call(event='Stop')))
        self.assertEqual(self.call(event='Stop'),'');self.assertEqual(self.call(event='Stop',active=True),'')
    def test_internal_recap_never_rearms(self):
        self.call(prompt='/nomem real request');self.assertTrue(self.denied(self.call(event='Stop')))
        self.call(prompt='Recap: internal summary');self.assertEqual(self.call(event='Stop'),'')
        self.call(prompt='/nomem genuinely new request');self.assertTrue(self.denied(self.call(event='Stop')))
    def test_sessions_do_not_release_each_others_latches(self):
        self.assertTrue(self.denied(self.call(event='Stop',session='A')))
        self.call(prompt='/nomem B',session='B');self.assertTrue(self.denied(self.call(event='Stop',session='B')))
        self.assertEqual(self.call(event='Stop',session='A'),'')
    def test_unknown_has_no_automatic_resend_at_stop(self):
        self.store({'remember':{'status':'ok','summary':{}}},read=False)
        self.assertTrue(self.denied(self.call(event='Stop')));self.call(event='Stop')
        self.assertEqual(sum(x[0]=='remember' for x in self.calls()),1)
    def test_stale_diagnostic_snapshots_cannot_skip_stop(self):
        self.store();turns=Path(self.env['RESPITE_TURN_STATE'])
        snapshots={p.name:p.read_bytes() for p in turns.glob('*.json')}
        self.call(prompt='/nomem fresh request')
        for name,raw in snapshots.items():(turns/name).write_bytes(raw)
        self.assertTrue(self.denied(self.call(event='Stop')))
    def test_unwritable_state_fails_open(self):
        blocker=self.root/'blocked';blocker.write_text('file',encoding='utf-8')
        self.env['RESPITE_TURN_STATE']=str(blocker/'child')
        self.assertEqual(self.call(event='Stop'),'')

if __name__=='__main__':unittest.main(verbosity=2)
