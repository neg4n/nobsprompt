unit_test = executable(
  'test-unit',
  'test_unit.c',
  dependencies: core_dep,
)

test('unit', unit_test)

sh = find_program('sh')
test(
  'cli',
  sh,
  args: [
    files('test_cli.sh'),
    nbsp_exe,
    zsh_init_source,
    zsh_opinionated_source,
    zsh_autosuggest_source,
  ],
  timeout: 30,
)

zsh_tests = get_option('zsh_tests')
zsh = find_program('zsh')
expect = find_program('expect', required: zsh_tests)

test(
  'zsh-syntax',
  zsh,
  args: ['-n', zsh_init_source],
)
test(
  'zsh-autosuggest-syntax',
  zsh,
  args: ['-n', zsh_autosuggest_source],
)
test(
  'zsh-data-protocol',
  zsh,
  args: ['-f', files('test_zsh_data.zsh'), nbsp_exe, zsh_init_source],
  timeout: 30,
)
test(
  'zsh-option-isolation',
  zsh,
  args: ['-f', files('test_zsh_options.zsh'), zsh_init_source],
  timeout: 30,
)
test(
  'zsh-quote-parity',
  zsh,
  args: ['-f', files('test_zsh_quote_parity.zsh'), nbsp_exe],
  timeout: 30,
)

if expect.found()
  test(
    'zsh-integration',
    expect,
    args: [files('test_zsh_integration.exp'), nbsp_exe],
    timeout: 90,
  )
  test(
    'zsh-detached',
    expect,
    args: [files('test_zsh_detached.exp'), nbsp_exe],
    timeout: 30,
  )
  test(
    'zsh-autosuggest',
    expect,
    args: [files('test_zsh_autosuggest.exp'), nbsp_exe],
    timeout: 30,
  )
  test(
    'zsh-autosuggest-no-memo',
    expect,
    args: [files('test_zsh_autosuggest.exp'), nbsp_exe, '--no-memo'],
    timeout: 30,
  )
endif

if get_option('fuzzing')
  fuzz_flags = ['-fsanitize=address,undefined', '-fno-omit-frame-pointer']
  fuzz_parsers = executable(
    'fuzz-parsers',
    'fuzz_parsers.c',
    dependencies: core_dep,
    c_args: fuzz_flags,
    link_args: fuzz_flags + dead_strip_args,
  )
endif

executable(
  'asan-runtime-probe',
  'asan_runtime_probe.c',
  build_by_default: false,
)
