#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "nbsp_cache.h"
#include "nbsp_git.h"
#include "nbsp_prompt.h"
#include "nbsp_util.h"

static uint64_t random_state = UINT64_C(0x9e3779b97f4a7c15);

static uint64_t fuzz_random(void) {
    uint64_t value = random_state;
    value ^= value >> 12U;
    value ^= value << 25U;
    value ^= value >> 27U;
    random_state = value;
    return value * UINT64_C(2685821657736338717);
}

static void exercise_input(const uint8_t *data, size_t size) {
    if (size == SIZE_MAX) return;
    char *input = malloc(size + 1U);
    if (!input) return;
    memcpy(input, data, size);
    input[size] = '\0';

    struct nbsp_git_status status;
    (void) nbsp_git_parse_status(input, &status);
    (void) nbsp_cache_parse(input, "/tmp/nobsprompt-fuzz-repo", &status);

    for (unsigned prompt_options = 0U; prompt_options < 8U; ++prompt_options) {
        struct nbsp_buf quoted;
        nbsp_buf_init(&quoted);
        (void) nbsp_prompt_quote(&quoted, input, prompt_options);
        nbsp_buf_free(&quoted);

        char *prompt = nbsp_prompt_render(input,
            (int) (size & 1U),
            (unsigned long) size,
            (unsigned) (size & 7U),
            prompt_options);
        free(prompt);
    }

    char *encoded = nbsp_percent_encode(input);
    if (encoded) {
        char *decoded = nbsp_percent_decode(encoded);
        free(decoded);
        free(encoded);
    }

    char *version = nbsp_nvm_version(input);
    free(version);

    char path[NBSP_PATH_CAP];
    (void) nbsp_path_abbreviate_into(input, path, sizeof path);

    long parsed = 0;
    (void) nbsp_parse_long(input, -1000L, 1000L, &parsed);

    struct nbsp_buf buf;
    nbsp_buf_init(&buf);
    (void) nbsp_buf_append_n(&buf, input, size);
    (void) nbsp_buf_appendf(&buf, "%zu", size);
    nbsp_buf_free(&buf);
    free(input);
}

static size_t build_input(uint8_t *buffer, size_t cap, uint64_t iteration) {
    static const char *const seeds[] = {
        "# branch.oid 1234567890abcdef1234567890abcdef12345678\n"
        "# branch.head main\n"
        "# branch.upstream origin/main\n"
        "# branch.ab +0 -0\n",
        "# branch.oid abcdef0123456789abcdef0123456789abcdef01\n"
        "# branch.head feature/100%\n"
        "# branch.upstream origin/feature/100%\n"
        "# branch.ab +12 -3\n"
        "# stash 2\n"
        "1 MM N... 100644 100644 100644 "
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb file\n"
        "u UU N... 100644 100644 100644 100644 "
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb "
            "cccccccccccccccccccccccccccccccccccccccc conflict\n"
        "? untracked\n",
        "/Users/example/a/very/long/path/with/%/characters",
        "/Users/example/.nvm/versions/node/v22.14.0/bin",
        "version=2\n"
        "repo=/tmp/nobsprompt-fuzz-repo\n"
        "updated_ms=123\n"
        "branch=feature/cache-parser\n"
        "staged=1\nmodified=2\nuntracked=3\nconflicted=4\n"
        "ahead=5\nbehind=6\nstashes=7\n",
        "version=2\n"
        "repo=/tmp/nobsprompt-fuzz-repo\n"
        "updated_ms=456\n"
        "branch=main\n"
        "staged=0\nmodified=0\nuntracked=0\nconflicted=0\n"
        "ahead=0\nbehind=0\nstashes=0\n"
        "future_field=opaque\n",
    };

    const size_t seed_count = sizeof seeds / sizeof seeds[0];
    bool pristine_seed = iteration < seed_count;
    size_t length = 0U;
    if (pristine_seed || (iteration & 3U) != 0U) {
        const char *seed = pristine_seed ?
            seeds[(size_t) iteration] : seeds[fuzz_random() % seed_count];
        length = strlen(seed);
        if (length > cap) length = cap;
        memcpy(buffer, seed, length);
        unsigned mutations = pristine_seed ? 0U : (unsigned) (fuzz_random() % 33U);
        for (unsigned i = 0U; i < mutations && length; ++i) {
            size_t at = (size_t) (fuzz_random() % length);
            buffer[at] = (uint8_t) fuzz_random();
        }
    } else {
        size_t limit = (iteration & 255U) == 0U ? cap : 4096U;
        length = (size_t) (fuzz_random() % (limit + 1U));
        for (size_t i = 0U; i < length; ++i) {
            buffer[i] = (uint8_t) fuzz_random();
        }
    }
    return length;
}

static int usage(const char *program) {
    fprintf(stderr, "usage: %s [positive-iterations]\n", program);
    return 2;
}

int main(int argc, char **argv) {
    unsigned long iterations = 250000UL;
    if (argc == 2) {
        if (argv[1][0] == '\0') {
            return usage(argv[0]);
        }
        for (const unsigned char *p = (const unsigned char *) argv[1]; *p; ++p) {
            if (*p < '0' || *p > '9') {
                return usage(argv[0]);
            }
        }
        errno = 0;
        char *end = NULL;
        unsigned long parsed = strtoul(argv[1], &end, 10);
        if (errno != 0 || end == argv[1] || *end != '\0' || parsed == 0UL) {
            return usage(argv[0]);
        }
        iterations = parsed;
    } else if (argc != 1) {
        return usage(argv[0]);
    }

    uint8_t *buffer = malloc(16384U);
    if (!buffer) return 1;
    for (unsigned long i = 0UL; i < iterations; ++i) {
        size_t length = build_input(buffer, 16384U, (uint64_t) i);
        exercise_input(buffer, length);
    }
    free(buffer);
    printf("fuzz iterations: %lu\n", iterations);
    return 0;
}
