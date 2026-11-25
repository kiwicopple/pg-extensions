"""Installer CLI tests, plus opt-in disposable Postgres integration tests.

python3 -m unittest discover -s test -p 'test_install.py'
INSTALL_TEST_IMAGE=postgres:17 python3 -m unittest discover -s test -p 'test_install.py'
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
PACKAGES = {
    'pg_idkit': ('0.0.5', 'extensions', 'select extensions.gen_random_uuid_v7() is not null'),
    'pg_crdt': ('0.0.1', 'crdt', 'select crdt.pn_value(crdt.pn_empty()) = 0'),
    'pg_permissions': ('0.1.0', 'permissions', 'select permissions.current_subject_type()'),
    'pg_validate': ('0.0.1', 'validate', "select validate.email('ada@example.com')"),
}

# Serve the checkout's files through curl's CLI contract. No test downloads from
# main, so a test always exercises the SQL in the same checkout as the installer.
CURL = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
url = next(a for a in args if a.startswith('https://'))
out = pathlib.Path(args[args.index('-o') + 1])
with open(os.environ['TEST_DOWNLOADS'], 'a') as log:
    log.write(json.dumps(url) + '\n')
if os.environ.get('TEST_DOWNLOAD_FAIL'):
    out.write_text('partial download')
    sys.exit(22)
source = pathlib.Path(os.environ['TEST_REPO']).joinpath(*url.split('/')[-2:])
if not source.is_file():
    sys.exit(22)
body = source.read_text()
if source.suffix == '.control' and os.environ.get('TEST_BAD_CONTROL'):
    body = "default_version = '../../unexpected'"
if source.suffix == '.sql':
    if os.environ.get('TEST_EMPTY_SQL'):
        body = ''
    if os.environ.get('TEST_SQL_FAIL'):
        body += '\ncreate table public.installer_rollback_probe (id int);\nselect 1 / 0;\n'
out.write_text(body)
'''

PSQL = r'''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
args = sys.argv[1:]
source = next(a for a in args if a.startswith('--file='))
body = pathlib.Path(source.split('=', 1)[1]).read_text()
pathlib.Path(os.environ['TEST_SQL']).write_text(body)
pathlib.Path(os.environ['TEST_ARGS']).write_text(json.dumps(args))
if os.environ.get('TEST_CONTAINER'):
    args[args.index(source)] = '--file=-'
    result = subprocess.run(['docker', 'exec', '-i', os.environ['TEST_CONTAINER'],
                             'psql', *args], input=body, text=True)
    sys.exit(result.returncode)
sys.exit(int(os.environ.get('TEST_PSQL_EXIT', '0')))
'''


class InstallerCase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='installer-test-')
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.bin = self.work / 'bin'
        self.bin.mkdir()
        for name, body in [('curl', CURL), ('psql', PSQL)]:
            target = self.bin / name
            target.write_text(body)
            target.chmod(0o755)
        self.env = {
            **os.environ,
            'PATH': str(self.bin) + os.pathsep + os.environ['PATH'],
            'TEST_REPO': str(ROOT),
            'TEST_DOWNLOADS': str(self.work / 'downloads'),
            'TEST_SQL': str(self.work / 'executed.sql'),
            'TEST_ARGS': str(self.work / 'psql-args.json'),
            'TMPDIR': str(self.work),
        }
        self.env.pop('DATABASE_URL', None)
        self.env.pop('TEST_CONTAINER', None)

    def run_installer(self, *args, env=None, ok=True):
        result = subprocess.run(['sh', str(ROOT / 'install.sh'), *args],
                                env={**self.env, **(env or {})}, cwd=self.work,
                                text=True, capture_output=True)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(list(self.work.glob('pg-extensions.*')), [], 'temporary files leaked')
        return result


class InstallerTests(InstallerCase):
    def test_latest_for_every_package(self):
        for package, (version, schema, _) in PACKAGES.items():
            with self.subTest(package=package):
                result = self.run_installer(package, '--database', 'dbname=app user=owner')
                sql = (self.work / 'executed.sql').read_text()
                self.assertIn((ROOT / package / f'{package}--{version}.sql').read_text(), sql)
                self.assertIn(f'Installed {package} {version} in schema {schema}', result.stdout)
                self.assertTrue(sql.rstrip().endswith('commit;'))

    def test_pinned_output_needs_no_database_or_psql(self):
        (self.bin / 'psql').unlink()
        output = self.work / 'migration.sql'
        self.run_installer('pg_idkit', '--version', '0.0.4', '--ref', 'a' * 40,
                           '--output', str(output))
        self.assertIn('pg_idkit 0.0.4', output.read_text())
        self.assertEqual(len((self.work / 'downloads').read_text().splitlines()), 1)
        self.assertIn('/' + 'a' * 40 + '/', (self.work / 'downloads').read_text())
        self.assertFalse((self.work / 'executed.sql').exists())
        original = output.read_bytes()
        self.run_installer('pg_idkit', '--output', str(output), ok=False)
        self.assertEqual(output.read_bytes(), original)

    def test_connection_environment_and_role_quoting(self):
        role = 'owner"; select 1/0; --'
        self.run_installer('pg_crdt', '--role', role,
                           env={'DATABASE_URL': 'postgresql://owner:secret@localhost/app'})
        self.assertIn('set local role "owner""; select 1/0; --";',
                      (self.work / 'executed.sql').read_text())
        args = json.loads((self.work / 'psql-args.json').read_text())
        self.assertIn('--dbname=postgresql://owner:secret@localhost/app', args)
        self.assertIn('-X', args)
        self.assertIn('--set=ON_ERROR_STOP=1', args)

    def test_invalid_arguments_do_not_connect(self):
        cases = [[], ['unknown'], ['pg_crdt', '--version'], ['pg_crdt', '--unknown'],
                 ['pg_crdt', '--version', '../escape'], ['pg_crdt', '--ref', 'main\nbad'],
                 ['pg_crdt', '--version', '0.0.1\ninvalid'],
                 ['pg_crdt', 'pg_idkit'], ['pg_crdt'], ['pg_crdt', '--database', '']]
        for args in cases:
            with self.subTest(args=args):
                self.run_installer(*args, ok=False)
        self.assertFalse((self.work / 'downloads').exists())
        self.assertFalse((self.work / 'executed.sql').exists())

    def test_download_failure_empty_sql_and_bad_metadata_never_connect(self):
        for key in ['TEST_DOWNLOAD_FAIL', 'TEST_EMPTY_SQL', 'TEST_BAD_CONTROL']:
            with self.subTest(key=key):
                self.run_installer('pg_crdt', '--database', 'dbname=app', env={key: '1'}, ok=False)
                self.assertFalse((self.work / 'executed.sql').exists())
        self.run_installer('pg_crdt', '--version', '99.0.0', '--database', 'dbname=app', ok=False)
        self.assertFalse((self.work / 'executed.sql').exists())

    def test_psql_failure_is_not_reported_as_success(self):
        result = self.run_installer('pg_crdt', '--database', 'dbname=app',
                                    env={'TEST_PSQL_EXIT': '3'}, ok=False)
        self.assertNotIn('Installed ', result.stdout)


@unittest.skipUnless(os.environ.get('INSTALL_TEST_IMAGE'), 'set INSTALL_TEST_IMAGE for real Postgres')
class PostgresTests(InstallerCase):
    @classmethod
    def setUpClass(cls):
        cls.container = 'pg-installer-test-' + uuid.uuid4().hex[:10]
        subprocess.run(['docker', 'run', '-d', '--rm', '--name', cls.container,
                        '-e', 'POSTGRES_HOST_AUTH_METHOD=trust', os.environ['INSTALL_TEST_IMAGE']],
                       check=True, capture_output=True)
        cls.addClassCleanup(lambda: subprocess.run(['docker', 'rm', '-f', cls.container],
                                                   capture_output=True))
        for _ in range(100):
            # The image first starts a socket-only server for init scripts.
            # Wait for TCP so it cannot restart underneath the first test.
            ready = subprocess.run(['docker', 'exec', cls.container, 'pg_isready',
                                    '-h', '127.0.0.1', '-U', 'postgres'],
                                   capture_output=True)
            if ready.returncode == 0:
                break
            time.sleep(0.2)
        else:
            raise RuntimeError('Postgres did not start')
        cls.query("create role app_owner; create role installer_login login; "
                  "grant app_owner to installer_login; "
                  'create role "owner""; select 1/0; --";', database='postgres')

    @classmethod
    def query(cls, sql, database):
        return subprocess.run(['docker', 'exec', '-i', cls.container, 'psql', '-XAt',
                               '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', database],
                              input=sql, text=True, capture_output=True, check=True).stdout.strip()

    def setUp(self):
        super().setUp()
        self.database = 'installer_' + uuid.uuid4().hex[:12]
        self.query(f'create database {self.database} owner app_owner;', database='postgres')

    def install_real(self, package, *args, ok=True, env=None):
        return self.run_installer(package, '--database', f'dbname={self.database} user=installer_login',
                                  '--role', 'app_owner', *args, ok=ok,
                                  env={'TEST_CONTAINER': self.container, **(env or {})})

    def test_real_installs_and_reinstall_refusal(self):
        for package, (_, schema, smoke) in PACKAGES.items():
            with self.subTest(package=package):
                self.install_real(package)
                self.assertIn(self.query(smoke, self.database), ['t', 'user'])
                self.assertEqual(self.query(
                    f"select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace "
                    f"where n.nspname='{schema}' and p.proowner <> 'app_owner'::regrole;",
                    self.database), '0')
                self.install_real(package, ok=False)
                self.assertIn(self.query(smoke, self.database), ['t', 'user'])

    def test_real_failure_rolls_back_objects(self):
        self.install_real('pg_permissions', env={'TEST_SQL_FAIL': '1'}, ok=False)
        self.assertEqual(self.query("select to_regnamespace('permissions') is null "
                                    "and to_regclass('public.installer_rollback_probe') is null;",
                                    self.database), 't')

    def test_real_existing_schema_preserved(self):
        self.query('create schema crdt; create table crdt.keep_me (id int); '
                   'insert into crdt.keep_me values (42);', self.database)
        self.install_real('pg_crdt', ok=False)
        self.assertEqual(self.query('select id from crdt.keep_me', self.database), '42')

    def test_real_shared_extensions_schema(self):
        self.query('set role app_owner; create schema extensions; '
                   'create function extensions.keep_me() returns int language sql as $$select 42$$;',
                   self.database)
        self.install_real('pg_idkit', '--version', '0.0.4')
        self.assertEqual(self.query('select extensions.keep_me()', self.database), '42')
        self.install_real('pg_idkit', ok=False)
        self.assertEqual(self.query("select to_regprocedure('extensions.gen_random_ulid()') is null;",
                                    self.database), 't')

    def test_real_unpermitted_role_is_rejected(self):
        self.install_real('pg_validate', '--role', 'postgres', ok=False)
        self.assertEqual(self.query("select to_regnamespace('validate') is null;", self.database), 't')

    def test_real_quoted_owner_and_saved_sql(self):
        role = 'owner"; select 1/0; --'
        self.query(f'grant create on database {self.database} to "owner""; select 1/0; --";', self.database)
        output = self.work / 'saved.sql'
        self.run_installer('pg_validate', '--role', role, '--output', str(output))
        self.query(output.read_text(), self.database)
        self.assertEqual(self.query("select pg_get_userbyid(nspowner) from pg_namespace "
                                    "where nspname='validate';", self.database), role)


if __name__ == '__main__':
    unittest.main()
