#include "nbsp_prompt.h"

#include <ctype.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "nbsp_cache.h"
#include "nbsp_git.h"
#include "nbsp_util.h"

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

static bool env_bool(const char *name, bool fallback) {
    const char *value = getenv(name);
    if (!value || !*value) {
        return fallback;
    }
    return strcmp(value, "0") != 0 && strcmp(value, "false") != 0 && strcmp(value, "no") != 0;
}

static unsigned env_unsigned(const char *name, unsigned fallback, unsigned min, unsigned max) {
    const char *value = getenv(name);
    long parsed = 0;
    if (!value || !nbsp_parse_long(value, (long) min, (long) max, &parsed)) {
        return fallback;
    }
    return (unsigned) parsed;
}

bool nbsp_color_valid(const char *color) {
    static const char *const names[] = {
        "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white", "default", "none"
    };
    if (!color || !*color) {
        return false;
    }
    for (size_t i = 0; i < sizeof names / sizeof names[0]; ++i) {
        if (strcmp(color, names[i]) == 0) {
            return true;
        }
    }
    long number = 0;
    return nbsp_parse_long(color, 0, 255, &number);
}

static const char *env_color(const char *name, const char *fallback) {
    const char *value = getenv(name);
    return nbsp_color_valid(value) ? value : fallback;
}

void nbsp_config_from_env(struct nbsp_config *config) {
    if (!config) {
        return;
    }
    config->color_path = env_color("NBSP_COLOR_PATH", "default");
    config->color_git = env_color("NBSP_COLOR_GIT", "default");
    config->color_node = env_color("NBSP_COLOR_NODE", "green");
    config->color_meta = env_color("NBSP_COLOR_META", "yellow");
    config->color_ok = env_color("NBSP_COLOR_OK", "none");
    config->color_error = env_color("NBSP_COLOR_ERROR", "red");
    const char *prompt_char = getenv("NBSP_PROMPT_CHAR");
    config->prompt_char = prompt_char && *prompt_char ? prompt_char : "%#";
    config->duration_threshold_ms = env_unsigned("NBSP_DURATION_THRESHOLD_MS", 2000U, 0U, UINT_MAX);
    config->git_timeout_ms = env_unsigned("NBSP_GIT_TIMEOUT_MS", 1500U, 50U, 60000U);
    config->show_git = env_bool("NBSP_SHOW_GIT", true);
    config->show_nvm = env_bool("NBSP_SHOW_NVM", true);
    config->show_jobs = env_bool("NBSP_SHOW_JOBS", true);
}

static bool append_colored(struct nbsp_buf *buf, const char *color, const char *text) {
    if (strcmp(color, "none") != 0 && !nbsp_buf_appendf(buf, "%%F{%s}", color)) {
        return false;
    }
    for (const unsigned char *p = (const unsigned char *) text; *p; ++p) {
        if (*p == '%') {
            if (!nbsp_buf_append(buf, "%%")) return false;
        } else if (*p < 32U || *p == 127U) {
            if (!nbsp_buf_append_char(buf, '?')) return false;
        } else if (!nbsp_buf_append_char(buf, (char) *p)) {
            return false;
        }
    }
    return strcmp(color, "none") == 0 || nbsp_buf_append(buf, "%f");
}

static bool append_prompt_character(struct nbsp_buf *buf, const char *color, const char *text) {
    if (strcmp(text, "%#") != 0) return append_colored(buf, color, text);
    bool colored = strcmp(color, "none") != 0;
    return (!colored || nbsp_buf_appendf(buf, "%%F{%s}", color)) &&
        nbsp_buf_append(buf, "%#") &&
        (!colored || nbsp_buf_append(buf, "%f"));
}

static bool append_git(struct nbsp_buf *buf,
    const char *branch,
    const struct nbsp_git_status *status,
    const char *color) {
    bool colored = strcmp(color, "none") != 0;
    bool ok = !colored || nbsp_buf_appendf(buf, "%%F{%s}", color);
    if (ok) ok = nbsp_buf_append_char(buf, '[');
    if (ok) {
        for (const unsigned char *p = (const unsigned char *) branch; *p; ++p) {
            if (*p == '%') ok = nbsp_buf_append(buf, "%%");
            else if (*p < 32U || *p == 127U) ok = nbsp_buf_append_char(buf, '?');
            else ok = nbsp_buf_append_char(buf, (char) *p);
            if (!ok) break;
        }
    }
    if (ok && status->valid) {
        if (status->staged) ok = nbsp_buf_appendf(buf, " +%u", status->staged);
        if (ok && status->modified) ok = nbsp_buf_appendf(buf, " ~%u", status->modified);
        if (ok && status->untracked) ok = nbsp_buf_appendf(buf, " ?%u", status->untracked);
        if (ok && status->conflicted) ok = nbsp_buf_appendf(buf, " !%u", status->conflicted);
        if (ok && status->ahead) ok = nbsp_buf_appendf(buf, " ^%u", status->ahead);
        if (ok && status->behind) ok = nbsp_buf_appendf(buf, " v%u", status->behind);
        if (ok && status->stashes) ok = nbsp_buf_appendf(buf, " *%u", status->stashes);
    } else if (ok) {
        ok = nbsp_buf_append(buf, " ...");
    }
    if (ok) ok = nbsp_buf_append_char(buf, ']');
    if (ok && colored) ok = nbsp_buf_append(buf, "%f");
    return ok;
}

