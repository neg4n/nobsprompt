#include "nbsp_git.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include "nbsp_util.h"

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

extern char **environ;

void nbsp_repo_free(struct nbsp_repo *repo) {
    if (repo) {
        repo->root[0] = '\0';
        repo->git_dir[0] = '\0';
    }
}

static bool ascii_hex(unsigned char value) {
    return (value >= '0' && value <= '9') ||
        (value >= 'a' && value <= 'f') ||
        (value >= 'A' && value <= 'F');
}

static bool value_has_no_space(const char *value) {
    if (!value || *value == '\0') return false;
    for (const unsigned char *p = (const unsigned char *) value; *p; ++p) {
        if (*p <= 0x20U || *p == 0x7fU) return false;
    }
    return true;
}

static bool read_first_line(const char *path, char *out, size_t out_len) {
    if (!path || !out || out_len == 0U) {
        return false;
    }
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return false;
    size_t length = 0U;
    bool complete = false;
    int read_error = 0;
    while (length < out_len - 1U) {
        ssize_t count = read(fd, out + length, out_len - 1U - length);
        if (count > 0) {
            size_t received = (size_t) count;
            if (memchr(out + length, '\0', received)) {
                read_error = EINVAL;
                break;
            }
            char *newline = memchr(out + length, '\n', received);
            if (newline) {
                length = (size_t) (newline - out);
                complete = true;
                break;
            }
            length += received;
        } else if (count == 0) {
            complete = length != 0U;
            break;
        } else if (errno != EINTR) {
            read_error = errno;
            break;
        }
    }
    if (close(fd) != 0 && read_error == 0) read_error = errno;
    if (!complete || read_error != 0) {
        errno = read_error ? read_error : EOVERFLOW;
        return false;
    }
    if (length && out[length - 1U] == '\r') --length;
    out[length] = '\0';
    return true;
}

static bool resolve_git_file(const char *worktree,
    const char *git_file,
    char *out,
    size_t out_len) {
    char line[PATH_MAX];
    if (!read_first_line(git_file, line, sizeof line) || strncmp(line, "gitdir: ", 8U) != 0) {
        return false;
    }
    const char *value = line + 8U;
    if (*value == '\0') return false;
    char candidate[PATH_MAX];
    int count = value[0] == '/'
        ? snprintf(candidate, sizeof candidate, "%s", value)
        : snprintf(candidate, sizeof candidate, "%s/%s", worktree, value);
    if (count < 0 || (size_t) count >= sizeof candidate) {
        return false;
    }
    char resolved[PATH_MAX];
    struct stat info;
    if (!realpath(candidate, resolved) || stat(resolved, &info) != 0 ||
        !S_ISDIR(info.st_mode)) {
        return false;
    }
    count = snprintf(out, out_len, "%s", resolved);
    return count >= 0 && (size_t) count < out_len;
}

bool nbsp_git_discover(const char *cwd, struct nbsp_repo *out) {
    if (!cwd || !out) {
        return false;
    }
    out->root[0] = '\0';
    out->git_dir[0] = '\0';

    char current[PATH_MAX];
    struct stat cwd_info;
    if (!realpath(cwd, current) || stat(current, &cwd_info) != 0 ||
        !S_ISDIR(cwd_info.st_mode)) {
        return false;
    }
    dev_t start_device = cwd_info.st_dev;

    for (;;) {
        struct stat current_info;
        if (stat(current, &current_info) != 0 ||
            current_info.st_dev != start_device) {
            return false;
        }
        char git_path[PATH_MAX];
        int count = snprintf(git_path, sizeof git_path, "%s%s.git",
            current,
            strcmp(current, "/") == 0 ? "" : "/");
        if (count < 0 || (size_t) count >= sizeof git_path) {
            return false;
        }
        struct stat link_info;
        if (lstat(git_path, &link_info) == 0) {
            struct stat info;
            if (stat(git_path, &info) != 0) {
                return false;
            }
            bool git_dir_ok = false;
            if (S_ISDIR(info.st_mode)) {
                char resolved[PATH_MAX];
                if (!realpath(git_path, resolved)) return false;
                count = snprintf(out->git_dir, sizeof out->git_dir, "%s", resolved);
                git_dir_ok = count >= 0 && (size_t) count < sizeof out->git_dir;
            } else if (S_ISREG(info.st_mode)) {
                git_dir_ok = resolve_git_file(current, git_path, out->git_dir, sizeof out->git_dir);
            }
            if (!git_dir_ok) return false;
            count = snprintf(out->root, sizeof out->root, "%s", current);
            if (count < 0 || (size_t) count >= sizeof out->root) return false;
            return true;
        }
        if (errno != ENOENT && errno != ENOTDIR) {
            return false;
        }

        if (strcmp(current, "/") == 0) {
            break;
        }
        char *slash = strrchr(current, '/');
        if (!slash) {
            break;
        }
        if (slash == current) {
            current[1] = '\0';
        } else {
            *slash = '\0';
        }
    }
    return false;
}

