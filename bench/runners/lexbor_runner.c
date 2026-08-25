#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#include "lexbor/html/html.h"

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
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static unsigned char *read_file(const char *path, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    if (fseek(f, 0, SEEK_END) != 0) {
        fclose(f);
        return NULL;
    }
    long sz = ftell(f);
    if (sz < 0) {
        fclose(f);
        return NULL;
    }
    rewind(f);

    unsigned char *buf = (unsigned char *)malloc((size_t)sz != 0 ? (size_t)sz : 1);
    if (!buf) {
        fclose(f);
        return NULL;
    }

    if (fread(buf, 1, (size_t)sz, f) != (size_t)sz) {
        free(buf);
        fclose(f);
        return NULL;
    }
    fclose(f);
    *out_len = (size_t)sz;
    return buf;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s <html-file> <iterations>\n", argv[0]);
        return 2;
    }

    size_t len = 0;
    unsigned char *input = read_file(argv[1], &len);
    if (!input) {
        fprintf(stderr, "failed to read file: %s\n", argv[1]);
        return 1;
    }

    size_t iterations = 0;
    if (!parse_iterations(argv[2], &iterations)) {
        fprintf(stderr, "invalid iterations: %s\n", argv[2]);
        free(input);
        return 2;
    }

    lxb_html_document_t *doc = lxb_html_document_create();
    if (doc == NULL) {
        free(input);
        return 1;
    }

    // Use input directly when parsing benchmark fixtures.
    lxb_html_document_opt_set(doc, LXB_HTML_DOCUMENT_PARSE_WO_COPY);

    uint64_t start = now_ns();

    for (size_t i = 0; i < iterations; i++) {
        lxb_html_document_clean(doc);
        lxb_status_t st = lxb_html_document_parse(doc, (const lxb_char_t *)input, len);
        if (st != LXB_STATUS_OK) {
            lxb_html_document_destroy(doc);
            free(input);
            return 1;
        }
    }

    uint64_t end = now_ns();
    printf("%llu\n", (unsigned long long)(end - start));
    lxb_html_document_destroy(doc);
    free(input);
    return 0;
}
