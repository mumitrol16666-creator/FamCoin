"""Safe diagnostic: original restore.sh runs against a fake docker executable."""
import gzip
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(sys.argv[1]).resolve()
results = []
with tempfile.TemporaryDirectory(prefix='famcoin-restore-probe-') as folder:
    temp = Path(folder)
    binaries = temp / 'bin'
    binaries.mkdir()
    fake = binaries / 'docker'
    fake.write_text('''#!/usr/bin/env python3
import os, sys
with open(os.environ['AUDIT_LOG'], 'a') as log:
    log.write(' '.join(sys.argv[1:]) + '\\n')
if 'psql' in sys.argv and '-q' in sys.argv:
    sys.stdin.read()
    sys.stderr.write('ERROR: simulated SQL error (psql default continues)\\n')
''')
    fake.chmod(0o755)
    broken_sql = temp / 'sql-error.sql.gz'
    with gzip.open(broken_sql, 'wb') as stream:
        stream.write(b'SELECT nonexistent_audit_function();\n')
    for name, backup in [('missing-backup', temp / 'does-not-exist.sql.gz'), ('sql-error', broken_sql)]:
        log = temp / f'{name}.log'
        env = dict(os.environ, PATH=f'{binaries}:{os.environ["PATH"]}', AUDIT_LOG=str(log))
        run = subprocess.run(['bash', str(root / 'deploy/restore.sh'), str(backup), str(temp)], input='y\n', text=True, capture_output=True, env=env)
        calls = log.read_text().splitlines()
        results.append({'case': name, 'exit': run.returncode, 'dockerCalls': calls, 'stdout': run.stdout.strip(), 'stderr': run.stderr.strip()})
    assert any('DROP DATABASE' in c for c in results[0]['dockerCalls']), results[0]
    assert results[0]['exit'] != 0
    assert results[1]['exit'] == 0 and 'восстановлено' in results[1]['stdout'], results[1]
print(json.dumps(results, ensure_ascii=False, indent=2))