static bool copy_symbolic_branch(const char *reference, char *out, size_t out_len) {
    if (!reference || strncmp(reference, "refs/", 5U) != 0) return false;
    const char *display = reference;
    const char *heads = "refs/heads/";
    if (strncmp(display, heads, strlen(heads)) == 0) {
        display += strlen(heads);
    }
    size_t display_len = strlen(display);
    if (display_len == 0U || display_len >= out_len ||
        !value_has_no_space(display)) return false;
    memcpy(out, display, display_len + 1U);
    return true;
}

bool nbsp_git_read_branch(const struct nbsp_repo *repo, char *out, size_t out_len) {
    if (!repo || repo->git_dir[0] == '\0' || !out || out_len == 0U) {
        return false;
    }
    char head_path[PATH_MAX];
    int count = snprintf(head_path, sizeof head_path, "%s/HEAD", repo->git_dir);
    if (count < 0 || (size_t) count >= sizeof head_path) return false;
    struct stat head_info;
    if (lstat(head_path, &head_info) != 0) return false;
    if (S_ISLNK(head_info.st_mode)) {
        char reference[1024];
        ssize_t length = readlink(head_path, reference, sizeof reference - 1U);
        if (length <= 0 || (size_t) length >= sizeof reference) return false;
        reference[length] = '\0';
        return copy_symbolic_branch(reference, out, out_len);
    }
    if (!S_ISREG(head_info.st_mode)) return false;
    char line[1024];
    bool ok = read_first_line(head_path, line, sizeof line);
    if (!ok || line[0] == '\0') {
        return false;
    }

    if (strncmp(line, "ref: ", 5U) == 0) {
        return copy_symbolic_branch(line + 5U, out, out_len);
    }

    size_t length = strlen(line);
    for (size_t i = 0U; i < length; ++i) {
        if (!ascii_hex((unsigned char) line[i])) return false;
    }
    if (length != 40U && length != 64U) return false;
    size_t short_len = 8U;
    if (short_len + 1U > out_len) {
        return false;
    }
    memcpy(out, line, short_len);
    out[short_len] = '\0';
    return true;
}

static bool parse_unsigned_field(const char *text, size_t length, unsigned *out) {
    if (!text || length == 0U || !out) return false;
    unsigned value = 0U;
    for (size_t i = 0U; i < length; ++i) {
        unsigned char byte = (unsigned char) text[i];
        if (byte < '0' || byte > '9') return false;
        unsigned digit = (unsigned) (byte - (unsigned char) '0');
        if (value > (UINT_MAX - digit) / 10U) return false;
        value = value * 10U + digit;
    }
    *out = value;
    return true;
}

static bool parse_ahead_behind(const char *value, unsigned *ahead, unsigned *behind) {
    if (!value || value[0] != '+') return false;
    const char *space = strchr(value, ' ');
    if (!space || space == value + 1 || space[1] != '-' || space[2] == '\0' ||
        strchr(space + 1, ' ')) {
        return false;
    }
    return parse_unsigned_field(value + 1, (size_t) (space - value - 1), ahead) &&
        parse_unsigned_field(space + 2, strlen(space + 2), behind);
}

