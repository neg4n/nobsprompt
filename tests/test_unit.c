#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "nbsp_cache.h"
#include "nbsp_git.h"
#include "nbsp_prompt.h"
#include "nbsp_util.h"

static int failures = 0;

#define CHECK(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #condition); \
        ++failures; \
    } \
} while (0)

static void test_paths(void) {
    char *path = nbsp_path_abbreviate("/Users/igorklepacki/programming/test");
    CHECK(path && strcmp(path, "/U/i/p/test") == 0);
    free(path);

    path = nbsp_path_abbreviate("/Users/test/code/acme/app/src");
    CHECK(path && strcmp(path, "/U/t/c/a/a/src") == 0);
    free(path);

    path = nbsp_path_abbreviate("/one/.config/three/four");
    CHECK(path && strcmp(path, "/o/.c/t/four") == 0);
    free(path);
}

static void test_escape_and_nvm(void) {
    char *escaped = nbsp_prompt_escape("feature/100%\033bad\n");
    CHECK(escaped && strcmp(escaped, "feature/100%%?bad?") == 0);
    free(escaped);

    char *version = nbsp_nvm_version("/Users/test/.nvm/versions/node/v22.14.0/bin");
    CHECK(version && strcmp(version, "22.14.0") == 0);
    free(version);

    version = nbsp_nvm_version("/unexpected/path with spaces/bin");
    CHECK(version == NULL);

    char bytes[256];
    for (unsigned i = 1U; i < 256U; ++i) bytes[i - 1U] = (char) i;
    bytes[255] = '\0';
    char *encoded = nbsp_percent_encode(bytes);
    char *decoded = encoded ? nbsp_percent_decode(encoded) : NULL;
    CHECK(decoded && memcmp(decoded, bytes, sizeof bytes) == 0);
    free(decoded);
    free(encoded);

    char too_long[NBSP_PATH_CAP + 32U];
    memset(too_long, 'a', sizeof too_long);
    too_long[0] = '/';
    too_long[sizeof too_long - 1U] = '\0';
    char contracted[NBSP_PATH_CAP];
    CHECK(!nbsp_path_abbreviate_into(too_long, contracted, sizeof contracted));
}

static void test_status_parser(void) {
    const char *sample =
        "# branch.oid 1234567890abcdef\n"
        "# branch.head main\n"
        "# branch.upstream origin/main\n"
        "# branch.ab +2 -3\n"
        "# stash 4\n"
        "1 M. N... 100644 100644 100644 a a staged\n"
        "1 .M N... 100644 100644 100644 a a modified\n"
        "1 MM N... 100644 100644 100644 a a both\n"
        "u UU N... 100644 100644 100644 100644 a a a conflict\n"
        "? untracked\n";
    struct nbsp_git_status status;
    CHECK(nbsp_git_parse_status(sample, &status));
    CHECK(status.valid);
    CHECK(strcmp(status.branch, "main") == 0);
    CHECK(status.staged == 2U);
    CHECK(status.modified == 2U);
    CHECK(status.untracked == 1U);
    CHECK(status.conflicted == 1U);
    CHECK(status.ahead == 2U && status.behind == 3U && status.stashes == 4U);
}

