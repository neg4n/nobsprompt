#include "nbsp_prompt.h"

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "nbsp_cache.h"
#include "nbsp_git.h"
#include "nbsp_util.h"

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
        struct nbsp_git_status cached = {0};
        bool cache_loaded = nbsp_cache_load(repo.root, &cached);
        char current_branch[sizeof data->git_branch] = {0};
        bool branch_loaded = nbsp_git_read_branch(
            &repo, current_branch, sizeof current_branch);
        if (cache_loaded && branch_loaded &&
            strcmp(cached.branch, current_branch) == 0) {
            data->git_valid = true;
            data->git_updated_ms = cached.updated_ms;
            data->git_staged = cached.staged;
            data->git_modified = cached.modified;
            data->git_untracked = cached.untracked;
            data->git_conflicted = cached.conflicted;
            data->git_ahead = cached.ahead;
            data->git_behind = cached.behind;
            data->git_stashes = cached.stashes;
        }
        if (branch_loaded) {
            (void) snprintf(
                data->git_branch, sizeof data->git_branch, "%s", current_branch);
        } else if (cache_loaded) {
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

static bool append_color_start(struct nbsp_buf *buf, const char *color, unsigned options) {
    return (options & NBSP_PROMPT_PERCENT) == 0U ||
        nbsp_buf_appendf(buf, "%%F{%s}", color);
}

static bool append_color_end(struct nbsp_buf *buf, unsigned options) {
    return (options & NBSP_PROMPT_PERCENT) == 0U || nbsp_buf_append(buf, "%f");
}

static bool append_colored(struct nbsp_buf *buf,
    const char *color,
    const char *text,
    unsigned options) {
    return append_color_start(buf, color, options) &&
        nbsp_prompt_quote(buf, text, options) &&
        append_color_end(buf, options);
}

static bool append_count(struct nbsp_buf *buf,
    const char *marker,
    unsigned count,
    unsigned options) {
    return nbsp_buf_append_char(buf, ' ') &&
        nbsp_prompt_quote(buf, marker, options) &&
        nbsp_buf_appendf(buf, "%u", count);
}

static bool append_git(struct nbsp_buf *buf,
    const struct nbsp_prompt_data *data,
    unsigned options) {
    bool ok = append_color_start(buf, "default", options) &&
        nbsp_buf_append_char(buf, '[') &&
        nbsp_prompt_quote(buf, data->git_branch, options);
    if (ok && data->git_valid) {
        if (data->git_staged) ok = append_count(buf, "+", data->git_staged, options);
        if (ok && data->git_modified) ok = append_count(buf, "~", data->git_modified, options);
        if (ok && data->git_untracked) ok = append_count(buf, "?", data->git_untracked, options);
        if (ok && data->git_conflicted) ok = append_count(buf, "!", data->git_conflicted, options);
        if (ok && data->git_ahead) ok = append_count(buf, "^", data->git_ahead, options);
        if (ok && data->git_behind) ok = append_count(buf, "v", data->git_behind, options);
        if (ok && data->git_stashes) ok = append_count(buf, "*", data->git_stashes, options);
    } else if (ok) {
        ok = nbsp_buf_append(buf, " ...");
    }
    return ok && nbsp_buf_append_char(buf, ']') && append_color_end(buf, options);
}

static bool append_duration(struct nbsp_buf *buf,
    unsigned long duration_ms,
    unsigned options) {
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
    return append_colored(buf, "yellow", text, options);
}

static bool append_prompt_character(struct nbsp_buf *buf,
    int status,
    unsigned options) {
    if ((options & NBSP_PROMPT_PERCENT) != 0U) {
        if (status == 0) {
            return nbsp_buf_append(buf, "%#");
        }
        return nbsp_buf_appendf(buf, "%%F{red}e%d%%#%%f", status);
    }

    char prompt_character = geteuid() == 0 ? '#' : '%';
    return (status == 0 || nbsp_buf_appendf(buf, "e%d", status)) &&
        nbsp_buf_append_char(buf, prompt_character);
}

char *nbsp_prompt_render(const char *cwd,
    int last_status,
    unsigned long duration_ms,
    unsigned jobs,
    unsigned prompt_options) {
    struct nbsp_prompt_data data;
    if (!nbsp_prompt_data_collect(cwd, last_status, duration_ms, jobs, &data)) {
        return NULL;
    }

    struct nbsp_buf prompt;
    nbsp_buf_init(&prompt);
    bool ok = append_colored(&prompt, "default", data.path, prompt_options);

    if (ok && data.git_present && data.git_branch[0] != '\0') {
        ok = nbsp_buf_append_char(&prompt, ' ') &&
            append_git(&prompt, &data, prompt_options);
    }
    if (ok && data.node_version[0] != '\0') {
        char text[320];
        (void) snprintf(text, sizeof text, "[node:%s]", data.node_version);
        ok = nbsp_buf_append_char(&prompt, ' ') &&
            append_colored(&prompt, "green", text, prompt_options);
    }
    if (ok && data.duration_ms >= NBSP_DURATION_THRESHOLD_MS) {
        ok = nbsp_buf_append_char(&prompt, ' ') &&
            append_duration(&prompt, data.duration_ms, prompt_options);
    }
    if (ok && data.jobs > 0U) {
        char text[64];
        (void) snprintf(text, sizeof text, "[jobs:%u]", data.jobs);
        ok = nbsp_buf_append_char(&prompt, ' ') &&
            append_colored(&prompt, "yellow", text, prompt_options);
    }
    if (ok) {
        ok = nbsp_buf_append_char(&prompt, ' ') &&
            append_prompt_character(&prompt, data.status, prompt_options) &&
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

    int lock_fd = nbsp_cache_lock(repo.root);
    if (lock_fd == NBSP_CACHE_LOCK_BUSY) {
        nbsp_repo_free(&repo);
        send_notification(notify);
        return 0;
    }
    if (lock_fd == NBSP_CACHE_LOCK_ERROR) {
        nbsp_repo_free(&repo);
        send_notification(notify);
        return 1;
    }

    if (!force && nbsp_cache_load(repo.root, &cached)) {
        uint64_t now = nbsp_wall_millis();
        if (now >= cached.updated_ms && now - cached.updated_ms < UINT64_C(250)) {
            nbsp_cache_unlock(lock_fd);
            nbsp_repo_free(&repo);
            send_notification(notify);
            return 0;
        }
    }

    struct nbsp_git_status fresh;
    int result = nbsp_git_collect(&repo, timeout_ms, &fresh);
    if (result == NBSP_GIT_OK) {
        char branch[sizeof fresh.branch];
        if (!nbsp_git_read_branch(&repo, branch, sizeof branch) ||
            strcmp(branch, fresh.branch) != 0 ||
            !nbsp_cache_store(repo.root, &fresh)) {
            result = NBSP_GIT_ERROR;
        }
    }

    nbsp_cache_unlock(lock_fd);
    nbsp_repo_free(&repo);
    send_notification(notify);
    return result;
}
