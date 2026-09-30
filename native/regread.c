/* Read-only 32-bit physical register reader via /dev/mem: regread 0xADDR [...] */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s 0xADDR [0xADDR...]\n", argv[0]);
        return 1;
    }
    int fd = open("/dev/mem", O_RDONLY | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); return 1; }
    long page = sysconf(_SC_PAGESIZE);
    for (int i = 1; i < argc; i++) {
        unsigned long addr = strtoul(argv[i], NULL, 0);
        unsigned long base = addr & ~(unsigned long)(page - 1);
        void *map = mmap(NULL, page, PROT_READ, MAP_SHARED, fd, base);
        if (map == MAP_FAILED) { perror("mmap"); return 1; }
        uint32_t v = *(volatile uint32_t *)((char *)map + (addr - base));
        printf("0x%08lx = 0x%08x\n", addr, v);
        munmap(map, page);
    }
    close(fd);
    return 0;
}
