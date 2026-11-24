#!/usr/bin/env python3
"""load.py — send a program to the rv-ai-lab bootloader (sw/boot.c), then talk to it.

    make load PROG=talk [PORT=/dev/ttyUSB0]
    python3 tools/load.py /dev/ttyUSB0 build/load/talk.bin [--now] [--no-term]

1. Asks you to press KEY[0] (reset) and waits for the bootloader's "boot: ready".
   (--now skips this: the bootloader is already waiting.)
2. Sends the frame sw/boot.c expects: "RVLD", the length and the CRC-32 of the
   image as little-endian words around the image itself.
3. Waits for the answer line: "boot: ok" or what went wrong.
4. Becomes a terminal (unless --no-term): what the program prints appears here,
   what you type goes to it (Enter sends CR, Backspace 0x7F, as picocom does).
   Ctrl+] quits. Staying on the same open port means nothing the program
   prints right after starting is lost.

Standard library only (termios): no pyserial needed.
"""
import os
import select
import struct
import sys
import termios
import time
import tty
import zlib

BAUD = termios.B115200
QUIT = b"\x1d"                                  # Ctrl+]


def open_port(dev):
    """The serial port, raw 8N1 at 115200, no flow control, input flushed."""
    fd = os.open(dev, os.O_RDWR | os.O_NOCTTY)
    a = termios.tcgetattr(fd)
    a[0] = 0                                    # iflag: no translation of input
    a[1] = 0                                    # oflag: no translation of output
    a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL   # 8N1, ignore modem lines
    a[3] = 0                                    # lflag: raw, no echo
    a[4] = a[5] = BAUD
    a[6][termios.VMIN] = 0
    a[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, a)
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def read_line(fd, timeout):
    """One line from the board (without the newline), or None on timeout."""
    buf = b""
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            c = os.read(fd, 1)
            if c == b"\n":
                return buf.decode(errors="replace").rstrip("\r")
            buf += c
    return None


def wait_for(fd, text, timeout):
    """Read lines until one equals text; False on timeout."""
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        line = read_line(fd, end - time.monotonic())
        if line == text:
            return True
    return False


def terminal(fd):
    """Copy the port to the screen and the keyboard to the port until Ctrl+]."""
    out = sys.stdout.buffer
    if not sys.stdin.isatty():
        print("(stdin is not a terminal: not starting the terminal)")
        return
    saved = termios.tcgetattr(sys.stdin)
    tty.setraw(sys.stdin)
    try:
        while True:
            r, _, _ = select.select([fd, sys.stdin], [], [])
            if fd in r:
                data = os.read(fd, 256)
                out.write(data.replace(b"\n", b"\r\n"))   # programs print bare \n
                out.flush()
            if sys.stdin in r:
                key = os.read(sys.stdin.fileno(), 1)
                if key == QUIT:
                    break
                os.write(fd, key)
    finally:
        termios.tcsetattr(sys.stdin, termios.TCSADRAIN, saved)
        print()


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = [a for a in sys.argv[1:] if a.startswith("--")]
    if len(args) != 2:
        sys.exit(__doc__)
    dev, path = args
    image = open(path, "rb").read()
    frame = (b"RVLD" + struct.pack("<I", len(image)) + image
             + struct.pack("<I", zlib.crc32(image)))

    fd = open_port(dev)
    if "--now" not in flags:
        print("Press KEY[0] on the board (reset)...", flush=True)
        if not wait_for(fd, "boot: ready", 60):
            sys.exit("no \"boot: ready\" from the board in 60 s: is the bootloader "
                     "built in (make fpga ... PROG=boot) and programmed?")

    seconds = len(frame) * 10 / 115200
    print(f"sending {os.path.basename(path)}: {len(image)} bytes, "
          f"CRC {zlib.crc32(image):08x}, {seconds:.1f} s", flush=True)
    t0 = time.monotonic()
    sent = 0
    while sent < len(frame):                    # a tty may take a large write in parts
        sent += os.write(fd, frame[sent:])
    answer = read_line(fd, seconds + 3)
    if answer != "boot: ok":
        sys.exit(f"the bootloader answered {answer!r}" if answer is not None else
                 "no answer from the bootloader (press KEY[0] and try again)")
    print(f"boot: ok after {time.monotonic() - t0:.1f} s; running it. "
          f"Ctrl+] quits.", flush=True)
    if "--no-term" not in flags:
        terminal(fd)


if __name__ == "__main__":
    main()
