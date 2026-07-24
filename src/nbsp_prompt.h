#ifndef NBSP_PROMPT_H
#define NBSP_PROMPT_H

#include <stdbool.h>

struct nbsp_config {
    const char *color_path;
    const char *color_git;
    const char *color_node;
    const char *color_meta;
    const char *color_ok;
    const char *color_error;
    const char *prompt_char;
    unsigned duration_threshold_ms;
    unsigned git_timeout_ms;
    bool show_git;
    bool show_nvm;
    bool show_jobs;
};

void nbsp_config_from_env(struct nbsp_config *config);
bool nbsp_color_valid(const char *color);
char *nbsp_prompt_render(const char *cwd,
    int last_status,
    unsigned long duration_ms,
    unsigned jobs,
    const struct nbsp_config *config);
int nbsp_refresh(const char *cwd, unsigned timeout_ms, bool notify);

#endif /* NBSP_PROMPT_H */
