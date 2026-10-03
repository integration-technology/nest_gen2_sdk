/* Nest backplate UART link, meant to run as an Erlang/Elixir port.
 *
 * stdout: one line per valid frame received:   rx <cmd hex4> <payload hex>
 * stdin:  one command per line:                tx <cmd hex> [payload hex]
 *                                               brk   (flush, then a 100 ms BREAK)
 * Exits when stdin closes, so it never outlives its owner.
 *
 * Frame: d5 aa 96 | cmd u16le | len u16le | payload | crc16-xmodem(cmd..payload) u16le
 */
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

#define MAX_PAYLOAD 1024

static uint16_t crc16_xmodem(const uint8_t *d, size_t n) {
    uint16_t crc = 0;
    while (n--) {
        crc ^= (uint16_t)(*d++) << 8;
        for (int i = 0; i < 8; i++)
            crc = (crc & 0x8000) ? (uint16_t)((crc << 1) ^ 0x1021) : (uint16_t)(crc << 1);
    }
    return crc;
}

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

static int hexval(int c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static int send_frame(int fd, unsigned cmd, const uint8_t *p, size_t n) {
    uint8_t f[3 + 4 + MAX_PAYLOAD + 2];
    f[0] = 0xd5; f[1] = 0xaa; f[2] = 0x96;
    f[3] = cmd & 0xff; f[4] = (cmd >> 8) & 0xff;
    f[5] = n & 0xff;   f[6] = (n >> 8) & 0xff;
    memcpy(f + 7, p, n);
    uint16_t crc = crc16_xmodem(f + 3, 4 + n);
    f[7 + n] = crc & 0xff; f[8 + n] = crc >> 8;
    size_t len = 9 + n, off = 0;
    while (off < len) {
        ssize_t w = write(fd, f + off, len - off);
        if (w < 0) { if (errno == EINTR) continue; return -1; }
        off += (size_t)w;
    }
    return 0;
}

static void handle_command(int fd, char *line) {
    char *save, *verb = strtok_r(line, " \t\r\n", &save);
    if (!verb) return;
    if (strcmp(verb, "brk") == 0) {
        /* What Nest's client does at start: the backplate restarts on a BREAK
         * and then says hello (0x0004), which wakes it from its silent state. */
        tcflush(fd, TCIOFLUSH);
        if (ioctl(fd, TCSBRKP, 1) < 0) printf("err brk %s\n", strerror(errno));
        return;
    }
    if (strcmp(verb, "tx") != 0) { printf("err unknown %s\n", verb); return; }
    char *cmds = strtok_r(NULL, " \t\r\n", &save);
    char *hex = strtok_r(NULL, " \t\r\n", &save);
    if (!cmds) { printf("err missing cmd\n"); return; }
    unsigned cmd = (unsigned)strtoul(cmds, NULL, 16);
    uint8_t payload[MAX_PAYLOAD];
    size_t n = 0;
    if (hex) {
        size_t hl = strlen(hex);
        if (hl % 2 || hl / 2 > MAX_PAYLOAD) { printf("err bad payload\n"); return; }
        for (size_t i = 0; i < hl; i += 2) {
            int a = hexval(hex[i]), b = hexval(hex[i + 1]);
            if (a < 0 || b < 0) { printf("err bad payload\n"); return; }
            payload[n++] = (uint8_t)(a << 4 | b);
        }
    }
    if (send_frame(fd, cmd, payload, n) < 0) printf("err write %s\n", strerror(errno));
}

/* Consume complete frames from buf; returns bytes kept. */
static size_t parse_frames(uint8_t *buf, size_t len) {
    size_t i = 0;
    for (;;) {
        while (i + 3 <= len && !(buf[i] == 0xd5 && buf[i + 1] == 0xaa && buf[i + 2] == 0x96)) i++;
        if (i + 7 > len) break;
        unsigned cmd = buf[i + 3] | buf[i + 4] << 8;
        size_t n = buf[i + 5] | (size_t)buf[i + 6] << 8;
        if (n > MAX_PAYLOAD) { i++; continue; }
        if (i + 9 + n > len) break;
        uint16_t crc = buf[i + 7 + n] | buf[i + 8 + n] << 8;
        if (crc != crc16_xmodem(buf + i + 3, 4 + n)) { i++; continue; }
        printf("rx %04x ", cmd);
        for (size_t k = 0; k < n; k++) printf("%02x", buf[i + 7 + k]);
        printf("\n");
        i += 9 + n;
    }
    memmove(buf, buf + i, len - i);
    return len - i;
}

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "/dev/ttyO2";
    setvbuf(stdout, NULL, _IOLBF, 0);
    int fd = open_tty(path);
    if (fd < 0) { printf("err open %s %s\n", path, strerror(errno)); return 1; }
    printf("ready %s\n", path);

    uint8_t rbuf[4 * (MAX_PAYLOAD + 16)];
    size_t rlen = 0;
    char lbuf[3 * MAX_PAYLOAD + 64];
    size_t llen = 0;
    struct pollfd pfd[2] = {{fd, POLLIN, 0}, {STDIN_FILENO, POLLIN, 0}};

    for (;;) {
        if (poll(pfd, 2, -1) < 0) { if (errno == EINTR) continue; return 1; }
        if (pfd[0].revents & POLLIN) {
            ssize_t r = read(fd, rbuf + rlen, sizeof(rbuf) - rlen);
            if (r > 0) {
                rlen += (size_t)r;
                rlen = parse_frames(rbuf, rlen);
                if (rlen == sizeof(rbuf)) rlen = 0;
            }
        }
        if (pfd[1].revents & (POLLIN | POLLHUP)) {
            ssize_t r = read(STDIN_FILENO, lbuf + llen, sizeof(lbuf) - 1 - llen);
            if (r <= 0) return 0;
            llen += (size_t)r;
            char *nl;
            while ((nl = memchr(lbuf, '\n', llen))) {
                *nl = 0;
                handle_command(fd, lbuf);
                size_t used = (size_t)(nl - lbuf) + 1;
                memmove(lbuf, lbuf + used, llen - used);
                llen -= used;
            }
            if (llen == sizeof(lbuf) - 1) llen = 0;
        }
    }
}