static bool append_duration(struct nbsp_buf *buf, unsigned long duration_ms, const char *color) {
    char text[64];
    if (duration_ms < 1000UL) {
        (void) snprintf(text, sizeof text, "[%lums]", duration_ms);
    } else if (duration_ms < 60000UL) {
        unsigned long tenths = (duration_ms + 50UL) / 100UL;
        (void) snprintf(text, sizeof text, "[%lu.%lus]", tenths / 10UL, tenths % 10UL);
    } else {
        unsigned long total_seconds = duration_ms / 1000UL;
        (void) snprintf(text, sizeof text, "[%lum%02lus]", total_seconds / 60UL, total_seconds % 60UL);
    }
    return append_colored(buf, color, text);
}

static bool append_failure_prompt(struct nbsp_buf *buf,
    int status,
    const char *color,
    const char *prompt_char) {
    bool colored = strcmp(color, "none") != 0;
    if (colored && !nbsp_buf_appendf(buf, "%%F{%s}", color)) return false;
    if (!nbsp_buf_appendf(buf, "e%d", status)) return false;
    if (strcmp(prompt_char, "%#") == 0) {
        if (!nbsp_buf_append(buf, "%#")) return false;
    } else {
        for (const unsigned char *p = (const unsigned char *) prompt_char; *p; ++p) {
            if (*p == '%') {
                if (!nbsp_buf_append(buf, "%%")) return false;
            } else if (*p < 32U || *p == 127U) {
                if (!nbsp_buf_append_char(buf, '?')) return false;
            } else if (!nbsp_buf_append_char(buf, (char) *p)) {
                return false;
            }
        }
    }
    return !colored || nbsp_buf_append(buf, "%f");
}

char *nbsp_prompt_render(const char *cwd,
    int last_status,
    unsigned long duration_ms,
    unsigned jobs,
    const struct nbsp_config *config) {
    if (!cwd || !config) {
        return NULL;
    }
    struct nbsp_buf prompt;
    nbsp_buf_init(&prompt);

    char path[NBSP_PATH_CAP];
    if (!nbsp_path_abbreviate_into(cwd, path, sizeof path) ||
        !append_colored(&prompt, config->color_path, path)) {
        nbsp_buf_free(&prompt);
        return NULL;
    }

    if (config->show_git) {
        struct nbsp_repo repo;
        if (nbsp_git_discover(cwd, &repo)) {
            char branch[256] = {0};
            struct nbsp_git_status git_status;
            (void) nbsp_cache_load(repo.root, &git_status);
            if (!nbsp_git_read_branch(&repo, branch, sizeof branch) && git_status.branch[0]) {
                (void) snprintf(branch, sizeof branch, "%s", git_status.branch);
            }
            if (branch[0]) {
                if (!nbsp_buf_append_char(&prompt, ' ') ||
                    !append_git(&prompt, branch, &git_status, config->color_git)) {
                    nbsp_repo_free(&repo);
                    nbsp_buf_free(&prompt);
                    return NULL;
                }
            }
            nbsp_repo_free(&repo);
        }
    }

    if (config->show_nvm) {
        char version[256];
        if (nbsp_nvm_version_into(getenv("NVM_BIN"), version, sizeof version)) {
            char text[320];
            (void) snprintf(text, sizeof text, "[node:%s]", version);
            if (!nbsp_buf_append_char(&prompt, ' ') ||
                !append_colored(&prompt, config->color_node, text)) {
                nbsp_buf_free(&prompt);
                return NULL;
            }
        }
    }

    if (duration_ms >= (unsigned long) config->duration_threshold_ms) {
        if (!nbsp_buf_append_char(&prompt, ' ') ||
            !append_duration(&prompt, duration_ms, config->color_meta)) {
            nbsp_buf_free(&prompt);
            return NULL;
        }
    }

    if (config->show_jobs && jobs > 0U) {
        char text[64];
        (void) snprintf(text, sizeof text, "[jobs:%u]", jobs);
        if (!nbsp_buf_append_char(&prompt, ' ') ||
            !append_colored(&prompt, config->color_meta, text)) {
            nbsp_buf_free(&prompt);
            return NULL;
        }
    }

    if (!nbsp_buf_append_char(&prompt, ' ') ||
        !(last_status == 0
            ? append_prompt_character(&prompt, config->color_ok, config->prompt_char)
            : append_failure_prompt(&prompt,
                last_status,
                config->color_error,
                config->prompt_char)) ||
        !nbsp_buf_append_char(&prompt, ' ')) {
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

int nbsp_refresh(const char *cwd, unsigned timeout_ms, bool notify) {
    struct nbsp_repo repo;
    if (!nbsp_git_discover(cwd, &repo)) {
        send_notification(notify);
        return 0;
    }

    struct nbsp_git_status cached;
    if (nbsp_cache_load(repo.root, &cached)) {
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

    if (nbsp_cache_load(repo.root, &cached)) {
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
