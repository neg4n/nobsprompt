#include "nbsp_util.h"

#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static bool nbsp_buf_reserve(struct nbsp_buf *buf, size_t extra) {
    if (!buf || extra > SIZE_MAX - buf->len - 1U) {
        return false;
    }

    size_t needed = buf->len + extra + 1U;
    if (needed <= buf->cap) {
        return true;
    }

    size_t cap = buf->cap ? buf->cap : 256U;
    while (cap < needed) {
        if (cap > SIZE_MAX / 2U) {
            cap = needed;
            break;
        }
        cap *= 2U;
    }

    char *grown = realloc(buf->data, cap);
    if (!grown) {
        return false;
    }
    buf->data = grown;
    buf->cap = cap;
    return true;
}

void nbsp_buf_init(struct nbsp_buf *buf) {
    if (buf) {
        buf->data = NULL;
        buf->len = 0;
        buf->cap = 0;
    }
}

void nbsp_buf_free(struct nbsp_buf *buf) {
    if (buf) {
        free(buf->data);
        nbsp_buf_init(buf);
    }
}

bool nbsp_buf_append_n(struct nbsp_buf *buf, const char *text, size_t len) {
    if (!buf || (!text && len != 0U) || !nbsp_buf_reserve(buf, len)) {
        return false;
    }
    if (len != 0U) {
        memcpy(buf->data + buf->len, text, len);
    }
    buf->len += len;
    buf->data[buf->len] = '\0';
    return true;
}

bool nbsp_buf_append(struct nbsp_buf *buf, const char *text) {
    return text && nbsp_buf_append_n(buf, text, strlen(text));
}

bool nbsp_buf_append_char(struct nbsp_buf *buf, char value) {
    return nbsp_buf_append_n(buf, &value, 1U);
}

bool nbsp_buf_appendf(struct nbsp_buf *buf, const char *fmt, ...) {
    if (!buf || !fmt) {
        return false;
    }

    va_list args;
    va_start(args, fmt);
    va_list copy;
    va_copy(copy, args);
    int count = vsnprintf(NULL, 0, fmt, copy);
    va_end(copy);
    if (count < 0 || !nbsp_buf_reserve(buf, (size_t) count)) {
        va_end(args);
        return false;
    }
    (void) vsnprintf(buf->data + buf->len, buf->cap - buf->len, fmt, args);
    va_end(args);
    buf->len += (size_t) count;
    return true;
}

char *nbsp_buf_take(struct nbsp_buf *buf) {
    if (!buf) {
        return NULL;
    }
    if (!buf->data) {
        buf->data = calloc(1U, 1U);
        if (!buf->data) {
            return NULL;
        }
    }
    char *data = buf->data;
    nbsp_buf_init(buf);
    return data;
}

char *nbsp_strdup(const char *text) {
    if (!text) {
        return NULL;
    }
    size_t len = strlen(text) + 1U;
    char *copy = malloc(len);
    if (copy) {
        memcpy(copy, text, len);
    }
    return copy;
}

static size_t utf8_character_length(const char *text, size_t available) {
    if (!text || available == 0U) return 0U;
    unsigned char first = (unsigned char) text[0];
    size_t length = 1U;
    if ((first & 0xe0U) == 0xc0U) length = 2U;
    else if ((first & 0xf0U) == 0xe0U) length = 3U;
    else if ((first & 0xf8U) == 0xf0U) length = 4U;
    if (length > available) return 1U;
    for (size_t i = 1U; i < length; ++i) {
        if (((unsigned char) text[i] & 0xc0U) != 0x80U) return 1U;
    }
    return length;
}

static bool path_append(char *out,
    size_t out_len,
    size_t *written,
    const char *text,
    size_t length) {
    if (!out || !written || !text || *written > out_len || length >= out_len - *written) {
        return false;
    }
    memcpy(out + *written, text, length);
    *written += length;
    out[*written] = '\0';
    return true;
}

