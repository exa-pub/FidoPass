#!/usr/bin/env python3
"""Exercise the packaged OpenSK helper from outside the checkout, without a physical key."""
import pathlib
import select
import struct
import subprocess
import sys
import tempfile
import time


def read_exact(stream, count, deadline):
    result = bytearray()
    while len(result) < count:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([stream], [], [], remaining)[0]:
            raise RuntimeError('Packaged OpenSK helper timed out')
        chunk = stream.read(count - len(result))
        if not chunk:
            raise RuntimeError('Packaged OpenSK helper exited unexpectedly')
        result.extend(chunk)
    return bytes(result)


def exchange(process, opcode, request_id, payload):
    header = struct.pack('>BBQ', 2, opcode, request_id)
    process.stdin.write(struct.pack('>I', len(header) + len(payload)) + header + payload)
    process.stdin.flush()
    deadline = time.monotonic() + 5
    size, = struct.unpack('>I', read_exact(process.stdout, 4, deadline))
    if not 10 <= size <= 65536:
        raise RuntimeError('Invalid helper frame size')
    reply = read_exact(process.stdout, size, deadline)
    if reply[:10] != header:
        raise RuntimeError('Helper protocol/header mismatch')
    return reply[10:]


def main():
    app = pathlib.Path(sys.argv[1]).resolve()
    helper = app / 'Contents/Helpers/fidopass-test-authenticator'
    with tempfile.TemporaryDirectory() as directory:
        process = subprocess.Popen([str(helper)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, env={}, cwd=directory, bufsize=0)
        try:
            seed_and_settings = bytes([42]) * 32 + bytes([0, 0, 0]) + struct.pack('>I', 5000)
            if exchange(process, 0, 1, seed_and_settings):
                raise RuntimeError('Unexpected initialization reply')
            info = exchange(process, 1, 2, bytes([4]))
            if len(info) < 2 or info[0] != 0:
                raise RuntimeError('Packaged OpenSK getInfo failed')
            # Parent EOF must also terminate a helper blocked in the watchdog fixture.
            header = struct.pack('>BBQ', 2, 7, 3)
            process.stdin.write(struct.pack('>I', len(header)) + header)
            process.stdin.close()
            if process.wait(timeout=2) != 0:
                raise RuntimeError('Helper failed on parent EOF')
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()
            process.stdout.close()
            if not process.stdin.closed:
                process.stdin.close()
    print('Packaged OpenSK: initialization, CTAP getInfo and parent-EOF cleanup passed')


if __name__ == '__main__':
    main()
