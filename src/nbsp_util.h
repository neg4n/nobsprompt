#ifndef NBSP_UTIL_H
#define NBSP_UTIL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define NBSP_PATH_CAP 4096

struct nbsp_buf {
    char *data;
    size_t len;
    size_t cap;
};

enum nbsp_prompt_options {
    NBSP_PROMPT_PERCENT = 1U << 0,
    NBSP_PROMPT_SUBST = 1U << 1,
    NBSP_PROMPT_BANG = 1U << 2
};

void nbsp_buf_init(struct nbsp_buf *buf);
void nbsp_buf_free(struct nbsp_buf *buf);
bool nbsp_buf_append_n(struct nbsp_buf *buf, const char *text, size_t len);
bool nbsp_buf_append(struct nbsp_buf *buf, const char *text);
bool nbsp_buf_append_char(struct nbsp_buf *buf, char value);
bool nbsp_buf_appendf(struct nbsp_buf *buf, const char *fmt, ...);
char *nbsp_buf_take(struct nbsp_buf *buf);

char *nbsp_strdup(const char *text);
bool nbsp_copy_cstr(char *dst, size_t dst_len, const char *src);
bool nbsp_path_abbreviate_into(const char *cwd, char *out, size_t out_len);
bool nbsp_prompt_quote(struct nbsp_buf *buf, const char *text, unsigned options);

char *nbsp_percent_encode(const char *text);
bool nbsp_percent_decode_into(const char *encoded,
    size_t encoded_len,
    char *out,
    size_t out_len);
bool nbsp_percent_encoded_equals(const char *encoded,
    size_t encoded_len,
    const char *plain);
bool nbsp_percent_validate(const char *encoded, size_t encoded_len);

bool nbsp_parse_long(const char *text, long min, long max, long *out);
bool nbsp_parse_u64(const char *text, uint64_t *out);
bool nbsp_parse_u64_n(const char *text, size_t length, uint64_t *out);
bool nbsp_parse_uint_n(const char *text, size_t length, unsigned *out);

bool nbsp_nvm_version_into(const char *nvm_bin, char *out, size_t out_len);

uint64_t nbsp_hash_path(const char *path);
uint64_t nbsp_wall_millis(void);
uint64_t nbsp_monotonic_millis(void);

#endif /* NBSP_UTIL_H */
