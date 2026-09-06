import ctypes
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'tools'))
from live_ui.runner import write_json


class FileHandoffTests(unittest.TestCase):
    def test_transient_reader_lock_retries_same_payload_and_nonce(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'request.json'
            path.write_text('{"id":"old"}')
            original=Path.replace; attempts=[]
            def replace(source, target):
                attempts.append(source.read_bytes())
                if len(attempts)<3:
                    self.assertEqual(json.loads(path.read_text())['id'],'old')
                    raise PermissionError('reader has not closed yet')
                return original(source,target)
            with patch.object(Path,'replace',replace), patch('live_ui.runner.time.sleep') as sleep:
                write_json(path,{'id':'new-nonce','action':'observe'})
            self.assertEqual(len(attempts),3); self.assertEqual(sleep.call_count,2)
            self.assertEqual(len(set(attempts)),1)
            self.assertEqual(json.loads(path.read_text())['id'],'new-nonce')
            self.assertFalse(path.with_suffix('.json.tmp').exists())

    def test_persistent_permission_error_is_bounded_and_preserves_old_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'request.json'; path.write_text('old')
            with patch.object(Path,'replace',side_effect=PermissionError('denied')) as replace, \
                 patch('live_ui.runner.time.sleep') as sleep:
                with self.assertRaises(PermissionError): write_json(path,{'id':'same'})
            self.assertEqual(replace.call_count,81); self.assertEqual(sleep.call_count,80)
            self.assertEqual(path.read_text(),'old')

    def test_unrelated_io_failure_is_not_retried(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(Path,'replace',side_effect=FileNotFoundError('directory gone')) as replace, \
                 patch('live_ui.runner.time.sleep') as sleep:
                with self.assertRaises(FileNotFoundError): write_json(Path(directory)/'x.json',{})
            self.assertEqual(replace.call_count,1); sleep.assert_not_called()

    @unittest.skipUnless(os.name=='nt','Windows sharing semantics')
    def test_real_windows_reader_without_delete_sharing(self):
        from ctypes import wintypes as W
        kernel=ctypes.WinDLL('kernel32',use_last_error=True)
        kernel.CreateFileW.argtypes=[W.LPCWSTR,W.DWORD,W.DWORD,ctypes.c_void_p,W.DWORD,W.DWORD,W.HANDLE]
        kernel.CreateFileW.restype=W.HANDLE
        kernel.CloseHandle.argtypes=[W.HANDLE]
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'request.json'; path.write_text('{"id":"old"}')
            handle=kernel.CreateFileW(str(path),0x80000000,1,None,3,0x80,None)
            self.assertNotEqual(handle,ctypes.c_void_p(-1).value)
            timer=threading.Timer(.15,lambda:kernel.CloseHandle(handle)); timer.start()
            try:
                write_json(path,{'id':'new'})
                self.assertEqual(json.loads(path.read_text())['id'],'new')
            finally: timer.join()


if __name__=='__main__': unittest.main()
