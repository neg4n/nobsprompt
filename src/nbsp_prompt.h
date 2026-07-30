#ifndef NBSP_PROMPT_H
#define NBSP_PROMPT_H

#include <stdbool.h>
#include <stdint.h>

#include "nbsp_util.h"

struct nbsp_prompt_data {
    char cwd[NBSP_PATH_CAP];
    char path[NBSP_PATH_CAP];
    int status;
    unsigned long duration_ms;
    unsigned jobs;
    char node_version[256];
    bool git_present;
    bool git_valid;
    char git_branch[256];
    uint64_t git_updated_ms;
    unsigned git_staged;
    unsigned git_modified;
    unsigned git_untracked;
    unsigned git_conflicted;
    unsigned git_ahead;
    unsigned git_behind;
    unsigned git_stashes;
};

unsigned nbsp_git_timeout_from_env(void);
bool nbsp_prompt_data_collect(const char *cwd,
    int last_status,
    unsigned long duration_ms,
    unsigned jobs,
    struct nbsp_prompt_data *data);
char *nbsp_prompt_render(const char *cwd,
    int last_status,
    unsigned long duration_ms,
    unsigned jobs,
    unsigned prompt_options);
int nbsp_refresh(const char *cwd, unsigned timeout_ms, bool notify, bool force);

#endif /* NBSP_PROMPT_H */