bool nbsp_path_abbreviate_into(const char *cwd, char *out, size_t out_len) {
    if (!out || out_len == 0U) return false;
    if (!cwd || *cwd == '\0') {
        return out_len >= 2U && (out[0] = '?', out[1] = '\0', true);
    }

    size_t written = 0U;
    out[0] = '\0';
    const char *cursor = cwd;
    bool absolute = *cursor == '/';
    if (absolute) {
        if (!path_append(out, out_len, &written, "/", 1U)) return false;
        while (*cursor == '/') ++cursor;
        if (*cursor == '\0') return true;
    }

    bool first_segment = true;
    while (*cursor) {
        const char *segment = cursor;
        while (*cursor && *cursor != '/') ++cursor;
        size_t segment_len = (size_t) (cursor - segment);
        while (*cursor == '/') ++cursor;
        bool last = *cursor == '\0';

        if (!first_segment || !absolute) {
            if (!first_segment && !path_append(out, out_len, &written, "/", 1U)) return false;
        }

        if (last) {
            if (!path_append(out, out_len, &written, segment, segment_len)) return false;
        } else {
            size_t prefix = 0U;
            if (segment_len > 1U && segment[0] == '.') {
                if (!path_append(out, out_len, &written, ".", 1U)) return false;
                prefix = 1U;
            }
            size_t char_len = utf8_character_length(segment + prefix, segment_len - prefix);
            if (char_len == 0U ||
                !path_append(out, out_len, &written, segment + prefix, char_len)) {
                return false;
            }
        }
        first_segment = false;
    }
    return true;
}

char *nbsp_path_abbreviate(const char *cwd) {
    char path[NBSP_PATH_CAP];
    return nbsp_path_abbreviate_into(cwd, path, sizeof path) ? nbsp_strdup(path) : NULL;
}

bool nbsp_prompt_quote(struct nbsp_buf *buf, const char *text, unsigned options) {
    if (!buf || !text) {
        return false;
    }

    static const char hex[] = "0123456789ABCDEF";
    bool substitute = (options & NBSP_PROMPT_SUBST) != 0U;
    if (substitute && !nbsp_buf_append(buf, "${(g::):-")) return false;

    for (const unsigned char *p = (const unsigned char *) text; *p; ++p) {
        unsigned char value = (*p < 32U || *p == 127U) ? '?' : *p;
        unsigned repetitions = 1U;
        if (((options & NBSP_PROMPT_BANG) != 0U && value == '!') ||
            ((options & NBSP_PROMPT_PERCENT) != 0U && value == '%')) {
            repetitions = 2U;
        }
        for (unsigned i = 0U; i < repetitions; ++i) {
            if (substitute) {
                char encoded[] = {'\\', 'x', hex[value >> 4U], hex[value & 15U]};
                if (!nbsp_buf_append_n(buf, encoded, sizeof encoded)) return false;
            } else if (!nbsp_buf_append_char(buf, (char) value)) {
                return false;
            }
        }
    }
    return !substitute || nbsp_buf_append_char(buf, '}');
}

static bool percent_safe(unsigned char value) {
    return (value >= (unsigned char) 'A' && value <= (unsigned char) 'Z') ||
        (value >= (unsigned char) 'a' && value <= (unsigned char) 'z') ||
        (value >= (unsigned char) '0' && value <= (unsigned char) '9') ||
        value == '-' || value == '_' || value == '.' || value == '/';
}

char *nbsp_percent_encode(const char *text) {
    static const char hex[] = "0123456789ABCDEF";
    if (!text) {
        return NULL;
    }
    struct nbsp_buf buf;
    nbsp_buf_init(&buf);
    for (const unsigned char *p = (const unsigned char *) text; *p; ++p) {
        if (percent_safe(*p)) {
            if (!nbsp_buf_append_char(&buf, (char) *p)) {
                nbsp_buf_free(&buf);
                return NULL;
            }
        } else {
            char encoded[3] = {'%', hex[*p >> 4U], hex[*p & 15U]};
            if (!nbsp_buf_append_n(&buf, encoded, sizeof encoded)) {
                nbsp_buf_free(&buf);
                return NULL;
            }
        }
    }
    return nbsp_buf_take(&buf);
}

static int hex_value(char value) {
    if (value >= '0' && value <= '9') return value - '0';
    if (value >= 'A' && value <= 'F') return value - 'A' + 10;
    if (value >= 'a' && value <= 'f') return value - 'a' + 10;
    return -1;
}

