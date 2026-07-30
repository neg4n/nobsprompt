#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include "nbsp_cache.h"
#include "nbsp_data.h"
#include "nbsp_dirs.h"
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

static bool write_cache_fixture(const char *path,
    const char *version,
    const char *branch,
    const char *extra) {
    FILE *file = fopen(path, "w");
    if (!file) return false;
    bool ok = fprintf(file,
        "version=%s\n"
        "repo=/tmp/repo%%20with%%20spaces\n"
        "updated_ms=123456\n"
        "branch=%s\n"
        "staged=1\n"
        "modified=2\n"
        "untracked=3\n"
        "conflicted=4\n"
        "ahead=5\n"
        "behind=6\n"
        "stashes=7\n"
        "%s",
        version,
        branch,
        extra ? extra : "") > 0;
    return fclose(file) == 0 && ok;
}

static void restore_environment(const char *name, const char *value) {
    if (value) {
        CHECK(setenv(name, value, 1) == 0);
    } else {
        CHECK(unsetenv(name) == 0);
    }
}

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

static char *prompt_quote(unsigned options) {
    struct nbsp_buf quoted;
    nbsp_buf_init(&quoted);
    CHECK(nbsp_prompt_quote(&quoted, "100% $(x) `y` ! \\\033\n", options));
    return nbsp_buf_take(&quoted);
}

static void test_escape_and_nvm(void) {
    char *quoted = prompt_quote(0U);
    CHECK(quoted && strcmp(quoted, "100% $(x) `y` ! \\??") == 0);
    free(quoted);

    quoted = prompt_quote(NBSP_PROMPT_PERCENT);
    CHECK(quoted && strcmp(quoted, "100%% $(x) `y` ! \\??") == 0);
    free(quoted);

    quoted = prompt_quote(NBSP_PROMPT_BANG);
    CHECK(quoted && strcmp(quoted, "100% $(x) `y` !! \\??") == 0);
    free(quoted);

    quoted = prompt_quote(
        NBSP_PROMPT_PERCENT | NBSP_PROMPT_SUBST | NBSP_PROMPT_BANG);
    CHECK(quoted && strncmp(quoted, "${(g::):-", 9U) == 0);
    CHECK(quoted && quoted[strlen(quoted) - 1U] == '}');
    CHECK(quoted && strstr(quoted, "$(x)") == NULL);
    CHECK(quoted && strchr(quoted, '`') == NULL);
    CHECK(quoted && strstr(quoted, "\\x25\\x25"));
    CHECK(quoted && strstr(quoted, "\\x21\\x21"));
    CHECK(quoted && strstr(quoted, "\\x3F\\x3F"));
    free(quoted);

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
        "# branch.oid 1234567890abcdef1234567890abcdef12345678\n"
        "# branch.head main\n"
        "# branch.upstream origin/main\n"
        "# branch.ab +2 -3\n"
        "# stash 4\n"
        "# Future-Header opaque value\n"
        "1 M. N... 100644 100644 100644 "
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa staged\n"
        "1 .M N... 100644 100644 100644 "
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa modified\n"
        "1 MM N... 100644 100644 100644 "
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa both\n"
        "u UU N... 100644 100644 100644 100644 "
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa conflict\n"
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

    const char *detached =
        "# branch.oid abcdef0123456789abcdef0123456789abcdef01\n"
        "# branch.head (detached)\n";
    CHECK(nbsp_git_parse_status(detached, &status));
    CHECK(status.valid && strcmp(status.branch, "abcdef01") == 0);

    const char *invalid[] = {
        "",
        "# branch.oid 1234567890abcdef1234567890abcdef12345678\n",
        "# branch.oid 1234567890abcdef1234567890abcdef12345678\n"
            "# branch.head main\n# branch.head other\n",
        "# branch.oid 1234567890abcdef1234567890abcdef12345678\n"
            "# branch.head main\n#unknown value\n",
        "# branch.oid 1234567890abcdef1234567890abcdef12345678\n"
            "# branch.head main\n# branch.ab +42949672960 -0\n",
        "# branch.oid 1234567890abcdef1234567890abcdef12345678\n"
            "# branch.head main\n# stash -1\n",
        "# branch.oid 1234567890abcdef1234567890abcdef12345678\n"
            "# branch.head main\n# stash 0\n",
        "# branch.oid 1234567890abcdef1234567890abcdef12345678\n"
            "# branch.head main\n1 M. N... 100644\n",
        "# branch.oid not-a-hex-object\n# branch.head (detached)\n",
        "# branch.oid 1234567890abcdef1234567890abcdef12345678\n"
            "# branch.head main\n\n? untracked\n",
        "# branch.oid 1234567890abcdef1234567890abcdef12345678\n"
            "# branch.head main",
    };
    for (size_t i = 0U; i < sizeof invalid / sizeof invalid[0]; ++i) {
        memset(&status, 0xa5, sizeof status);
        CHECK(!nbsp_git_parse_status(invalid[i], &status));
        CHECK(!status.valid);
    }

    char long_branch[512];
    const char *prefix =
        "# branch.oid 1234567890abcdef1234567890abcdef12345678\n"
        "# branch.head ";
    size_t prefix_len = strlen(prefix);
    memcpy(long_branch, prefix, prefix_len);
    memset(long_branch + prefix_len, 'a', sizeof status.branch);
    long_branch[prefix_len + sizeof status.branch] = '\n';
    long_branch[prefix_len + sizeof status.branch + 1U] = '\0';
    CHECK(!nbsp_git_parse_status(long_branch, &status));
}

