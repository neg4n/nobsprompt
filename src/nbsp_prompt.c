#include "nbsp_prompt.h"

#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "nbsp_cache.h"
#include "nbsp_git.h"
#include "nbsp_util.h"

bool nbsp_prompt_data_collect(const char *cwd,
    int last_status,
    unsigned long duration_ms,
    unsigned jobs,
    struct nbsp_prompt_data *data) {
    if (!cwd || !data) {
        return false;
    }

    memset(data, 0, sizeof *data);
    if (!nbsp_copy_cstr(data->cwd, sizeof data->cwd, cwd) ||
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
            (void) nbsp_copy_cstr(
                data->git_branch, sizeof data->git_branch, current_branch);
        } else if (cache_loaded) {
            (void) nbsp_copy_cstr(
                data->git_branch, sizeof data->git_branch, cached.branch);
        }
        nbsp_repo_clear(&repo);
    }

    (void) nbsp_nvm_version_into(
        getenv("NVM_BIN"),
        data->node_version,
        sizeof data->node_version);
    return true;
}