char *nbsp_percent_decode(const char *text) {
    if (!text) {
        return NULL;
    }
    struct nbsp_buf buf;
    nbsp_buf_init(&buf);
    for (size_t i = 0; text[i]; ++i) {
        if (text[i] == '%') {
            int hi = hex_value(text[i + 1U]);
            int lo = text[i + 1U] ? hex_value(text[i + 2U]) : -1;
            if (hi < 0 || lo < 0) {
                nbsp_buf_free(&buf);
                return NULL;
            }
            char value = (char) ((hi << 4) | lo);
            if (value == '\0' || !nbsp_buf_append_char(&buf, value)) {
                nbsp_buf_free(&buf);
                return NULL;
            }
            i += 2U;
        } else if (!nbsp_buf_append_char(&buf, text[i])) {
            nbsp_buf_free(&buf);
            return NULL;
        }
    }
    return nbsp_buf_take(&buf);
}

bool nbsp_nvm_version_into(const char *nvm_bin, char *out, size_t out_len) {
    if (!nvm_bin || !*nvm_bin || !out || out_len == 0U) return false;
    const char *begin = nvm_bin;
    const char *end = nvm_bin + strlen(nvm_bin);
    while (end > begin + 1 && end[-1] == '/') --end;

    const char *component = end;
    while (component > begin && component[-1] != '/') --component;
    if ((size_t) (end - component) == 3U && memcmp(component, "bin", 3U) == 0 && component > begin) {
        end = component - 1;
        component = end;
        while (component > begin && component[-1] != '/') --component;
    }
    if (component < end && *component == 'v' && component + 1 < end &&
        component[1] >= '0' && component[1] <= '9') {
        ++component;
    }
    size_t length = (size_t) (end - component);
    if (length == 0U || length + 1U > out_len) return false;
    for (const unsigned char *p = (const unsigned char *) component;
         p < (const unsigned char *) end;
         ++p) {
        if (!((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') ||
            (*p >= '0' && *p <= '9') || *p == '.' || *p == '-' ||
            *p == '_')) {
            return false;
        }
    }
    memcpy(out, component, length);
    out[length] = '\0';
    return true;
}

char *nbsp_nvm_version(const char *nvm_bin) {
    char version[256];
    return nbsp_nvm_version_into(nvm_bin, version, sizeof version)
        ? nbsp_strdup(version)
        : NULL;
}

bool nbsp_parse_long(const char *text, long min, long max, long *out) {
    if (!text || !*text || !out) {
        return false;
    }
    errno = 0;
    char *end = NULL;
    long value = strtol(text, &end, 10);
    if (errno != 0 || !end || *end != '\0' || value < min || value > max) {
        return false;
    }
    *out = value;
    return true;
}

bool nbsp_parse_u64(const char *text, uint64_t *out) {
    if (!text || !*text || !out || *text == '-') {
        return false;
    }
    errno = 0;
    char *end = NULL;
    unsigned long long value = strtoull(text, &end, 10);
    if (errno != 0 || !end || *end != '\0') {
        return false;
    }
    *out = (uint64_t) value;
    return true;
}

uint64_t nbsp_hash_path(const char *path) {
    uint64_t hash = UINT64_C(14695981039346656037);
    if (!path) {
        return hash;
    }
    for (const unsigned char *p = (const unsigned char *) path; *p; ++p) {
        hash ^= (uint64_t) *p;
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

static uint64_t clock_millis(clockid_t clock_id) {
    struct timespec value;
    if (clock_gettime(clock_id, &value) != 0) {
        return 0U;
    }
    return (uint64_t) value.tv_sec * UINT64_C(1000) + (uint64_t) value.tv_nsec / UINT64_C(1000000);
}

uint64_t nbsp_wall_millis(void) {
    return clock_millis(CLOCK_REALTIME);
}

uint64_t nbsp_monotonic_millis(void) {
    return clock_millis(CLOCK_MONOTONIC);
}

bool nbsp_ends_with(const char *text, const char *suffix) {
    if (!text || !suffix) {
        return false;
    }
    size_t text_len = strlen(text);
    size_t suffix_len = strlen(suffix);
    return text_len >= suffix_len && strcmp(text + text_len - suffix_len, suffix) == 0;
}
