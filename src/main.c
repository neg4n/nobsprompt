#include <errno.h>
#include <getopt.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdbool.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>

#include "nbsp_cache.h"
#include "nbsp_data.h"
#include "nbsp_dirs.h"
#include "nbsp_prompt.h"
#include "nbsp_refresh.h"
#include "nbsp_util.h"
#include "nbsp_zsh.h"

#ifndef NBSP_VERSION
#define NBSP_VERSION "0.0.0"
#endif

static bool resolve_self_path(char *out, size_t out_len) {
    char raw[NBSP_PATH_CAP];
    uint32_t size = (uint32_t) sizeof raw;
    if (_NSGetExecutablePath(raw, &size) != 0) {
        return false;
    }
    char resolved[NBSP_PATH_CAP];
    if (!realpath(raw, resolved)) {
        return nbsp_copy_cstr(out, out_len, raw);
    }
    return nbsp_copy_cstr(out, out_len, resolved);
}

static void print_zsh_single_quoted(FILE *out, const char *text) {
    fputc('\'', out);
    if (text) {
        for (const char *p = text; *p; ++p) {
            if (*p == '\'') {
                fputs("'\\''", out);
            } else {
                fputc(*p, out);
            }
        }
    }
    fputc('\'', out);
}

static void print_nbsp_bin_assignment(FILE *out) {
    char self[NBSP_PATH_CAP];
    fputs("typeset -g _NBSP_BIN=", out);
    if (resolve_self_path(self, sizeof self)) {
        print_zsh_single_quoted(out, self);
    } else {
        fputs("nbsp", out);
    }
    fputc('\n', out);
}

static void print_usage(FILE *out) {
    fputs(
        "Usage:\n"
        "  nbsp init zsh [--detached] [--autosuggest]\n"
        "  nbsp data [--status N] [--duration-ms N] [--jobs N]"
            " [--format lines|nul]\n"
        "  nbsp refresh [--cwd PATH] [--notify] [--force]\n"
        "  nbsp dirs [--cwd PATH] [--format nul]\n"
        "  nbsp cache clear\n"
        "  nbsp --help\n"
        "  nbsp --version\n",
        out);
}

static void print_help(void) {
    print_usage(stdout);
    fputs(
        "\n"
        "nbsp is a small, asynchronous prompt for macOS and Zsh.\n"
        "Run 'eval \"$(nbsp init zsh)\"' from .zshrc for the opinionated prompt.\n"
        "Use 'nbsp init zsh --detached' to own PROMPT from NBSP_DATA.\n"
        "The data path never starts Git; refresh is the background worker.\n",
        stdout);
}

static int command_data(int argc, char **argv) {
    int last_status = 0;
    unsigned long duration_ms = 0UL;
    unsigned jobs = 0U;
    enum nbsp_data_format format = NBSP_DATA_LINES;
    enum { OPT_STATUS = 1, OPT_DURATION, OPT_JOBS, OPT_FORMAT };
    static const struct option options[] = {
        {"status", required_argument, NULL, OPT_STATUS},
        {"duration-ms", required_argument, NULL, OPT_DURATION},
        {"jobs", required_argument, NULL, OPT_JOBS},
        {"format", required_argument, NULL, OPT_FORMAT},
        {0, 0, 0, 0}
    };
    optind = 1;
    int option = 0;
    while ((option = getopt_long(argc, argv, "", options, NULL)) != -1) {
        long parsed = 0;
        switch (option) {
            case OPT_STATUS:
                if (!nbsp_parse_long(optarg, 0, 255, &parsed)) return 2;
                last_status = (int) parsed;
                break;
            case OPT_DURATION:
                if (!nbsp_parse_long(optarg, 0, LONG_MAX, &parsed)) return 2;
                duration_ms = (unsigned long) parsed;
                break;
            case OPT_JOBS:
                if (!nbsp_parse_long(optarg, 0, INT_MAX, &parsed)) return 2;
                jobs = (unsigned) parsed;
                break;
            case OPT_FORMAT:
                if (strcmp(optarg, "lines") == 0) {
                    format = NBSP_DATA_LINES;
                } else if (strcmp(optarg, "nul") == 0) {
                    format = NBSP_DATA_NUL;
                } else {
                    return 2;
                }
                break;
            default:
                return 2;
        }
    }
    if (optind != argc) {
        return 2;
    }

    char cwd[NBSP_PATH_CAP];
    if (!getcwd(cwd, sizeof cwd)) {
        return 1;
    }
    struct nbsp_prompt_data data;
    if (!nbsp_prompt_data_collect(cwd, last_status, duration_ms, jobs, &data)) {
        return 1;
    }
    return nbsp_data_write(stdout, &data, format) ? 0 : 1;
}