static bool take_record_field(const char **cursor, const char **field, size_t *length) {
    if (!cursor || !*cursor || !field || !length || **cursor == '\0' ||
        **cursor == ' ' || **cursor == '\t') {
        return false;
    }
    const char *begin = *cursor;
    const char *space = strchr(begin, ' ');
    if (!space || space == begin || space[1] == '\0' || space[1] == ' ') return false;
    for (const char *p = begin; p < space; ++p) {
        if (*p == '\t') return false;
    }
    *field = begin;
    *length = (size_t) (space - begin);
    *cursor = space + 1;
    return true;
}

static bool valid_xy(const char *field, size_t length) {
    static const char states[] = ".MTADRCU";
    return length == 2U && strchr(states, field[0]) && strchr(states, field[1]);
}

static bool valid_submodule(const char *field, size_t length) {
    if (length != 4U) return false;
    if (field[0] == 'N') {
        return memcmp(field, "N...", 4U) == 0;
    }
    return field[0] == 'S' && strchr(".C", field[1]) &&
        strchr(".M", field[2]) && strchr(".U", field[3]);
}

static bool valid_mode(const char *field, size_t length) {
    static const char *const modes[] = {
        "000000", "100644", "100755", "120000", "160000",
    };
    if (length != 6U) return false;
    for (size_t i = 0U; i < sizeof modes / sizeof modes[0]; ++i) {
        if (memcmp(field, modes[i], length) == 0) return true;
    }
    return false;
}

static bool valid_oid(const char *field, size_t length) {
    if (length != 40U && length != 64U) return false;
    for (size_t i = 0U; i < length; ++i) {
        if (!ascii_hex((unsigned char) field[i])) return false;
    }
    return true;
}

static bool valid_optional_header(const char *line) {
    if (!line || line[0] != '#' || line[1] != ' ') return false;
    const unsigned char *value = (const unsigned char *) line + 2U;
    if (*value == '\0') return false;
    for (const unsigned char *p = value; *p; ++p) {
        if (*p < 0x20U || *p == 0x7fU) return false;
    }
    return true;
}

static bool increment_counter(unsigned *counter) {
    if (!counter || *counter == UINT_MAX) return false;
    ++*counter;
    return true;
}

static bool parse_tracked_record(const char *line, struct nbsp_git_status *status) {
    bool renamed = line[0] == '2';
    const char *cursor = line + 2U;
    const char *fields[8];
    size_t lengths[8];
    size_t field_count = renamed ? 8U : 7U;
    for (size_t i = 0U; i < field_count; ++i) {
        if (!take_record_field(&cursor, &fields[i], &lengths[i])) return false;
    }
    if (!valid_xy(fields[0], lengths[0]) ||
        !valid_submodule(fields[1], lengths[1]) ||
        !valid_mode(fields[2], lengths[2]) ||
        !valid_mode(fields[3], lengths[3]) ||
        !valid_mode(fields[4], lengths[4]) ||
        !valid_oid(fields[5], lengths[5]) ||
        !valid_oid(fields[6], lengths[6]) || *cursor == '\0') {
        return false;
    }
    if (renamed) {
        if (lengths[7] < 2U || (fields[7][0] != 'R' && fields[7][0] != 'C')) {
            return false;
        }
        unsigned score = 0U;
        if (!parse_unsigned_field(fields[7] + 1U, lengths[7] - 1U, &score) ||
            score > 100U) {
            return false;
        }
        const char *separator = strchr(cursor, '\t');
        if (!separator || separator == cursor || separator[1] == '\0') return false;
    }
    if (fields[0][0] != '.' && !increment_counter(&status->staged)) return false;
    if (fields[0][1] != '.' && !increment_counter(&status->modified)) return false;
    return true;
}

