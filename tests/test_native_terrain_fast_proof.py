"""Drive the offline native terrain fast-path proofs from the Python suite.

tests/native_terrain_fast/{align,refine,minmax,material}_proof.py run Build
35924's TransportFever2.exe machine code inside their own process (mapping the
image, or copying a self-contained routine) and compare it with the
replacements exported by tpf2mp_hook_build35924.dll. They need
numpy, capstone, pefile, the game executable and a built DLL, so each proof
runs as its own subprocess and is skipped unless the environment provides
both TPF2MP_GAME_EXECUTABLE and the hook DLL (TPF2MP_NATIVE_HOOK_DLL, else
runtime/native-build/Release). Only the standard library is imported here.
"""
import os
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROOFS = ROOT / "tests" / "native_terrain_fast"
SCRIPTS = ("align_proof.py", "refine_proof.py", "minmax_proof.py", "material_proof.py")
DEFAULT_DLL = ROOT / "runtime" / "native-build" / "Release" / "tpf2mp_hook_build35924.dll"
TIMEOUT = 600


class NativeTerrainFastProofTests(unittest.TestCase):
    def proof(self, name):
        executable = os.environ.get("TPF2MP_GAME_EXECUTABLE")
        if not executable or not Path(executable).is_file():
            self.skipTest("set TPF2MP_GAME_EXECUTABLE to Build 35924 TransportFever2.exe "
                          "for the native original-code proofs")
        dll = Path(os.environ.get("TPF2MP_NATIVE_HOOK_DLL") or DEFAULT_DLL)
        if not dll.is_file():
            self.skipTest(f"build {dll} or set TPF2MP_NATIVE_HOOK_DLL "
                          "for the native original-code proofs")
        result = subprocess.run([sys.executable, str(PROOFS / name),
                                 "--exe", executable, "--dll", str(dll)],
                                capture_output=True, text=True, timeout=TIMEOUT)
        if result.returncode != 0:
            tail = "\n".join(((result.stdout or "") + (result.stderr or "")).splitlines()[-30:])
            self.fail(f"{name} exited {result.returncode}\n{tail}")

    def test_terrain_align_fast_matches_original(self):
        self.proof("align_proof.py")

    def test_terrain_refine_matches_original(self):
        self.proof("refine_proof.py")

    def test_terrain_minmax_matches_original(self):
        self.proof("minmax_proof.py")

    def test_material_index_matches_original(self):
        self.proof("material_proof.py")

    def test_proof_scripts_target_the_tpf2mp_exports(self):
        for name in SCRIPTS:
            script = PROOFS / name
            with self.subTest(script=name):
                self.assertTrue(script.is_file(), script)
                self.assertIn("TPF2MP_TerrainFastTest", script.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
