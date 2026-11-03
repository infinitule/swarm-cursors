"""Real MCP SDK handshake/discovery; no desktop actions or model calls."""
import asyncio
import os
from pathlib import Path
import sys
import tempfile
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

async def main():
    with tempfile.TemporaryDirectory() as directory:
        server = StdioServerParameters(command=sys.executable,
            args=[str(Path(__file__).resolve().parents[1] / 'mcp_server.py')],
            env=dict(os.environ, SWARM_BRIDGE_DIR=directory))
        async with stdio_client(server) as (read, write):
            async with ClientSession(read, write) as session:
                await session.initialize()
                tools = (await session.list_tools()).tools
                names = {tool.name for tool in tools}
                assert len(names) == 9, names
                assert 'swarm_submit_loupe' in names and 'swarm_execute_action' in names
                offline = await session.call_tool('swarm_status', {})
                assert offline.isError
                jobs = await session.call_tool('swarm_list_jobs', {})
                assert not jobs.isError
                print('PASS: MCP initialize, nine tools, offline error, empty job listing')

asyncio.run(main())
