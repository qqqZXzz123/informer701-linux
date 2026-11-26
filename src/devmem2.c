/*
 * devmem2.c - simple program to read/write from/to any location in memory.
 * Adapted for Informer 701 (Allwinner A10, Debian 12 Bookworm armhf / glibc).
 *
 * Compatible CLI and output format with Jan-Derk Bakker's devmem2 (GPL-2.0+):
 *   devmem2 { address } [ type [ data ] ]
 *     address : memory address to act upon
 *     type    : access operation type : [b]yte, [h]alfword, [w]ord (default)
 *     data    : data to be written
 */
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define MAP_SIZE 4096UL
#define MAP_MASK (MAP_SIZE - 1)

/* Custom parser avoids C23 __isoc23_strtoul@GLIBC_2.38 when cross-compiled
 * on newer hosts against targets running Debian 12 Bookworm (glibc 2.36). */
static int parse_u32(const char *s, uint32_t *out) {
    uint64_t val = 0;
    int base = 10;
    if (!s || !*s) return -1;
    while (isspace((unsigned char)*s)) s++;
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
        base = 16;
        s += 2;
    } else if (s[0] == '0' && s[1] != '\0') {
        base = 8;
        s += 1;
    }
    if (!*s) return -1;
    while (*s) {
        unsigned d;
        unsigned char c = (unsigned char)*s++;
        if (c >= '0' && c <= '9') d = c - '0';
        else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
        else return -1;
        if ((int)d >= base) return -1;
        val = val * (uint64_t)base + d;
        if (val > 0xFFFFFFFFULL) return -1;
    }
    *out = (uint32_t)val;
    return 0;
}

int main(int argc, char **argv) {
    int fd;
    void *map_base, *virt_addr;
    uint32_t read_result = 0, writeval = 0, target = 0;
    int access_type = 'w';

    if (argc >= 2 && (strcmp(argv[1], "--version") == 0 || strcmp(argv[1], "-V") == 0)) {
        printf("devmem2 0.2-debian (armhf glibc)\n");
        return 0;
    }

    if (argc < 2 || strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0) {
        fprintf(stderr,
            "\nUsage:\t%s { address } [ type [ data ] ]\n"
            "\taddress : memory address to act upon\n"
            "\ttype    : access operation type : [b]yte, [h]alfword, [w]ord\n"
            "\tdata    : data to be written\n\n",
            argv[0]);
        return (argc < 2) ? 1 : 0;
    }

    if (parse_u32(argv[1], &target) != 0) {
        fprintf(stderr, "Invalid address: %s\n", argv[1]);
        return 1;
    }

    if (argc > 2 && argv[2][0] != '\0') {
        access_type = tolower((unsigned char)argv[2][0]);
    }

    if (access_type != 'b' && access_type != 'h' && access_type != 'w') {
        fprintf(stderr, "Illegal data type '%c'.\n", access_type);
        return 2;
    }

    if (argc > 3 && parse_u32(argv[3], &writeval) != 0) {
        fprintf(stderr, "Invalid write data: %s\n", argv[3]);
        return 1;
    }

    fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd == -1) {
        fprintf(stderr, "Error opening /dev/mem (%d): %s\n", errno, strerror(errno));
        return 1;
    }
    printf("/dev/mem opened.\n");
    fflush(stdout);

    map_base = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED,
                    fd, (off_t)(target & ~MAP_MASK));
    if (map_base == MAP_FAILED) {
        fprintf(stderr, "Error mapping /dev/mem (%d): %s\n", errno, strerror(errno));
        close(fd);
        return 1;
    }
    printf("Memory mapped at address %p.\n", map_base);
    fflush(stdout);

    virt_addr = (char *)map_base + (target & MAP_MASK);
    switch (access_type) {
        case 'b':
            read_result = *((volatile uint8_t *)virt_addr);
            break;
        case 'h':
            read_result = *((volatile uint16_t *)virt_addr);
            break;
        case 'w':
            read_result = *((volatile uint32_t *)virt_addr);
            break;
    }
    printf("Read at address  0x%08X (%p): 0x%X\n",
           target, virt_addr, read_result);
    fflush(stdout);

    if (argc > 3) {
        switch (access_type) {
            case 'b':
                *((volatile uint8_t *)virt_addr) = (uint8_t)writeval;
                read_result = *((volatile uint8_t *)virt_addr);
                break;
            case 'h':
                *((volatile uint16_t *)virt_addr) = (uint16_t)writeval;
                read_result = *((volatile uint16_t *)virt_addr);
                break;
            case 'w':
                *((volatile uint32_t *)virt_addr) = writeval;
                read_result = *((volatile uint32_t *)virt_addr);
                break;
        }
        printf("Write at address 0x%08X (%p): 0x%X, readback 0x%X\n",
               target, virt_addr, writeval, read_result);
        fflush(stdout);
    }

    munmap(map_base, MAP_SIZE);
    close(fd);
    return 0;
}
