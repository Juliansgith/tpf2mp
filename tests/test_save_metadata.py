from pathlib import Path
import contextlib
import io
import json
import tempfile
import unittest
from unittest.mock import patch

from tpf2mp.save_metadata import MetadataError, inspect_save_directory, validate_metadata
from tpf2mp.recovery import write_recovery_archive


class SaveMetadataTests(unittest.TestCase):
    def test_browser_diagnostic_cli_reports_unsupported_data_without_blocking(self):
        from tpf2mp.cli import main
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "suspect.sav.lua").write_bytes(b"function data() return {} end = 0,")
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(main(["inspect-save-directory", str(root)]), 0)
            report = json.loads(output.getvalue())
            self.assertTrue(report["complete"])
            self.assertEqual(report["issues"][0]["file"], "suspect.sav.lua")

    def test_browser_scan_reports_oversized_metadata_without_reading_it(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "large.sav.lua").write_bytes(b"x" * 16)
            with patch("tpf2mp.save_metadata.MAX_METADATA_BYTES", 8):
                report = inspect_save_directory(root)
            self.assertEqual(report["bytesRead"], 0)
            self.assertIn("per-file limit", report["issues"][0]["reason"])

    def test_browser_scan_finds_bad_unselected_save_without_changing_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            contents = {"selected.sav.lua": b"function data() return {} end",
                        "old-crash.sav.lua": b"function data() return {} end\n = 0,",
                        "empty.sav.lua": b"", "world.sav": b"untouched-binary",
                        "unrelated.lua": b"not save metadata"}
            for name, raw in contents.items():
                (root / name).write_bytes(raw)
            validate_metadata(root / "selected.sav")
            report = inspect_save_directory(root)
            self.assertTrue(report["complete"])
            self.assertEqual(report["checked"], 3)
            self.assertEqual([item["file"] for item in report["issues"]],
                             ["empty.sav.lua", "old-crash.sav.lua"])
            self.assertEqual({p.name: p.read_bytes() for p in root.iterdir()}, contents)

    def test_browser_scan_is_nonrecursive_and_does_not_execute_lua(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "subdir").mkdir()
            (root / "subdir" / "hidden.sav.lua").write_bytes(b"broken")
            (root / "mod.sav.lua").write_text('function data() return os.execute("bad") end')
            report = inspect_save_directory(root)
            self.assertEqual(report["checked"], 1)
            self.assertEqual(report["issues"][0]["file"], "mod.sav.lua")

    def test_browser_scan_limits_are_not_reported_as_clean_complete_scans(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "test.sav.lua").write_text("function data() return {} end")
            for limit in ("MAX_SCAN_FILES", "MAX_SCAN_BYTES", "MAX_SCAN_SECONDS"):
                with self.subTest(limit=limit), patch("tpf2mp.save_metadata." + limit, 0):
                    report = inspect_save_directory(root)
                    self.assertFalse(report["complete"])
                    self.assertTrue(report["limits"])

    def test_browser_scan_rejects_non_utf8_and_missing_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "bad.sav.lua").write_bytes(b"\xff")
            self.assertEqual(len(inspect_save_directory(root)["issues"]), 1)
            with self.assertRaises(OSError):
                inspect_save_directory(root / "missing")

    def check(self, text):
        with tempfile.TemporaryDirectory() as directory:
            save = Path(directory) / "world.sav"
            sidecar = Path(str(save) + ".lua")
            sidecar.write_bytes(text.encode("utf-8"))
            before = sidecar.read_bytes()
            try:
                validate_metadata(save)
            finally:
                self.assertEqual(sidecar.read_bytes(), before)

    def test_native_data_literals_and_escaped_names(self):
        self.check('''function data()
return { ["tpf2_mp.lua"] = { enabled=true, count=-2, time=1.2e-5,
 [1] = { "quoted\\\"text", false, nil, }, empty={}, }, }
end
-- retained comment
''')

    def test_reproduced_crash_save_trailing_fragment_is_rejected(self):
        with self.assertRaisesRegex(MetadataError, "unexpected content"):
            self.check('function data() return { state={} } end\n = 0,\n recipeDigest="41b68bfc",')

    def test_native_infinity_and_escaped_multiline_diagnostics(self):
        self.check('function data() return { min=inf, max=-inf, value=nan, '
                   'error="first\\\nsecond\\\r\nthird" } end')

    def test_empty_truncated_or_invalid_data_is_rejected(self):
        for text in ('', 'function data() return {', 'function data() return {}',
                     'function data() return { value= } end',
                     'function data() return { end=1 } end'):
            with self.subTest(text=text), self.assertRaises(MetadataError):
                self.check(text)

    def test_metadata_is_never_executed(self):
        for text in ('function data() return { x=os.execute("bad") } end',
                     'function data() return {} end os.execute("bad")'):
            with self.assertRaises(MetadataError):
                self.check(text)

    def test_depth_is_bounded(self):
        with self.assertRaisesRegex(MetadataError, "nesting limit"):
            self.check('function data() return ' + '{' * 130 + '}' * 130 + ' end')

    def test_missing_non_utf8_and_oversized_metadata_fail_cleanly(self):
        with tempfile.TemporaryDirectory() as directory:
            save = Path(directory) / "world.sav"
            with self.assertRaisesRegex(MetadataError, "original files were not changed"):
                validate_metadata(save)
            metadata = Path(str(save) + ".lua")
            metadata.write_bytes(b"\xff")
            with self.assertRaises(MetadataError):
                validate_metadata(save)
            metadata.write_bytes(b"function data() return {} end")
            with patch("tpf2mp.save_metadata.MAX_METADATA_BYTES", 8):
                with self.assertRaisesRegex(MetadataError, "exceeds"):
                    validate_metadata(save)
            self.assertEqual(metadata.read_bytes(), b"function data() return {} end")

    def test_damaged_archive_is_not_published_and_source_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            save = root / "world.sav"
            save.write_bytes(b"native-world")
            metadata = Path(str(save) + ".lua")
            damaged = b"function data() return {} end\n = 0,"
            metadata.write_bytes(damaged)
            with self.assertRaises(MetadataError):
                write_recovery_archive(save, root / "archive", "save-check", "player1")
            self.assertFalse((root / "archive").exists())
            self.assertEqual(save.read_bytes(), b"native-world")
            self.assertEqual(metadata.read_bytes(), damaged)


if __name__ == "__main__":
    unittest.main()
