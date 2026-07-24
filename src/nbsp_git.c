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

static bool read_first_line(const char *path, char *out, size_t out_len) {
    if (!path || !out || out_len == 0U) {
        return false;
    }
    int fd = open(path, O_RDONLY);
    if (fd < 0) return false;
    ssize_t count = 0;
    do {
        count = read(fd, out, out_len - 1U);
    } while (count < 0 && errno == EINTR);
    (void) close(fd);
    if (count <= 0) return false;
    size_t length = (size_t) count;
    char *newline = memchr(out, '\n', length);
    if (newline) {
        length = (size_t) (newline - out);
    } else if (length == out_len - 1U) {
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
    char candidate[PATH_MAX];
    int count = value[0] == '/'
        ? snprintf(candidate, sizeof candidate, "%s", value)
        : snprintf(candidate, sizeof candidate, "%s/%s", worktree, value);
    if (count < 0 || (size_t) count >= sizeof candidate) {
        return false;
    }
    char resolved[PATH_MAX];
    if (realpath(candidate, resolved)) {
        count = snprintf(out, out_len, "%s", resolved);
    } else {
        count = snprintf(out, out_len, "%s", candidate);
    }
    return count >= 0 && (size_t) count < out_len;
}

bool nbsp_git_discover(const char *cwd, struct nbsp_repo *out) {
    if (!cwd || !out) {
        return false;
    }
    out->root[0] = '\0';
    out->git_dir[0] = '\0';

    char current[PATH_MAX];
    int cwd_count = snprintf(current, sizeof current, "%s", cwd);
    if (cwd_count < 0 || (size_t) cwd_count >= sizeof current) {
        return false;
    }
    size_t current_len = strlen(current);
    while (current_len > 1U && current[current_len - 1U] == '/') {
        current[--current_len] = '\0';
    }
    if (current[0] != '/') {
        char resolved[PATH_MAX];
        if (!realpath(current, resolved)) {
            return false;
        }
        (void) snprintf(current, sizeof current, "%s", resolved);
    }

    for (;;) {
        char git_path[PATH_MAX];
        int count = snprintf(git_path, sizeof git_path, "%s%s.git",
            current,
            strcmp(current, "/") == 0 ? "" : "/");
        if (count < 0 || (size_t) count >= sizeof git_path) {
            return false;
        }
        struct stat info;
        if (stat(git_path, &info) == 0) {
            bool git_dir_ok = false;
            if (S_ISDIR(info.st_mode)) {
                char resolved[PATH_MAX];
                const char *source = realpath(git_path, resolved) ? resolved : git_path;
                count = snprintf(out->git_dir, sizeof out->git_dir, "%s", source);
                git_dir_ok = count >= 0 && (size_t) count < sizeof out->git_dir;
            } else if (S_ISREG(info.st_mode)) {
                git_dir_ok = resolve_git_file(current, git_path, out->git_dir, sizeof out->git_dir);
            }
            if (git_dir_ok) {
                char resolved_root[PATH_MAX];
                const char *source = realpath(current, resolved_root) ? resolved_root : current;
                count = snprintf(out->root, sizeof out->root, "%s", source);
                if (count < 0 || (size_t) count >= sizeof out->root) return false;
                return true;
            }
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

bool nbsp_git_read_branch(const struct nbsp_repo *repo, char *out, size_t out_len) {
    if (!repo || repo->git_dir[0] == '\0' || !out || out_len == 0U) {
        return false;
    }
    char head_path[PATH_MAX];
    int count = snprintf(head_path, sizeof head_path, "%s/HEAD", repo->git_dir);
    if (count < 0 || (size_t) count >= sizeof head_path) return false;
    char line[1024];
    bool ok = read_first_line(head_path, line, sizeof line);
    if (!ok || line[0] == '\0') {
        return false;
    }

    if (strncmp(line, "ref: ", 5U) == 0) {
        const char *display = line + 5U;
        const char *heads = "refs/heads/";
        if (strncmp(display, heads, strlen(heads)) == 0) {
            display += strlen(heads);
        }
        (void) snprintf(out, out_len, "%s", display);
        return out[0] != '\0';
    }

    size_t length = strlen(line);
    size_t short_len = length < 8U ? length : 8U;
    if (short_len + 1U > out_len) {
        return false;
    }
    memcpy(out, line, short_len);
    out[short_len] = '\0';
    return true;
}

static void copy_branch(char *target, size_t target_len, const char *value) {
    if (!target || target_len == 0U || !value) {
        return;
    }
    (void) snprintf(target, target_len, "%s", value);
}

bool nbsp_git_parse_status(const char *output, struct nbsp_git_status *status) {
    if (!output || !status) {
        return false;
    }
    memset(status, 0, sizeof *status);
    char *copy = nbsp_strdup(output);
    if (!copy) {
        return false;
    }

    char *save = NULL;
    for (char *line = strtok_r(copy, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        if (strncmp(line, "# branch.head ", 14U) == 0) {
            const char *branch = line + 14U;
            if (strcmp(branch, "(detached)") != 0) {
                copy_branch(status->branch, sizeof status->branch, branch);
            }
        } else if (strncmp(line, "# branch.oid ", 13U) == 0 && status->branch[0] == '\0') {
            const char *oid = line + 13U;
            if (strcmp(oid, "(initial)") != 0) {
                size_t len = strlen(oid) < 8U ? strlen(oid) : 8U;
                if (len < sizeof status->branch) {
                    memcpy(status->branch, oid, len);
                    status->branch[len] = '\0';
                }
            }
        } else if (strncmp(line, "# branch.ab +", 13U) == 0) {
            (void) sscanf(line + 13U, "%u -%u", &status->ahead, &status->behind);
        } else if (strncmp(line, "# stash ", 8U) == 0) {
            (void) sscanf(line + 8U, "%u", &status->stashes);
        } else if ((line[0] == '1' || line[0] == '2') && line[1] == ' ' && strlen(line) >= 4U) {
            char index_state = line[2];
            char tree_state = line[3];
            if (index_state != '.') {
                ++status->staged;
            }
            if (tree_state != '.') {
                ++status->modified;
            }
        } else if (line[0] == 'u' && line[1] == ' ') {
            ++status->conflicted;
        } else if (line[0] == '?' && line[1] == ' ') {
            ++status->untracked;
        }
    }
    free(copy);
    status->updated_ms = nbsp_wall_millis();
    status->valid = true;
    return true;
}

static int collect_output(pid_t child, int fd, unsigned timeout_ms, struct nbsp_buf *output) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) {
        (void) fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    }

    uint64_t started = nbsp_monotonic_millis();
    char chunk[8192];
    bool done = false;
    while (!done) {
        uint64_t elapsed = nbsp_monotonic_millis() - started;
        if (elapsed >= timeout_ms) {
            (void) kill(child, SIGKILL);
            (void) waitpid(child, NULL, 0);
            return 124;
        }
        uint64_t remaining = (uint64_t) timeout_ms - elapsed;
        int wait_ms = remaining > 50U ? 50 : (int) remaining;
        struct pollfd poll_fd = {.fd = fd, .events = POLLIN | POLLHUP, .revents = 0};
        int ready = poll(&poll_fd, 1U, wait_ms);
        if (ready < 0 && errno != EINTR) {
            (void) kill(child, SIGKILL);
            (void) waitpid(child, NULL, 0);
            return 1;
        }
        if (ready <= 0) {
            continue;
        }
        for (;;) {
            ssize_t count = read(fd, chunk, sizeof chunk);
            if (count > 0) {
                if (output->len > 8U * 1024U * 1024U - (size_t) count ||
                    !nbsp_buf_append_n(output, chunk, (size_t) count)) {
                    (void) kill(child, SIGKILL);
                    (void) waitpid(child, NULL, 0);
                    return 1;
                }
            } else if (count == 0) {
                done = true;
                break;
            } else if (errno == EAGAIN || errno == EWOULDBLOCK) {
                break;
            } else if (errno != EINTR) {
                (void) kill(child, SIGKILL);
                (void) waitpid(child, NULL, 0);
                return 1;
            }
        }
    }

    int status = 0;
    if (waitpid(child, &status, 0) < 0) {
        return 1;
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}

int nbsp_git_collect(const struct nbsp_repo *repo,
    unsigned timeout_ms,
    struct nbsp_git_status *status) {
    if (!repo || repo->root[0] == '\0' || !status || timeout_ms == 0U) {
        return 1;
    }

    int pipe_fd[2];
    if (pipe(pipe_fd) != 0) {
        return 1;
    }

    posix_spawn_file_actions_t actions;
    if (posix_spawn_file_actions_init(&actions) != 0) {
        (void) close(pipe_fd[0]);
        (void) close(pipe_fd[1]);
        return 1;
    }
    (void) posix_spawn_file_actions_adddup2(&actions, pipe_fd[1], STDOUT_FILENO);
    (void) posix_spawn_file_actions_addclose(&actions, pipe_fd[0]);
    (void) posix_spawn_file_actions_addclose(&actions, pipe_fd[1]);
    (void) posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);

    char *root_arg = (char *) repo->root;
    char *const argv[] = {
        "git",
        "--no-optional-locks",
        "-C",
        root_arg,
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
    int spawn_status = posix_spawnp(&child, "git", &actions, NULL, argv, environ);
    (void) posix_spawn_file_actions_destroy(&actions);
    (void) close(pipe_fd[1]);
    if (spawn_status != 0) {
        (void) close(pipe_fd[0]);
        return spawn_status;
    }

    struct nbsp_buf output;
    nbsp_buf_init(&output);
    int result = collect_output(child, pipe_fd[0], timeout_ms, &output);
    (void) close(pipe_fd[0]);
    if (result == 0 && !output.data) {
        (void) nbsp_buf_append(&output, "");
    }
    if (result == 0 && !nbsp_git_parse_status(output.data, status)) {
        result = 1;
    }
    nbsp_buf_free(&output);
    return result;
}
