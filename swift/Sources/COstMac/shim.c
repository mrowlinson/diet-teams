// Shim: gives the COstMac target a C source so SPM builds its module.
#include "ostmac_core.h"

const char *ostmac_shim_anchor(void) { return ostmac_version(); }