static bool write_text_file(const char *path, const char *text) {
    FILE *file = fopen(path, "w");
    if (!file) return false;
    bool ok = fputs(text, file) >= 0;
    return fclose(file) == 0 && ok;
}

static void test_git_discovery(void) {
#ifdef __APPLE__
    char root_template[] = "/private/tmp/nbsp-git-unit-XXXXXX";
#else
    char root_template[] = "/tmp/nbsp-git-unit-XXXXXX";
#endif
    char *root = mkdtemp(root_template);
    CHECK(root != NULL);
    if (!root) return;

    char repo_path[512];
    char git_path[512];
    char head_path[512];
    char child_path[512];
    char linked_child[512];
    (void) snprintf(repo_path, sizeof repo_path, "%s/repo", root);
    (void) snprintf(git_path, sizeof git_path, "%s/.git", repo_path);
    (void) snprintf(head_path, sizeof head_path, "%s/HEAD", git_path);
    (void) snprintf(child_path, sizeof child_path, "%s/nested", repo_path);
    (void) snprintf(linked_child, sizeof linked_child, "%s/logical-nested", root);
    CHECK(mkdir(repo_path, 0700) == 0);
    CHECK(mkdir(git_path, 0700) == 0);
    CHECK(mkdir(child_path, 0700) == 0);
    CHECK(write_text_file(head_path, "ref: refs/heads/main\n"));
    CHECK(symlink(child_path, linked_child) == 0);

    struct nbsp_repo repo;
    CHECK(nbsp_git_discover(linked_child, &repo));
    char expected_root[NBSP_PATH_CAP];
    char expected_git[NBSP_PATH_CAP];
    CHECK(realpath(repo_path, expected_root) != NULL);
    CHECK(realpath(git_path, expected_git) != NULL);
    CHECK(strcmp(repo.root, expected_root) == 0);
    CHECK(strcmp(repo.git_dir, expected_git) == 0);
    char branch[sizeof ((struct nbsp_git_status *) 0)->branch];
    CHECK(nbsp_git_read_branch(&repo, branch, sizeof branch));
    CHECK(strcmp(branch, "main") == 0);

    char oversized_head[512] = "ref: refs/heads/";
    size_t head_prefix_len = strlen(oversized_head);
    memset(oversized_head + head_prefix_len, 'b', 256U);
    oversized_head[head_prefix_len + 256U] = '\n';
    oversized_head[head_prefix_len + 257U] = '\0';
    CHECK(write_text_file(head_path, oversized_head));
    CHECK(!nbsp_git_read_branch(&repo, branch, sizeof branch));
    CHECK(write_text_file(head_path,
        "abcdef0123456789abcdef0123456789abcdef01\n"));
    CHECK(nbsp_git_read_branch(&repo, branch, sizeof branch));
    CHECK(strcmp(branch, "abcdef01") == 0);
    CHECK(write_text_file(head_path, "abcdef0123456789\n"));
    CHECK(!nbsp_git_read_branch(&repo, branch, sizeof branch));

    char outer_path[512];
    char outer_git[512];
    char outer_head[512];
    char inner_path[512];
    char inner_git_file[512];
    (void) snprintf(outer_path, sizeof outer_path, "%s/outer", root);
    (void) snprintf(outer_git, sizeof outer_git, "%s/.git", outer_path);
    (void) snprintf(outer_head, sizeof outer_head, "%s/HEAD", outer_git);
    (void) snprintf(inner_path, sizeof inner_path, "%s/inner", outer_path);
    (void) snprintf(inner_git_file, sizeof inner_git_file, "%s/.git", inner_path);
    CHECK(mkdir(outer_path, 0700) == 0);
    CHECK(mkdir(outer_git, 0700) == 0);
    CHECK(mkdir(inner_path, 0700) == 0);
    CHECK(write_text_file(outer_head, "ref: refs/heads/outer\n"));
    CHECK(write_text_file(inner_git_file, "gitdir: \n"));
    CHECK(!nbsp_git_discover(inner_path, &repo));
    CHECK(unlink(inner_git_file) == 0);
    CHECK(rmdir(inner_path) == 0);
    CHECK(unlink(outer_head) == 0);
    CHECK(rmdir(outer_git) == 0);
    CHECK(rmdir(outer_path) == 0);

    CHECK(unlink(linked_child) == 0);
    CHECK(rmdir(child_path) == 0);
    CHECK(unlink(head_path) == 0);
    CHECK(rmdir(git_path) == 0);
    CHECK(rmdir(repo_path) == 0);
    CHECK(rmdir(root) == 0);
}

