#ifndef NBSP_CACHE_H
#define NBSP_CACHE_H

#include <stdbool.h>
#include <stddef.h>

#include "nbsp_git.h"

bool nbsp_cache_git_dir(char *out, size_t out_len, bool create);
bool nbsp_cache_load(const char *repo_root, struct nbsp_git_status *status);
bool nbsp_cache_store(const char *repo_root, const struct nbsp_git_status *status);
int nbsp_cache_lock(const char *repo_root, unsigned stale_after_ms, char *path, size_t path_len);
void nbsp_cache_unlock(int fd, const char *path);
int nbsp_cache_clear(void);

#endif /* NBSP_CACHE_H */

