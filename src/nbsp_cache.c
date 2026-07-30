#include "nbsp_cache.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include "nbsp_util.h"

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

enum cache_dir_result {
    CACHE_DIR_OK,
    CACHE_DIR_MISSING,
    CACHE_DIR_ERROR,
};

static bool normalize_cache_path(const char *base,
    const char *suffix,
    char *out,
    size_t out_len) {
    if (!base || base[0] != '/' || !suffix || !out || out_len < 2U) {
        return false;
    }

    char combined[PATH_MAX];
    int count = snprintf(combined, sizeof combined, "%s%s", base, suffix);
    if (count <= 0 || (size_t) count >= sizeof combined) {
        return false;
    }

    size_t written = 1U;
    out[0] = '/';
    out[1] = '\0';
    const char *cursor = combined;
    while (*cursor == '/') ++cursor;
    while (*cursor) {
        const char *component = cursor;
        while (*cursor && *cursor != '/') ++cursor;
        size_t length = (size_t) (cursor - component);
        if ((length == 1U && component[0] == '.') ||
            (length == 2U && component[0] == '.' && component[1] == '.')) {
            return false;
        }
        if (written != 1U) {
            if (written + 1U >= out_len) return false;
            out[written++] = '/';
        }
        if (length >= out_len - written) return false;
        memcpy(out + written, component, length);
        written += length;
        out[written] = '\0';
        while (*cursor == '/') ++cursor;
    }
    return written > 1U;
}

static bool canonicalize_platform_alias(const char *path,
    char *out,
    size_t out_len) {
    if (!path || path[0] != '/' || !out || out_len == 0U) {
        errno = EINVAL;
        return false;
    }

    const char *component_end = strchr(path + 1U, '/');
    size_t component_len = component_end ?
        (size_t) (component_end - path) : strlen(path);
    if (component_len < 2U || component_len >= PATH_MAX) {
        errno = EINVAL;
        return false;
    }

    char first_component[PATH_MAX];
    memcpy(first_component, path, component_len);
    first_component[component_len] = '\0';

    struct stat info;
    if (lstat(first_component, &info) != 0) {
        if (errno != ENOENT) return false;
        int count = snprintf(out, out_len, "%s", path);
        if (count <= 0 || (size_t) count >= out_len) errno = ENAMETOOLONG;
        return count > 0 && (size_t) count < out_len;
    }
    if (!S_ISLNK(info.st_mode)) {
        int count = snprintf(out, out_len, "%s", path);
        if (count <= 0 || (size_t) count >= out_len) errno = ENAMETOOLONG;
        return count > 0 && (size_t) count < out_len;
    }

    const char *expected_link = NULL;
    const char *replacement = NULL;
#ifdef __APPLE__
    if (strcmp(first_component, "/tmp") == 0) {
        expected_link = "private/tmp";
        replacement = "/private/tmp";
    } else if (strcmp(first_component, "/var") == 0) {
        expected_link = "private/var";
        replacement = "/private/var";
    }
#endif
    if (info.st_uid != 0 || !expected_link || !replacement) {
        errno = ELOOP;
        return false;
    }
    char target[PATH_MAX];
    ssize_t target_len = readlink(first_component, target, sizeof target - 1U);
    if (target_len < 0) return false;
    target[target_len] = '\0';
    if (strcmp(target, expected_link) != 0) {
        errno = ELOOP;
        return false;
    }
    return normalize_cache_path(
        replacement, component_end ? component_end : "", out, out_len);
}

static bool select_cache_path(const char *base,
    const char *suffix,
    char *out,
    size_t out_len) {
    char normalized[PATH_MAX];
    if (!normalize_cache_path(base, suffix, normalized, sizeof normalized)) {
        errno = EINVAL;
        return false;
    }
    return canonicalize_platform_alias(normalized, out, out_len);
}

static bool cache_root(char *out, size_t out_len) {
    const char *override = getenv("NBSP_CACHE_DIR");
    if (override) {
        return select_cache_path(override, "", out, out_len);
    }

    const char *xdg = getenv("XDG_CACHE_HOME");
    if (xdg && xdg[0] == '/') {
        return select_cache_path(xdg, "/nbsp", out, out_len);
    }

    const char *home = getenv("HOME");
    if (!home) {
        errno = ENOENT;
        return false;
    }
    return select_cache_path(home, "/Library/Caches/nbsp", out, out_len);
}

