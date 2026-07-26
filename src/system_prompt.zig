pub const default_system_prompt: []const u8 = @embedFile("system_prompt.md");

test "default system prompt is loaded from template file" {
    const std = @import("std");
    try std.testing.expect(std.mem.indexOf(u8, default_system_prompt, "You are Phenom") == null);
    try std.testing.expect(std.mem.indexOf(u8, default_system_prompt, "Model decides when contracts/tools are needed") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_system_prompt, "Do not roleplay identity") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_system_prompt, "MEMORY=verified project/workdir facts") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_system_prompt, "SKILLS=user-confirmed durable rules/preferences/operational constraints") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_system_prompt, "before a relevant memory lookup") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_system_prompt, "promote a concise interpreted SKILLS rule") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_system_prompt, "separate known, inferred, and unknown") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_system_prompt, "Do not fill gaps") != null);
}
