const std = @import("std");

pub const default_system_prompt: []const u8 = @embedFile("system_prompt.md");
pub const strict_system_prompt: []const u8 = @embedFile("system_prompt_strict.md");

pub const Profile = enum {
    stock,
    strict,
};

pub fn parseProfile(value: []const u8) ?Profile {
    if (std.mem.eql(u8, value, "stock") or std.mem.eql(u8, value, "default")) return .stock;
    if (std.mem.eql(u8, value, "strict")) return .strict;
    return null;
}

pub fn profileName(profile: Profile) []const u8 {
    return switch (profile) {
        .stock => "stock",
        .strict => "strict",
    };
}

pub fn profileText(profile: Profile) []const u8 {
    return switch (profile) {
        .stock => default_system_prompt,
        .strict => strict_system_prompt,
    };
}

test "default system prompt is loaded from template file" {
    try std.testing.expect(std.mem.indexOf(u8, default_system_prompt, "You are Phenom") == null);
    try std.testing.expect(std.mem.indexOf(u8, default_system_prompt, "Model decides when contracts/tools are needed") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_system_prompt, "Do not roleplay identity") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_system_prompt, "language of the latest user message") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_system_prompt, "MEMORY=verified project/workdir facts") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_system_prompt, "SKILLS=user-confirmed durable rules/preferences/operational constraints") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_system_prompt, "before a relevant memory lookup") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_system_prompt, "explicitly states a durable future-turn rule/preference") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_system_prompt, "Internally separate known, inferred, and unknown factual claims") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_system_prompt, "Low factual confidence requires read-only verification") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_system_prompt, "external facts use search_web/rag_web") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_system_prompt, "state insufficient evidence; never guess") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_system_prompt, "Do not fill gaps") != null);
}

test "system prompt profiles are named and selectable" {
    try std.testing.expectEqual(Profile.stock, parseProfile("stock").?);
    try std.testing.expectEqual(Profile.stock, parseProfile("default").?);
    try std.testing.expectEqual(Profile.strict, parseProfile("strict").?);
    try std.testing.expect(parseProfile("unknown") == null);
    try std.testing.expectEqualStrings("strict", profileName(.strict));
    try std.testing.expect(profileText(.stock).ptr == default_system_prompt.ptr);
    try std.testing.expect(std.mem.indexOf(u8, profileText(.strict), "Do not infer identity") != null);
    try std.testing.expect(std.mem.indexOf(u8, profileText(.strict), "unsupported external facts require search_web/rag_web") != null);
}
