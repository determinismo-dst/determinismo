// SPDX-License-Identifier: MIT
// The C SDK's coverage callbacks alone, for a program or library built with clang's
// -fsanitize-coverage=trace-pc-guard: each edge reports itself once a timeline, and thread
// pausing pauses threads there (determinismo.h). Compile it plain (without the flag) and link it
// in; nothing else of the SDK is used (examples/race's C++ build, examples/galera's library).
#define DETERMINISMO_IMPLEMENTATION
#define DETERMINISMO_COVERAGE
#include "determinismo.h"
