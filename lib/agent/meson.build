need_universal_agent = host_os_family == 'darwin' \
    and assets_mode == 'installed' \
    and agent_compat != ''

# When compat provides the host-arch agent (e.g. when use_apple_tls is on, so
# the agent has to be built separately to avoid pulling in Apple frameworks),
# skip building it here.
build_agent = agent_host_compat == ''

if build_agent
  agent_sources = [
    'agent.vala',
    'agent-glue.c',
  ]

  force_cpp_linking = have_v8
  if force_cpp_linking
    agent_sources += ['dummy.cpp']
  endif

  extra_vala_args = []
  extra_link_args = []
  extra_link_depends = []

  if host_os_family != 'windows'
    extra_vala_args += '--pkg=posix'
  endif
  if host_os_family == 'darwin'
    extra_vala_args += '--pkg=frida-gum-darwin-1.0'
  endif

  if host_os_family == 'windows'
    if host_toolchain != 'microsoft'
      symfile = (host_arch == 'x86') ? 'xda-core-x86.symbols' : 'xda-core.symbols'
      extra_link_args += '-Wl,--retain-symbols-file,' + meson.current_source_dir() / symfile
      extra_link_depends += symfile
    endif
  elif host_os_family == 'darwin'
    extra_link_args += '-Wl,-exported_symbol,_xda_core_main'
  else
    if libc == 'glibc'
      symscript = 'xda-core-glibc.version'
    elif host_os == 'android'
      symscript = 'xda-core-android.version'
    else
      symscript = 'xda-core.version'
    endif
    extra_link_args += '-Wl,--version-script,' + meson.current_source_dir() / symscript
    extra_link_depends += symscript
  endif

  if host_os_family in ['linux', 'qnx']
    # For our libc shim to be effective.
    extra_link_args += '-Wl,-Bsymbolic'
  endif

  raw_agent = shared_library('xda-core-raw', agent_sources,
    name_prefix: 'lib',
    c_args: frida_component_cflags,
    vala_header: 'xda-core.h',
    vala_args: [base_vala_args, payload_vala_args, extra_vala_args],
    link_args: extra_link_args,
    link_depends: extra_link_depends,
    vs_module_defs: 'xda-core.def',
    override_options: ['b_asneeded=true'],
    dependencies: [gio_dep, gee_dep, gum_dep, gumjs_dep, base_dep, pipe_dep, tls_provider_dep, payload_dep],
  )

  operations = ['--move', 'constructor', 'frida_libc_shim_init', 'first']
  if host_os_family != 'darwin'
    operations += ['--move', 'destructor', 'frida_libc_shim_deinit', 'first']
  endif
  modulated_agent = custom_target('xda-core-modulated',
    input: raw_agent,
    output: 'libxda-core-modulated' + shlib_suffix,
    command: modulate + operations,
  )

  if host_os_family == 'darwin'
    identity = 'FridaAgent'
  else
    identity = agent_name
  endif
  agent = custom_target('xda-core',
    input: modulated_agent,
    output: need_universal_agent ? f'@agent_name@-@host_abi@' : agent_name,
    command: post_process + ['shared-library', identity],
    build_by_default: true,
    install: assets_mode == 'installed' and not need_universal_agent,
    install_dir: asset_dir,
  )

  agent_dep = declare_dependency(link_with: agent)
endif

if need_universal_agent
  if build_agent
    custom_target('xda-core-universal',
      input: agent,
      output: agent_name,
      command: [
        lipo,
        '@INPUT@',
        agent_compat,
        '-create',
        '-output', meson.current_build_dir() / agent_name,
      ],
      depends: agent_depends,
      install: true,
      install_dir: asset_dir,
    )
  else
    custom_target('xda-core-universal',
      output: agent_name,
      command: [
        lipo,
        agent_host_compat,
        agent_compat,
        '-create',
        '-output', meson.current_build_dir() / agent_name,
      ],
      depends: agent_depends,
      install: true,
      install_dir: asset_dir,
    )
  endif
endif
