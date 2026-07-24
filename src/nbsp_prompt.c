#include "nbsp_prompt.h"

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "nbsp_cache.h"
#include "nbsp_git.h"
#include "nbsp_util.h"

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

#define NBSP_DURATION_THRESHOLD_MS 2000U
#define NBSP_GIT_TIMEOUT_MS 1500U

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

bool nbsp_prompt_data_collect(const char *cwd,
    int last_status,
    unsigned long duration_ms,
    unsigned jobs,
    struct nbsp_prompt_data *data) {
    if (!cwd || !data) {
        return false;
    }

    memset(data, 0, sizeof *data);
    int cwd_count = snprintf(data->cwd, sizeof data->cwd, "%s", cwd);
    if (cwd_count < 0 || (size_t) cwd_count >= sizeof data->cwd ||
        !nbsp_path_abbreviate_into(cwd, data->path, sizeof data->path)) {
        return false;
    }
    data->status = last_status;
    data->duration_ms = duration_ms;
    data->jobs = jobs;

    struct nbsp_repo repo;
    if (nbsp_git_discover(cwd, &repo)) {
        data->git_present = true;
        struct nbsp_git_status cached;
        if (nbsp_cache_load(repo.root, &cached)) {
            data->git_valid = true;
            data->git_updated_ms = cached.updated_ms;
            data->git_staged = cached.staged;
            data->git_modified = cached.modified;
            data->git_untracked = cached.untracked;
            data->git_conflicted = cached.conflicted;
            data->git_ahead = cached.ahead;
            data->git_behind = cached.behind;
            data->git_stashes = cached.stashes;
        } else {
            memset(&cached, 0, sizeof cached);
        }
        if (!nbsp_git_read_branch(&repo, data->git_branch, sizeof data->git_branch) &&
            cached.branch[0] != '\0') {
            (void) snprintf(data->git_branch, sizeof data->git_branch, "%s", cached.branch);
        }
        nbsp_repo_free(&repo);
    }

    (void) nbsp_nvm_version_into(
        getenv("NVM_BIN"),
        data->node_version,
        sizeof data->node_version);
    return true;
}

static bool append_escaped(struct nbsp_buf *buf, const char *text) {
    for (const unsigned char *p = (const unsigned char *) text; *p; ++p) {
        if (*p == '%') {
            if (!nbsp_buf_append(buf, "%%")) return false;
        } else if (*p < 32U || *p == 127U) {
            if (!nbsp_buf_append_char(buf, '?')) return false;
        } else if (!nbsp_buf_append_char(buf, (char) *p)) {
            return false;
        }
    }
    return true;
}

static bool append_colored(struct nbsp_buf *buf, const char *color, const char *text) {
    return nbsp_buf_appendf(buf, "%%F{%s}", color) &&
        append_escaped(buf, text) &&
        nbsp_buf_append(buf, "%f");
}

static bool append_git(struct nbsp_buf *buf, const struct nbsp_prompt_data *data) {
    if (!nbsp_buf_append(buf, "%F{default}[")) {
        return false;
    }
    bool ok = append_escaped(buf, data->git_branch);
    if (ok && data->git_valid) {
        if (data->git_staged) ok = nbsp_buf_appendf(buf, " +%u", data->git_staged);
        if (ok && data->git_modified) ok = nbsp_buf_appendf(buf, " ~%u", data->git_modified);
        if (ok && data->git_untracked) ok = nbsp_buf_appendf(buf, " ?%u", data->git_untracked);
        if (ok && data->git_conflicted) ok = nbsp_buf_appendf(buf, " !%u", data->git_conflicted);
        if (ok && data->git_ahead) ok = nbsp_buf_appendf(buf, " ^%u", data->git_ahead);
        if (ok && data->git_behind) ok = nbsp_buf_appendf(buf, " v%u", data->git_behind);
        if (ok && data->git_stashes) ok = nbsp_buf_appendf(buf, " *%u", data->git_stashes);
    } else if (ok) {
        ok = nbsp_buf_append(buf, " ...");
    }
    return ok && nbsp_buf_append(buf, "]%f");
}

