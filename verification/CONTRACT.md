# Rewrite acceptance contract

Authority: README.md, doc/nbsp.1, and every page under docs/. Functional descriptions take precedence over the reference implementation. Implementation/build descriptions change with the port; behavior does not.

Reference: main at 56db8ce9cce0ea50345d66288c76dfca30f67f47, Meson release, optimization=3, LTO, native Apple Silicon. The unchanged reference binary remains in ignored build-zig-reference/.

| Documented contract | Claim source | Zig owner | Acceptance evidence |
| --- | --- | --- | --- |
| CLI commands, ranges, init modes, statuses | [reference/cli](../docs/reference/cli.mdx) | [main](../src/main.zig) | [test_cli.sh](../tests/test_cli.sh); [differential.sh](../tests/differential.sh) |
| Physical cwd; no Git/Node foreground spawn; native discovery and HEAD; NVM byte domain | [internals/performance](../docs/internals/performance.mdx) | [snapshot](../src/snapshot.zig), [git](../src/git.zig), [util](../src/util.zig) | [unit tests](../src/tests.zig); [test_cli.sh](../tests/test_cli.sh); [differential.sh](../tests/differential.sh) |
| Schema 2: 18 fields, lines percent codec, raw NUL, complete producer status | [reference/data-protocol](../docs/reference/data-protocol.mdx) | [snapshot](../src/snapshot.zig), [util](../src/util.zig); unchanged Zsh loader | [test_zsh_data.zsh](../tests/test_zsh_data.zsh); [test_cli.sh](../tests/test_cli.sh); [unit tests](../src/tests.zig) |
| Detached PROMPT/RPROMPT ownership; callbacks on every complete successful frame only | [detached-mode/data-lifecycle](../docs/detached-mode/data-lifecycle.mdx) | [nbsp_zsh.zsh](../src/nbsp_zsh.zsh) | [test_zsh_detached.exp](../tests/test_zsh_detached.exp); [test_zsh_data.zsh](../tests/test_zsh_data.zsh) |
| Fixed opinionated rendering; 2-second threshold; markers, exact status | [get-started/opinionated-prompt](../docs/get-started/opinionated-prompt.mdx) | [nbsp_opinionated.zsh](../src/nbsp_opinionated.zsh) | [test_cli.sh](../tests/test_cli.sh); [test_zsh_integration.exp](../tests/test_zsh_integration.exp) |
| Percent/subst/bang escaping and option isolation | [detached-mode/data-lifecycle](../docs/detached-mode/data-lifecycle.mdx) | [nbsp_zsh.zsh](../src/nbsp_zsh.zsh) | [test_zsh_options.zsh](../tests/test_zsh_options.zsh); [test_zsh_quote_parity.zsh](../tests/test_zsh_quote_parity.zsh); PTY integration |
| Editor precedence, private widget, undefined-only Alt+E, multiline/Vim cursor | [reference/external-editor](../docs/reference/external-editor.mdx) | [nbsp_zsh.zsh](../src/nbsp_zsh.zsh) | [test_zsh_integration.exp](../tests/test_zsh_integration.exp) |
| History bounds, redraw eligibility, ownership, early/late conflicts | [reference/autosuggestions](../docs/reference/autosuggestions.mdx) | [nbsp_autosuggest.zsh](../src/nbsp_autosuggest.zsh) | [test_zsh_autosuggest.exp](../tests/test_zsh_autosuggest.exp) (memo and no-memo) |
| Static cd operands, quote removal, CDPATH/POSIX_CD, snapshot-gated candidates | [reference/autosuggestions](../docs/reference/autosuggestions.mdx) | [nbsp_autosuggest.zsh](../src/nbsp_autosuggest.zsh) | [test_zsh_autosuggest.exp](../tests/test_zsh_autosuggest.exp) |
| Directory schema 1, sorted byte names and symlinks; 50ms/1024/64KiB | [reference/autosuggestions](../docs/reference/autosuggestions.mdx) | [dirs](../src/dirs.zig), [darwin](../src/darwin.zig) | [unit tests](../src/tests.zig); [test_cli.sh](../tests/test_cli.sh); PTY autosuggestions |
| Git argument vector, selector environment, record semantics and cap | [internals](../docs/internals/index.mdx) | [git](../src/git.zig) | [parser tests](../src/tests.zig); [test_cli.sh](../tests/test_cli.sh); [mutation tests](../src/fuzz.zig) |
| Process group, timeout even after EOF, closed stdio, descendants, reap | [internals](../docs/internals/index.mdx) | [git](../src/git.zig) | [test_cli.sh](../tests/test_cli.sh); [test_process.sh](../tests/test_process.sh) |
| Branch match before publication and foreground counters; fallback label | [detached-mode/data-lifecycle](../docs/detached-mode/data-lifecycle.mdx) | [git](../src/git.zig), [snapshot](../src/snapshot.zig), [cache](../src/cache.zig) | [test_cli.sh](../tests/test_cli.sh); [unit tests](../src/tests.zig); [differential.sh](../tests/differential.sh) |
| 250ms debounce before/after lock; force affects only debounce; notifications | [reference/cli](../docs/reference/cli.mdx) | [refresh](../src/refresh.zig) | [test_cli.sh](../tests/test_cli.sh); [test_process.sh](../tests/test_process.sh) |
| Cache precedence, fail closed, exact Darwin aliases, nofollow traversal | [reference/configuration](../docs/reference/configuration.mdx) | [cache](../src/cache.zig) | cache [unit tests](../src/tests.zig); [test_cli.sh](../tests/test_cli.sh); [differential.sh](../tests/differential.sh) |
| 0700 directories; 0600 owned single-link files; fcntl persistent locks | [internals](../docs/internals/index.mdx) | [cache](../src/cache.zig) | cache [unit tests](../src/tests.zig); lock [unit tests](../src/tests.zig); [test_process.sh](../tests/test_process.sh) |
| Cache v2/hash/encoding, bounded full read plus EOF, reject bad fields | [internals](../docs/internals/index.mdx) | [cache](../src/cache.zig), [util](../src/util.zig) | [parser tests](../src/tests.zig); [mutation tests](../src/fuzz.zig); cross-language [differential.sh](../tests/differential.sh) |
| Temp fsync + atomic rename, no directory durability guarantee | [internals](../docs/internals/index.mdx) | [cache](../src/cache.zig) | [write-failure unit test](../src/tests.zig); source review |
| Clear snapshots names before deletion; preserve lock inode | [reference/cli](../docs/reference/cli.mdx) | [cache](../src/cache.zig) | cache [unit tests](../src/tests.zig); lock [unit tests](../src/tests.zig); [test_process.sh](../tests/test_process.sh) |
| Build/install and exact canonical template; all docs examples | [get-started](../docs/get-started/index.mdx) | [build.zig](../build.zig) | zig build test; staged install checks; docs:ci |
| Performance, size, and memory with raw provenance | [internals/performance](../docs/internals/performance.mdx) | [benchmark.zsh](../bench/benchmark.zsh), verification | repeated C/Zig reports; acceptance report |

No functional exception has been approved. macOS 13+ and Zig 0.16.0 are the explicitly selected platform/toolchain requirements. Native Intel runtime and performance evidence is required before promotion; cross-compilation is insufficient.

Binary size is informational at the user’s request. The latency (5%) and peak process memory (10%) gates remain.

Two defects in the original verification tools were corrected before comparing
implementations: the benchmark helper overwrote Zsh’s special `path` variable,
and a PTY expectation could match a sentinel in echoed command text before its
output arrived. The fixed PTY case also passes against the frozen C binary.