static bool parse_unmerged_record(const char *line, struct nbsp_git_status *status) {
    const char *cursor = line + 2U;
    const char *fields[9];
    size_t lengths[9];
    for (size_t i = 0U; i < 9U; ++i) {
        if (!take_record_field(&cursor, &fields[i], &lengths[i])) return false;
    }
    static const char *const conflicts[] = {
        "DD", "AU", "UD", "UA", "DU", "AA", "UU",
    };
    bool valid_conflict = false;
    for (size_t i = 0U; i < sizeof conflicts / sizeof conflicts[0]; ++i) {
        if (lengths[0] == 2U && memcmp(fields[0], conflicts[i], 2U) == 0) {
            valid_conflict = true;
            break;
        }
    }
    if (!valid_conflict ||
        !valid_submodule(fields[1], lengths[1])) {
        return false;
    }
    for (size_t i = 2U; i < 6U; ++i) {
        if (!valid_mode(fields[i], lengths[i])) return false;
    }
    for (size_t i = 6U; i < 9U; ++i) {
        if (!valid_oid(fields[i], lengths[i])) return false;
    }
    return *cursor != '\0' && increment_counter(&status->conflicted);
}

bool nbsp_git_parse_status(const char *output, struct nbsp_git_status *status) {
    if (!output || !status) return false;
    memset(status, 0, sizeof *status);
    size_t output_len = strlen(output);
    if (output_len == 0U || output[output_len - 1U] != '\n') return false;

    char *copy = nbsp_strdup(output);
    if (!copy) return false;

    struct nbsp_git_status parsed = {0};
    char detached_oid[9] = {0};
    bool oid_initial = false;
    bool head_detached = false;
    bool saw_record = false;
    unsigned oid_headers = 0U;
    unsigned head_headers = 0U;
    unsigned upstream_headers = 0U;
    unsigned ab_headers = 0U;
    unsigned stash_headers = 0U;
    bool ok = true;

    char *line = copy;
    while (ok && *line != '\0') {
        char *newline = strchr(line, '\n');
        if (newline) *newline = '\0';
        if (*line == '\0' || strchr(line, '\r')) {
            ok = false;
        } else if (line[0] == '#') {
            if (saw_record) {
                ok = false;
            } else if (strncmp(line, "# branch.oid ", 13U) == 0) {
                const char *oid = line + 13U;
                size_t oid_len = strlen(oid);
                if (++oid_headers != 1U) {
                    ok = false;
                } else if (strcmp(oid, "(initial)") == 0) {
                    oid_initial = true;
                } else if (!valid_oid(oid, oid_len)) {
                    ok = false;
                } else {
                    memcpy(detached_oid, oid, 8U);
                    detached_oid[8] = '\0';
                }
            } else if (strncmp(line, "# branch.head ", 14U) == 0) {
                const char *branch = line + 14U;
                size_t branch_len = strlen(branch);
                if (++head_headers != 1U || !value_has_no_space(branch)) {
                    ok = false;
                } else if (strcmp(branch, "(detached)") == 0) {
                    head_detached = true;
                } else if (branch_len >= sizeof parsed.branch) {
                    ok = false;
                } else {
                    memcpy(parsed.branch, branch, branch_len + 1U);
                }
            } else if (strncmp(line, "# branch.upstream ", 18U) == 0) {
                ok = ++upstream_headers == 1U && value_has_no_space(line + 18U);
            } else if (strncmp(line, "# branch.ab ", 12U) == 0) {
                ok = ++ab_headers == 1U &&
                    parse_ahead_behind(line + 12U, &parsed.ahead, &parsed.behind);
            } else if (strncmp(line, "# stash ", 8U) == 0) {
                const char *value = line + 8U;
                ok = ++stash_headers == 1U &&
                    parse_unsigned_field(value, strlen(value), &parsed.stashes) &&
                    parsed.stashes != 0U;
            } else {
                ok = valid_optional_header(line);
            }
        } else {
            saw_record = true;
            if ((line[0] == '1' || line[0] == '2') && line[1] == ' ') {
                ok = parse_tracked_record(line, &parsed);
            } else if (line[0] == 'u' && line[1] == ' ') {
                ok = parse_unmerged_record(line, &parsed);
            } else if (line[0] == '?' && line[1] == ' ' && line[2] != '\0') {
                ok = increment_counter(&parsed.untracked);
            } else if (line[0] == '!' && line[1] == ' ' && line[2] != '\0') {
                ok = true;
            } else {
                ok = false;
            }
        }

        if (!newline) break;
        line = newline + 1U;
    }

    if (ok && (oid_headers != 1U || head_headers != 1U ||
        (ab_headers != 0U && upstream_headers == 0U) ||
        (head_detached && (oid_initial || detached_oid[0] == '\0')))) {
        ok = false;
    }
    if (ok && head_detached) {
        memcpy(parsed.branch, detached_oid, sizeof detached_oid);
    }
    if (ok) {
        parsed.updated_ms = nbsp_wall_millis();
        parsed.valid = true;
        *status = parsed;
    }
    free(copy);
    return ok;
}

