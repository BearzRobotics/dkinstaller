//! dkrescue-install library: probe, answers, plan and files (SPEC.md 6.1).

pub const probe = @import("probe.zig");
pub const answers = @import("answers.zig");
pub const plan = @import("plan.zig");
pub const files = @import("files.zig");
pub const execute = @import("execute.zig");
pub const term = @import("ui/term.zig");
pub const ui = @import("ui/ui.zig");

test {
    _ = probe;
    _ = answers;
    _ = plan;
    _ = files;
    _ = execute;
    _ = term;
    _ = ui;
}
