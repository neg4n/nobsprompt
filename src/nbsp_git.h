#ifndef NBSP_GIT_H
#define NBSP_GIT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "nbsp_util.h"

struct nbsp_repo {
    char root[NBSP_PATH_CAP];
    char git_dir[NBSP_PATH_CAP];
};

struct nbsp_git_status {
    bool valid;
    uint64_t updated_ms;
    char branch[256];
    unsigned staged;
    unsigned modified;
    unsigned untracked;
    unsigned conflicted;
    unsigned ahead;
    unsigned behind;
    unsigned stashes;
};

enum nbsp_git_result {
    NBSP_GIT_OK = 0,
    NBSP_GIT_ERROR = 1,
    NBSP_GIT_TIMEOUT = 124,
};

void nbsp_repo_free(struct nbsp_repo *repo);
bool nbsp_git_discover(const char *cwd, struct nbsp_repo *out);
bool nbsp_git_read_branch(const struct nbsp_repo *repo, char *out, size_t out_len);
bool nbsp_git_parse_status(const char *output, struct nbsp_git_status *status);
int nbsp_git_collect(const struct nbsp_repo *repo,
    unsigned timeout_ms,
    struct nbsp_git_status *status);

#endif /* NBSP_GIT_H */