static void test_cache(void) {
    char *saved_cache = nbsp_strdup(getenv("NBSP_CACHE_DIR"));
    char *saved_xdg = nbsp_strdup(getenv("XDG_CACHE_HOME"));
    char *saved_home = nbsp_strdup(getenv("HOME"));
    char dir_template[] = "/tmp/nbsp-unit-XXXXXX";
    char *dir = mkdtemp(dir_template);
    CHECK(dir != NULL);
    if (!dir) goto restore;
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
    struct nbsp_git_status invalid = stored;
    invalid.updated_ms = 0U;
    CHECK(!nbsp_cache_store("/tmp/repo with spaces", &invalid));
    invalid = stored;
    memset(invalid.branch, 'x', sizeof invalid.branch);
    CHECK(!nbsp_cache_store("/tmp/repo with spaces", &invalid));
    invalid = stored;
    invalid.branch[0] = '\0';
    CHECK(!nbsp_cache_store("/tmp/repo with spaces", &invalid));
    invalid = stored;
    invalid.branch[0] = '\n';
    invalid.branch[1] = '\0';
    CHECK(!nbsp_cache_store("/tmp/repo with spaces", &invalid));
    CHECK(nbsp_cache_store("/tmp/repo with spaces", &stored));
    struct nbsp_git_status loaded;
    CHECK(nbsp_cache_load("/tmp/repo with spaces", &loaded));
    CHECK(strcmp(loaded.branch, stored.branch) == 0);
    CHECK(loaded.staged == 1U && loaded.stashes == 7U);
    CHECK(!nbsp_cache_load("/tmp/a different repo", &loaded));

    char git_dir[512] = {0};
    bool git_dir_ready = nbsp_cache_git_dir(git_dir, sizeof git_dir, false);
    CHECK(git_dir_ready);
    if (!git_dir_ready) goto restore;
    char cache_path[768];
    (void) snprintf(cache_path, sizeof cache_path, "%s/%016" PRIx64 ".cache",
        git_dir,
        nbsp_hash_path("/tmp/repo with spaces"));

    FILE *stored_file = fopen(cache_path, "r");
    CHECK(stored_file != NULL);
    if (stored_file) {
        char first_line[32];
        CHECK(fgets(first_line, sizeof first_line, stored_file) != NULL);
        CHECK(strcmp(first_line, "version=2\n") == 0);
        CHECK(fclose(stored_file) == 0);
    }

    char lock_path[768];
    (void) snprintf(lock_path, sizeof lock_path, "%s/%016" PRIx64 ".lock",
        git_dir,
        nbsp_hash_path("/tmp/repo with spaces"));
    int first_lock = nbsp_cache_lock("/tmp/repo with spaces");
    CHECK(first_lock >= 0);
    pid_t child = fork();
    CHECK(child >= 0);
    if (child == 0) {
        int child_lock = nbsp_cache_lock("/tmp/repo with spaces");
        if (child_lock >= 0) nbsp_cache_unlock(child_lock);
        _exit(child_lock == NBSP_CACHE_LOCK_BUSY ? 0 : 1);
    } else if (child > 0) {
        int child_status = 0;
        CHECK(waitpid(child, &child_status, 0) == child);
        CHECK(WIFEXITED(child_status) && WEXITSTATUS(child_status) == 0);
    }
    nbsp_cache_unlock(first_lock);
    CHECK(access(lock_path, F_OK) == 0);
    int next_lock = nbsp_cache_lock("/tmp/repo with spaces");
    CHECK(next_lock >= 0);
    nbsp_cache_unlock(next_lock);

    CHECK(write_cache_fixture(cache_path, "1", "percent%25branch", NULL));
    CHECK(!nbsp_cache_load("/tmp/repo with spaces", &loaded));

    CHECK(write_cache_fixture(cache_path,
        "2", "percent%25branch", "future_field=opaque%3Dvalue\n"));
    CHECK(nbsp_cache_load("/tmp/repo with spaces", &loaded));

    CHECK(write_cache_fixture(cache_path,
        "2", "percent%25branch", "future_field=bad%\n"));
    CHECK(!nbsp_cache_load("/tmp/repo with spaces", &loaded));

    CHECK(write_cache_fixture(cache_path,
        "2", "percent%25branch", "future_field=raw=value\n"));
    CHECK(!nbsp_cache_load("/tmp/repo with spaces", &loaded));

    CHECK(write_cache_fixture(cache_path, "2", "", NULL));
    CHECK(!nbsp_cache_load("/tmp/repo with spaces", &loaded));

    CHECK(write_cache_fixture(cache_path, "2", "%0A", NULL));
    CHECK(!nbsp_cache_load("/tmp/repo with spaces", &loaded));

    CHECK(write_cache_fixture(cache_path,
        "2", "percent%25branch", "staged=9\n"));
    CHECK(!nbsp_cache_load("/tmp/repo with spaces", &loaded));

    CHECK(write_cache_fixture(cache_path,
        "2", "percent%25branch", "malformed-line\n"));
    CHECK(!nbsp_cache_load("/tmp/repo with spaces", &loaded));

    CHECK(write_cache_fixture(cache_path, "2", "percent%25branch", NULL));
    FILE *binary = fopen(cache_path, "a");
    CHECK(binary != NULL);
    if (binary) {
        CHECK(fputc('\0', binary) == 0);
        CHECK(fputs("future_field=hidden\n", binary) >= 0);
        CHECK(fclose(binary) == 0);
    }
    CHECK(!nbsp_cache_load("/tmp/repo with spaces", &loaded));

    FILE *missing = fopen(cache_path, "w");
    CHECK(missing != NULL);
    if (missing) {
        CHECK(fputs(
            "version=2\n"
            "repo=/tmp/repo%20with%20spaces\n"
            "updated_ms=123456\n"
            "branch=percent%25branch\n"
            "staged=1\n"
            "modified=2\n"
            "untracked=3\n"
            "conflicted=4\n"
            "ahead=5\n"
            "behind=6\n",
            missing) >= 0);
        CHECK(fclose(missing) == 0);
    }
    CHECK(!nbsp_cache_load("/tmp/repo with spaces", &loaded));

    FILE *corrupt = fopen(cache_path, "w");
    CHECK(corrupt != NULL);
    if (corrupt) {
        CHECK(fseek(corrupt, 17000L, SEEK_SET) == 0);
        CHECK(fputc('x', corrupt) == 'x');
        CHECK(fclose(corrupt) == 0);
    }
    CHECK(!nbsp_cache_load("/tmp/repo with spaces", &loaded));
    CHECK(nbsp_cache_store("/tmp/repo with spaces", &stored));

    CHECK(chmod(cache_path, 0644) == 0);
    CHECK(!nbsp_cache_load("/tmp/repo with spaces", &loaded));
    CHECK(!nbsp_cache_store("/tmp/repo with spaces", &stored));
    CHECK(chmod(cache_path, 0600) == 0);

    char backup_path[768];
    (void) snprintf(backup_path, sizeof backup_path, "%s.backup", cache_path);
    CHECK(rename(cache_path, backup_path) == 0);
    CHECK(symlink(backup_path, cache_path) == 0);
    CHECK(!nbsp_cache_load("/tmp/repo with spaces", &loaded));
    CHECK(!nbsp_cache_store("/tmp/repo with spaces", &stored));
    CHECK(unlink(cache_path) == 0);
    CHECK(rename(backup_path, cache_path) == 0);

    char unsafe_path[768];
    (void) snprintf(unsafe_path, sizeof unsafe_path, "%s/0123456789abcdef.cache", git_dir);
    CHECK(symlink(cache_path, unsafe_path) == 0);
    errno = 0;
    CHECK(nbsp_cache_clear() == -1);
    CHECK(errno == EPERM);
    struct stat unsafe_info;
    CHECK(lstat(unsafe_path, &unsafe_info) == 0 && S_ISLNK(unsafe_info.st_mode));
    CHECK(access(cache_path, F_OK) != 0);
    CHECK(access(lock_path, F_OK) == 0);
    CHECK(unlink(unsafe_path) == 0);
    CHECK(nbsp_cache_clear() == 0);
    CHECK(unlink(lock_path) == 0);
    CHECK(rmdir(git_dir) == 0);

    CHECK(chmod(dir, 0755) == 0);
    CHECK(!nbsp_cache_git_dir(git_dir, sizeof git_dir, true));
    CHECK(chmod(dir, 0700) == 0);

    char real_root[512];
    char linked_root[512];
    (void) snprintf(real_root, sizeof real_root, "%s/real-cache", dir);
    (void) snprintf(linked_root, sizeof linked_root, "%s/linked-cache", dir);
    CHECK(mkdir(real_root, 0700) == 0);
    CHECK(symlink(real_root, linked_root) == 0);
    CHECK(setenv("NBSP_CACHE_DIR", linked_root, 1) == 0);
    CHECK(!nbsp_cache_git_dir(git_dir, sizeof git_dir, true));
    CHECK(unlink(linked_root) == 0);
    CHECK(rmdir(real_root) == 0);

    char real_parent[512];
    char linked_parent[512];
    char nested_root[512];
    (void) snprintf(real_parent, sizeof real_parent, "%s/real-parent", dir);
    (void) snprintf(linked_parent, sizeof linked_parent, "%s/linked-parent", dir);
    (void) snprintf(nested_root, sizeof nested_root, "%s/cache", linked_parent);
    CHECK(mkdir(real_parent, 0700) == 0);
    CHECK(symlink(real_parent, linked_parent) == 0);
    CHECK(setenv("NBSP_CACHE_DIR", nested_root, 1) == 0);
    CHECK(!nbsp_cache_git_dir(git_dir, sizeof git_dir, true));
    CHECK(unlink(linked_parent) == 0);
    CHECK(rmdir(real_parent) == 0);

    CHECK(setenv("NBSP_CACHE_DIR", "relative/cache", 1) == 0);
    CHECK(!nbsp_cache_git_dir(git_dir, sizeof git_dir, true));

    CHECK(unsetenv("NBSP_CACHE_DIR") == 0);
    CHECK(unsetenv("XDG_CACHE_HOME") == 0);
    CHECK(unsetenv("HOME") == 0);
    CHECK(!nbsp_cache_git_dir(git_dir, sizeof git_dir, true));

    char xdg[512];
    (void) snprintf(xdg, sizeof xdg, "%s/xdg", dir);
    CHECK(mkdir(xdg, 0700) == 0);
    CHECK(setenv("XDG_CACHE_HOME", xdg, 1) == 0);
    CHECK(nbsp_cache_git_dir(git_dir, sizeof git_dir, true));
    char expected[768];
    char canonical_xdg[512];
    CHECK(realpath(xdg, canonical_xdg) != NULL);
    (void) snprintf(expected, sizeof expected, "%s/nbsp/git", canonical_xdg);
    CHECK(strcmp(git_dir, expected) == 0);
    CHECK(rmdir(git_dir) == 0);
    (void) snprintf(expected, sizeof expected, "%s/nbsp", xdg);
    CHECK(rmdir(expected) == 0);
    CHECK(rmdir(xdg) == 0);

    char fake_home[512];
    (void) snprintf(fake_home, sizeof fake_home, "%s/home", dir);
    CHECK(mkdir(fake_home, 0700) == 0);
    CHECK(setenv("XDG_CACHE_HOME", "relative/cache", 1) == 0);
    CHECK(setenv("HOME", fake_home, 1) == 0);
    CHECK(nbsp_cache_git_dir(git_dir, sizeof git_dir, true));
    char canonical_home[512];
    CHECK(realpath(fake_home, canonical_home) != NULL);
    (void) snprintf(expected, sizeof expected,
        "%s/Library/Caches/nbsp/git", canonical_home);
    CHECK(strcmp(git_dir, expected) == 0);
    CHECK(rmdir(git_dir) == 0);
    (void) snprintf(expected, sizeof expected, "%s/Library/Caches/nbsp", fake_home);
    CHECK(rmdir(expected) == 0);
    (void) snprintf(expected, sizeof expected, "%s/Library/Caches", fake_home);
    CHECK(rmdir(expected) == 0);
    (void) snprintf(expected, sizeof expected, "%s/Library", fake_home);
    CHECK(rmdir(expected) == 0);
    CHECK(rmdir(fake_home) == 0);
    CHECK(rmdir(dir) == 0);

restore:
    restore_environment("NBSP_CACHE_DIR", saved_cache);
    restore_environment("XDG_CACHE_HOME", saved_xdg);
    restore_environment("HOME", saved_home);
    free(saved_cache);
    free(saved_xdg);
    free(saved_home);
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
}

