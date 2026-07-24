#include "nbsp_data.h"

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "nbsp_util.h"

static bool write_record(FILE *out,
    enum nbsp_data_format format,
    const char *key,
    const char *value) {
    if (format == NBSP_DATA_NUL) {
        return fwrite(key, 1U, strlen(key), out) == strlen(key) &&
            fputc('\0', out) != EOF &&
            fwrite(value, 1U, strlen(value), out) == strlen(value) &&
            fputc('\0', out) != EOF;
    }

    char *encoded = nbsp_percent_encode(value);
    if (!encoded) {
        return false;
    }
    bool ok = fprintf(out, "%s=%s\n", key, encoded) >= 0;
    free(encoded);
    return ok;
}

bool nbsp_data_write(FILE *out,
    const struct nbsp_prompt_data *data,
    enum nbsp_data_format format) {
    if (!out || !data) {
        return false;
    }

    char status[32];
    char duration[32];
    char jobs[32];
    char git_present[2] = {data->git_present ? '1' : '0', '\0'};
    char git_valid[2] = {data->git_valid ? '1' : '0', '\0'};
    char updated[32];
    char staged[32];
    char modified[32];
    char untracked[32];
    char conflicted[32];
    char ahead[32];
    char behind[32];
    char stashes[32];
    (void) snprintf(status, sizeof status, "%d", data->status);
    (void) snprintf(duration, sizeof duration, "%lu", data->duration_ms);
    (void) snprintf(jobs, sizeof jobs, "%u", data->jobs);
    (void) snprintf(updated, sizeof updated, "%" PRIu64, data->git_updated_ms);
    (void) snprintf(staged, sizeof staged, "%u", data->git_staged);
    (void) snprintf(modified, sizeof modified, "%u", data->git_modified);
    (void) snprintf(untracked, sizeof untracked, "%u", data->git_untracked);
    (void) snprintf(conflicted, sizeof conflicted, "%u", data->git_conflicted);
    (void) snprintf(ahead, sizeof ahead, "%u", data->git_ahead);
    (void) snprintf(behind, sizeof behind, "%u", data->git_behind);
    (void) snprintf(stashes, sizeof stashes, "%u", data->git_stashes);

    return write_record(out, format, "schema_version", "1") &&
        write_record(out, format, "cwd", data->cwd) &&
        write_record(out, format, "path", data->path) &&
        write_record(out, format, "status", status) &&
        write_record(out, format, "duration_ms", duration) &&
        write_record(out, format, "jobs", jobs) &&
        write_record(out, format, "node_version", data->node_version) &&
        write_record(out, format, "git_present", git_present) &&
        write_record(out, format, "git_valid", git_valid) &&
        write_record(out, format, "git_branch", data->git_branch) &&
        write_record(out, format, "git_updated_ms", updated) &&
        write_record(out, format, "git_staged", staged) &&
        write_record(out, format, "git_modified", modified) &&
        write_record(out, format, "git_untracked", untracked) &&
        write_record(out, format, "git_conflicted", conflicted) &&
        write_record(out, format, "git_ahead", ahead) &&
        write_record(out, format, "git_behind", behind) &&
        write_record(out, format, "git_stashes", stashes);
}
