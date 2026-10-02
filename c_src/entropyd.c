/*
 * entropyd: keeps the kernel's entropy count up on the Nest.
 *
 * The Nest has no hardware RNG and, without Nest's own software, almost
 * nothing feeds the kernel's entropy pool, so it sits at zero. On this
 * kernel (2.6.37, no getrandom()) OpenSSL 3 waits for /dev/random to become
 * readable before using /dev/urandom, and that wait blocks the Erlang VM's
 * scheduler on its first TLS connection.
 *
 * Every second, if the entropy count is below LOW bits, this mixes bytes from
 * /dev/urandom with timing jitter and credits them to the pool
 * (RNDADDENTROPY), like rngd/haveged do on other headless boards. At start it
 * also feeds the seed file saved last time and writes a fresh one, so the
 * pool starts from different state on every boot.
 *
 *   entropyd [seed-file]
 */
#include <errno.h>
#include <fcntl.h>
#include <linux/random.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#define LOW 512
#define CHUNK 64

static int entropy_avail(void) {
    char buf[32];
    int fd = open("/proc/sys/kernel/random/entropy_avail", O_RDONLY);
    if (fd < 0) return -1;
    ssize_t n = read(fd, buf, sizeof buf - 1);
    close(fd);
    if (n <= 0) return -1;
    buf[n] = 0;
    return atoi(buf);
}

static uint32_t jitter(void) {
    struct timespec a, b;
    clock_gettime(CLOCK_MONOTONIC, &a);
    for (volatile int i = 0; i < 1000; i++) {
    }
    clock_gettime(CLOCK_MONOTONIC, &b);
    return (uint32_t)(b.tv_nsec ^ (a.tv_nsec << 7) ^ b.tv_sec);
}

/* Credits `len` bytes (with `bits` of entropy) to the kernel pool. */
static int credit(int rnd, const unsigned char *data, int len, int bits) {
    struct rand_pool_info *info = malloc(sizeof *info + len);
    if (!info) return -1;
    info->entropy_count = bits;
    info->buf_size = len;
    memcpy(info->buf, data, len);
    int r = ioctl(rnd, RNDADDENTROPY, info);
    free(info);
    return r;
}

static int top_up(int rnd, int urnd) {
    unsigned char buf[CHUNK];
    if (read(urnd, buf, sizeof buf) != (ssize_t)sizeof buf) return -1;
    for (int i = 0; i < CHUNK; i += 4) {
        uint32_t j = jitter();
        buf[i] ^= j;
        buf[i + 1] ^= j >> 8;
        buf[i + 2] ^= j >> 16;
        buf[i + 3] ^= j >> 24;
    }
    return credit(rnd, buf, sizeof buf, CHUNK * 8);
}

static void seed(int rnd, int urnd, const char *path) {
    unsigned char buf[512];
    int fd = open(path, O_RDONLY);
    if (fd >= 0) {
        ssize_t n = read(fd, buf, sizeof buf);
        close(fd);
        if (n > 0) credit(rnd, buf, (int)n, 0);
    }
    if (read(urnd, buf, sizeof buf) == (ssize_t)sizeof buf) {
        fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
        if (fd >= 0) {
            if (write(fd, buf, sizeof buf) < 0) {
            }
            fsync(fd);
            close(fd);
        }
    }
}

int main(int argc, char **argv) {
    int rnd = open("/dev/random", O_RDWR);
    int urnd = open("/dev/urandom", O_RDONLY);
    if (rnd < 0 || urnd < 0) {
        fprintf(stderr, "entropyd: open: %s\n", strerror(errno));
        return 1;
    }
    if (argc > 1) seed(rnd, urnd, argv[1]);

    for (;;) {
        int avail = entropy_avail();
        while (avail >= 0 && avail < LOW) {
            if (top_up(rnd, urnd) < 0) {
                fprintf(stderr, "entropyd: RNDADDENTROPY: %s\n", strerror(errno));
                return 1;
            }
            int now = entropy_avail();
            if (now <= avail) break;
            avail = now;
        }
        sleep(1);
    }
}
