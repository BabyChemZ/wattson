#!/usr/bin/env python3
"""Exercise shutdown and singleton behavior with isolated, non-acting engines."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

binary = Path(sys.argv[1] if len(sys.argv) > 1 else '.build/debug/wattson').resolve()
with tempfile.TemporaryDirectory(prefix='wattson-smoke-') as directory:
    home = Path(directory)
    (home / 'config.json').write_text(json.dumps({
        'dryRun': True, 'yieldForHeavyWork': False, 'localNotifications': False,
        'alertCPUPercent': None, 'alertMemoryPercent': None,
        'alertBatteryTemperature': None, 'minimumSamples': 1_000_000,
    }))
    env = dict(os.environ, WATTSON_HOME=directory)
    processes = []
    try:
        with (home / 'engine.out').open('w') as output:
            first = subprocess.Popen([str(binary), 'watch'], env=env,
                                     stdout=output, stderr=subprocess.STDOUT)
            processes.append(first)
            deadline = time.monotonic() + 15
            while 'wattson started' not in (home / 'engine.out').read_text():
                assert first.poll() is None, 'first engine exited during startup'
                assert time.monotonic() < deadline, 'engine did not start'
                time.sleep(0.1)
            second = subprocess.run([str(binary), 'watch'], env=env,
                                    capture_output=True, text=True, timeout=10)
            assert second.returncode == 0, second.stdout + second.stderr
            assert 'another instance' in second.stdout, second.stdout
            print('PASS second engine cannot acquire the same data directory')
            # Let the counter sampler produce at least one usable delta.
            time.sleep(9)
            first.terminate()
            assert first.wait(timeout=20) == 0, (home / 'engine.out').read_text()
            baselines = json.loads((home / 'baselines.json').read_text())
            assert baselines, 'shutdown did not persist sampled baselines'
            journal = home / 'priority-leases.json'
            assert not journal.exists() or not json.loads(journal.read_text()), 'observe-only created leases'
            print('PASS SIGTERM exits normally and persists actual samples')
            print('PASS observe-only leaves no priority restoration obligations')
    finally:
        for process in processes:
            if process.poll() is None:
                process.kill()
                process.wait()
