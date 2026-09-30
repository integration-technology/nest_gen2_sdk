/* Blocking-read watcher for evdev input devices, run as an Erlang port.
 * Prints one line per input event:  ev <type> <code> <value>
 * EV_SYN markers are skipped. Erlang's own file:read on these character
 * devices was found to be unreliable/delayed; a plain blocking read() is not.
 *
 * Records are parsed by offset rather than via struct input_event: the
 * 2.6.37 kernel uses 32-bit timevals (16-byte records), which newer musl
 * headers no longer match. */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define RECORD 16

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s /dev/input/eventN\n", argv[0]);
        return 1;
    }

    int fd = open(argv[1], O_RDONLY);
    if (fd < 0) {
        perror("open");
        return 1;
    }

    uint8_t buf[RECORD * 64];
    setvbuf(stdout, NULL, _IOLBF, 0);

    for (;;) {
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n < 0) {
            if (errno == EINTR) continue;
            perror("read");
            usleep(1000000);
            continue;
        }
        for (ssize_t off = 0; off + RECORD <= n; off += RECORD) {
            uint16_t type, code;
            int32_t value;
            memcpy(&type, buf + off + 8, 2);
            memcpy(&code, buf + off + 10, 2);
            memcpy(&value, buf + off + 12, 4);
            if (type == 0) continue;
            /* SIGPIPE is ignored under the BEAM, so a dead owner shows up as a
             * write error rather than a signal: exit instead of lingering. */
            if (printf("ev %u %u %d\n", type, code, value) < 0)
                return 0;
        }
        if (fflush(stdout) == EOF)
            return 0;
    }
}
