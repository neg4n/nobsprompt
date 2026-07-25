project('nobsprompt', 'c',
  version: '0.1.0',
  meson_version: '>=1.1.0',
  default_options: [
    'c_std=c11',
    'warning_level=3',
  ],
)

cc = meson.get_compiler('c')

warn_args = cc.get_supported_arguments([
  '-Wpedantic',
  '-Werror=implicit-function-declaration',
  '-Wshadow',
  '-Wconversion',
  '-Wstrict-prototypes',
  '-fvisibility=hidden',
])

dead_strip_args = cc.get_supported_link_arguments(['-Wl,-dead_strip'])

add_project_arguments(
  warn_args + [
    '-D_POSIX_C_SOURCE=200809L',
    '-D_DARWIN_C_SOURCE',
    '-DNBSP_VERSION="@0@"'.format(meson.project_version()),
  ],
  language: 'c',
)

src_inc = include_directories('src')

python3 = find_program('python3')
zsh_init_source = files('src/nbsp_zsh.zsh')
zsh_generated_source = custom_target(
  'nbsp-zsh-source',
  input: ['tools/embed_zsh.py', 'src/nbsp_zsh.zsh'],
  output: 'nbsp_zsh.c',
  command: [python3, '@INPUT0@', '@INPUT1@', '@OUTPUT@'],
)

core_sources = files(
  'src/nbsp_util.c',
  'src/nbsp_cache.c',
  'src/nbsp_data.c',
  'src/nbsp_git.c',
  'src/nbsp_prompt.c',
) + [zsh_generated_source]

core_lib = static_library(
  'nbsp-core',
  core_sources,
  include_directories: src_inc,
)

core_dep = declare_dependency(
  link_with: core_lib,
  include_directories: src_inc,
)

nbsp_exe = executable(
  'nbsp',
  'src/main.c',
  dependencies: core_dep,
  link_args: dead_strip_args,
  install: true,
)

install_man('doc/nbsp.1')
install_data(
  'docs/index.mdx',
  install_dir: join_paths(get_option('datadir'), 'doc', 'nobsprompt'),
)
install_data(
  'docs/get-started/index.mdx',
  'docs/get-started/opinionated-prompt.mdx',
  install_dir: join_paths(get_option('datadir'), 'doc', 'nobsprompt', 'get-started'),
)
install_data(
  'docs/detached-mode/index.mdx',
  'docs/detached-mode/data-lifecycle.mdx',
  'docs/detached-mode/recipes.mdx',
  install_dir: join_paths(get_option('datadir'), 'doc', 'nobsprompt', 'detached-mode'),
)
install_data(
  'docs/internals/index.mdx',
  'docs/internals/performance.mdx',
  install_dir: join_paths(get_option('datadir'), 'doc', 'nobsprompt', 'internals'),
)
install_data(
  'docs/reference/cli.mdx',
  'docs/reference/data-protocol.mdx',
  'docs/reference/configuration.mdx',
  'docs/reference/external-editor.mdx',
  install_dir: join_paths(get_option('datadir'), 'doc', 'nobsprompt', 'reference'),
)

subdir('tests')
