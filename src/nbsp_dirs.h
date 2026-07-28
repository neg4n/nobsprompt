#ifndef NBSP_DIRS_H
#define NBSP_DIRS_H

#include <stdbool.h>
#include <stdio.h>

#define NBSP_DIR_TIMEOUT_MS 50U
#define NBSP_DIR_MAX_ENTRIES 1024U
#define NBSP_DIR_MAX_BYTES (64U * 1024U)

bool nbsp_dirs_write(FILE *out, const char *cwd);

#endif /* NBSP_DIRS_H */