#define NBSP_GIT_OUTPUT_MAX (8U * 1024U * 1024U)

static bool environment_name_is(const char *entry, const char *name) {
    size_t name_len = strlen(name);
    return strncmp(entry, name, name_len) == 0 && entry[name_len] == '=';
}

static bool is_git_selector_environment(const char *entry) {
    static const char *const names[] = {
        "GIT_DIR",
        "GIT_COMMON_DIR",
        "GIT_WORK_TREE",
        "GIT_IMPLICIT_WORK_TREE",
        "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_CONFIG",
        "GIT_CONFIG_GLOBAL",
        "GIT_CONFIG_SYSTEM",
        "GIT_CONFIG_NOSYSTEM",
        "GIT_CONFIG_PARAMETERS",
        "GIT_CONFIG_COUNT",
        "GIT_CEILING_DIRECTORIES",
        "GIT_DISCOVERY_ACROSS_FILESYSTEM",
        "GIT_NAMESPACE",
        "GIT_SHALLOW_FILE",
        "GIT_GRAFT_FILE",
        "GIT_NO_REPLACE_OBJECTS",
        "GIT_REPLACE_REF_BASE",
        "GIT_REFERENCE_BACKEND",
        "GIT_QUARANTINE_PATH",
        "GIT_PREFIX",
        "GIT_SUPER_PREFIX",
        "GIT_INTERNAL_SUPER_PREFIX",
    };
    for (size_t i = 0U; i < sizeof names / sizeof names[0]; ++i) {
        if (environment_name_is(entry, names[i])) return true;
    }
    return false;
}

static char **git_environment(void) {
    size_t count = 0U;
    while (environ[count]) {
        if (count == SIZE_MAX - 1U) return NULL;
        ++count;
    }
    char **clean = calloc(count + 1U, sizeof clean[0]);
    if (!clean) return NULL;
    size_t written = 0U;
    for (size_t i = 0U; i < count; ++i) {
        if (!is_git_selector_environment(environ[i])) {
            clean[written++] = environ[i];
        }
    }
    return clean;
}

static bool set_close_on_exec(int fd) {
    int flags = fcntl(fd, F_GETFD, 0);
    return flags >= 0 && fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0;
}

static bool move_above_standard_descriptors(int *fd) {
    if (!fd || *fd < 0) return false;
    if (*fd > STDERR_FILENO) return true;
    int moved = fcntl(*fd, F_DUPFD, STDERR_FILENO + 1);
    if (moved < 0) return false;
    if (close(*fd) != 0) {
        (void) close(moved);
        return false;
    }
    *fd = moved;
    return true;
}

static bool set_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0;
}

static void kill_process_group(pid_t child) {
    int saved_errno = errno;
    (void) kill(-child, SIGKILL);
    (void) kill(child, SIGKILL);
    errno = saved_errno;
}

static void reap_child(pid_t child) {
    int child_status = 0;
    while (waitpid(child, &child_status, 0) < 0 && errno == EINTR) {
    }
}

