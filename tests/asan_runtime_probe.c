#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#if defined(__clang__) || defined(__GNUC__)
#define NBSP_NOINLINE __attribute__((noinline))
#else
#define NBSP_NOINLINE
#endif

static NBSP_NOINLINE bool intentionally_leak(void) {
    unsigned char *volatile allocation = malloc(64U);
    if (!allocation) return false;
    allocation[0] = 0x5aU;
    allocation = NULL;
    return true;
}

int main(int argc, char **argv) {
    if (argc == 1) return 0;
    if (argc == 2 && strcmp(argv[1], "--leak") == 0) {
        return intentionally_leak() ? 0 : 1;
    }
    return 2;
}
