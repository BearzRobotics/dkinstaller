//! dkrescue-install library: probe, answers, plan and files (SPEC.md 6.1).

pub const probe = @import("probe.zig");
pub const answers = @import("answers.zig");
pub const plan = @import("plan.zig");
pub const files = @import("files.zig");

test {
    _ = probe;
    _ = answers;
    _ = plan;
    _ = files;
}
