#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int parse_iterations(const char *text, size_t *out) {
    errno = 0;
    char *end = NULL;
    const unsigned long long value = strtoull(text, &end, 10);
    if (errno == ERANGE || end == text || *end != '\0' || value > SIZE_MAX) return 0;
    *out = (size_t)value;
    return 1;
}

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ((uint64_t)ts.tv_sec * 1000000000ULL) + (uint64_t)ts.tv_nsec;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s <html-file> <iterations>\n", argv[0]);
        return 2;
    }

    const char *path = argv[1];
    size_t iterations = 0;
    if (!parse_iterations(argv[2], &iterations)) {
        fprintf(stderr, "invalid iterations: %s\n", argv[2]);
        return 2;
    }

    FILE *f = fopen(path, "rb");
    if (f == NULL) {
        perror("fopen");
        return 1;
    }

    if (fseek(f, 0, SEEK_END) != 0) {
        perror("fseek");
        fclose(f);
        return 1;
    }
    const long fsize = ftell(f);
    if (fsize < 0) {
        perror("ftell");
        fclose(f);
        return 1;
    }
    if (fseek(f, 0, SEEK_SET) != 0) {
        perror("fseek");
        fclose(f);
        return 1;
    }

    const size_t size = (size_t)fsize;
    char *buf = (char *)malloc(size + 1);
    if (buf == NULL) {
        perror("malloc");
        fclose(f);
        return 1;
    }

    if (size > 0 && fread(buf, 1, size, f) != size) {
        perror("fread");
        free(buf);
        fclose(f);
        return 1;
    }
    fclose(f);
    buf[size] = '\0';

    volatile size_t sink = 0;
    const uint64_t start = now_ns();
    for (size_t i = 0; i < iterations; i++) {
        sink += strlen(buf);
    }
    const uint64_t end = now_ns();

    if (sink == (size_t)-1) {
        fprintf(stderr, "unreachable\n");
    }

    printf("%llu\n", (unsigned long long)(end - start));
    free(buf);
    return 0;
}
