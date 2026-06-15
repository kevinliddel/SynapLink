//
//  SynapLink-Bridging-Header.h
//  SynapLink
//
//  Everything Swift sees from the C/C++ core. Keep this surface pure C —
//  C++ headers must never be imported here.
//

#pragma once

#include "synap_engine.h"
#include "synap_whisper.h"

#if __has_include(<os/proc.h>)
#include <os/proc.h> // os_proc_available_memory() — jetsam headroom (iOS only)
#endif
