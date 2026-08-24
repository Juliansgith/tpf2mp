"""Manual/integration-only relay tunnel round-trip probe."""

from __future__ import annotations

import argparse
import socket


def round_trip(port: int, payload: bytes) -> bool:
    with socket.create_connection(("127.0.0.1", port), timeout=10) as connection:
        connection.sendall(payload)
        received = bytearray()
        while len(received) < len(payload):
            chunk = connection.recv(min(64 * 1024, len(payload) - len(received)))
            if not chunk:
                break
            received.extend(chunk)
    return bytes(received) == payload


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--gameplay-port", type=int, required=True)
    parser.add_argument("--save-port", type=int, required=True)
    args = parser.parse_args()
    gameplay = b'{"kind":"e2e","protocol":1}\n'
    save = bytes(range(256)) * 1024
    gameplay_ok = round_trip(args.gameplay_port, gameplay)
    save_ok = round_trip(args.save_port, save)
    print(f"gameplay_echo={str(gameplay_ok).lower()} bytes={len(gameplay)}")
    print(f"save_echo={str(save_ok).lower()} bytes={len(save)}")
    return 0 if gameplay_ok and save_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
