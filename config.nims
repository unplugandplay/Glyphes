## Project-local compiler pin — the "wrong slice" fix, same one as
## ../nimaps/config.nims (nimaps DEVLOG §"the wrong slice incident").
##
## Apple clang is a universal binary. When the process tree runs under
## Rosetta the driver defaults to the x86_64 target, so an arm64 build
## produces an x86_64 lib/libglyphes.so and Ruby's dlopen refuses it:
##
##   FFI::DynamicLibrary ... mach-o file, but is an incompatible
##   architecture (have 'x86_64', need 'arm64')
##
## and pre-pin caches also fail with "Undefined symbols for architecture
## x86_64". Both are the slice, not a missing flag. Naming the target
## explicitly makes the build correct from either slice.
when defined(macosx) and hostCPU == "arm64":
  switch("passC", "-arch arm64")
  switch("passL", "-arch arm64")