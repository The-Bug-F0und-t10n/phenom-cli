const std = @import("std");

const collect_evidence = @import("collect_evidence.zig");
const diagnostic_runner = @import("diagnostic_runner.zig");
const evidence = @import("evidence.zig");

pub const Result = struct {
    evidence_text: []u8,
    audit_text: []u8,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.evidence_text);
        allocator.free(self.audit_text);
    }
};

pub fn execute(allocator: std.mem.Allocator, path: []const u8, budget_bytes: usize) !Result {
    const diagnostic = try diagnostic_runner.run(allocator, path, budget_bytes);
    defer diagnostic.deinit(allocator);

    var packet = evidence.EvidencePacket.init(allocator);
    defer packet.deinit();
    try packet.add(try collect_evidence.cloneEvidenceEntry(allocator, diagnostic.entry));

    const evidence_text = try packet.render(allocator);
    errdefer allocator.free(evidence_text);
    const audit_text = try allocator.dupe(u8, diagnostic.audit_text);
    errdefer allocator.free(audit_text);
    return .{
        .evidence_text = evidence_text,
        .audit_text = audit_text,
    };
}

test "syntax validation renders diagnostic evidence packet" {
    const path = "syntax_validation_bad_test.zig";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = path,
        .data = "pub fn broken( {\n",
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const result = try execute(std.testing.allocator, path, 4096);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.evidence_text, "[EVIDENCE]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.evidence_text, "severity=blocking") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.audit_text, "strategy=diagnostic") != null);
}

test "syntax validation rejects unsupported language" {
    try std.testing.expectError(error.UnsupportedDiagnosticLanguage, execute(std.testing.allocator, "README.md", 4096));
}
