#include "nbsp_refresh.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "nbsp_cache.h"
#include "nbsp_git.h"
#include "nbsp_util.h"

#define NBSP_GIT_TIMEOUT_MS 1500U
#define NBSP_CACHE_FRESH_MS UINT64_C(250)

static unsigned env_unsigned(const char *name, unsigned fallback, unsigned min, unsigned max) {
    const char *value = getenv(name);
    long parsed = 0;
    if (!value || !nbsp_parse_long(value, (long) min, (long) max, &parsed)) {
        return fallback;
    }
    return (unsigned) parsed;
}

unsigned nbsp_git_timeout_from_env(void) {
    return env_unsigned("NBSP_GIT_TIMEOUT_MS", NBSP_GIT_TIMEOUT_MS, 50U, 60000U);
}

static void send_notification(bool notify) {
    if (notify) {
        (void) fputc('\n', stdout);
        (void) fflush(stdout);
    }
}

static bool cache_is_fresh(const struct nbsp_git_status *cached) {
    uint64_t now = nbsp_wall_millis();
    return now >= cached->updated_ms &&
        now - cached->updated_ms < NBSP_CACHE_FRESH_MS;
}

int nbsp_refresh(const char *cwd, unsigned timeout_ms, bool notify, bool force) {
    struct nbsp_repo repo;
    int lock_fd = -1;
    int result = 0;

    if (!nbsp_git_discover(cwd, &repo)) {
        goto done;
    }

    struct nbsp_git_status cached;
    if (!force && nbsp_cache_load(repo.root, &cached) && cache_is_fresh(&cached)) {
        goto done;
    }

    lock_fd = nbsp_cache_lock(repo.root);
    if (lock_fd == NBSP_CACHE_LOCK_BUSY) {
        lock_fd = -1;
        goto done;
    }
    if (lock_fd == NBSP_CACHE_LOCK_ERROR) {
        lock_fd = -1;
        result = 1;
        goto done;
    }

    if (!force && nbsp_cache_load(repo.root, &cached) && cache_is_fresh(&cached)) {
        goto done;
    }

    struct nbsp_git_status fresh;
    result = nbsp_git_collect(&repo, timeout_ms, &fresh);
    if (result == NBSP_GIT_OK) {
        char branch[sizeof fresh.branch];
        if (!nbsp_git_read_branch(&repo, branch, sizeof branch) ||
            strcmp(branch, fresh.branch) != 0 ||
            !nbsp_cache_store(repo.root, &fresh)) {
            result = NBSP_GIT_ERROR;
        }
    }

done:
    if (lock_fd >= 0) {
        nbsp_cache_unlock(lock_fd);
    }
    nbsp_repo_clear(&repo);
    send_notification(notify);
    return result;
}
