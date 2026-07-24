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
  args: [files('test_cli.sh'), nbsp_exe, zsh_init_source],
  timeout: 30,
)

zsh = find_program('zsh')
test(
  'zsh-syntax',
  zsh,
  args: ['-n', zsh_init_source],
)

expect = find_program('expect')
test(
  'zsh-integration',
  expect,
  args: [files('test_zsh_integration.exp'), nbsp_exe],
  timeout: 30,
)

if get_option('fuzzing')
  fuzz_flags = ['-fsanitize=address,undefined', '-fno-omit-frame-pointer']
  fuzz_parsers = executable(
    'fuzz-parsers',
    ['fuzz_parsers.c'] + core_sources,
    include_directories: src_inc,
    c_args: fuzz_flags,
    link_args: fuzz_flags + dead_strip_args,
  )
endif
