import asyncio
import contextlib
import json
from pathlib import Path
import stat
import sys
import tempfile
import time
import unittest
from unittest.mock import AsyncMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from mcp_server import Runtime, atomic_json, candidates, Ground, resolve, run_loupe


class BridgeTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.runtime = Runtime(self.root)
        atomic_json(self.root / 'status.json', dict(heartbeat=time.time(), paused=False))

    async def asyncTearDown(self):
        await self.runtime.shutdown()
        self.temp.cleanup()

    def test_private_files(self):
        self.assertEqual(stat.S_IMODE((self.root / 'status.json').stat().st_mode), 0o600)

    def test_offline(self):
        (self.root / 'status.json').unlink()
        with self.assertRaisesRegex(ValueError, 'Open Swarm'): self.runtime.status()

    def test_stale_heartbeat(self):
        atomic_json(self.root / 'status.json', dict(heartbeat=0))
        with self.assertRaisesRegex(ValueError, 'not responding'): self.runtime.status()

    def test_job_limit(self):
        for i in range(8): self.runtime.new_job(str(i), 'loupe')
        with self.assertRaisesRegex(ValueError, 'Eight'): self.runtime.new_job('overflow', 'loupe')

    def test_ui_telemetry_excludes_source_and_result(self):
        job = self.runtime.new_job('demo', 'loupe')
        job['source'] = 'private'; job['result'] = 'private result'
        self.runtime.publish()
        text = next((self.root / 'sessions').glob('*.json')).read_text()
        self.assertNotIn('private', text)

    async def test_rpc_roundtrip_and_cleanup(self):
        async def fake_native_app():
            while not list((self.root / 'requests').glob('*.json')): await asyncio.sleep(.01)
            request = next((self.root / 'requests').glob('*.json'))
            body = json.loads(request.read_text())
            self.assertEqual(body['command'], 'observe')
            self.assertGreater(body['deadline'], time.time())
            atomic_json(self.root / 'responses' / request.name, {'snapshot_id':'fixture', 'nodes':[]})
        task = asyncio.create_task(fake_native_app())
        result = await self.runtime.rpc('observe', pid=123)
        await task
        self.assertEqual(result['snapshot_id'], 'fixture')
        self.assertFalse(list((self.root / 'requests').glob('*.json')))
        self.assertFalse(list((self.root / 'responses').glob('*.json')))

    async def test_inference_serialized(self):
        active = 0; maximum = 0
        async def work():
            nonlocal active, maximum
            async with self.runtime.inference_lane():
                active += 1; maximum = max(maximum, active)
                await asyncio.sleep(.03); active -= 1
        await asyncio.gather(work(), work(), work())
        self.assertEqual(maximum, 1)

    async def test_cancel_releases_lane(self):
        job = self.runtime.new_job('cancel', 'loupe')
        entered = asyncio.Event()
        async def work(): entered.set(); await asyncio.sleep(30)
        task = asyncio.create_task(self.runtime.worker(job, work))
        await entered.wait(); task.cancel(); await task
        self.assertEqual(job['state'], 'cancelled')
        async with asyncio.timeout(1):
            async with self.runtime.inference_lane(): pass

    async def test_error_escalates_to_gpt(self):
        job = self.runtime.new_job('bad', 'loupe')
        async def fail(): raise ValueError('rejected local result')
        await self.runtime.worker(job, fail)
        self.assertEqual(job['state'], 'needs_gpt')

    async def test_unchanged_loupe_fix_escalates(self):
        source = 'def avg(xs):\n    return sum(xs) / len(xs)\n'
        process = AsyncMock()
        process.returncode = 0
        process.communicate.return_value = (source.encode(), b'')
        with patch('mcp_server.LOUPE', Path(__file__)), patch(
                'mcp_server.asyncio.create_subprocess_exec', return_value=process):
            with self.assertRaisesRegex(ValueError, 'unchanged'):
                await run_loupe('fix', source)

    async def test_loupe_result_requires_behavior_review(self):
        process = AsyncMock()
        process.returncode = 0
        process.communicate.return_value = (b'Returns the arithmetic mean.', b'')
        with patch('mcp_server.LOUPE', Path(__file__)), patch(
                'mcp_server.asyncio.create_subprocess_exec', return_value=process):
            result = await run_loupe('explain', 'def avg(xs): return sum(xs) / len(xs)')
        self.assertFalse(result['behavior_verified'])
        self.assertFalse(result['applied_to_files'])

    async def test_exact_grounding_preserves_text(self):
        params = Ground(snapshot_id='test', title='fill', operation='set_text', target_hint='Name', text='Ada Lovelace')
        result = await resolve(params, {'nodes':[{'id':4,'label':'Name','value':'','actions':['set_text']}]})
        self.assertEqual(result['target'], 4)
        self.assertEqual(result['text'], 'Ada Lovelace')
        self.assertEqual(result['method'], 'deterministic_exact_label')

    def test_grounding_filters_wrong_operations_and_unrelated_labels(self):
        nodes = [{'id':1,'label':'Name','actions':['press']}, {'id':2,'label':'Delete all','actions':['set_text']}]
        self.assertEqual(candidates(nodes, 'set_text', 'Name'), [])

    async def test_stop_rejects_requests(self):
        atomic_json(self.root / 'status.json', dict(heartbeat=time.time(), paused=True))
        with self.assertRaisesRegex(ValueError, 'stopped'): await self.runtime.rpc('observe', pid=123)


if __name__ == '__main__': unittest.main()