static int collect_output(pid_t child,
    int fd,
    unsigned timeout_ms,
    uint64_t started,
    struct nbsp_buf *output) {
    char chunk[8192];
    bool eof = false;
    int child_status = 0;

    for (;;) {
        if (eof) {
            pid_t waited = waitpid(child, &child_status, WNOHANG);
            if (waited == child) {
                return WIFEXITED(child_status) && WEXITSTATUS(child_status) == 0
                    ? NBSP_GIT_OK
                    : NBSP_GIT_ERROR;
            } else if (waited < 0 && errno == ECHILD) {
                return NBSP_GIT_ERROR;
            } else if (waited < 0 && errno != EINTR) {
                kill_process_group(child);
                reap_child(child);
                return NBSP_GIT_ERROR;
            }
        }

        uint64_t now = nbsp_monotonic_millis();
        uint64_t elapsed = now >= started ? now - started : (uint64_t) timeout_ms;
        if (elapsed >= (uint64_t) timeout_ms) {
            kill_process_group(child);
            reap_child(child);
            return NBSP_GIT_TIMEOUT;
        }
        uint64_t remaining = (uint64_t) timeout_ms - elapsed;
        int wait_ms = remaining > 25U ? 25 : (int) remaining;
        struct pollfd poll_fd = {.fd = fd, .events = POLLIN | POLLHUP, .revents = 0};
        nfds_t descriptor_count = eof ? 0U : 1U;
        int ready = poll(&poll_fd, descriptor_count, wait_ms);
        if (ready < 0) {
            if (errno == EINTR) continue;
            kill_process_group(child);
            reap_child(child);
            return NBSP_GIT_ERROR;
        }
        if (ready == 0 || eof) continue;
        if ((poll_fd.revents & POLLNVAL) != 0) {
            kill_process_group(child);
            reap_child(child);
            return NBSP_GIT_ERROR;
        }
        if ((poll_fd.revents & (POLLIN | POLLHUP | POLLERR)) == 0) continue;

        for (;;) {
            now = nbsp_monotonic_millis();
            if (now < started || now - started >= (uint64_t) timeout_ms) {
                kill_process_group(child);
                reap_child(child);
                return NBSP_GIT_TIMEOUT;
            }
            ssize_t count = read(fd, chunk, sizeof chunk);
            if (count > 0) {
                size_t length = (size_t) count;
                if (length > NBSP_GIT_OUTPUT_MAX ||
                    output->len > NBSP_GIT_OUTPUT_MAX - length ||
                    !nbsp_buf_append_n(output, chunk, length)) {
                    kill_process_group(child);
                    reap_child(child);
                    return NBSP_GIT_ERROR;
                }
            } else if (count == 0) {
                eof = true;
                break;
            } else if (errno == EAGAIN || errno == EWOULDBLOCK) {
                break;
            } else if (errno != EINTR) {
                kill_process_group(child);
                reap_child(child);
                return NBSP_GIT_ERROR;
            }
        }
    }
}