static void test_prompt(void) {
    CHECK(setenv("HOME", "/Users/test", 1) == 0);
    CHECK(setenv("NVM_BIN", "/Users/test/.nvm/versions/node/v20.1.0/bin", 1) == 0);
    char *prompt = nbsp_prompt_render(
        "/Users/test/code/app", 1, 2450UL, 2U, NBSP_PROMPT_PERCENT);
    CHECK(prompt != NULL);
    CHECK(prompt && strstr(prompt, "%F{default}/U/t/c/app%f"));
    CHECK(prompt && strstr(prompt, "[node:20.1.0]"));
    CHECK(prompt && strstr(prompt, "[2.5s]"));
    CHECK(prompt && strstr(prompt, "[jobs:2]"));
    CHECK(prompt && strstr(prompt, "%F{red}e1%#%f"));
    free(prompt);

    CHECK(unsetenv("NVM_BIN") == 0);
    prompt = nbsp_prompt_render(
        "/Users/test/code/app", 0, 0UL, 0U, NBSP_PROMPT_PERCENT);
    CHECK(prompt && strstr(prompt, " %# "));
    CHECK(prompt && !strstr(prompt, "e0%#"));
    CHECK(prompt && !strstr(prompt, "%F{green}"));
    free(prompt);

    prompt = nbsp_prompt_render(
        "/tmp/100%$(touch${IFS}$NBSP_MARKER)`echo`!",
        1,
        0UL,
        0U,
        NBSP_PROMPT_PERCENT | NBSP_PROMPT_SUBST | NBSP_PROMPT_BANG);
    CHECK(prompt && strstr(prompt, "${(g::):-"));
    CHECK(prompt && strstr(prompt, "\\x25\\x25"));
    CHECK(prompt && strstr(prompt, "$(touch") == NULL);
    CHECK(prompt && strchr(prompt, '`') == NULL);
    free(prompt);

    prompt = nbsp_prompt_render("/tmp/100%", 1, 0UL, 0U, 0U);
    CHECK(prompt && strstr(prompt, "100%"));
    CHECK(prompt && !strstr(prompt, "%F{"));
    CHECK(prompt && !strstr(prompt, "%#"));
    free(prompt);
}

