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

static bool mkdir_p(const char *path) {
    if (!path || path[0] != '/' || strlen(path) >= PATH_MAX) {
        return false;
    }
    char copy[PATH_MAX];
    (void) snprintf(copy, sizeof copy, "%s", path);
    for (char *p = copy + 1; *p; ++p) {
        if (*p != '/') {
            continue;
        }
        *p = '\0';
        if (mkdir(copy, 0700) != 0 && errno != EEXIST) {
            return false;
        }
        *p = '/';
    }
    return mkdir(copy, 0700) == 0 || errno == EEXIST;
}

static bool cache_root(char *out, size_t out_len) {
    const char *override = getenv("NBSP_CACHE_DIR");
    if (override && override[0] == '/') {
        return snprintf(out, out_len, "%s", override) > 0 && strlen(override) + 1U <= out_len;
    }
    const char *xdg = getenv("XDG_CACHE_HOME");
    if (xdg && xdg[0] == '/') {
        int count = snprintf(out, out_len, "%s/nbsp", xdg);
        return count > 0 && (size_t) count < out_len;
    }
    const char *home = getenv("HOME");
    if (home && home[0] == '/') {
        int count = snprintf(out, out_len, "%s/Library/Caches/nbsp", home);
        return count > 0 && (size_t) count < out_len;
    }
    int count = snprintf(out, out_len, "/tmp/nbsp-%lu", (unsigned long) getuid());
    return count > 0 && (size_t) count < out_len;
}

bool nbsp_cache_git_dir(char *out, size_t out_len, bool create) {
    char root[PATH_MAX];
    if (!cache_root(root, sizeof root)) {
        return false;
    }
    if (create && !mkdir_p(root)) {
        return false;
    }
    int count = snprintf(out, out_len, "%s/git", root);
    if (count <= 0 || (size_t) count >= out_len) {
        return false;
    }
    return !create || mkdir_p(out);
}

static bool cache_path(const char *repo_root,
    const char *suffix,
    bool create,
    char *out,
    size_t out_len) {
    char dir[PATH_MAX];
    if (!nbsp_cache_git_dir(dir, sizeof dir, create)) {
        return false;
    }
    uint64_t key = nbsp_hash_path(repo_root);
    int count = snprintf(out, out_len, "%s/%016" PRIx64 "%s", dir, key, suffix);
    return count > 0 && (size_t) count < out_len;
}

static bool parse_unsigned(const char *text, unsigned *out) {
    uint64_t value = 0U;
    if (!nbsp_parse_u64(text, &value) || value > UINT_MAX) {
        return false;
    }
    *out = (unsigned) value;
    return true;
}

static int encoded_hex(char value) {
    if (value >= '0' && value <= '9') return value - '0';
    if (value >= 'A' && value <= 'F') return value - 'A' + 10;
    if (value >= 'a' && value <= 'f') return value - 'a' + 10;
    return -1;
}

static bool percent_decode_into(const char *encoded, char *out, size_t out_len) {
    if (!encoded || !out || out_len == 0U) {
        return false;
    }
    size_t written = 0U;
    for (size_t i = 0U; encoded[i]; ++i) {
        unsigned char value = (unsigned char) encoded[i];
        if (value == '%') {
            int hi = encoded_hex(encoded[i + 1U]);
            int lo = encoded[i + 1U] ? encoded_hex(encoded[i + 2U]) : -1;
            if (hi < 0 || lo < 0) return false;
            value = (unsigned char) ((hi << 4) | lo);
            if (value == 0U) return false;
            i += 2U;
        }
        if (written + 1U >= out_len) return false;
        out[written++] = (char) value;
    }
    out[written] = '\0';
    return true;
}

static bool percent_encoded_equals(const char *encoded, const char *plain) {
    if (!encoded || !plain) return false;
    size_t encoded_at = 0U;
    size_t plain_at = 0U;
    while (encoded[encoded_at]) {
        unsigned char value = (unsigned char) encoded[encoded_at++];
        if (value == '%') {
            int hi = encoded_hex(encoded[encoded_at]);
            int lo = encoded[encoded_at] ? encoded_hex(encoded[encoded_at + 1U]) : -1;
            if (hi < 0 || lo < 0) return false;
            value = (unsigned char) ((hi << 4) | lo);
            if (value == 0U) return false;
            encoded_at += 2U;
        }
        if ((unsigned char) plain[plain_at++] != value) return false;
    }
    return plain[plain_at] == '\0';
}

