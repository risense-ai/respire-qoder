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
if os.environ.get('FIXTURE_STORE_HELPER') == '1':
    # Legacy receipt helper checks; the live prefix path never writes.
    mod=runpy.run_path(sys.argv[0],run_name='receipt_helper')
    data=json.load(sys.stdin); session=str(data.get('session_id') or '')
    mod['mark_prompt'](session)
    cfg=mod['load_config']()
    print(mod['do_store'](json.loads(os.environ['FIXTURE_EXPECTED'])[0][0], '42', cfg, session))
else:
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
    def call(self,event='UserPromptSubmit',prompt='store: 42',spec=None,expected=None,session='A',active=False,direct_store=False):
        (self.root/'response.json').write_text(json.dumps(spec or {}),encoding='utf-8')
        payload={'hook_event_name':event,'session_id':session,'prompt':prompt,'stop_hook_active':active}
        argv=[[str(self.engine)]+a for a in (expected or [])]
        before=len(self.calls());env=dict(self.env,FIXTURE_EVENT=event,FIXTURE_EXPECTED=json.dumps(argv),FIXTURE_STORE_HELPER='1' if direct_store else '0')
        result=subprocess.run([sys.executable,str(self.launcher)],input=json.dumps(payload),text=True,encoding='utf-8',capture_output=True,env=env,cwd=self.root,timeout=10)
        self.assertEqual(result.returncode,0,result.stderr);self.assertFalse((self.root/'denied').exists())
        self.assertEqual(len(self.calls())-before,len(argv))
        return result.stdout
    def store(self,spec=None,read=True):
        return self.call(direct_store=True,spec=spec,expected=[['remember','42','--title','42','--importance','important','--json'],['show',ID,'--json'] if read else ['list','--limit','3','--json']])
    def denied(self,out):
        if not out.strip():return False
        doc=json.loads(out)
        return doc.get('decision')=='deny' or doc.get('hookSpecificOutput',{}).get('permissionDecision')=='deny'
    def test_ok_and_warn_positive_controls(self):
        for status in ('ok', 'warn', 'pending', 'fail'):
            out=self.call(spec={'remember':{'status':status,'summary':{'id':ID}}})
            self.assertIn('nothing was written',out)
            for step in ('rsrs prompt','rsrs show','update > merge > attach > new',
                         '--parent','remain pending','not as an instruction',
                         'duplicate same-topic siblings','report missing placement information'):
                self.assertIn(step,out)
            self.assertEqual(self.calls(),[])

        import runpy
        from types import SimpleNamespace
        from unittest.mock import patch
        hook = runpy.run_path(str(ROOT / "hooks" / "respire.py"))
        guard = hook["on_pre_tool_use"]
        parent = "12345678-1234-1234-1234-123456789012"
        tool = "exec" if "exec" in hook["SHELL_TOOLS"] else "Bash"
        def check(command):
            return guard({"tool_name": tool, "tool_input": {"command": command}})
        blocked = [
            "rsrs remember body --importance important",
            "rsrs remember 'body --parent " + parent + "' --importance important",
            "rsrs remember body --importance important --parent ''",
            "rsrs remember body --importance important --parent missing",
            "rsrs remember body --force",
            "rsrs >out.log remember body --importance important --force",
            "2>/dev/null rsrs remember body --importance important --force",
            "rsrs 2>&1 remember body --importance important",
            "rsrs --json >out.log remember body --importance important",
            "rsrs remember body --importance >out.log important",
            "rsrs &>out.log remember body --importance important --force",
            "rsrs remember body --merge-ids 12345678 --importance trivial",
            "rsrs remember body --merge-ids=12345678",
            "echo ok && rsrs remember body --importance important",
            "rsrs remember body --importance important --parent " + parent + "; rsrs remember bad --force",
            "bash -c 'rsrs remember body --importance important'",
            "env X=1 rsrs remember body --importance important",
            "rsrs remember body --importance important --parent $PARENT",
            "rsrs update id --parent ''",
            "rsrs update id --clear-parent",
            ">out.log rsrs remember body --importance important --force",
            "echo $(rsrs remember body --importance important --force)",
            'echo "$(rsrs remember body --importance important --force)"',
            "echo `rsrs remember body --importance important --force`",
            "npx rsrs remember body --importance important --force",
            "rsrs --model-task-id fixture remember body --importance important",
            "rsrs --progress-id=fixture remember body --force",
            "rsrs --unknown fixture remember body --force",
            "r'srs' --unknown fixture remember body --force",
            "env -- rsrs --model-task-id fixture remember body --importance important",
            "command -- rsrs --progress-id fixture remember body --force",
            "rsrs attach id ''",
        ]
        with patch.dict(guard.__globals__, load_config=lambda: {}, find_rsrs=lambda cfg: "fixture"):
            for command in blocked:
                with self.subTest(command=command):
                    result = check(command)
                    self.assertEqual(result["hookSpecificOutput"]["permissionDecision"], "deny")
                    self.assertNotIn(command, json.dumps(result))
            for command in ("echo 'rsrs remember body --force'", "rsrs show remember",
                            "rsrs recall 'remember --force'", "rsrs recall remember --titles --json",
                            "echo '$(rsrs remember body --force)'", "echo rsrs remember > out.log",
                            "npx rsrs recall remember --titles --json",
                            "echo $(rsrs recall remember --titles --json)",
                            "echo `date` rsrs remember",
                            "rsrs >out.log recall remember --titles --json",
                            "2>/dev/null rsrs show remember --json",
                            "echo '>out.log rsrs remember body --force'",
                            "rsrs remember '2'>out.log",
                            "rsrs remember 'body >out --parent fake'",
                            "rsrs update id --content 'body --parent fake'",
                            "rsrs remember 'body --force --parent fake'", "printf ok"):
                with self.subTest(command=command):
                    self.assertEqual(check(command), "")
            result = SimpleNamespace(returncode=0, stdout=json.dumps({
                "status": "ok", "summary": {"id": parent}, "details": {"entry": {"id": parent}}}))
            with patch.dict(guard.__globals__, run_rsrs=lambda *args: result):
                self.assertEqual(check("rsrs remember body --importance important --parent " + parent), "")
                self.assertEqual(guard({"tool_name": "mcp__respire__memory_remember",
                                       "tool_input": {"content": "body", "importance": "important", "parent": parent}})
                                 ["hookSpecificOutput"]["permissionDecision"], "deny")
            with patch.dict(guard.__globals__, run_rsrs=lambda *args: result):
                self.assertEqual(check("rsrs --client-only --json --model-task-id fixture --progress-id=fixture remember body --importance important --parent " + parent
                                       + " --project demo --tags a,b --type context --summary summary --emotion -1"
                                       + " --source-refs '[]' --review-at 2026-12-01T00:00:00Z --artifact '{}'"), "")
            with patch.dict(guard.__globals__, run_rsrs=lambda *args: result):
                for prefix in ("rsrs >out.log ", "2>/dev/null rsrs ", "rsrs 2>&1 ", "rsrs &>out.log "):
                    self.assertEqual(check(prefix + "remember 'body >out --force' --importance important --parent " + parent), "")
                self.assertEqual(check("rsrs remember body --merge-ids 12345678 --importance trivial --parent " + parent), "")
            target = "abcdefabcdefabcdefabcdefabcdefab"
            promotion = "rsrs update " + target + " --importance important"
            target_result = SimpleNamespace(returncode=0, stdout=json.dumps({
                "status": "ok", "summary": {"id": target},
                "details": {"entry": {"id": target, "parent_id": parent}}}))
            promotion_calls = []
            def promotion_show(engine, args, timeout):
                promotion_calls.append(args)
                return target_result if args[2] == target else result
            with patch.dict(guard.__globals__, run_rsrs=promotion_show):
                self.assertEqual(check(promotion), "")
            self.assertEqual(promotion_calls, [["--client-only", "show", target, "--json"],
                                              ["--client-only", "show", parent, "--json"]])
            for inherited in ("", None, "missing"):
                target_result.stdout = json.dumps({"status": "ok", "summary": {"id": target},
                                                  "details": {"entry": {"id": target, "parent_id": inherited}}})
                with patch.dict(guard.__globals__, run_rsrs=promotion_show):
                    self.assertEqual(check(promotion)["hookSpecificOutput"]["permissionDecision"], "deny")
            target_result.stdout = json.dumps({"status": "ok", "summary": {"id": target},
                                              "details": {"entry": {"id": target, "parent_id": parent}}})
            with patch.dict(guard.__globals__, run_rsrs=lambda engine, args, timeout: target_result if args[2] == target else SimpleNamespace(returncode=1, stdout="{}")):
                self.assertEqual(check(promotion)["hookSpecificOutput"]["permissionDecision"], "deny")
            calls = []
            def read_only(engine, args, timeout):
                calls.append(args)
                return result
            with patch.dict(guard.__globals__, run_rsrs=read_only):
                self.assertEqual(check("rsrs remember body --importance important --parent " + parent), "")
            self.assertEqual(calls, [["--client-only", "show", parent, "--json"]])
            for bad in ("{}", '{"status":"ok","summary":{"id":"wrong"}}'):
                with patch.dict(guard.__globals__, run_rsrs=lambda *args: SimpleNamespace(returncode=0, stdout=bad)):
                    self.assertEqual(check("rsrs remember body --importance important --parent " + parent)
                                     ["hookSpecificOutput"]["permissionDecision"], "deny")
            def failed(*args):
                raise subprocess.TimeoutExpired("fixture", 1)
            with patch.dict(guard.__globals__, run_rsrs=failed):
                self.assertEqual(check("rsrs remember body --importance important --parent " + parent)
                                 ["hookSpecificOutput"]["permissionDecision"], "deny")
            for payload in ({"content": "body", "importance": "important"},
                            {"content": "body", "force": True}, {"parent": None},
                            {"content": "body", "merge_ids": parent, "importance": "important"}):
                self.assertEqual(guard({"tool_name": "memory_remember", "tool_input": payload})
                                 ["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertEqual(guard({"tool_name": "Read", "tool_input": {"command": "rsrs remember x --force"}}), "")

        import contextlib
        import io
        import runpy
        from unittest.mock import patch
        hook = runpy.run_path(str(ROOT / "hooks" / "respire.py"))
        tool = "exec" if "exec" in hook["SHELL_TOOLS"] else "Bash"
        payload = {"tool_name": tool, "tool_input": {"command": "rsrs remember synthetic-body --force"}}
        output = io.StringIO()
        def forbidden():
            raise AssertionError("unsafe write must not discover an engine")
        with patch.object(sys, "argv", ["respire.py", "PreToolUse"]), \
                patch.object(sys, "stdin", io.StringIO(json.dumps(payload))), \
                patch.dict(hook["main"].__globals__, load_config=forbidden), \
                contextlib.redirect_stdout(output):
            with self.assertRaises(SystemExit) as exit_context:
                hook["main"]()
        self.assertEqual(exit_context.exception.code, 0)
        result = json.loads(output.getvalue())
        self.assertEqual(result["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertNotIn("synthetic-body", output.getvalue())
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