static bool secure_directory(const struct stat *info) {
    return info && S_ISDIR(info->st_mode) && info->st_uid == getuid() &&
        (info->st_mode & 07777) == 0700;
}

static bool secure_regular_file(const struct stat *info) {
    return info && S_ISREG(info->st_mode) && info->st_uid == getuid() &&
        (info->st_mode & 07777) == 0600 && info->st_nlink == 1;
}

static enum cache_dir_result open_directory_tree(const char *path,
    bool create,
    int *fd_out) {
    if (!path || path[0] != '/' || strlen(path) >= PATH_MAX || !fd_out) {
        errno = EINVAL;
        return CACHE_DIR_ERROR;
    }
    *fd_out = -1;

    char components[PATH_MAX];
    (void) snprintf(components, sizeof components, "%s", path + 1U);
    char *cursor = components;
    int current_fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (current_fd < 0) return CACHE_DIR_ERROR;

    while (*cursor) {
        char *slash = strchr(cursor, '/');
        if (slash) *slash = '\0';
        int flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC;
        int next_fd = openat(current_fd,
            cursor,
            flags);
        if (next_fd < 0 && errno == ENOENT && create) {
            if (mkdirat(current_fd, cursor, 0700) != 0 && errno != EEXIST) {
                int mkdir_error = errno;
                (void) close(current_fd);
                errno = mkdir_error;
                return CACHE_DIR_ERROR;
            }
            next_fd = openat(current_fd, cursor, flags);
        }
        if (next_fd < 0) {
            int open_error = errno;
            enum cache_dir_result result = !create && errno == ENOENT ?
                CACHE_DIR_MISSING : CACHE_DIR_ERROR;
            (void) close(current_fd);
            errno = open_error;
            return result;
        }
        if (close(current_fd) != 0) {
            int close_error = errno;
            (void) close(next_fd);
            errno = close_error;
            return CACHE_DIR_ERROR;
        }
        current_fd = next_fd;
        if (!slash) break;
        cursor = slash + 1U;
    }

    struct stat root_info;
    if (fstat(current_fd, &root_info) != 0) {
        int stat_error = errno;
        (void) close(current_fd);
        errno = stat_error;
        return CACHE_DIR_ERROR;
    }
    if (!secure_directory(&root_info)) {
        (void) close(current_fd);
        errno = EACCES;
        return CACHE_DIR_ERROR;
    }
    *fd_out = current_fd;
    return CACHE_DIR_OK;
}

