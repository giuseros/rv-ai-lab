// talk.c — an interactive program for the board: type a line, get it back reversed.
//   make fpga BOARD=de10-lite TOP=soc PROG=talk && make program BOARD=de10-lite TOP=soc PROG=talk
//   picocom -b 115200 --imap lfcrlf /dev/ttyUSB0
//
// What you type is echoed as you type it (picocom does not show it by itself);
// Backspace works. Enter sends a bare CR, a pasted file has LF (or CRLF): any
// of them ends a line. "quit" ends the program, and the number of lines you
// typed is its exit code, on the displays.
//
// After each line the receiver's status is checked: if a byte was dropped (a
// paste longer than the FIFO, while the program was busy printing) or arrived
// with a framing error (wrong baud rate), it says so.

#include "soc.h"

#define MAX 72

static int read_line(char *buf)
{
    static int last_cr;             // a CR just ended a line: skip the LF of a CRLF
    int n = 0, c;

    for (;;) {
        c = getchar();
        if (c == '\n' && last_cr) { last_cr = 0; continue; }
        last_cr = (c == '\r');
        if (c == '\r' || c == '\n') break;
        if (c == 0x7F || c == '\b') {               // Backspace (picocom sends 0x7F)
            if (n > 0) { n--; puts("\b \b"); }
        } else if (c >= ' ' && c < 0x7F && n < MAX) {
            buf[n++] = (char)c;
            putchar(c);                             // echo
        }
    }
    buf[n] = '\0';
    putchar('\n');
    return n;
}

int main(void)
{
    char line[MAX + 1];
    int  lines = 0;

    puts("\nrv-ai-lab: hello from the DE10-Lite. Type a line; \"quit\" ends.\n");
    for (;;) {
        puts("> ");
        int n = read_line(line);

        uint32_t s = RX_STAT;
        if (s & (RX_DROPPED | RX_FRAMING)) {
            RX_STAT = s;                            // clear what we saw
            if (s & RX_DROPPED) puts("  (some input was lost: it came faster than I read it)\n");
            if (s & RX_FRAMING) puts("  (a byte had a framing error: wrong baud rate?)\n");
        }
        if (n == 0) continue;
        if (memcmp(line, "quit", 5) == 0) break;
        lines++;

        puts("  reversed: ");
        for (int i = n - 1; i >= 0; i--) putchar(line[i]);
        printf("   (%d characters)\n", n);
    }
    printf("bye: %d lines\n", lines);
    return lines;
}
