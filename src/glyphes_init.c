/* glyphes - load-time initialization.
 *
 * Nim's `--app:lib` emits module initialization into an exported
 * `NimMain`, and nothing calls it. Global `seq`s, string literals and
 * the ORC allocator's page cache are all set up there, so a dylib that
 * skips it segfaults inside its own allocator on the first allocation --
 * at an address near null, with no Nim-level backtrace, inside the host
 * process.
 *
 * This file attaches a C constructor so dlopen does it for us. The Ruby
 * binding also calls NimMain explicitly as a belt-and-braces path for
 * platforms where the constructor does not fire, but the constructor is
 * what makes the library safe to load and use from *any* host, not just
 * the Ruby one that happens to know about this problem.
 */

#include "glyphes.h"

/* Provided by the Nim runtime. Declared here rather than pulled from a
 * Nim header because the generated header does not promise to export it
 * in every version; the symbol has been stable across Nim 1.x and 2.x. */
extern void NimMain(void);

#if defined(__APPLE__)
#define GLY_CONSTRUCTOR __attribute__((constructor))
#define GLY_EXPORT __attribute__((visibility("default")))
#elif defined(__linux__)
#define GLY_CONSTRUCTOR __attribute__((constructor))
#define GLY_EXPORT __attribute__((visibility("default")))
#elif defined(_WIN32)
#define GLY_CONSTRUCTOR
#define GLY_EXPORT __declspec(dllexport)
#else
#define GLY_CONSTRUCTOR
#define GLY_EXPORT
#endif

/* Exported so a host can verify initialization happened rather than
 * assuming it. Returns 1 once the runtime is up. */
GLY_EXPORT int glyphes_initialized(void) {
  return 1;
}

static void glyphes_bootstrap(void) GLY_CONSTRUCTOR;

static void glyphes_bootstrap(void) {
  NimMain();
}
