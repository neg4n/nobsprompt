#include <errno.h>
#include <getopt.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "nbsp_cache.h"
#include "nbsp_prompt.h"
#include "nbsp_util.h"
#include "nbsp_zsh.h"

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

#ifndef NBSP_VERSION
#define NBSP_VERSION "0.0.0"
#endif

static void print_usage(FILE *out) {
    fputs(
        "Usage:\n"
        "  nbsp init zsh\n"
        "  nbsp prompt [--status N] [--duration-ms N] [--jobs N]\n"
        "  nbsp refresh [--cwd PATH] [--notify]\n"
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
        "Run 'eval \"$(nbsp init zsh)\"' from .zshrc to install its hooks.\n"
        "The prompt command never starts Git; refresh is the background worker.\n",
        stdout);
}

static int command_prompt(int argc, char **argv) {
    int last_status = 0;
    unsigned long duration_ms = 0UL;
    unsigned jobs = 0U;
    enum { OPT_STATUS = 1, OPT_DURATION, OPT_JOBS };
    static const struct option options[] = {
        {"status", required_argument, NULL, OPT_STATUS},
        {"duration-ms", required_argument, NULL, OPT_DURATION},
        {"jobs", required_argument, NULL, OPT_JOBS},
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
            default:
                return 2;
        }
    }
    if (optind != argc) {
        return 2;
    }

    char cwd[PATH_MAX];
    if (!getcwd(cwd, sizeof cwd)) {
        (void) snprintf(cwd, sizeof cwd, "?");
    }
    struct nbsp_config config;
    nbsp_config_from_env(&config);
    char *prompt = nbsp_prompt_render(cwd, last_status, duration_ms, jobs, &config);
    if (!prompt) {
        fputs("> ", stdout);
        return 0;
    }
    fputs(prompt, stdout);
    free(prompt);
    return 0;
}

static int command_refresh(int argc, char **argv) {
    const char *cwd_arg = NULL;
    bool notify = false;
    enum { OPT_CWD = 1, OPT_NOTIFY };
    static const struct option options[] = {
        {"cwd", required_argument, NULL, OPT_CWD},
        {"notify", no_argument, NULL, OPT_NOTIFY},
        {0, 0, 0, 0}
    };
    optind = 1;
    int option = 0;
    while ((option = getopt_long(argc, argv, "", options, NULL)) != -1) {
        if (option == OPT_CWD) {
            cwd_arg = optarg;
        } else if (option == OPT_NOTIFY) {
            notify = true;
        } else {
            return 2;
        }
    }
    if (optind != argc) {
        return 2;
    }

    char cwd[PATH_MAX];
    if (!cwd_arg) {
        if (!getcwd(cwd, sizeof cwd)) {
            if (notify) fputc('\n', stdout);
            return 1;
        }
        cwd_arg = cwd;
    }
    struct nbsp_config config;
    nbsp_config_from_env(&config);
    return nbsp_refresh(cwd_arg, config.git_timeout_ms, notify);
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
        if (argc != 3 || strcmp(argv[2], "zsh") != 0) {
            print_usage(stderr);
            return 2;
        }
        nbsp_print_zsh_init(stdout);
        return 0;
    }
    if (strcmp(argv[1], "prompt") == 0) {
        return command_prompt(argc - 1, argv + 1);
    }
    if (strcmp(argv[1], "refresh") == 0) {
        return command_refresh(argc - 1, argv + 1);
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