static bool append_duration(struct nbsp_buf *buf, unsigned long duration_ms) {
    char text[64];
    if (duration_ms < 1000UL) {
        (void) snprintf(text, sizeof text, "[%lums]", duration_ms);
    } else if (duration_ms < 60000UL) {
        unsigned long tenths = (duration_ms + 50UL) / 100UL;
        (void) snprintf(text, sizeof text, "[%lu.%lus]", tenths / 10UL, tenths % 10UL);
    } else {
        unsigned long total_seconds = duration_ms / 1000UL;
        (void) snprintf(text, sizeof text, "[%lum%02lus]",
            total_seconds / 60UL,
            total_seconds % 60UL);
    }
    return append_colored(buf, "yellow", text);
}

static bool append_prompt_character(struct nbsp_buf *buf, int status) {
    if (status == 0) {
        return nbsp_buf_append(buf, "%#");
    }
    return nbsp_buf_appendf(buf, "%%F{red}e%d%%#%%f", status);
}

char *nbsp_prompt_render(const char *cwd,
    int last_status,
    unsigned long duration_ms,
    unsigned jobs) {
    struct nbsp_prompt_data data;
    if (!nbsp_prompt_data_collect(cwd, last_status, duration_ms, jobs, &data)) {
        return NULL;
    }

    struct nbsp_buf prompt;
    nbsp_buf_init(&prompt);
    bool ok = append_colored(&prompt, "default", data.path);

    if (ok && data.git_present && data.git_branch[0] != '\0') {
        ok = nbsp_buf_append_char(&prompt, ' ') && append_git(&prompt, &data);
    }
    if (ok && data.node_version[0] != '\0') {
        char text[320];
        (void) snprintf(text, sizeof text, "[node:%s]", data.node_version);
        ok = nbsp_buf_append_char(&prompt, ' ') && append_colored(&prompt, "green", text);
    }
    if (ok && data.duration_ms >= NBSP_DURATION_THRESHOLD_MS) {
        ok = nbsp_buf_append_char(&prompt, ' ') && append_duration(&prompt, data.duration_ms);
    }
    if (ok && data.jobs > 0U) {
        char text[64];
        (void) snprintf(text, sizeof text, "[jobs:%u]", data.jobs);
        ok = nbsp_buf_append_char(&prompt, ' ') && append_colored(&prompt, "yellow", text);
    }
    if (ok) {
        ok = nbsp_buf_append_char(&prompt, ' ') &&
            append_prompt_character(&prompt, data.status) &&
            nbsp_buf_append_char(&prompt, ' ');
    }
    if (!ok) {
        nbsp_buf_free(&prompt);
        return NULL;
    }
    return nbsp_buf_take(&prompt);
}

static void send_notification(bool notify) {
    if (notify) {
        (void) fputc('\n', stdout);
        (void) fflush(stdout);
    }
}

int nbsp_refresh(const char *cwd, unsigned timeout_ms, bool notify, bool force) {
    struct nbsp_repo repo;
    if (!nbsp_git_discover(cwd, &repo)) {
        send_notification(notify);
        return 0;
    }

    struct nbsp_git_status cached;
    if (!force && nbsp_cache_load(repo.root, &cached)) {
        uint64_t now = nbsp_wall_millis();
        if (now >= cached.updated_ms && now - cached.updated_ms < UINT64_C(250)) {
            nbsp_repo_free(&repo);
            send_notification(notify);
            return 0;
        }
    }

    char lock_path[PATH_MAX] = {0};
    int lock_fd = nbsp_cache_lock(repo.root, timeout_ms, lock_path, sizeof lock_path);
    if (lock_fd < 0) {
        nbsp_repo_free(&repo);
        send_notification(notify);
        return 0;
    }

    if (!force && nbsp_cache_load(repo.root, &cached)) {
        uint64_t now = nbsp_wall_millis();
        if (now >= cached.updated_ms && now - cached.updated_ms < UINT64_C(250)) {
            nbsp_cache_unlock(lock_fd, lock_path);
            nbsp_repo_free(&repo);
            send_notification(notify);
            return 0;
        }
    }

    struct nbsp_git_status fresh;
    int result = nbsp_git_collect(&repo, timeout_ms, &fresh);
    if (result == 0) {
        char branch[sizeof fresh.branch];
        if (nbsp_git_read_branch(&repo, branch, sizeof branch)) {
            (void) snprintf(fresh.branch, sizeof fresh.branch, "%s", branch);
        }
        if (!nbsp_cache_store(repo.root, &fresh)) {
            result = 1;
        }
    }

    nbsp_cache_unlock(lock_fd, lock_path);
    nbsp_repo_free(&repo);
    send_notification(notify);
    return result;
}
