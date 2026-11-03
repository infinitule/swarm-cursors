"""Opt-in integration test, restricted to the synthetic Swarm Practice bundle."""
import asyncio
import json
import os
from pathlib import Path
import sys
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

ROOT = Path(__file__).resolve().parents[2]
async def main():
    server = StdioServerParameters(command=sys.executable, args=[str(ROOT / 'desktop/mcp_server.py')], env=dict(os.environ, SWARM_BRIDGE_DIR=str(ROOT / 'dist/bridge')))
    async with stdio_client(server) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            async def call(name, params=None):
                response = await session.call_tool(name, {} if params is None else {'params':params})
                if response.isError: raise RuntimeError(str(response.content))
                return response.structuredContent or json.loads(response.content[0].text)
            state = await call('swarm_status')
            assert state['accessibility']
            apps = [a for a in state['apps'] if a['bundle_id'] == 'com.infinitule.swarm.practice']
            assert len(apps) == 1
            observed = await call('swarm_observe_app', {'pid':apps[0]['pid']})
            async def stage(observation, label, operation, text=''):
                matches = [n for n in observation['nodes'] if n['label'] == label and operation in n['actions']]
                assert len(matches) == 1
                return await call('swarm_stage_action', dict(snapshot_id=observation['snapshot_id'],title='Practice: '+label,action=operation,target=matches[0]['id'],text=text))
            # Two jobs share a snapshot. Executing one must invalidate the other.
            stale = await stage(observed, 'Save', 'press')
            edit = await stage(observed, 'Title', 'set_text', 'Codex + Loupe test')
            edited = await call('swarm_execute_action', {'job_id':edit['job_id']})
            assert any(n['label'] == 'Title' and n['value'] == 'Codex + Loupe test' for n in edited['nodes'])
            rejected = await session.call_tool('swarm_execute_action', {'params':{'job_id':stale['job_id']}})
            assert rejected.isError, 'Stale action must fail'
            saved = await stage(edited, 'Save', 'press')
            result = await call('swarm_execute_action', {'job_id':saved['job_id']})
            assert any(n['value'].startswith('Saved:') and 'Codex + Loupe test' in n['value'] for n in result['nodes'])
            replay = await session.call_tool('swarm_execute_action', {'params':{'job_id':saved['job_id']}})
            assert replay.isError, 'Replay must fail'
            report = dict(passed=True, checks=['live MCP connection','Practice-only observation','text replacement','stale action rejection','Save button + resulting state','execution replay rejection'])
            print(json.dumps(report))
if __name__ == '__main__':
    if sys.argv[1:] != ['--run-practice']:
        raise SystemExit('Opt-in only: pass --run-practice to edit the in-memory Swarm Practice app.')
    asyncio.run(main())