static enum cache_dir_result open_git_dir(bool create,
    char *path,
    size_t path_len,
    int *fd_out) {
    if (!path || path_len == 0U || !fd_out) {
        return CACHE_DIR_ERROR;
    }
    *fd_out = -1;

    char root[PATH_MAX];
    if (!cache_root(root, sizeof root)) {
        return CACHE_DIR_ERROR;
    }
    int root_fd = -1;
    enum cache_dir_result root_result = open_directory_tree(root, create, &root_fd);
    if (root_result != CACHE_DIR_OK) {
        return root_result;
    }

    if (create && mkdirat(root_fd, "git", 0700) != 0 && errno != EEXIST) {
        int mkdir_error = errno;
        (void) close(root_fd);
        errno = mkdir_error;
        return CACHE_DIR_ERROR;
    }
    int git_fd = openat(root_fd, "git", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (git_fd < 0) {
        int open_error = errno;
        enum cache_dir_result result = !create && errno == ENOENT ?
            CACHE_DIR_MISSING : CACHE_DIR_ERROR;
        (void) close(root_fd);
        errno = open_error;
        return result;
    }
    struct stat git_info;
    if (fstat(git_fd, &git_info) != 0) {
        int stat_error = errno;
        (void) close(git_fd);
        (void) close(root_fd);
        errno = stat_error;
        return CACHE_DIR_ERROR;
    }
    if (!secure_directory(&git_info)) {
        (void) close(git_fd);
        (void) close(root_fd);
        errno = EACCES;
        return CACHE_DIR_ERROR;
    }

    int count = snprintf(path, path_len, "%s/git", root);
    if (count <= 0 || (size_t) count >= path_len) {
        (void) close(root_fd);
        (void) close(git_fd);
        errno = ENAMETOOLONG;
        return CACHE_DIR_ERROR;
    }
    if (close(root_fd) != 0) {
        int close_error = errno;
        (void) close(git_fd);
        errno = close_error;
        return CACHE_DIR_ERROR;
    }
    *fd_out = git_fd;
    return CACHE_DIR_OK;
}

bool nbsp_cache_git_dir(char *out, size_t out_len, bool create) {
    int fd = -1;
    enum cache_dir_result result = open_git_dir(create, out, out_len, &fd);
    return result == CACHE_DIR_OK && close(fd) == 0;
}

static bool cache_name(const char *repo_root,
    const char *suffix,
    char *out,
    size_t out_len) {
    if (!repo_root || !suffix || !out || out_len == 0U) {
        return false;
    }
    int count = snprintf(out,
        out_len,
        "%016" PRIx64 "%s",
        nbsp_hash_path(repo_root),
        suffix);
    return count > 0 && (size_t) count < out_len;
}

static bool parse_decimal(const char *text, size_t length, uint64_t *out) {
    if (!text || length == 0U || !out) return false;
    uint64_t value = 0U;
    for (size_t i = 0U; i < length; ++i) {
        unsigned char byte = (unsigned char) text[i];
        if (byte < '0' || byte > '9') return false;
        uint64_t digit = (uint64_t) (byte - '0');
        if (value > (UINT64_MAX - digit) / UINT64_C(10)) return false;
        value = value * UINT64_C(10) + digit;
    }
    *out = value;
    return true;
}

static bool parse_unsigned(const char *text, size_t length, unsigned *out) {
    uint64_t value = 0U;
    if (!parse_decimal(text, length, &value) || value > UINT_MAX) return false;
    *out = (unsigned) value;
    return true;
}

static int encoded_hex(char value) {
    if (value >= '0' && value <= '9') return value - '0';
    if (value >= 'A' && value <= 'F') return value - 'A' + 10;
    if (value >= 'a' && value <= 'f') return value - 'a' + 10;
    return -1;
}

static bool encoded_literal_safe(unsigned char value) {
    return (value >= 'a' && value <= 'z') ||
        (value >= 'A' && value <= 'Z') ||
        (value >= '0' && value <= '9') ||
        value == '-' || value == '_' || value == '.' || value == '/';
}

static bool encoded_value_valid(const char *encoded, size_t encoded_len) {
    if (!encoded) return false;
    for (size_t i = 0U; i < encoded_len; ++i) {
        unsigned char value = (unsigned char) encoded[i];
        if (value == '%') {
            if (i + 2U >= encoded_len ||
                encoded_hex(encoded[i + 1U]) < 0 ||
                encoded_hex(encoded[i + 2U]) < 0 ||
                (encoded[i + 1U] == '0' && encoded[i + 2U] == '0')) {
                return false;
            }
            i += 2U;
        } else if (!encoded_literal_safe(value)) {
            return false;
        }
    }
    return true;
}

static bool branch_value_valid(const char *branch, size_t branch_len) {
    if (!branch || branch_len == 0U) return false;
    for (size_t i = 0U; i < branch_len; ++i) {
        unsigned char value = (unsigned char) branch[i];
        if (value < 0x20U || value == 0x7fU) return false;
    }
    return true;
}

static bool percent_decode_into(const char *encoded,
    size_t encoded_len,
    char *out,
    size_t out_len) {
    if (!encoded || !out || out_len == 0U) {
        return false;
    }
    size_t written = 0U;
    for (size_t i = 0U; i < encoded_len; ++i) {
        unsigned char value = (unsigned char) encoded[i];
        if (value == '%') {
            if (i + 2U >= encoded_len) return false;
            int hi = encoded_hex(encoded[i + 1U]);
            int lo = encoded_hex(encoded[i + 2U]);
            if (hi < 0 || lo < 0) return false;
            value = (unsigned char) ((hi << 4) | lo);
            if (value == 0U) return false;
            i += 2U;
        } else if (!encoded_literal_safe(value)) {
            return false;
        }
        if (written + 1U >= out_len) return false;
        out[written++] = (char) value;
    }
    out[written] = '\0';
    return true;
}

static bool percent_encoded_equals(const char *encoded,
    size_t encoded_len,
    const char *plain) {
    if (!encoded || !plain) return false;
    size_t encoded_at = 0U;
    size_t plain_at = 0U;
    while (encoded_at < encoded_len) {
        unsigned char value = (unsigned char) encoded[encoded_at++];
        if (value == '%') {
            if (encoded_at + 1U >= encoded_len) return false;
            int hi = encoded_hex(encoded[encoded_at]);
            int lo = encoded_hex(encoded[encoded_at + 1U]);
            if (hi < 0 || lo < 0) return false;
            value = (unsigned char) ((hi << 4) | lo);
            if (value == 0U) return false;
            encoded_at += 2U;
        } else if (!encoded_literal_safe(value)) {
            return false;
        }
        if (plain[plain_at] == '\0' || (unsigned char) plain[plain_at] != value) {
            return false;
        }
        ++plain_at;
    }
    return plain[plain_at] == '\0';
}

static bool span_equals(const char *text, size_t length, const char *expected) {
    size_t expected_len = strlen(expected);
    return length == expected_len && memcmp(text, expected, length) == 0;
}

bool nbsp_cache_parse(const char *content,
    const char *repo_root,
    struct nbsp_git_status *status) {
    enum {
        FIELD_VERSION = 1U << 0,
        FIELD_REPO = 1U << 1,
        FIELD_UPDATED = 1U << 2,
        FIELD_BRANCH = 1U << 3,
        FIELD_STAGED = 1U << 4,
        FIELD_MODIFIED = 1U << 5,
        FIELD_UNTRACKED = 1U << 6,
        FIELD_CONFLICTED = 1U << 7,
        FIELD_AHEAD = 1U << 8,
        FIELD_BEHIND = 1U << 9,
        FIELD_STASHES = 1U << 10,
    };
    if (!content || !repo_root || !status) return false;
    memset(status, 0, sizeof *status);
    size_t content_len = strnlen(content, 16384U);
    if (content_len == 0U || content_len >= 16384U) return false;

    const unsigned required_fields = (1U << 11) - 1U;
    unsigned fields = 0U;
    struct nbsp_git_status parsed = {0};

    const char *cursor = content;
    const char *end = content + content_len;
    while (cursor < end) {
        const char *newline = memchr(cursor, '\n', (size_t) (end - cursor));
        const char *line_end = newline ? newline : end;
        if (line_end > cursor && line_end[-1] == '\r') --line_end;
        size_t line_len = (size_t) (line_end - cursor);
        if (line_len == 0U) return false;

        const char *equals = memchr(cursor, '=', line_len);
        if (!equals || equals == cursor) return false;
        size_t key_len = (size_t) (equals - cursor);
        const char *value = equals + 1U;
        size_t value_len = (size_t) (line_end - value);
        if (memchr(value, '=', value_len)) return false;
        for (size_t i = 0U; i < key_len; ++i) {
            unsigned char byte = (unsigned char) cursor[i];
            if (!((byte >= 'a' && byte <= 'z') ||
                (byte >= '0' && byte <= '9') || byte == '_')) {
                return false;
            }
        }
        unsigned field = 0U;
        bool valid = true;

        if (span_equals(cursor, key_len, "version")) {
            field = FIELD_VERSION;
            valid = span_equals(value, value_len, "2");
        } else if (span_equals(cursor, key_len, "repo")) {
            field = FIELD_REPO;
            valid = percent_encoded_equals(value, value_len, repo_root);
        } else if (span_equals(cursor, key_len, "updated_ms")) {
            field = FIELD_UPDATED;
            valid = parse_decimal(value, value_len, &parsed.updated_ms) &&
                parsed.updated_ms != 0U;
        } else if (span_equals(cursor, key_len, "branch")) {
            field = FIELD_BRANCH;
            valid = percent_decode_into(
                    value, value_len, parsed.branch, sizeof parsed.branch) &&
                branch_value_valid(parsed.branch, strlen(parsed.branch));
        } else if (span_equals(cursor, key_len, "staged")) {
            field = FIELD_STAGED;
            valid = parse_unsigned(value, value_len, &parsed.staged);
        } else if (span_equals(cursor, key_len, "modified")) {
            field = FIELD_MODIFIED;
            valid = parse_unsigned(value, value_len, &parsed.modified);
        } else if (span_equals(cursor, key_len, "untracked")) {
            field = FIELD_UNTRACKED;
            valid = parse_unsigned(value, value_len, &parsed.untracked);
        } else if (span_equals(cursor, key_len, "conflicted")) {
            field = FIELD_CONFLICTED;
            valid = parse_unsigned(value, value_len, &parsed.conflicted);
        } else if (span_equals(cursor, key_len, "ahead")) {
            field = FIELD_AHEAD;
            valid = parse_unsigned(value, value_len, &parsed.ahead);
        } else if (span_equals(cursor, key_len, "behind")) {
            field = FIELD_BEHIND;
            valid = parse_unsigned(value, value_len, &parsed.behind);
        } else if (span_equals(cursor, key_len, "stashes")) {
            field = FIELD_STASHES;
            valid = parse_unsigned(value, value_len, &parsed.stashes);
        } else {
            valid = encoded_value_valid(value, value_len);
        }

        if (!valid) return false;
        if (field != 0U) {
            if ((fields & field) != 0U) return false;
            fields |= field;
        }
        cursor = newline ? newline + 1U : end;
    }

    if (fields != required_fields) return false;
    parsed.valid = true;
    *status = parsed;
    return true;
}

bool nbsp_cache_load(const char *repo_root, struct nbsp_git_status *status) {
    if (!repo_root || !status) {
        return false;
    }
    memset(status, 0, sizeof *status);

    char dir[PATH_MAX];
    int dir_fd = -1;
    if (open_git_dir(false, dir, sizeof dir, &dir_fd) != CACHE_DIR_OK) {
        return false;
    }
    char name[64];
    if (!cache_name(repo_root, ".cache", name, sizeof name)) {
        (void) close(dir_fd);
        return false;
    }
    int fd = openat(dir_fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) {
        (void) close(dir_fd);
        return false;
    }

    struct stat info;
    if (fstat(fd, &info) != 0 || !secure_regular_file(&info) ||
        info.st_size <= 0 || info.st_size >= 16384) {
        (void) close(fd);
        (void) close(dir_fd);
        return false;
    }

    char content[16384];
    size_t expected = (size_t) info.st_size;
    size_t offset = 0U;
    bool ok = true;
    while (offset < expected) {
        ssize_t count = read(fd, content + offset, expected - offset);
        if (count > 0) {
            offset += (size_t) count;
        } else if (count < 0 && errno == EINTR) {
            continue;
        } else {
            ok = false;
            break;
        }
    }
    if (ok) {
        char extra;
        ssize_t count;
        do {
            count = read(fd, &extra, 1U);
        } while (count < 0 && errno == EINTR);
        ok = count == 0;
    }
    if (close(fd) != 0) ok = false;
    if (close(dir_fd) != 0) ok = false;
    if (!ok) return false;

    if (memchr(content, '\0', offset)) return false;
    content[offset] = '\0';
    return nbsp_cache_parse(content, repo_root, status);
}

static int create_temp_file(int dir_fd,
    uint64_t key,
    char *name,
    size_t name_len) {
    uint64_t nonce = nbsp_monotonic_millis();
    for (unsigned attempt = 0U; attempt < 128U; ++attempt) {
        int count = snprintf(name,
            name_len,
            "%016" PRIx64 ".cache.tmp.%ld.%" PRIu64 ".%u",
            key,
            (long) getpid(),
            nonce,
            attempt);
        if (count <= 0 || (size_t) count >= name_len) return -1;
        int fd = openat(dir_fd,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0600);
        if (fd >= 0) {
            if (fchmod(fd, 0600) != 0) {
                (void) close(fd);
                (void) unlinkat(dir_fd, name, 0);
                return -1;
            }
            struct stat info;
            if (fstat(fd, &info) != 0 || !secure_regular_file(&info)) {
                (void) close(fd);
                (void) unlinkat(dir_fd, name, 0);
                return -1;
            }
            return fd;
        }
        if (errno != EEXIST) return -1;
    }
    return -1;
}

bool nbsp_cache_store(const char *repo_root, const struct nbsp_git_status *status) {
    if (!repo_root || !status || !status->valid || status->updated_ms == 0U) {
        return false;
    }
    size_t branch_len = strnlen(status->branch, sizeof status->branch);
    if (branch_len == sizeof status->branch ||
        !branch_value_valid(status->branch, branch_len)) return false;

    char dir[PATH_MAX];
    int dir_fd = -1;
    if (open_git_dir(true, dir, sizeof dir, &dir_fd) != CACHE_DIR_OK) {
        return false;
    }
    char name[64];
    if (!cache_name(repo_root, ".cache", name, sizeof name)) {
        (void) close(dir_fd);
        return false;
    }

    struct stat existing;
    if (fstatat(dir_fd, name, &existing, AT_SYMLINK_NOFOLLOW) == 0) {
        if (!secure_regular_file(&existing)) {
            (void) close(dir_fd);
            return false;
        }
    } else if (errno != ENOENT) {
        (void) close(dir_fd);
        return false;
    }

    char temp_name[128];
    int fd = create_temp_file(dir_fd, nbsp_hash_path(repo_root), temp_name, sizeof temp_name);
    if (fd < 0) {
        (void) close(dir_fd);
        return false;
    }
    FILE *file = fdopen(fd, "w");
    if (!file) {
        (void) close(fd);
        (void) unlinkat(dir_fd, temp_name, 0);
        (void) close(dir_fd);
        return false;
    }

    char *repo_encoded = nbsp_percent_encode(repo_root);
    char *branch_encoded = nbsp_percent_encode(status->branch);
    bool ok = repo_encoded && branch_encoded &&
        fprintf(file,
            "version=2\n"
            "repo=%s\n"
            "updated_ms=%" PRIu64 "\n"
            "branch=%s\n"
            "staged=%u\n"
            "modified=%u\n"
            "untracked=%u\n"
            "conflicted=%u\n"
            "ahead=%u\n"
            "behind=%u\n"
            "stashes=%u\n",
            repo_encoded,
            status->updated_ms,
            branch_encoded,
            status->staged,
            status->modified,
            status->untracked,
            status->conflicted,
            status->ahead,
            status->behind,
            status->stashes) > 0;
    free(repo_encoded);
    free(branch_encoded);

    if (ok && fflush(file) != 0) ok = false;
    if (ok && fsync(fd) != 0) ok = false;
    if (fclose(file) != 0) ok = false;

    if (ok && renameat(dir_fd, temp_name, dir_fd, name) != 0) {
        ok = false;
    }
    if (!ok && unlinkat(dir_fd, temp_name, 0) != 0 && errno != ENOENT) {
        ok = false;
    }
    if (close(dir_fd) != 0) ok = false;
    return ok;
}

int nbsp_cache_lock(const char *repo_root) {
    if (!repo_root) return NBSP_CACHE_LOCK_ERROR;

    char dir[PATH_MAX];
    int dir_fd = -1;
    if (open_git_dir(true, dir, sizeof dir, &dir_fd) != CACHE_DIR_OK) {
        return NBSP_CACHE_LOCK_ERROR;
    }
    char name[64];
    if (!cache_name(repo_root, ".lock", name, sizeof name)) {
        (void) close(dir_fd);
        return NBSP_CACHE_LOCK_ERROR;
    }

    bool created = true;
    int fd = openat(dir_fd,
        name,
        O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
        0600);
    if (fd < 0 && errno == EEXIST) {
        created = false;
        fd = openat(dir_fd, name, O_RDWR | O_NOFOLLOW | O_CLOEXEC);
    }
    if (fd < 0) {
        (void) close(dir_fd);
        return NBSP_CACHE_LOCK_ERROR;
    }
    if (created && fchmod(fd, 0600) != 0) {
        (void) close(fd);
        (void) unlinkat(dir_fd, name, 0);
        (void) close(dir_fd);
        return NBSP_CACHE_LOCK_ERROR;
    }
    struct stat info;
    if (fstat(fd, &info) != 0 || !secure_regular_file(&info)) {
        (void) close(fd);
        if (created) (void) unlinkat(dir_fd, name, 0);
        (void) close(dir_fd);
        return NBSP_CACHE_LOCK_ERROR;
    }

    struct flock lock = {
        .l_type = F_WRLCK,
        .l_whence = SEEK_SET,
        .l_start = 0,
        .l_len = 0,
    };
    if (fcntl(fd, F_SETLK, &lock) != 0) {
        int lock_error = errno;
        (void) close(fd);
        (void) close(dir_fd);
        return lock_error == EACCES || lock_error == EAGAIN ?
            NBSP_CACHE_LOCK_BUSY : NBSP_CACHE_LOCK_ERROR;
    }
    if (close(dir_fd) != 0) {
        (void) close(fd);
        return NBSP_CACHE_LOCK_ERROR;
    }
    return fd;
}

void nbsp_cache_unlock(int fd) {
    if (fd < 0) return;
    struct flock lock = {
        .l_type = F_UNLCK,
        .l_whence = SEEK_SET,
        .l_start = 0,
        .l_len = 0,
    };
    (void) fcntl(fd, F_SETLK, &lock);
    (void) close(fd);
}

static bool cache_artifact_name(const char *name) {
    if (!name || strlen(name) < 22U) return false;
    for (size_t i = 0U; i < 16U; ++i) {
        if (!((name[i] >= '0' && name[i] <= '9') ||
            (name[i] >= 'a' && name[i] <= 'f'))) {
            return false;
        }
    }
    if (strcmp(name + 16U, ".cache") == 0) return true;
    return strncmp(name + 16U, ".cache.tmp.", 11U) == 0 && name[27] != '\0';
}

static void free_artifact_names(char **names, size_t count) {
    if (!names) return;
    for (size_t i = 0U; i < count; ++i) free(names[i]);
    free(names);
}

static bool append_artifact_name(char ***names,
    size_t *count,
    size_t *capacity,
    const char *name) {
    if (!names || !count || !capacity || !name) {
        errno = EINVAL;
        return false;
    }
    if (*count == *capacity) {
        size_t next = *capacity ? *capacity * 2U : 16U;
        if (next < *capacity || next > SIZE_MAX / sizeof **names) {
            errno = ENOMEM;
            return false;
        }
        char **grown = realloc(*names, next * sizeof **names);
        if (!grown) return false;
        *names = grown;
        *capacity = next;
    }
    size_t length = strlen(name) + 1U;
    char *copy = malloc(length);
    if (!copy) return false;
    memcpy(copy, name, length);
    (*names)[(*count)++] = copy;
    return true;
}

int nbsp_cache_clear(void) {
    char dir[PATH_MAX];
    int dir_fd = -1;
    enum cache_dir_result dir_result = open_git_dir(false, dir, sizeof dir, &dir_fd);
    if (dir_result == CACHE_DIR_MISSING) return 0;
    if (dir_result != CACHE_DIR_OK) {
        if (errno == 0) errno = EIO;
        return -1;
    }

    int unlink_fd = fcntl(dir_fd, F_DUPFD_CLOEXEC, 0);
    if (unlink_fd < 0) {
        int duplicate_error = errno;
        (void) close(dir_fd);
        errno = duplicate_error;
        return -1;
    }
    DIR *handle = fdopendir(dir_fd);
    if (!handle) {
        int stream_error = errno;
        (void) close(dir_fd);
        (void) close(unlink_fd);
        errno = stream_error;
        return -1;
    }

    char **names = NULL;
    size_t count = 0U;
    size_t capacity = 0U;
    int scan_error = 0;
    for (;;) {
        errno = 0;
        struct dirent *entry = readdir(handle);
        if (!entry) {
            scan_error = errno;
            break;
        }
        if (!cache_artifact_name(entry->d_name)) continue;
        if (!append_artifact_name(&names, &count, &capacity, entry->d_name)) {
            scan_error = errno ? errno : ENOMEM;
            break;
        }
    }
    if (closedir(handle) != 0 && scan_error == 0) scan_error = errno;
    if (scan_error != 0) {
        free_artifact_names(names, count);
        (void) close(unlink_fd);
        errno = scan_error;
        return -1;
    }

    int first_error = 0;
    for (size_t i = 0U; i < count; ++i) {
        struct stat info;
        if (fstatat(unlink_fd, names[i], &info, AT_SYMLINK_NOFOLLOW) != 0) {
            if (errno != ENOENT && first_error == 0) first_error = errno;
        } else if (!secure_regular_file(&info)) {
            if (first_error == 0) first_error = EPERM;
        } else if (unlinkat(unlink_fd, names[i], 0) != 0 &&
            errno != ENOENT && first_error == 0) {
            first_error = errno;
        }
    }
    free_artifact_names(names, count);
    if (close(unlink_fd) != 0 && first_error == 0) first_error = errno;
    if (first_error != 0) {
        errno = first_error;
        return -1;
    }
    return 0;
}
