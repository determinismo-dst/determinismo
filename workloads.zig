// SPDX-License-Identifier: MIT
//! A deployment's own workloads, built in this build beside the platform's (build.zig calls
//! `register` with the platform's modules and steps, so `zig build <workload>` works here). None
//! in the platform's own repository: test programs usually live in their project, which takes
//! this package as a dependency (docs/GETTING_STARTED.md). A tree assembled from this repository
//! and a workloads one replaces this file with a `register` that adds them.
const std = @import("std");

pub fn register(b: *std.Build, platform: anytype) void {
    _ = b;
    _ = platform;
}