bool nbsp_cache_load(const char *repo_root, struct nbsp_git_status *status) {
    if (!repo_root || !status) {
        return false;
    }
    memset(status, 0, sizeof *status);

    char path[PATH_MAX];
    if (!cache_path(repo_root, ".cache", false, path, sizeof path)) {
        return false;
    }
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        return false;
    }

    struct stat info;
    if (fstat(fd, &info) != 0 || info.st_size <= 0 || info.st_size >= 16384) {
        (void) close(fd);
        return false;
    }
    char content[16384];
    size_t expected = (size_t) info.st_size;
    size_t offset = 0U;
    while (offset < expected) {
        ssize_t count = read(fd, content + offset, expected - offset);
        if (count > 0) {
            offset += (size_t) count;
        } else if (count < 0 && errno == EINTR) {
            continue;
        } else {
            (void) close(fd);
            return false;
        }
    }
    (void) close(fd);
    content[offset] = '\0';

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
    const unsigned required_fields = (1U << 11) - 1U;
    unsigned fields = 0U;
    char *save = NULL;
    for (char *line = strtok_r(content, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        size_t len = strlen(line);
        if (len && line[len - 1U] == '\r') line[len - 1U] = '\0';
        char *equals = strchr(line, '=');
        if (!equals) {
            continue;
        }
        *equals = '\0';
        const char *value = equals + 1U;
        if (strcmp(line, "version") == 0) {
            if (strcmp(value, "1") == 0) fields |= FIELD_VERSION;
        } else if (strcmp(line, "repo") == 0) {
            if (percent_encoded_equals(value, repo_root)) fields |= FIELD_REPO;
        } else if (strcmp(line, "updated_ms") == 0) {
            if (nbsp_parse_u64(value, &status->updated_ms) && status->updated_ms != 0U) {
                fields |= FIELD_UPDATED;
            }
        } else if (strcmp(line, "branch") == 0) {
            if (percent_decode_into(value, status->branch, sizeof status->branch)) {
                fields |= FIELD_BRANCH;
            }
        } else if (strcmp(line, "staged") == 0) {
            if (parse_unsigned(value, &status->staged)) fields |= FIELD_STAGED;
        } else if (strcmp(line, "modified") == 0) {
            if (parse_unsigned(value, &status->modified)) fields |= FIELD_MODIFIED;
        } else if (strcmp(line, "untracked") == 0) {
            if (parse_unsigned(value, &status->untracked)) fields |= FIELD_UNTRACKED;
        } else if (strcmp(line, "conflicted") == 0) {
            if (parse_unsigned(value, &status->conflicted)) fields |= FIELD_CONFLICTED;
        } else if (strcmp(line, "ahead") == 0) {
            if (parse_unsigned(value, &status->ahead)) fields |= FIELD_AHEAD;
        } else if (strcmp(line, "behind") == 0) {
            if (parse_unsigned(value, &status->behind)) fields |= FIELD_BEHIND;
        } else if (strcmp(line, "stashes") == 0) {
            if (parse_unsigned(value, &status->stashes)) fields |= FIELD_STASHES;
        }
    }
    status->valid = fields == required_fields;
    return status->valid;
}

bool nbsp_cache_store(const char *repo_root, const struct nbsp_git_status *status) {
    if (!repo_root || !status || !status->valid) {
        return false;
    }
    char path[PATH_MAX];
    if (!cache_path(repo_root, ".cache", true, path, sizeof path)) {
        return false;
    }
    char temp[PATH_MAX];
    int count = snprintf(temp, sizeof temp, "%s.tmp.%ld", path, (long) getpid());
    if (count <= 0 || (size_t) count >= sizeof temp) {
        return false;
    }

    int fd = open(temp, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) {
        return false;
    }
    FILE *file = fdopen(fd, "w");
    if (!file) {
        (void) close(fd);
        (void) unlink(temp);
        return false;
    }

    char *repo_encoded = nbsp_percent_encode(repo_root);
    char *branch_encoded = nbsp_percent_encode(status->branch);
    bool ok = repo_encoded && branch_encoded &&
        fprintf(file,
            "version=1\n"
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

    if (ok && fflush(file) != 0) {
        ok = false;
    }
    if (ok && fsync(fd) != 0) {
        ok = false;
    }
    if (fclose(file) != 0) {
        ok = false;
    }
    if (ok && rename(temp, path) != 0) {
        ok = false;
    }
    if (!ok) {
        (void) unlink(temp);
    }
    return ok;
}

int nbsp_cache_lock(const char *repo_root, unsigned stale_after_ms, char *path, size_t path_len) {
    if (!repo_root || !path || !cache_path(repo_root, ".lock", true, path, path_len)) {
        return -1;
    }
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd >= 0) {
        (void) dprintf(fd, "%ld\n", (long) getpid());
        return fd;
    }
    if (errno != EEXIST) {
        return -1;
    }

    struct stat info;
    if (stat(path, &info) != 0) {
        return -1;
    }
    uint64_t now = nbsp_wall_millis();
    uint64_t modified = (uint64_t) info.st_mtime * UINT64_C(1000);
    uint64_t threshold = (uint64_t) stale_after_ms + UINT64_C(5000);
    if (now <= modified || now - modified <= threshold || unlink(path) != 0) {
        return -1;
    }
    fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd >= 0) {
        (void) dprintf(fd, "%ld\n", (long) getpid());
    }
    return fd;
}

void nbsp_cache_unlock(int fd, const char *path) {
    if (fd >= 0) {
        (void) close(fd);
    }
    if (path && *path) {
        (void) unlink(path);
    }
}

int nbsp_cache_clear(void) {
    char dir[PATH_MAX];
    if (!nbsp_cache_git_dir(dir, sizeof dir, false)) {
        return -1;
    }
    DIR *handle = opendir(dir);
    if (!handle) {
        return errno == ENOENT ? 0 : -1;
    }
    int result = 0;
    struct dirent *entry = NULL;
    while ((entry = readdir(handle)) != NULL) {
        if (entry->d_name[0] == '.' &&
            (entry->d_name[1] == '\0' ||
                (entry->d_name[1] == '.' && entry->d_name[2] == '\0'))) {
            continue;
        }
        if (!nbsp_ends_with(entry->d_name, ".cache") &&
            !nbsp_ends_with(entry->d_name, ".lock") &&
            strstr(entry->d_name, ".cache.tmp.") == NULL) {
            continue;
        }
        char path[PATH_MAX];
        int count = snprintf(path, sizeof path, "%s/%s", dir, entry->d_name);
        if (count <= 0 || (size_t) count >= sizeof path || unlink(path) != 0) {
            result = -1;
        }
    }
    (void) closedir(handle);
    return result;
}
