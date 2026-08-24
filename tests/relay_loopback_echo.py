"""Manual/integration-only loopback TCP echo endpoints for relay tunnel tests."""

from __future__ import annotations

import argparse
import socket
import threading


def serve(port: int) -> None:
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", port))
    listener.listen(4)
    print(f"echo_ready={port}", flush=True)
    while True:
        connection, _ = listener.accept()
        threading.Thread(target=echo, args=(connection,), daemon=True).start()


def echo(connection: socket.socket) -> None:
    with connection:
        while True:
            data = connection.recv(64 * 1024)
            if not data:
                return
            connection.sendall(data)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("ports", nargs="+", type=int)
    args = parser.parse_args()
    threads = [threading.Thread(target=serve, args=(port,), daemon=True) for port in args.ports]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()


if __name__ == "__main__":
    main()