static int command_refresh(int argc, char **argv) {
    const char *cwd_arg = NULL;
    bool notify = false;
    bool force = false;
    enum { OPT_CWD = 1, OPT_NOTIFY, OPT_FORCE };
    static const struct option options[] = {
        {"cwd", required_argument, NULL, OPT_CWD},
        {"notify", no_argument, NULL, OPT_NOTIFY},
        {"force", no_argument, NULL, OPT_FORCE},
        {0, 0, 0, 0}
    };
    optind = 1;
    int option = 0;
    while ((option = getopt_long(argc, argv, "", options, NULL)) != -1) {
        if (option == OPT_CWD) {
            cwd_arg = optarg;
        } else if (option == OPT_NOTIFY) {
            notify = true;
        } else if (option == OPT_FORCE) {
            force = true;
        } else {
            return 2;
        }
    }
    if (optind != argc) {
        return 2;
    }

    char cwd[NBSP_PATH_CAP];
    if (!cwd_arg) {
        if (!getcwd(cwd, sizeof cwd)) {
            if (notify) fputc('\n', stdout);
            return 1;
        }
        cwd_arg = cwd;
    }
    return nbsp_refresh(cwd_arg, nbsp_git_timeout_from_env(), notify, force);
}

static int command_dirs(int argc, char **argv) {
    const char *cwd_arg = NULL;
    enum { OPT_CWD = 1, OPT_FORMAT };
    static const struct option options[] = {
        {"cwd", required_argument, NULL, OPT_CWD},
        {"format", required_argument, NULL, OPT_FORMAT},
        {0, 0, 0, 0}
    };
    optind = 1;
    int option = 0;
    while ((option = getopt_long(argc, argv, "", options, NULL)) != -1) {
        if (option == OPT_CWD) {
            cwd_arg = optarg;
        } else if (option == OPT_FORMAT) {
            if (strcmp(optarg, "nul") != 0) return 2;
        } else {
            return 2;
        }
    }
    if (optind != argc) return 2;

    char cwd[NBSP_PATH_CAP];
    if (!cwd_arg) {
        if (!getcwd(cwd, sizeof cwd)) return 1;
        cwd_arg = cwd;
    }

    struct sigaction alarm_action;
    memset(&alarm_action, 0, sizeof alarm_action);
    alarm_action.sa_handler = SIG_DFL;
    (void) sigemptyset(&alarm_action.sa_mask);
    if (sigaction(SIGALRM, &alarm_action, NULL) != 0) return 1;
    sigset_t alarm_set;
    if (sigemptyset(&alarm_set) != 0 || sigaddset(&alarm_set, SIGALRM) != 0 ||
        sigprocmask(SIG_UNBLOCK, &alarm_set, NULL) != 0) {
        return 1;
    }

    struct itimerval timer = {0};
    timer.it_value.tv_usec = (suseconds_t) NBSP_DIR_TIMEOUT_MS * 1000;
    if (setitimer(ITIMER_REAL, &timer, NULL) != 0) return 1;
    (void) setvbuf(stdout, NULL, _IONBF, 0);
    bool ok = nbsp_dirs_write(stdout, cwd_arg);
    memset(&timer, 0, sizeof timer);
    (void) setitimer(ITIMER_REAL, &timer, NULL);
    return ok ? 0 : 1;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        print_usage(stderr);
        return 2;
    }
    if (strcmp(argv[1], "--help") == 0 || strcmp(argv[1], "-h") == 0) {
        print_help();
        return 0;
    }
    if (strcmp(argv[1], "--version") == 0 || strcmp(argv[1], "-V") == 0) {
        printf("nbsp %s\n", NBSP_VERSION);
        return 0;
    }
    if (strcmp(argv[1], "init") == 0) {
        bool detached = false;
        bool autosuggest = false;
        if (argc < 3 || strcmp(argv[2], "zsh") != 0) {
            print_usage(stderr);
            return 2;
        }
        for (int i = 3; i < argc; ++i) {
            if (strcmp(argv[i], "--detached") == 0 && !detached) {
                detached = true;
            } else if (strcmp(argv[i], "--autosuggest") == 0 && !autosuggest) {
                autosuggest = true;
            } else {
                print_usage(stderr);
                return 2;
            }
        }
        fputs(detached
            ? "typeset -g _NBSP_INIT_MODE=detached\n"
            : "typeset -g _NBSP_INIT_MODE=prompt\n",
            stdout);
        print_nbsp_bin_assignment(stdout);
        nbsp_print_zsh_init(stdout);
        if (!detached) nbsp_print_zsh_opinionated(stdout);
        if (autosuggest) nbsp_print_zsh_autosuggest(stdout);
        return 0;
    }
    if (strcmp(argv[1], "data") == 0) {
        return command_data(argc - 1, argv + 1);
    }
    if (strcmp(argv[1], "refresh") == 0) {
        return command_refresh(argc - 1, argv + 1);
    }
    if (strcmp(argv[1], "dirs") == 0) {
        return command_dirs(argc - 1, argv + 1);
    }
    if (strcmp(argv[1], "cache") == 0) {
        if (argc == 3 && strcmp(argv[2], "clear") == 0) {
            if (nbsp_cache_clear() != 0) {
                fprintf(stderr, "nbsp: failed to clear cache: %s\n", strerror(errno));
                return 1;
            }
            return 0;
        }
        print_usage(stderr);
        return 2;
    }
    print_usage(stderr);
    return 2;
}