static void test_data_output(void) {
    struct nbsp_prompt_data data = {
        .cwd = "/tmp/project with space%",
        .path = "/t/project with space%",
        .status = 7,
        .duration_ms = 2450UL,
        .jobs = 2U,
        .node_version = "22.14.0",
        .git_present = true,
        .git_valid = true,
        .git_branch = "feature/100%",
        .git_updated_ms = 123456U,
        .git_staged = 1U,
        .git_modified = 2U,
        .git_untracked = 3U,
        .git_conflicted = 4U,
        .git_ahead = 5U,
        .git_behind = 6U,
        .git_stashes = 7U,
    };

    FILE *stream = tmpfile();
    CHECK(stream != NULL);
    if (stream) {
        CHECK(nbsp_data_write(stream, &data, NBSP_DATA_LINES));
        CHECK(fflush(stream) == 0);
        CHECK(fseek(stream, 0L, SEEK_SET) == 0);
        char output[2048];
        size_t length = fread(output, 1U, sizeof output - 1U, stream);
        output[length] = '\0';
        CHECK(strstr(output, "schema_version=1\n") == output);
        CHECK(strstr(output, "cwd=/tmp/project%20with%20space%25\n"));
        CHECK(strstr(output, "git_branch=feature/100%25\n"));
        CHECK(strstr(output, "git_stashes=7\n"));
        CHECK(fclose(stream) == 0);
    }

    stream = tmpfile();
    CHECK(stream != NULL);
    if (stream) {
        CHECK(nbsp_data_write(stream, &data, NBSP_DATA_NUL));
        CHECK(fflush(stream) == 0);
        CHECK(fseek(stream, 0L, SEEK_SET) == 0);
        unsigned char output[2048];
        size_t length = fread(output, 1U, sizeof output, stream);
        unsigned separators = 0U;
        for (size_t i = 0U; i < length; ++i) {
            if (output[i] == '\0') ++separators;
        }
        CHECK(separators == 36U);
        CHECK(fclose(stream) == 0);
    }
}

