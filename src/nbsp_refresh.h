#ifndef NBSP_REFRESH_H
#define NBSP_REFRESH_H

#include <stdbool.h>

unsigned nbsp_git_timeout_from_env(void);
int nbsp_refresh(const char *cwd, unsigned timeout_ms, bool notify, bool force);

#endif /* NBSP_REFRESH_H */
