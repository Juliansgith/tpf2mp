from __future__ import annotations

import io
from pathlib import Path
import socket
import tempfile
import threading
import unittest
from unittest import mock

from tpf2mp.bridge import GameBridge
from tpf2mp.network import CommitHost
from tpf2mp.protocol import ProtocolError, encode_line, sign
from tpf2mp import transport


def shutdown(sock: socket.socket) -> None:
    try:
        sock.shutdown(socket.SHUT_RDWR)
    except OSError:
        pass


def fill_send_buffer(sock: socket.socket) -> None:
    sock.setblocking(False)
    try:
        for _ in range(1024):
            try:
                sock.send(b"x" * 65536)
            except BlockingIOError:
                return
        raise AssertionError("could not saturate the test socket")
    finally:
        sock.setblocking(True)


class TransportTests(unittest.TestCase):
    def test_frame_read_consumes_at_most_limit_plus_one(self) -> None:
        reader = io.BytesIO(b"x" * (transport.MAX_FRAME_BYTES + 100) + b"\n")
        with self.assertRaises(ProtocolError):
            transport.read_frame(reader)
        self.assertEqual(reader.tell(), transport.MAX_FRAME_BYTES + 1)

    def test_exact_limit_and_multiple_frames(self) -> None:
        message = sign({"data": ""})
        message["data"] = "x" * (transport.MAX_FRAME_BYTES - len(encode_line(message)))
        message = sign(message)
        following = sign({"next": True})
        reader = io.BytesIO(encode_line(message) + encode_line(following))
        self.assertEqual(transport.read_frame(reader), message)
        self.assertEqual(transport.read_frame(reader), following)
        with self.assertRaises(ConnectionError):
            transport.read_frame(reader)

    def test_oversize_live_frame_is_rejected_without_newline_or_eof(self) -> None:
        sender, receiver = socket.socketpair()
        reader = transport.SocketReader(receiver)
        completed = threading.Event()
        errors = []

        def read() -> None:
            try:
                transport.read_frame(reader)
            except BaseException as exc:
                errors.append(exc)
            finally:
                completed.set()

        worker = threading.Thread(target=read, daemon=True)
        try:
            # Use a small limit to exercise a live open stream without relying
            # on the OS receive buffer holding a multi-megabyte frame.
            with mock.patch.object(transport, "MAX_FRAME_BYTES", 1024):
                worker.start()
                sender.sendall(b"x" * 1025)
                self.assertTrue(completed.wait(1.5), "reader waited for newline/EOF")
            self.assertIsInstance(errors[0], ProtocolError)
        finally:
            shutdown(sender)
            shutdown(receiver)
            worker.join(2)
            reader.close()
            sender.close()
            receiver.close()

    def test_stalled_broadcast_releases_ordering_and_enters_reconnect(self) -> None:
        sender, receiver = socket.socketpair()
        sender.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4096)
        receiver.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
        fill_send_buffer(sender)
        completed = threading.Event()
        errors = []
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            host = CommitHost(GameBridge(root / "bridge", "stall-test", "player1"),
                              "127.0.0.1", 0, root / "audit.ndjson")
            host.peers["player2"] = transport.ConnectedPeer(
                "player2", sender, threading.Lock())

            def broadcast() -> None:
                try:
                    with host.order_lock:
                        host._broadcast({"data": "x" * (1024 * 1024)})
                except BaseException as exc:
                    errors.append(exc)
                finally:
                    completed.set()

            worker = threading.Thread(target=broadcast, daemon=True)
            try:
                with mock.patch.object(transport, "SEND_TIMEOUT_SECONDS", 0.15):
                    worker.start()
                    self.assertTrue(completed.wait(1.5), "host broadcast stayed blocked")
                self.assertEqual(errors, [])
                self.assertNotIn("player2", host.peers)
                self.assertIn("player2", host.reconnect.waiting)
                acquired = host.order_lock.acquire(timeout=0.5)
                self.assertTrue(acquired, "ordering lock remained held")
                if acquired:
                    host.order_lock.release()
            finally:
                shutdown(sender)
                shutdown(receiver)
                worker.join(2)
                sender.close()
                receiver.close()

    def test_write_deadline_wakes_reader_and_abandons_partial_frames(self) -> None:
        sender, receiver = socket.socketpair()
        sender.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4096)
        receiver.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
        fill_send_buffer(sender)
        reader = transport.SocketReader(sender)
        messages, errors = [], []
        read_done = threading.Event()

        def read() -> None:
            try:
                messages.append(transport.read_frame(reader))
                messages.append(transport.read_frame(reader))
            except BaseException as exc:
                errors.append(exc)
            finally:
                read_done.set()

        worker = threading.Thread(target=read, daemon=True)
        expected = [sign({"data": "fragmented"}), sign({"data": "next"})]
        wire = b"".join(encode_line(item) for item in expected)
        try:
            worker.start()
            # Pause between pieces while the receiver already has a partial
            # frame buffered and the opposite direction is backpressured.
            receiver.sendall(wire[:7])
            with mock.patch.object(transport, "SEND_TIMEOUT_SECONDS", 0.05):
                with self.assertRaises(TimeoutError):
                    transport.send(sender, {"data": "x" * (1024 * 1024)}, threading.Lock())
            self.assertTrue(read_done.wait(1), "expired send did not wake its reader")
            self.assertEqual(messages, [])
            self.assertTrue(errors, "partial input was treated as a complete frame")
            with self.assertRaises(OSError):
                transport.send(sender, sign({"next": True}))
        finally:
            shutdown(sender)
            shutdown(receiver)
            worker.join(2)
            reader.close()
            receiver.close()

    def test_fragmented_and_coalesced_frames_survive_concurrent_send(self) -> None:
        sender, receiver = socket.socketpair()
        reader = transport.SocketReader(sender)
        opposite_reader = transport.SocketReader(receiver)
        messages, errors = [], []
        completed = threading.Event()
        expected = [sign({"data": "fragmented"}), sign({"data": "next"})]
        wire = b"".join(encode_line(item) for item in expected)

        def read() -> None:
            try:
                messages.extend(transport.read_frame(reader) for _ in expected)
            except BaseException as exc:
                errors.append(exc)
            finally:
                completed.set()

        worker = threading.Thread(target=read, daemon=True)
        try:
            worker.start()
            receiver.sendall(wire[:7])
            outgoing = sign({"outgoing": True})
            transport.send(sender, outgoing, threading.Lock())
            self.assertEqual(transport.read_frame(opposite_reader), outgoing)
            receiver.sendall(wire[7:])
            self.assertTrue(completed.wait(1))
            self.assertEqual(errors, [])
            self.assertEqual(messages, expected)
        finally:
            shutdown(sender)
            shutdown(receiver)
            worker.join(2)
            reader.close()
            opposite_reader.close()

    def test_send_lock_wait_has_a_deadline_without_releasing_another_owner(self) -> None:
        sender, receiver = socket.socketpair()
        lock = threading.Lock()
        lock.acquire()
        try:
            with mock.patch.object(transport, "SEND_TIMEOUT_SECONDS", 0.05):
                with self.assertRaisesRegex(TimeoutError, "lock deadline"):
                    transport.send(sender, sign({"data": "queued"}), lock)
            self.assertTrue(lock.locked())
            receiver.settimeout(1)
            self.assertEqual(receiver.recv(1), b"")
        finally:
            lock.release()
            sender.close()
            receiver.close()

    def test_concurrent_partial_writes_do_not_interleave_frames(self) -> None:
        sender, receiver = socket.socketpair()
        reader = transport.SocketReader(receiver)
        lock = threading.Lock()
        received, errors = [], []

        class PartialWriter:
            def setblocking(self, value):
                sender.setblocking(value)

            def send(self, data):
                return sender.send(data[:257])

            def fileno(self):
                return sender.fileno()

            def shutdown(self, how):
                sender.shutdown(how)

        writer = PartialWriter()

        def write(producer):
            try:
                for sequence in range(10):
                    transport.send(writer, sign({"producer": producer, "seq": sequence,
                                                 "data": "x" * 4096}), lock)
            except BaseException as exc:
                errors.append(exc)

        def read():
            try:
                received.extend(transport.read_frame(reader) for _ in range(20))
            except BaseException as exc:
                errors.append(exc)

        workers = [threading.Thread(target=write, args=(producer,), daemon=True)
                   for producer in (1, 2)]
        workers.append(threading.Thread(target=read, daemon=True))
        try:
            for worker in workers:
                worker.start()
            for worker in workers:
                worker.join(3)
            self.assertFalse(any(worker.is_alive() for worker in workers))
            self.assertEqual(errors, [])
            self.assertEqual(len(received), 20)
            for producer in (1, 2):
                self.assertEqual([item["seq"] for item in received
                                  if item["producer"] == producer], list(range(10)))
        finally:
            shutdown(sender)
            shutdown(receiver)
            for worker in workers:
                worker.join(2)
            sender.close()
            reader.close()

    def test_failed_old_broadcast_does_not_remove_replacement_connection(self) -> None:
        sender, receiver = socket.socketpair()
        replacement, replacement_receiver = socket.socketpair()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            host = CommitHost(GameBridge(root / "bridge", "replace-test", "player1"),
                              "127.0.0.1", 0, root / "audit.ndjson")
            old = transport.ConnectedPeer("player2", sender, threading.Lock())
            new = transport.ConnectedPeer("player2", replacement, threading.Lock())
            host.peers["player2"] = old

            def replace_then_fail(*args) -> None:
                host.peers["player2"] = new
                raise TimeoutError("old connection expired")

            try:
                with mock.patch("tpf2mp.network._send", side_effect=replace_then_fail):
                    host._broadcast(sign({"data": "pending"}))
                self.assertIs(host.peers.get("player2"), new)
                self.assertNotIn("player2", host.reconnect.waiting)
                transport.send(replacement, sign({"data": "still connected"}))
                reader = transport.SocketReader(replacement_receiver)
                self.assertEqual(transport.read_frame(reader)["data"], "still connected")
            finally:
                sender.close()
                receiver.close()
                replacement.close()
                replacement_receiver.close()


if __name__ == "__main__":
    unittest.main()
