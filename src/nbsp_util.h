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

void nbsp_buf_init(struct nbsp_buf *buf);
void nbsp_buf_free(struct nbsp_buf *buf);
bool nbsp_buf_append_n(struct nbsp_buf *buf, const char *text, size_t len);
bool nbsp_buf_append(struct nbsp_buf *buf, const char *text);
bool nbsp_buf_append_char(struct nbsp_buf *buf, char value);
bool nbsp_buf_appendf(struct nbsp_buf *buf, const char *fmt, ...);
char *nbsp_buf_take(struct nbsp_buf *buf);

char *nbsp_strdup(const char *text);
char *nbsp_path_abbreviate(const char *cwd);
bool nbsp_path_abbreviate_into(const char *cwd, char *out, size_t out_len);
char *nbsp_prompt_escape(const char *text);
char *nbsp_percent_encode(const char *text);
char *nbsp_percent_decode(const char *text);
char *nbsp_nvm_version(const char *nvm_bin);
bool nbsp_nvm_version_into(const char *nvm_bin, char *out, size_t out_len);

bool nbsp_parse_long(const char *text, long min, long max, long *out);
bool nbsp_parse_u64(const char *text, uint64_t *out);
uint64_t nbsp_hash_path(const char *path);
uint64_t nbsp_wall_millis(void);
uint64_t nbsp_monotonic_millis(void);
bool nbsp_ends_with(const char *text, const char *suffix);

#endif /* NBSP_UTIL_H */
