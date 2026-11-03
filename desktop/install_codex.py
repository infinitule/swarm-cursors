#!/usr/bin/env python3
"""Print, or explicitly install, the local stdio MCP configuration."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import tomllib

parser = argparse.ArgumentParser()
parser.add_argument('--install', action='store_true', help='Append the reviewed block to ~/.codex/config.toml')
parser.add_argument('--loupe', type=Path, default=Path.home() / 'loupe/.build/x86_64-apple-macosx/debug/loupe')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
python = root / '.venv/bin/python'
if not python.is_file(): parser.error('Create .venv and install desktop/requirements.lock first.')
if not args.loupe.is_file(): parser.error('Pass --loupe with the existing Loupe executable.')
block = '\n[mcp_servers.swarm_desktop]\n' + '\n'.join([
    'command = ' + json.dumps(str(python)),
    'args = ' + json.dumps([str(root / 'desktop/mcp_server.py')]),
    'cwd = ' + json.dumps(str(root)),
    'startup_timeout_sec = 20', 'tool_timeout_sec = 30',
    '\n[mcp_servers.swarm_desktop.env]',
    'SWARM_BRIDGE_DIR = ' + json.dumps(str(root / 'dist/bridge')),
    'SWARM_LOUPE_BIN = ' + json.dumps(str(args.loupe.resolve())),
]) + '\n'
if not args.install:
    print(block)
else:
    path = Path.home() / '.codex/config.toml'
    with path.open('a+') as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        stream.seek(0); original = stream.read()
        config = tomllib.loads(original)
        if 'swarm_desktop' in config.get('mcp_servers', {}):
            parser.error('swarm_desktop is already configured; no existing configuration was changed.')
        tomllib.loads(original + block)
        stream.seek(0, os.SEEK_END); stream.write(block); stream.flush(); os.fsync(stream.fileno())
    print('Registered swarm_desktop. Restart the Codex client if the new tools do not appear.')