static void test_cache(void) {
    char dir[128];
    (void) snprintf(dir, sizeof dir, "/tmp/nbsp-unit-%ld", (long) getpid());
    CHECK(mkdir(dir, 0700) == 0);
    CHECK(setenv("NBSP_CACHE_DIR", dir, 1) == 0);

    struct nbsp_git_status stored = {
        .valid = true,
        .updated_ms = 123456U,
        .branch = "percent%branch",
        .staged = 1U,
        .modified = 2U,
        .untracked = 3U,
        .conflicted = 4U,
        .ahead = 5U,
        .behind = 6U,
        .stashes = 7U,
    };
    CHECK(nbsp_cache_store("/tmp/repo with spaces", &stored));
    struct nbsp_git_status loaded;
    CHECK(nbsp_cache_load("/tmp/repo with spaces", &loaded));
    CHECK(strcmp(loaded.branch, stored.branch) == 0);
    CHECK(loaded.staged == 1U && loaded.stashes == 7U);
    CHECK(!nbsp_cache_load("/tmp/a different repo", &loaded));

    char lock_path[256];
    int first_lock = nbsp_cache_lock("/tmp/repo with spaces", 1000U, lock_path, sizeof lock_path);
    CHECK(first_lock >= 0);
    char second_path[256];
    int second_lock = nbsp_cache_lock("/tmp/repo with spaces", 1000U, second_path, sizeof second_path);
    CHECK(second_lock < 0);
    nbsp_cache_unlock(first_lock, lock_path);

    char git_dir[256];
    CHECK(nbsp_cache_git_dir(git_dir, sizeof git_dir, false));
    char cache_path[512];
    (void) snprintf(cache_path, sizeof cache_path, "%s/%016" PRIx64 ".cache",
        git_dir,
        nbsp_hash_path("/tmp/repo with spaces"));
    FILE *corrupt = fopen(cache_path, "w");
    CHECK(corrupt != NULL);
    if (corrupt) {
        fputs("version=1\nrepo=broken\nupdated_ms=not-a-number\n", corrupt);
        CHECK(fclose(corrupt) == 0);
    }
    CHECK(!nbsp_cache_load("/tmp/repo with spaces", &loaded));

    corrupt = fopen(cache_path, "w");
    CHECK(corrupt != NULL);
    if (corrupt) {
        CHECK(fseek(corrupt, 17000L, SEEK_SET) == 0);
        CHECK(fputc('x', corrupt) == 'x');
        CHECK(fclose(corrupt) == 0);
    }
    CHECK(!nbsp_cache_load("/tmp/repo with spaces", &loaded));
    CHECK(nbsp_cache_clear() == 0);
    CHECK(rmdir(git_dir) == 0);
    CHECK(rmdir(dir) == 0);
}

static void test_buffer_growth(void) {
    struct nbsp_buf buf;
    nbsp_buf_init(&buf);
    CHECK(!nbsp_buf_append_n(&buf, "x", SIZE_MAX));
    for (size_t i = 0U; i < 1024U * 1024U; ++i) {
        CHECK(nbsp_buf_append_char(&buf, (char) ('a' + i % 26U)));
    }
    CHECK(buf.len == 1024U * 1024U);
    CHECK(buf.data && buf.data[buf.len] == '\0');
    nbsp_buf_free(&buf);
    CHECK(nbsp_color_valid("none"));
    CHECK(!nbsp_color_valid("red}%n"));
}

static void test_prompt(void) {
    struct nbsp_config config = {
        .color_path = "cyan",
        .color_git = "magenta",
        .color_node = "green",
        .color_meta = "yellow",
        .color_ok = "none",
        .color_error = "red",
        .prompt_char = "%>",
        .duration_threshold_ms = 1000U,
        .git_timeout_ms = 1500U,
        .show_git = false,
        .show_nvm = true,
        .show_jobs = true,
    };
    CHECK(setenv("HOME", "/Users/test", 1) == 0);
    CHECK(setenv("NVM_BIN", "/Users/test/.nvm/versions/node/v20.1.0/bin", 1) == 0);
    char *prompt = nbsp_prompt_render("/Users/test/code/app", 1, 2450UL, 2U, &config);
    CHECK(prompt != NULL);
    CHECK(prompt && strstr(prompt, "%F{cyan}/U/t/c/app%f"));
    CHECK(prompt && strstr(prompt, "[node:20.1.0]"));
    CHECK(prompt && strstr(prompt, "[2.5s]"));
    CHECK(prompt && strstr(prompt, "[jobs:2]"));
    CHECK(prompt && strstr(prompt, "%F{red}e1%%>%f"));
    free(prompt);

    config.prompt_char = "%#";
    config.show_nvm = false;
    prompt = nbsp_prompt_render("/Users/test/code/app", 0, 0UL, 0U, &config);
    CHECK(prompt && strstr(prompt, " %# "));
    CHECK(prompt && !strstr(prompt, "e0%#"));
    CHECK(prompt && !strstr(prompt, "%F{green}"));
    free(prompt);
}

int main(void) {
    test_paths();
    test_escape_and_nvm();
    test_status_parser();
    test_cache();
    test_prompt();
    test_buffer_growth();
    if (failures) {
        fprintf(stderr, "%d unit check(s) failed\n", failures);
        return 1;
    }
    return 0;
}