int nbsp_git_collect(const struct nbsp_repo *repo,
    unsigned timeout_ms,
    struct nbsp_git_status *status) {
    if (!repo || repo->root[0] == '\0' || !status || timeout_ms == 0U) {
        return NBSP_GIT_ERROR;
    }
    memset(status, 0, sizeof *status);
    uint64_t started = nbsp_monotonic_millis();

    int pipe_fd[2];
    if (pipe(pipe_fd) != 0) {
        return NBSP_GIT_ERROR;
    }
    if (!move_above_standard_descriptors(&pipe_fd[0]) ||
        !move_above_standard_descriptors(&pipe_fd[1]) ||
        !set_close_on_exec(pipe_fd[0]) || !set_close_on_exec(pipe_fd[1]) ||
        !set_nonblocking(pipe_fd[0])) {
        (void) close(pipe_fd[0]);
        (void) close(pipe_fd[1]);
        return NBSP_GIT_ERROR;
    }

    posix_spawn_file_actions_t actions;
    int setup_status = posix_spawn_file_actions_init(&actions);
    if (setup_status != 0) {
        (void) close(pipe_fd[0]);
        (void) close(pipe_fd[1]);
        return NBSP_GIT_ERROR;
    }
    setup_status = posix_spawn_file_actions_adddup2(&actions, pipe_fd[1], STDOUT_FILENO);
    if (setup_status == 0) {
        setup_status = posix_spawn_file_actions_addclose(&actions, pipe_fd[0]);
    }
    if (setup_status == 0) {
        setup_status = posix_spawn_file_actions_addclose(&actions, pipe_fd[1]);
    }
    if (setup_status == 0) {
        setup_status = posix_spawn_file_actions_addopen(
            &actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    }
    if (setup_status == 0) {
        setup_status = posix_spawn_file_actions_addopen(
            &actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    }
    if (setup_status != 0) {
        (void) posix_spawn_file_actions_destroy(&actions);
        (void) close(pipe_fd[0]);
        (void) close(pipe_fd[1]);
        return NBSP_GIT_ERROR;
    }

    posix_spawnattr_t attributes;
    setup_status = posix_spawnattr_init(&attributes);
    bool attributes_initialized = setup_status == 0;
    if (setup_status == 0) {
        setup_status = posix_spawnattr_setpgroup(&attributes, 0);
    }
    if (setup_status == 0) {
        setup_status = posix_spawnattr_setflags(
            &attributes, (short) POSIX_SPAWN_SETPGROUP);
    }
    if (setup_status != 0) {
        if (attributes_initialized) {
            (void) posix_spawnattr_destroy(&attributes);
        }
        (void) posix_spawn_file_actions_destroy(&actions);
        (void) close(pipe_fd[0]);
        (void) close(pipe_fd[1]);
        return NBSP_GIT_ERROR;
    }

    char **clean_environment = git_environment();
    if (!clean_environment) {
        (void) posix_spawnattr_destroy(&attributes);
        (void) posix_spawn_file_actions_destroy(&actions);
        (void) close(pipe_fd[0]);
        (void) close(pipe_fd[1]);
        return NBSP_GIT_ERROR;
    }

    char root_arg[sizeof repo->root];
    int root_count = snprintf(root_arg, sizeof root_arg, "%s", repo->root);
    char git_dir_arg[sizeof repo->git_dir + sizeof "--git-dir="];
    int git_dir_count = snprintf(
        git_dir_arg, sizeof git_dir_arg, "--git-dir=%s", repo->git_dir);
    char work_tree_arg[sizeof repo->root + sizeof "--work-tree="];
    int work_tree_count = snprintf(
        work_tree_arg, sizeof work_tree_arg, "--work-tree=%s", repo->root);
    if (root_count < 0 || (size_t) root_count >= sizeof root_arg ||
        git_dir_count < 0 || (size_t) git_dir_count >= sizeof git_dir_arg ||
        work_tree_count < 0 || (size_t) work_tree_count >= sizeof work_tree_arg) {
        free(clean_environment);
        (void) posix_spawnattr_destroy(&attributes);
        (void) posix_spawn_file_actions_destroy(&actions);
        (void) close(pipe_fd[0]);
        (void) close(pipe_fd[1]);
        return NBSP_GIT_ERROR;
    }
    char *const argv[] = {
        "git",
        "--no-optional-locks",
        "-C",
        root_arg,
        git_dir_arg,
        work_tree_arg,
        "status",
        "--porcelain=v2",
        "--branch",
        "--show-stash",
        "--untracked-files=normal",
        "--ignore-submodules=dirty",
        "--no-renames",
        NULL
    };

    pid_t child = 0;
    int spawn_status = posix_spawnp(
        &child, "git", &actions, &attributes, argv, clean_environment);
    free(clean_environment);
    int attribute_destroy_status = posix_spawnattr_destroy(&attributes);
    int action_destroy_status = posix_spawn_file_actions_destroy(&actions);
    int parent_close_status = close(pipe_fd[1]);
    if (spawn_status != 0) {
        (void) close(pipe_fd[0]);
        return NBSP_GIT_ERROR;
    }
    if (parent_close_status != 0) {
        kill_process_group(child);
        reap_child(child);
        (void) close(pipe_fd[0]);
        return NBSP_GIT_ERROR;
    }

    struct nbsp_buf output;
    nbsp_buf_init(&output);
    int result = collect_output(child, pipe_fd[0], timeout_ms, started, &output);
    int read_close_status = close(pipe_fd[0]);
    if (result == NBSP_GIT_OK &&
        (attribute_destroy_status != 0 || action_destroy_status != 0 ||
            read_close_status != 0 ||
            !output.data || memchr(output.data, '\0', output.len) != NULL ||
            !nbsp_git_parse_status(output.data, status))) {
        result = NBSP_GIT_ERROR;
    }
    nbsp_buf_free(&output);
    return result;
}
