#include "nbsp_dirs.h"

#include <dirent.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "nbsp_util.h"

struct nbsp_dir_list {
    char *names[NBSP_DIR_MAX_ENTRIES];
    size_t count;
    size_t bytes;
};

static void dir_list_free(struct nbsp_dir_list *list) {
    if (!list) return;
    for (size_t i = 0U; i < list->count; ++i) {
        free(list->names[i]);
    }
    list->count = 0U;
    list->bytes = 0U;
}

static bool entry_is_directory(DIR *directory, const struct dirent *entry) {
    if (entry->d_type == DT_DIR) return true;
    if (entry->d_type != DT_UNKNOWN && entry->d_type != DT_LNK) return false;

    struct stat info;
    return fstatat(dirfd(directory), entry->d_name, &info, 0) == 0 &&
        S_ISDIR(info.st_mode);
}

static int compare_names(const void *left, const void *right) {
    const char *const *left_name = left;
    const char *const *right_name = right;
    return strcmp(*left_name, *right_name);
}

static bool write_record(FILE *out, const char *key, const char *value) {
    size_t key_len = strlen(key);
    size_t value_len = strlen(value);
    if (key_len > SIZE_MAX - value_len - 2U) return false;

    size_t record_len = key_len + value_len + 2U;
    char record[512];
    if (record_len > sizeof record) return false;
    memcpy(record, key, key_len);
    record[key_len] = '\0';
    memcpy(record + key_len + 1U, value, value_len);
    record[record_len - 1U] = '\0';
    return fwrite(record, 1U, record_len, out) == record_len;
}

bool nbsp_dirs_write(FILE *out, const char *cwd) {
    if (!out || !cwd || cwd[0] == '\0') return false;

    DIR *directory = opendir(cwd);
    if (!directory) return false;

    struct nbsp_dir_list list = {
        .bytes = sizeof("schema_version") + sizeof("1") +
            sizeof("complete") + sizeof("1")
    };
    bool ok = true;
    for (;;) {
        errno = 0;
        struct dirent *entry = readdir(directory);
        if (!entry) {
            if (errno != 0) ok = false;
            break;
        }
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0 ||
            !entry_is_directory(directory, entry)) {
            continue;
        }

        size_t name_len = strlen(entry->d_name);
        size_t record_bytes = sizeof("dir") + name_len + 1U;
        if (list.count >= NBSP_DIR_MAX_ENTRIES ||
            record_bytes > NBSP_DIR_MAX_BYTES ||
            list.bytes > NBSP_DIR_MAX_BYTES - record_bytes) {
            ok = false;
            break;
        }
        char *name = nbsp_strdup(entry->d_name);
        if (!name) {
            ok = false;
            break;
        }
        list.names[list.count++] = name;
        list.bytes += record_bytes;
    }
    if (closedir(directory) != 0) ok = false;

    if (ok) {
        qsort(list.names, list.count, sizeof list.names[0], compare_names);
        ok = write_record(out, "schema_version", "1");
        for (size_t i = 0U; ok && i < list.count; ++i) {
            ok = write_record(out, "dir", list.names[i]);
        }
        if (ok) ok = write_record(out, "complete", "1");
    }

    dir_list_free(&list);
    return ok;
}
