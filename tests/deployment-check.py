#!/usr/bin/env python3
"""Run the deployment role against disposable local source, state and HTTP fixtures.

Git, files, commands, HTTP requests and Ansible failure handling run normally.
Only package installation, systemd and privileged file ownership are adapted;
no host service, external endpoint, inventory or credential is used.
"""

import getpass
import grp
import http.server
import json
import os
from pathlib import Path
import shutil
import socketserver
import sqlite3
import ssl
import subprocess
import sys
import tempfile
import threading
import unittest

import yaml


ROOT = Path(__file__).resolve().parent.parent
ANSIBLE = shutil.which("ansible-playbook") or str(
    Path(sys.executable).with_name("ansible-playbook")
)
HOST = "website.fixture.invalid"
MANAGE = '''import json, os, pathlib, sqlite3, sys
root = pathlib.Path(__file__).resolve().parent
step = sys.argv[1]
if step in ('migrate', 'collectstatic'):
    assert os.environ.get('JENGASEC_DB_NAME') == 'selected_fixture_database'
    assert os.environ.get('JENGASEC_DB_URL') == os.environ.get('FIXTURE_EXPECT_DB_URL', '')
    assert os.environ.get('JENGASEC_DB_PASSWORD') == 'fixture password with spaces'
    assert os.environ.get('JENGASEC_DB_SSLMODE') == 'verify-full'
    assert os.environ.get('FIXTURE_LABEL') == 'Fixture Mailer <fixture@example.invalid>'
    print(os.environ['FIXTURE_SECRET'])
with (root / 'state/operations').open('a') as log:
    log.write(step + '\\n')
if step == 'migrate':
    with sqlite3.connect(os.environ.get('FIXTURE_DATABASE_PATH', root / 'db.sqlite3')) as db:
        db.execute('CREATE TABLE IF NOT EXISTS forward_migration (id INTEGER PRIMARY KEY)')
        db.execute('INSERT OR IGNORE INTO forward_migration VALUES (1)')
elif step == 'collectstatic':
    (root / 'static/new.asset.js').write_text('new asset')
    (root / 'static/staticfiles.json').write_text(json.dumps({'version': 'new'}))
if (root / 'state/fail-step').read_text().strip() == step:
    sys.exit('injected ' + step + ' failure after its state change')
print('completed ' + step)
'''


class HealthHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.server.requests.append((self.path, self.headers.get("Host")))
        mode = self.server.mode
        status, body, content_type = 200, b'{"status":"ok","database":"ok"}', "application/json"
        if self.headers.get("Host") != HOST:
            status, body = 400, b'{"status":"wrong host"}'
        elif mode == "unhealthy":
            status, body = 503, b'{"status":"unhealthy","database":"unavailable"}'
        elif mode == "html":
            body, content_type = b"<html>Unrelated default page</html>", "text/html"
        elif mode == "wrong_json":
            body = b'{"status":"ok","database":"unavailable"}'
        elif mode == "redirect":
            status, body = 302, b""
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        if mode == "redirect":
            self.send_header("Location", self.server.redirect_url)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        if not Path(ANSIBLE).is_file():
            self.fail("ansible-playbook is required; install ansible-core to run this check")
        temporary = tempfile.TemporaryDirectory(prefix="deployment-check-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.environment = os.environ.copy()
        self.environment.update({
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
            "JENGASEC_DB_URL": "postgresql://inherited.invalid/wrong_database",
        })
        self.repo = self.root / "source"
        self.checkout = self.root / "application"
        self.repo.mkdir()
        self.git(self.repo, "init", "--initial-branch=main")
        (self.repo / ".gitignore").write_text("state/\nmedia/\nstatic/\n__pycache__/\n")
        (self.repo / "manage.py").write_text(MANAGE)
        (self.repo / "requirements.txt").write_text("# Local fixture; pip is not run.\n")
        for version in ("v1", "v2", "v3"):
            (self.repo / "version").write_text(version)
            self.git(self.repo, "add", ".")
            self.git(self.repo, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                     "commit", "--no-gpg-sign", "-qm", version)
            self.git(self.repo, "tag", version)
        self.git(self.root, "clone", "--branch", "v1", str(self.repo), str(self.checkout))
        for directory in ("state", "media", "static"):
            (self.checkout / directory).mkdir()
        self.state = self.checkout / "state"
        self.database = self.state / "database.sqlite3"
        self.env_file = self.root / ".env"
        self.secret_canary = "fixture-sensitive-output-must-stay-redacted"
        self.env_file.write_text(
            "JENGASEC_DB_NAME=selected_fixture_database\n"
            "JENGASEC_DB_HOST=database.fixture.invalid\n"
            "JENGASEC_DB_USER=fixture\n"
            "JENGASEC_DB_PASSWORD=fixture password with spaces\n"
            "JENGASEC_DB_SSLMODE=verify-full\n"
            "FIXTURE_LABEL=Fixture Mailer <fixture@example.invalid>\n"
            f"FIXTURE_DATABASE_PATH={self.database}\n"
            f"FIXTURE_SECRET={self.secret_canary}\n"
        )
        self.env_file.chmod(0o600)
        with sqlite3.connect(self.database) as db:
            db.execute("CREATE TABLE retained_state (kind TEXT PRIMARY KEY, payload TEXT)")
            db.executemany("INSERT INTO retained_state VALUES (?, ?)", [
                ("score", "awarded score"), ("revision", "immutable previous revision"),
                ("policy", "frozen scoring policy"), ("ack", "pending acknowledgement"),
            ])
        (self.state / "fail-step").write_text("")
        self.protected_files = {
            self.checkout / "media/proof.bin": b"private archived proof",
            self.checkout / "static/old.asset.js": b"previous asset",
            self.state / "outbox.json": b'{"unacknowledged":[1,2]}',
        }
        for path, content in self.protected_files.items():
            path.write_bytes(content)
        self.previous_rows = self.retained_rows()
        self.release_log = self.state / "releases.log"
        self.release_log.write_text("previous successful release\n")
        self.maintenance = self.root / "maintenance.html"
        venv_bin = self.root / "venv/bin"
        venv_bin.mkdir(parents=True)
        (venv_bin / "python").symlink_to(sys.executable)

        self.socket = self.root / "application.sock"
        self.application = self.serve(socketserver.UnixStreamServer, str(self.socket))
        self.control = self.serve(http.server.HTTPServer, ("127.0.0.1", 0))
        self.control.mode = "html"
        self.origin = f"http://127.0.0.1:{self.control.server_port}/healthz/"
        self.application.redirect_url = self.origin
        self.prepare_role()
        self.variables = {
            "ansible_connection": "local", "ansible_become": False,
            "ansible_python_interpreter": sys.executable,
            "ansible_date_time": {"iso8601": "2026-01-01T00:00:00Z"},
            "app_repo_url": str(self.repo), "app_group": grp.getgrgid(os.getgid()).gr_name,
            "deployment_user": getpass.getuser(), "deployment_source_dir": str(self.checkout),
            "deployment_env_file": str(self.env_file),
            "deployment_state_dir": str(self.state), "deployment_venv_dir": str(venv_bin.parent),
            "deployment_revision": "v2", "deployment_log_to_journal": False,
            "deployment_maintenance_page": True, "deployment_maintenance_file": str(self.maintenance),
            "deployment_healthcheck_host": HOST, "deployment_healthcheck_unix_socket": str(self.socket),
            # The socket must win even if the URL or proxy reaches a default listener.
            "deployment_healthcheck_url": self.origin, "deployment_healthcheck_retries": 1,
            "deployment_healthcheck_delay": 0, "deployment_healthcheck_timeout": 2,
        }

    def serve(self, server_class, address, tls=None):
        server = server_class(address, HealthHandler)
        if tls:
            server.socket = tls.wrap_socket(server.socket, server_side=True)
        server.mode, server.requests = "healthy", []
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        thread.start()

        def close():
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

        self.addCleanup(close)
        return server

    def git(self, cwd, *arguments):
        return subprocess.run(["git", *arguments], cwd=cwd, env=self.environment,
                              check=True, text=True, capture_output=True).stdout.strip()

    def prepare_role(self):
        role = self.root / "roles/deployment"
        shutil.copytree(ROOT / "roles/deployment", role)
        task_file = role / "tasks/main.yml"
        tasks = yaml.safe_load(task_file.read_text())

        def isolate(items):
            for task in items:
                for child in ("block", "rescue", "always"):
                    isolate(task.get(child, []))
                for module, step in (("ansible.builtin.systemd", "reload"),
                                     ("ansible.builtin.pip", "install_requirements")):
                    if module in task:
                        del task[module]
                        task["ansible.builtin.command"] = {
                            "argv": [sys.executable, "manage.py", step], "chdir": str(self.checkout),
                        }
                if "ansible.builtin.template" in task:
                    task["ansible.builtin.template"].update({
                        "owner": getpass.getuser(), "group": grp.getgrgid(os.getgid()).gr_name,
                    })

        isolate(tasks)
        task_file.write_text(yaml.safe_dump(tasks, sort_keys=False))
        (self.root / "ansible.cfg").write_text(
            "[defaults]\nstdout_callback=default\nretry_files_enabled=False\n"
            "fact_caching=memory\ninterpreter_python=auto_silent\n"
        )
        self.environment.update({
            "ANSIBLE_CONFIG": str(self.root / "ansible.cfg"),
            "ANSIBLE_LOCAL_TEMP": str(self.root / ".ansible"),
            "ANSIBLE_NOCOLOR": "1", "PYTHONDONTWRITEBYTECODE": "1",
        })

    def deploy(self, *, tags=None, **overrides):
        variables = dict(self.variables, **overrides)
        playbook = self.root / "deploy.yml"
        playbook.write_text(yaml.safe_dump([{
            "hosts": "localhost", "gather_facts": False, "vars": variables,
            "environment": {"http_proxy": self.origin, "https_proxy": self.origin, "no_proxy": ""},
            "roles": ["deployment"],
        }], sort_keys=False))
        command = [ANSIBLE, "-i", "localhost,", str(playbook)]
        if tags:
            command += ["--tags", ",".join(tags)]
        result = subprocess.run(command, cwd=self.root, env=self.environment,
                                capture_output=True, text=True, timeout=60)
        self.assertNotIn(self.secret_canary, result.stdout + result.stderr)
        self.assertFalse((self.checkout / "db.sqlite3").exists())
        return result

    def retained_rows(self):
        with sqlite3.connect(self.database) as db:
            return db.execute("SELECT * FROM retained_state ORDER BY kind").fetchall()

    def assert_retained(self):
        self.assertEqual(self.previous_rows, self.retained_rows())
        for path, content in self.protected_files.items():
            self.assertEqual(content, path.read_bytes(), str(path))

    def assert_failed_release(self, result):
        self.assertNotEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("DEPLOYMENT FAILED", result.stdout, result.stdout + result.stderr)
        self.assertIn("compatible versioned correction", result.stdout)
        self.assertEqual("v2", (self.checkout / "version").read_text())
        self.assertTrue(self.maintenance.is_file())
        self.assertEqual("previous successful release\n", self.release_log.read_text())
        self.assert_retained()

    def test_failed_health_preserves_state_then_forward_correction_succeeds(self):
        self.application.mode = "unhealthy"
        self.assert_failed_release(self.deploy())
        self.assertEqual([], self.control.requests)
        self.assertTrue(all(request == ("/healthz/", HOST) for request in self.application.requests))
        self.assertGreaterEqual(len(self.application.requests), 2)
        self.assertEqual("new asset", (self.checkout / "static/new.asset.js").read_text())
        with sqlite3.connect(self.database) as db:
            self.assertEqual([(1,)], db.execute("SELECT * FROM forward_migration").fetchall())

        self.application.mode = "healthy"
        result = self.deploy(deployment_revision="v3")
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual("v3", (self.checkout / "version").read_text())
        self.assertFalse(self.maintenance.exists())
        self.assertIn("v3", self.release_log.read_text())
        self.assertEqual([], self.control.requests)
        self.assert_retained()

    def test_html_wrong_json_and_redirect_are_failures(self):
        for mode in ("html", "wrong_json", "redirect"):
            with self.subTest(mode=mode):
                self.application.mode = mode
                self.assert_failed_release(self.deploy())
                self.assertEqual([], self.control.requests)

    def test_failed_requirements_migration_static_and_reload_preserve_progress(self):
        for step in ("install_requirements", "migrate", "collectstatic", "reload"):
            with self.subTest(step=step):
                (self.state / "fail-step").write_text(step)
                self.assert_failed_release(self.deploy())
                operations = (self.state / "operations").read_text().splitlines()
                self.assertEqual(step, operations[-1])
                if step in ("migrate", "collectstatic", "reload"):
                    with sqlite3.connect(self.database) as db:
                        self.assertEqual([(1,)], db.execute("SELECT * FROM forward_migration").fetchall())
                if step in ("collectstatic", "reload"):
                    self.assertEqual({"version": "new"}, json.loads(
                        (self.checkout / "static/staticfiles.json").read_text()))
                self.assertEqual([], self.application.requests)

    def test_explicit_tcp_origin_requires_application_json_and_host(self):
        self.assert_failed_release(self.deploy(deployment_healthcheck_unix_socket=""))
        self.control.mode = "healthy"
        self.assert_failed_release(self.deploy(deployment_healthcheck_unix_socket="",
                                              deployment_healthcheck_host="wrong.fixture.invalid"))
        result = self.deploy(deployment_healthcheck_unix_socket="")
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual([], self.application.requests)
        self.assertEqual(("/healthz/", HOST), self.control.requests[-1])
        self.assert_retained()

    def test_legacy_automatic_rollback_is_refused_before_mutation(self):
        result = self.deploy(deployment_rollback_on_failure=True)
        self.assertNotEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("Automatic release rollback is no longer supported", result.stdout)
        self.assertEqual("v1", (self.checkout / "version").read_text())
        self.assertFalse(self.maintenance.exists())
        self.assertFalse((self.state / "operations").exists())
        self.assert_retained()

    def test_missing_empty_or_incomplete_environment_stops_before_checkout(self):
        for content in (None, "", "DJANGO_DEBUG=False\n", "JENGASEC_DB_NAME=missing_host_and_user\n"):
            with self.subTest(content=content):
                if content is None:
                    self.env_file.unlink()
                else:
                    self.env_file.write_text(content)
                result = self.deploy()
                self.assertNotEqual(0, result.returncode, result.stdout + result.stderr)
                self.assertEqual("v1", (self.checkout / "version").read_text())
                self.assertFalse((self.state / "operations").exists())
                self.assert_retained()

    def test_selected_migration_tag_still_fails_and_preserves_maintenance(self):
        (self.state / "fail-step").write_text("migrate")
        result = self.deploy(tags=["migrate"])
        self.assertNotEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("DEPLOYMENT FAILED", result.stdout)
        self.assertTrue(self.maintenance.is_file())
        self.assertEqual("v1", (self.checkout / "version").read_text())
        self.assertEqual(["migrate"], (self.state / "operations").read_text().splitlines())
        with sqlite3.connect(self.database) as db:
            self.assertEqual([(1,)], db.execute("SELECT * FROM forward_migration").fetchall())
        self.assert_retained()

    def test_https_requires_trust_and_accepts_an_explicit_ca(self):
        cert, key = self.root / "fixture-ca.pem", self.root / "fixture-key.pem"
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
            "-keyout", str(key), "-out", str(cert), "-subj", "/CN=deployment-fixture",
            "-addext", "subjectAltName=IP:127.0.0.1",
        ], check=True, capture_output=True, timeout=15)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        server = self.serve(http.server.HTTPServer, ("127.0.0.1", 0), tls=context)
        url = f"https://127.0.0.1:{server.server_port}/healthz/"
        self.assert_failed_release(self.deploy(deployment_healthcheck_unix_socket="",
                                              deployment_healthcheck_url=url))
        self.assertEqual([], server.requests)
        result = self.deploy(deployment_healthcheck_unix_socket="", deployment_healthcheck_url=url,
                             deployment_healthcheck_ca_path=str(cert))
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual([("/healthz/", HOST)], server.requests)
        self.assertEqual([], self.control.requests)
        self.assert_retained()

    def test_selected_database_url_and_connection_options_are_preserved(self):
        url = "postgresql://fixture@database.fixture.invalid/selected?sslmode=verify-full"
        with self.env_file.open("a") as stream:
            stream.write(f"JENGASEC_DB_URL={url}\nFIXTURE_EXPECT_DB_URL={url}\n")
        result = self.deploy(tags=["migrate"])
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual(["migrate"], (self.state / "operations").read_text().splitlines())
        self.assert_retained()


if __name__ == "__main__":
    unittest.main(verbosity=2)
