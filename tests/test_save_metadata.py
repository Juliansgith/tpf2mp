from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from tpf2mp.save_metadata import MetadataError, validate_metadata
from tpf2mp.recovery import write_recovery_archive


class SaveMetadataTests(unittest.TestCase):
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
