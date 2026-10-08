#!/usr/bin/env python3
"""Тесты deploy/restore.sh (R05, T51-T53).

Запуск: python3 deploy/restore_test.py

Скрипт настоящий, вместо docker — заглушка, которая выполняет команды `docker
compose exec ... db <команда>` на временном кластере PostgreSQL (initdb в
каталоге теста), а `stop`/`start api` и проверку API только записывает. Рабочие
базы и серверы не затрагиваются. Нужны `initdb`, `pg_ctl`, `psql`, `pg_dump`
в PATH (или каталог в POSTGRES_BIN); без них тесты пропускаются, а с
RESTORE_TEST_REQUIRED=1 (так в CI) — падают: пропуск не должен выглядеть зелёным.
"""
import glob
import gzip
import os
import shutil
import socket
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESTORE = ROOT / 'deploy' / 'restore.sh'
INTEGRITY = ROOT / 'deploy' / 'integrity.sql'

FAKE_DOCKER = r'''#!/usr/bin/env bash
echo "$*" >> "$AUDIT_LOG"
[ "$1" = compose ] || exit 0
shift
case "$1" in
  stop|start) exit 0 ;;
  exec)
    shift
    [ "$1" = -T ] && shift
    envs=()
    while [ "$1" = -e ]; do envs+=("$2"); shift 2; done
    service="$1"; shift
    if [ "$service" = api ]; then [ "${FAKE_API_HEALTH:-ok}" = ok ]; exit $?; fi
    exec env PGHOST=127.0.0.1 PGPORT="$PG_PORT" "${envs[@]}" "$@"
    ;;
esac
'''

# Минимальная схема: ровно то, что проверяет restore.sh и integrity.sql.
SCHEMA = '''
CREATE TABLE users (id text PRIMARY KEY, email text);
CREATE TABLE ledger_accounts (user_id text, id text, kind text, PRIMARY KEY (user_id, id));
CREATE TABLE transactions (user_id text, id text, reverses text, PRIMARY KEY (user_id, id));
CREATE TABLE postings (user_id text, tx_id text, n int, account_id text, amount bigint, PRIMARY KEY (user_id, tx_id, n));
'''


def populate(n_users, balanced=True):
    rows = [SCHEMA]
    for i in range(n_users):
        u = f'u{i}'
        rows.append(f"INSERT INTO users VALUES ('{u}', '{u}@example.test');")
        rows.append(f"INSERT INTO ledger_accounts VALUES ('{u}', 'cash', 'asset'), ('{u}', 'eq', 'equity');")
        rows.append(f"INSERT INTO transactions VALUES ('{u}', 'open', NULL);")
        credit = 100 if balanced else 99
        rows.append(f"INSERT INTO postings VALUES ('{u}', 'open', 0, 'cash', 100), ('{u}', 'open', 1, 'eq', {credit});")
    return '\n'.join(rows)


def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


def find(tool):
    extra = os.environ.get('POSTGRES_BIN')
    path = os.pathsep.join(filter(None, [extra, os.environ.get('PATH', '')] + glob.glob('/opt/homebrew/opt/postgresql*/bin') + glob.glob('/usr/lib/postgresql/*/bin')))
    return shutil.which(tool, path=path), path


class RestoreTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix='famcoin-restore-test-', dir='/tmp'))
        initdb, path = find('initdb')
        missing = [t for t in ('initdb', 'pg_ctl', 'psql', 'pg_dump') if not find(t)[0]]
        if missing:
            if os.environ.get('RESTORE_TEST_REQUIRED') == '1':
                raise RuntimeError(f'RESTORE_TEST_REQUIRED=1, а нет {", ".join(missing)}')
            raise unittest.SkipTest(f'нет {", ".join(missing)}')
        cls.path = path
        cls.port = free_port()
        cls.env = dict(os.environ, PATH=path, LC_ALL='C', LANG='C')
        sock = cls.tmp / 's'
        sock.mkdir()
        subprocess.run([initdb, '-D', str(cls.tmp / 'pg'), '-U', 'postgres', '--auth=trust', '-E', 'UTF8', '--locale=C'], check=True, capture_output=True, env=cls.env)
        subprocess.run(['pg_ctl', '-D', str(cls.tmp / 'pg'), '-o', f'-p {cls.port} -k {sock} -c listen_addresses=127.0.0.1', '-l', str(cls.tmp / 'pg.log'), '-w', 'start'], check=True, capture_output=True, env=cls.env)
        cls.sql('postgres', "CREATE ROLE famcoin LOGIN SUPERUSER", user='postgres')
        bin_dir = cls.tmp / 'bin'
        bin_dir.mkdir()
        fake = bin_dir / 'docker'
        fake.write_text(FAKE_DOCKER)
        fake.chmod(0o755)
        cls.bin = bin_dir

    @classmethod
    def tearDownClass(cls):
        subprocess.run(['pg_ctl', '-D', str(cls.tmp / 'pg'), '-m', 'immediate', 'stop'], capture_output=True, env=cls.env)
        shutil.rmtree(cls.tmp, ignore_errors=True)

    @classmethod
    def psql(cls, db, *args, user='famcoin', stdin=None):
        return subprocess.run(['psql', '-h', '127.0.0.1', '-p', str(cls.port), '-U', user, '-d', db, '-v', 'ON_ERROR_STOP=1', '-qAt', *args], input=stdin, text=True, capture_output=True, env=cls.env)

    @classmethod
    def sql(cls, db, sql, user='famcoin'):
        r = cls.psql(db, '-c', sql, user=user)
        assert r.returncode == 0, r.stderr
        return r.stdout.strip()

    def setUp(self):
        # Каждому тесту — свой кластерный набор баз: рабочая famcoin с 2 пользователями.
        for (name,) in [(l,) for l in self.sql('postgres', "select datname from pg_database where datname like 'famcoin%' or datname like 'src%'").splitlines()]:
            self.sql('postgres', f'DROP DATABASE "{name}"')
        self.sql('postgres', 'CREATE DATABASE famcoin OWNER famcoin')
        self.psql('famcoin', stdin=populate(2), user='famcoin')
        self.dir = Path(tempfile.mkdtemp(dir=self.tmp))
        (self.dir / 'deploy').mkdir()
        shutil.copy(INTEGRITY, self.dir / 'deploy' / 'integrity.sql')
        self.log = self.dir / 'docker.log'
        self.log.write_text('')

    def users(self, db='famcoin'):
        return int(self.sql(db, 'select count(*) from users'))

    def databases(self):
        return self.sql('postgres', "select datname from pg_database where datname like 'famcoin%' order by 1").splitlines()

    def backup(self, sql, name='backup.sql.gz', balanced=True):
        """Настоящий дамп pg_dump из временной базы с [sql]."""
        self.sql('postgres', 'CREATE DATABASE src_tmp OWNER famcoin')
        try:
            self.psql('src_tmp', stdin=sql)
            dump = subprocess.run(['pg_dump', '-h', '127.0.0.1', '-p', str(self.port), '-U', 'famcoin', '-d', 'src_tmp', '--no-owner'], capture_output=True, check=True, env=self.env).stdout
        finally:
            self.sql('postgres', 'DROP DATABASE src_tmp')
        path = self.dir / name
        with gzip.open(path, 'wb') as f:
            f.write(dump)
        return path

    def run_restore(self, file, health='ok'):
        env = dict(self.env, PATH=f'{self.bin}{os.pathsep}{self.path}', AUDIT_LOG=str(self.log), PG_PORT=str(self.port), RESTORE_YES='1', FAKE_API_HEALTH=health, RESTORE_HEALTH_TRIES='2', RESTORE_HEALTH_PAUSE='0')
        return subprocess.run(['bash', str(RESTORE), str(file), str(self.dir)], capture_output=True, text=True, env=env)

    def calls(self):
        return self.log.read_text().splitlines()

    def assertUntouched(self, run):
        """Рабочая база на месте, сервис не останавливался, ничего не переименовано и не удалено."""
        self.assertNotEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertNotIn('восстановлено из', run.stdout)
        calls = self.calls()
        self.assertFalse([c for c in calls if 'compose stop' in c], calls)
        self.assertFalse([c for c in calls if 'DROP DATABASE famcoin ' in c or 'DROP DATABASE IF EXISTS famcoin ' in c or 'RENAME' in c], calls)
        self.assertEqual(self.databases(), ['famcoin'], 'не осталось ни временных, ни переименованных баз')
        self.assertEqual(self.users(), 2)

    # --------------------------------------------------------------- T51
    def test_t51_missing_file(self):
        run = self.run_restore(self.dir / 'нет-такого.sql.gz')
        self.assertUntouched(run)
        self.assertEqual(self.calls(), [], 'до проверки файла к docker не обращались')

    def test_t51_corrupt_or_foreign_archives(self):
        good = self.backup(populate(5))
        data = good.read_bytes()
        cases = {
            'пустой файл': b'',
            'не gzip': b'SELECT 1;\n',
            'обрезанный gzip': data[: len(data) // 2],
            'gzip, но не дамп PostgreSQL': gzip.compress(b'DROP TABLE users;\n'),
        }
        for label, content in cases.items():
            with self.subTest(label):
                bad = self.dir / 'bad.sql.gz'
                bad.write_bytes(content)
                self.log.write_text('')
                run = self.run_restore(bad)
                self.assertUntouched(run)
                self.assertEqual(self.calls(), [], label)

    # --------------------------------------------------------------- T52
    def test_t52_sql_error_does_not_switch_or_report_success(self):
        good = self.backup(populate(5))
        broken = self.dir / 'broken.sql.gz'
        text = gzip.decompress(good.read_bytes()).decode() + '\nSELECT nonexistent_audit_function();\n'
        # ошибка не в конце, чтобы psql без ON_ERROR_STOP продолжил и «успешно» дошёл бы до конца
        text = text.replace('COPY public.postings', 'SELECT nonexistent_audit_function();\nCOPY public.postings', 1)
        broken.write_bytes(gzip.compress(text.encode()))
        run = self.run_restore(broken)
        self.assertUntouched(run)
        self.assertIn('nonexistent_audit_function', run.stderr)

    def test_t52_unbalanced_journal_is_refused(self):
        run = self.run_restore(self.backup(populate(3, balanced=False)))
        self.assertUntouched(run)
        self.assertIn('unbalanced', run.stderr)

    def test_t52_copy_without_famcoin_tables_is_refused(self):
        run = self.run_restore(self.backup('CREATE TABLE other (a int);'))
        self.assertUntouched(run)

    # --------------------------------------------------------------- T53
    def test_t53_good_backup_is_restored_after_verification(self):
        run = self.run_restore(self.backup(populate(5)))
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn('восстановлено из', run.stdout)
        self.assertEqual(self.users(), 5, 'рабочая база — содержимое копии')
        names = self.databases()
        self.assertEqual(len([n for n in names if n.startswith('famcoin_before_restore_')]), 1, names)
        old = [n for n in names if n.startswith('famcoin_before_restore_')][0]
        self.assertEqual(self.users(old), 2, 'прежняя база сохранена для отката')
        self.assertFalse([n for n in names if n.startswith('famcoin_restore_')], 'временная база стала рабочей')
        pre = glob.glob(str(self.dir / 'backups' / 'pre-restore-*.sql.gz'))
        self.assertEqual(len(pre), 1)
        self.assertIn(b'PostgreSQL database dump', gzip.decompress(Path(pre[0]).read_bytes()))
        # Порядок: временная база создана и проверена до остановки API и переименований.
        calls = self.calls()
        idx = lambda needle: next(i for i, c in enumerate(calls) if needle in c)
        self.assertLess(idx('CREATE DATABASE famcoin_restore_'), idx('compose stop api'))
        self.assertLess(idx('compose stop api'), idx('RENAME TO famcoin_before_restore_'))
        self.assertLess(idx('RENAME TO famcoin_before_restore_'), idx('compose start api'))
        self.assertFalse([c for c in calls if 'DROP DATABASE famcoin ' in c], 'рабочая база не удаляется')

    def test_t53_api_does_not_come_up_after_switch_rolls_back(self):
        run = self.run_restore(self.backup(populate(5)), health='fail')
        self.assertNotEqual(run.returncode, 0)
        self.assertNotIn('восстановлено из', run.stdout)
        self.assertEqual(self.users(), 2, 'вернулась прежняя база')
        self.assertTrue([c for c in self.calls() if c.endswith('compose start api')], 'API запущен на прежней базе')
        self.assertFalse([n for n in self.databases() if n.startswith('famcoin_before_restore_')])


if __name__ == '__main__':
    unittest.main(verbosity=2)
