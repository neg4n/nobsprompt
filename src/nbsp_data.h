#ifndef NBSP_DATA_H
#define NBSP_DATA_H

#include <stdbool.h>
#include <stdio.h>

#include "nbsp_prompt.h"

enum nbsp_data_format {
    NBSP_DATA_LINES,
    NBSP_DATA_NUL,
};

bool nbsp_data_write(FILE *out,
    const struct nbsp_prompt_data *data,
    enum nbsp_data_format format);

#endif /* NBSP_DATA_H */