static bool nul_output_has_pair(const unsigned char *output,
    size_t length,
    const char *wanted_key,
    const char *wanted_value) {
    size_t offset = 0U;
    while (offset < length) {
        const char *key = (const char *) output + offset;
        size_t key_len = strnlen(key, length - offset);
        if (key_len == length - offset) return false;
        offset += key_len + 1U;
        if (offset >= length) return false;
        const char *value = (const char *) output + offset;
        size_t value_len = strnlen(value, length - offset);
        if (value_len == length - offset) return false;
        offset += value_len + 1U;
        if (strcmp(key, wanted_key) == 0 && strcmp(value, wanted_value) == 0) {
            return true;
        }
    }
    return false;
}

static void test_dirs_output(void) {
    char root[128];
    char alpha[160];
    char spaced[160];
    char link[160];
    char broken_link[160];
    char regular[160];
    (void) snprintf(root, sizeof root, "/tmp/nbsp-dirs-unit-%ld", (long) getpid());
    (void) snprintf(alpha, sizeof alpha, "%s/alpha", root);
    (void) snprintf(spaced, sizeof spaced, "%s/space dir", root);
    (void) snprintf(link, sizeof link, "%s/linked", root);
    (void) snprintf(broken_link, sizeof broken_link, "%s/broken", root);
    (void) snprintf(regular, sizeof regular, "%s/regular", root);
    CHECK(mkdir(root, 0700) == 0);
    CHECK(mkdir(alpha, 0700) == 0);
    CHECK(mkdir(spaced, 0700) == 0);
    CHECK(symlink("alpha", link) == 0);
    CHECK(symlink("missing-target", broken_link) == 0);
    FILE *file = fopen(regular, "w");
    CHECK(file != NULL);
    if (file) CHECK(fclose(file) == 0);

    FILE *stream = tmpfile();
    CHECK(stream != NULL);
    if (stream) {
        CHECK(nbsp_dirs_write(stream, root));
        CHECK(fflush(stream) == 0);
        CHECK(fseek(stream, 0L, SEEK_SET) == 0);
        unsigned char output[4096];
        size_t length = fread(output, 1U, sizeof output, stream);
        CHECK(nul_output_has_pair(output, length, "schema_version", "1"));
        CHECK(nul_output_has_pair(output, length, "dir", "alpha"));
        CHECK(nul_output_has_pair(output, length, "dir", "space dir"));
        CHECK(nul_output_has_pair(output, length, "dir", "linked"));
        CHECK(!nul_output_has_pair(output, length, "dir", "broken"));
        CHECK(!nul_output_has_pair(output, length, "dir", "regular"));
        CHECK(nul_output_has_pair(output, length, "complete", "1"));
        CHECK(fclose(stream) == 0);
    }

    CHECK(unlink(regular) == 0);
    CHECK(unlink(broken_link) == 0);
    CHECK(unlink(link) == 0);
    CHECK(rmdir(spaced) == 0);
    CHECK(rmdir(alpha) == 0);
    CHECK(rmdir(root) == 0);
}

int main(void) {
    test_paths();
    test_escape_and_nvm();
    test_status_parser();
    test_git_discovery();
    test_cache();
    test_prompt();
    test_data_output();
    test_dirs_output();
    test_buffer_growth();
    if (failures) {
        fprintf(stderr, "%d unit check(s) failed\n", failures);
        return 1;
    }
    return 0;
}
