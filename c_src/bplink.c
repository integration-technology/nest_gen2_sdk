/* Nest backplate serial line, as an Erlang port: a byte pipe, nothing more.
 * Framing, checksums and every message's meaning live in Elixir
 * (NestGen2.Backplate.Frame and .Decode); this only does what the BEAM can't:
 * set the tty up (raw, 115200 8N1) and send a serial BREAK.
 *
 * Both directions use {packet, 2}: a 2-byte big-endian length, then a body
 * whose first byte says what it is.
 *
 *   from the BEAM:  'w' <bytes>    write the bytes to the line
 *                   'b'            flush both ways, then a 100 ms BREAK (the
 *                                  backplate restarts and says hello)
 *   to the BEAM:    'r' <bytes>    bytes read from the line, as they arrive
 *                   'o' <path>     the line is open
 *                   'e' <text>     an error
 *
 * Exits when stdin closes, so it never outlives its owner.
 */
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

#define MAX_PACKET 4096

static int open_tty(const char *path) {
    int fd = open(path, O_RDWR | O_NOCTTY);
    if (fd < 0) return -1;
    struct termios t;
    if (tcgetattr(fd, &t) < 0) return -1;
    cfmakeraw(&t);
    cfsetispeed(&t, B115200);
    cfsetospeed(&t, B115200);
    t.c_cflag |= CLOCAL | CREAD;
    t.c_cflag &= ~(CSTOPB | PARENB | CRTSCTS);
    t.c_cc[VMIN] = 0;
    t.c_cc[VTIME] = 0;
    if (tcsetattr(fd, TCSANOW, &t) < 0) return -1;
    tcflush(fd, TCIOFLUSH);
    return fd;
}

static int write_all(int fd, const uint8_t *p, size_t n) {
    while (n) {
        ssize_t w = write(fd, p, n);
        if (w < 0) { if (errno == EINTR) continue; return -1; }
        p += w; n -= (size_t)w;
    }
    return 0;
}

/* One packet to the BEAM: tag, then data. */
static void send_packet(char tag, const void *data, size_t n) {
    uint8_t hdr[3] = {(uint8_t)((n + 1) >> 8), (uint8_t)(n + 1), (uint8_t)tag};
    if (write_all(STDOUT_FILENO, hdr, 3) == 0) write_all(STDOUT_FILENO, data, n);
}

static void send_error(const char *fmt, ...) {
    char msg[256];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(msg, sizeof msg, fmt, ap);
    va_end(ap);
    if (n < 0) n = 0;
    if ((size_t)n >= sizeof msg) n = sizeof msg - 1;
    send_packet('e', msg, (size_t)n);
}

static void handle_packet(int fd, const uint8_t *p, size_t n) {
    if (n == 0) return;
    switch (p[0]) {
    case 'w':
        if (write_all(fd, p + 1, n - 1) < 0) send_error("write %s", strerror(errno));
        break;
    case 'b':
        /* What Nest's own client does at start: the backplate restarts on a
         * BREAK and then says hello (0x0004). */
        tcflush(fd, TCIOFLUSH);
        if (ioctl(fd, TCSBRKP, 1) < 0) send_error("brk %s", strerror(errno));
        break;
    default:
        send_error("unknown packet %c", p[0]);
    }
}

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "/dev/ttyO2";
    int fd = open_tty(path);
    if (fd < 0) { send_error("open %s %s", path, strerror(errno)); return 1; }
    send_packet('o', path, strlen(path));

    uint8_t in[2 + MAX_PACKET];
    size_t have = 0;
    uint8_t rbuf[1024];
    struct pollfd pfd[2] = {{fd, POLLIN, 0}, {STDIN_FILENO, POLLIN, 0}};

    for (;;) {
        if (poll(pfd, 2, -1) < 0) { if (errno == EINTR) continue; return 1; }
        if (pfd[0].revents & POLLIN) {
            ssize_t r = read(fd, rbuf, sizeof rbuf);
            if (r > 0) send_packet('r', rbuf, (size_t)r);
        }
        if (pfd[1].revents & (POLLIN | POLLHUP)) {
            ssize_t r = read(STDIN_FILENO, in + have, sizeof in - have);
            if (r <= 0) return 0;
            have += (size_t)r;
            for (;;) {
                if (have < 2) break;
                size_t len = (size_t)in[0] << 8 | in[1];
                if (len > MAX_PACKET) { send_error("packet too long"); return 1; }
                if (have < 2 + len) break;
                handle_packet(fd, in + 2, len);
                memmove(in, in + 2 + len, have - 2 - len);
                have -= 2 + len;
            }
        }
    }
}
