#include "include/AstraTestSeamBootstrap.h"

// Defined in Tests/RuntimeSeamTestBootstrap.swift via
// @_cdecl("astra_test_register_runtime_seams"); the reference resolves when
// the ASTRATests bundle links. See that file for why registration must
// happen at bundle load and not per-suite.
extern void astra_test_register_runtime_seams(void);

// Runs when dyld loads the ASTRATests bundle: before main, before XCTest or
// Swift Testing discovers a single test, while the process is still
// single-threaded. This is the module-load hook Swift code cannot declare
// itself (no ObjC-style +load, no eager top-level initializers).
__attribute__((constructor))
static void astra_test_seam_bootstrap(void) {
    astra_test_register_runtime_seams();
}

void astra_test_seam_bootstrap_force_link(void) {}
