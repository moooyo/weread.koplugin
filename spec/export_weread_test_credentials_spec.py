"""Synthetic-only checks for the private cookie export command."""

from __future__ import annotations

import contextlib
import http.cookiejar
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/export_weread_test_credentials.py"
MODULE_SPEC = importlib.util.spec_from_file_location("cookie_export", SCRIPT)
EXPORTER = importlib.util.module_from_spec(MODULE_SPEC)
MODULE_SPEC.loader.exec_module(EXPORTER)
SECRET = "synthetic-private-cookie-never-log-this"
SETTINGS = 'return { cookies = { wr_skey = "' + SECRET + '", wr_vid = "12345" } }'


class ExportCredentialsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="weread-cookie-export-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "input.txt"
        self.output = self.root / "private.cookies"

    def command(self, flag: str = "--settings", *, output: Path | None = None) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(SCRIPT), flag, str(self.source), "--output", str(output or self.output)],
            capture_output=True, text=True, timeout=15,
        )

    def run_input(self, text: str, flag: str = "--settings", *, output: Path | None = None) -> subprocess.CompletedProcess:
        self.source.write_text(text, encoding="utf-8", newline="")
        return self.command(flag, output=output)

    def load_jar(self, path: Path | None = None) -> dict:
        jar = http.cookiejar.MozillaCookieJar()
        jar.load(str(path or self.output), ignore_discard=True, ignore_expires=True)
        return {cookie.name: cookie for cookie in jar}

    def assert_private_failure(self, result: subprocess.CompletedProcess) -> None:
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertNotIn(SECRET, result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_settings_export_only_top_level_cookies(self) -> None:
        source = '''return {
            api_key = "API-KEY-DO-NOT-EXPORT",
            account = { name = "PRIVATE-ACCOUNT", cookies = { hidden = "HIDDEN-COOKIE" } },
            cookies = { wr_skey = "%s", wr_vid = "12345", extra = "abc=def%%20ghi" },
            nested = { true, false, nil, - 3, .5, 2e3, 0x10, 0x1.fp2, [false] = { ok = true } },
        } -- trailing comment''' % SECRET
        result = self.run_input(source)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report, {"output": str(self.output.absolute()), "cookies": 3})
        self.assertNotIn(SECRET, result.stdout + result.stderr)
        jar = self.load_jar()
        self.assertEqual(set(jar), {"wr_skey", "wr_vid", "extra"})
        self.assertEqual(jar["wr_skey"].value, SECRET)
        for cookie in jar.values():
            self.assertEqual(cookie.domain, ".weread.qq.com")
            self.assertTrue(cookie.domain_initial_dot)
            self.assertTrue(cookie.secure)
            self.assertEqual(cookie.path, "/")
        exported = self.output.read_text(encoding="ascii")
        for value in ("API-KEY-DO-NOT-EXPORT", "PRIVATE-ACCOUNT", "HIDDEN-COOKIE"):
            self.assertNotIn(value, exported)

    def test_lua_escapes_comments_long_strings_and_bom(self) -> None:
        source = '\ufeff--[==[ cookies = { fake = "ignored" } ]==]\n' + r'''return {
            decoy = [==[ "cookies" = { wr_skey = "DECOY" }; os.execute("ignored") ]==],
            quoted = "quote\" slash\\ newline\n tab\t",
            ["\099ookies"] = {
                wr_skey = "prefix\065\x42\z
                    suffix",
                wr_vid = [=[
12345]=];
            },
        }; -- final comment'''
        result = self.run_input(source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.load_jar()["wr_skey"].value, "prefixABsuffix")
        self.assertEqual(self.load_jar()["wr_vid"].value, "12345")

    def test_long_string_newline_normalization(self) -> None:
        parsed = EXPORTER.LiteralParser("return { note = [=[\r\na\r\nb\n\rc\rd]=] }").parse()
        self.assertEqual(parsed.fields[("string", "note")], "a\nb\nc\nd")

    def test_executable_lua_is_rejected_without_execution(self) -> None:
        marker = self.root / "must-not-exist"
        call = 'os.execute("touch ' + str(marker) + '")'
        cases = [
            call + "; " + SETTINGS,
            SETTINGS + "; " + call,
            'return { cookies = ' + call + ' } -- ' + SECRET,
            'return { cookies = (function() ' + call + ' end)() } -- ' + SECRET,
            'local value = "' + SECRET + '"; ' + SETTINGS,
            'return { cookies = { wr_skey = "' + SECRET + '" .. "suffix", wr_vid = "1" } }',
            'return loadstring("' + SECRET + '")()',
        ]
        for index, source in enumerate(cases):
            with self.subTest(index=index):
                destination = self.root / f"invalid-{index}.cookies"
                result = self.run_input(source, output=destination)
                self.assert_private_failure(result)
                self.assertFalse(destination.exists())
                self.assertFalse(marker.exists())

    def test_missing_empty_or_invalid_cookie_values(self) -> None:
        cases = [
            'return { other = { cookies = { wr_skey = "' + SECRET + '", wr_vid = "1" } } }',
            'return { cookies = { wr_skey = "' + SECRET + '" } }',
            'return { cookies = { wr_skey = "", wr_vid = "12345" } }',
            'return { cookies = { wr_skey = true, wr_vid = "12345" } }',
            'return { cookies = { wr_skey = {}, wr_vid = "12345" } }',
        ]
        for source in cases:
            with self.subTest(source_kind=len(source)):
                self.assert_private_failure(self.run_input(source))
                self.assertFalse(self.output.exists())

    def test_cookie_control_characters_and_invalid_names_are_rejected(self) -> None:
        for escape in (r"\n", r"\r", r"\t", r"\0", r"\x00", r"\127", " ", ";", ","):
            source = 'return { cookies = { wr_skey = "' + SECRET + escape + '", wr_vid = "1" } }'
            with self.subTest(escape=escape):
                self.assert_private_failure(self.run_input(source))
        result = self.run_input('return { cookies = { ["bad\\tname"] = "' + SECRET
                                + '", wr_skey = "key", wr_vid = "1" } }')
        self.assert_private_failure(result)
        self.assertFalse(self.output.exists())

    def test_duplicate_keys_and_invalid_string_escapes_are_rejected(self) -> None:
        for source in (
            'return { cookies = {}, cookies = { wr_skey = "' + SECRET + '", wr_vid = "1" } }',
            r'return { cookies = { wr_skey = "\999", wr_vid = "1" } }',
            r'return { cookies = { wr_skey = "\x0Z", wr_vid = "1" } }',
            r'return { cookies = { wr_skey = "\q", wr_vid = "1" } }',
            'return { note = [==[ ' + SECRET,
        ):
            self.assert_private_failure(self.run_input(source))
        self.assertFalse(self.output.exists())

    def test_input_size_and_depth_limits(self) -> None:
        self.source.write_bytes(b"-" * (EXPORTER.MAX_SETTINGS_BYTES + 1))
        result = self.command()
        self.assert_private_failure(result)
        self.assertIn("16 MiB", result.stderr)
        within = "return { extra = " + "{" * 63 + "nil" + "}" * 63 + " }"
        EXPORTER.LiteralParser(within).parse()
        excessive = "return { extra = " + "{" * 64 + "nil" + "}" * 64 + " }"
        with self.assertRaises(EXPORTER.ExportError):
            EXPORTER.LiteralParser(excessive).parse()
        self.assertFalse(self.output.exists())

    def test_existing_output_is_never_overwritten_or_chmodded(self) -> None:
        self.output.write_text("previous-private-file", encoding="ascii")
        if os.name == "posix":
            self.output.chmod(0o640)
        previous_mode = stat.S_IMODE(self.output.stat().st_mode)
        self.assert_private_failure(self.run_input(SETTINGS))
        self.assertEqual(self.output.read_text(encoding="ascii"), "previous-private-file")
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), previous_mode)

    @unittest.skipUnless(os.name == "posix", "POSIX file modes are not Windows ACLs")
    def test_new_file_is_private(self) -> None:
        result = self.run_input(SETTINGS)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o600)

    @unittest.skipUnless(os.name == "posix", "Symbolic-link creation can require privileges on Windows")
    def test_existing_symlink_is_not_followed(self) -> None:
        target = self.root / "uncreated-target"
        self.output.symlink_to(target)
        self.assert_private_failure(self.run_input(SETTINGS))
        self.assertTrue(self.output.is_symlink())
        self.assertFalse(target.exists())

    def test_invalid_input_and_arguments_do_not_leak(self) -> None:
        self.source.write_bytes(b"\xff" + SECRET.encode("ascii"))
        self.assert_private_failure(self.command())
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--unknown", SECRET], capture_output=True, text=True, timeout=15,
        )
        self.assert_private_failure(result)

    def test_browser_cookie_header_and_optional_prefix(self) -> None:
        for index, prefix in enumerate(("", "Cookie: ", "cOoKiE: ")):
            with self.subTest(prefix=prefix):
                destination = self.root / f"browser-{index}.cookies"
                source = prefix + 'wr_skey=' + SECRET + '; wr_vid="12345"; extra=a=b%20c\r\n'
                result = self.run_input(source, "--cookie-header-file", output=destination)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn(SECRET, result.stdout + result.stderr)
                self.assertEqual(json.loads(result.stdout)["cookies"], 3)
                jar = self.load_jar(destination)
                self.assertEqual(jar["wr_skey"].value, SECRET)
                self.assertEqual(jar["wr_vid"].value, "12345")
                self.assertEqual(jar["extra"].value, "a=b%20c")

    def test_browser_headers_reject_injection_and_partial_parses(self) -> None:
        valid = "wr_skey=" + SECRET + "; wr_vid=12345"
        for suffix in ("\r\nX-Test: injected", "\nAuthorization: injected", "\t", "\x00", "\n\n",
                       "; invalid-tail", "; extra=a b", "; wr_vid=67890", "; Path=/", "; $Path=/"):
            with self.subTest(suffix=suffix):
                self.assert_private_failure(self.run_input(valid + suffix, "--cookie-header-file"))
                self.assertFalse(self.output.exists())
        self.assert_private_failure(self.run_input("Set-Cookie: " + valid, "--cookie-header-file"))

    def test_browser_header_requires_both_credentials(self) -> None:
        for source in ("", "wr_skey=" + SECRET, "wr_skey=; wr_vid=12345", "wr_vid=12345"):
            self.assert_private_failure(self.run_input(source, "--cookie-header-file"))
        self.assertFalse(self.output.exists())

    def test_input_modes_are_mutually_exclusive(self) -> None:
        self.source.write_text(SETTINGS, encoding="utf-8")
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--settings", str(self.source), "--cookie-header-file", str(self.source),
             "--output", str(self.output)], capture_output=True, text=True, timeout=15,
        )
        self.assert_private_failure(result)
        self.assertFalse(self.output.exists())

    def test_write_failure_removes_partial_file_and_hides_exception(self) -> None:
        self.source.write_text(SETTINGS, encoding="utf-8")

        class FailingTarget:
            def __init__(self, descriptor: int) -> None:
                self.descriptor = descriptor

            def __enter__(self):
                return self

            def write(self, value: str) -> None:
                raise OSError(SECRET)

            def __exit__(self, *args) -> None:
                os.close(self.descriptor)

        output, errors = io.StringIO(), io.StringIO()
        with mock.patch.object(EXPORTER.os, "fdopen", side_effect=lambda descriptor, *a, **k: FailingTarget(descriptor)):
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
                result = EXPORTER.main(["--settings", str(self.source), "--output", str(self.output)])
        self.assertNotEqual(result, 0)
        self.assertEqual(output.getvalue(), "")
        self.assertNotIn(SECRET, errors.getvalue())
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
