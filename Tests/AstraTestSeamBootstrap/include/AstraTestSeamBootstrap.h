#ifndef ASTRA_TEST_SEAM_BOOTSTRAP_H
#define ASTRA_TEST_SEAM_BOOTSTRAP_H

// No-op. Exists so Tests/RuntimeSeamTestBootstrap.swift can reference this
// module at link time: without a referenced symbol the linker would drop this
// static-archive member from the test bundle — and the load-time constructor
// in AstraTestSeamBootstrap.c along with it.
void astra_test_seam_bootstrap_force_link(void);

#endif
