const std = @import("std");

const contracts = @import("contracts.zig");

pub const Blocker = enum {
    inspection_required,
    mutation_required,
    runtime_validation_required,
    browser_diagnostics_required,
    memory_promotion_required,
    memory_context_search_required,

    pub fn message(self: Blocker) []const u8 {
        return switch (self) {
            .inspection_required => "inspection evidence is required before finalization",
            .mutation_required => "a successful mutation is required before finalization",
            .runtime_validation_required => "runtime validation is required before finalization",
            .browser_diagnostics_required => "browser/runtime diagnostics are required before finalization",
            .memory_promotion_required => "memory or skills promotion is required before finalization",
            .memory_context_search_required => "memory context search is required before finalization",
        };
    }
};

pub const Progress = struct {
    contract_selected: bool = false,
    active_contract: contracts.ContractName = .workflow,
    requirements: contracts.OperationalContractRequest = .{
        .requires_inspection = false,
        .requires_mutation = false,
        .requires_runtime_validation = false,
        .requires_browser_diagnostics = false,
        .requires_memory_promotion = false,
    },
    observations: usize = 0,
    mutations: usize = 0,
    runtime_validations: usize = 0,
    browser_diagnostics: usize = 0,
    memory_promotions: usize = 0,
    persistent_context_searches: usize = 0,
    personal_memory_searches: usize = 0,
};

pub fn blocker(progress: Progress) ?Blocker {
    if (!progress.contract_selected) return null;
    if (progress.active_contract == .answer_only) return null;
    if (progress.requirements.requires_inspection and
        progress.observations == 0 and
        !(progress.requirements.requires_mutation and progress.mutations > 0))
    {
        return .inspection_required;
    }
    if (progress.requirements.requires_mutation and progress.mutations == 0) return .mutation_required;
    if (progress.requirements.requires_runtime_validation and progress.runtime_validations == 0) return .runtime_validation_required;
    if (progress.requirements.requires_browser_diagnostics and progress.browser_diagnostics == 0) return .browser_diagnostics_required;
    if (progress.requirements.requires_memory_promotion and progress.memory_promotions == 0) return .memory_promotion_required;
    if (progress.active_contract == .memory and
        progress.persistent_context_searches == 0 and
        progress.personal_memory_searches == 0 and
        progress.memory_promotions == 0)
    {
        return .memory_context_search_required;
    }
    return null;
}

pub fn blockerMessage(progress: Progress) ?[]const u8 {
    const value = blocker(progress) orelse return null;
    return value.message();
}

test "unselected or answer-only turns can finalize" {
    try std.testing.expect(blocker(.{}) == null);
    try std.testing.expect(blocker(.{
        .contract_selected = true,
        .active_contract = .answer_only,
    }) == null);
}

test "inspection obligation requires evidence unless mutation already produced it" {
    try std.testing.expectEqual(Blocker.inspection_required, blocker(.{
        .contract_selected = true,
        .active_contract = .collect_evidence,
        .requirements = .{
            .requires_inspection = true,
            .requires_mutation = false,
            .requires_runtime_validation = false,
            .requires_browser_diagnostics = false,
        },
    }).?);
    try std.testing.expect(blocker(.{
        .contract_selected = true,
        .active_contract = .collect_evidence,
        .requirements = .{
            .requires_inspection = true,
            .requires_mutation = false,
            .requires_runtime_validation = false,
            .requires_browser_diagnostics = false,
        },
        .observations = 1,
    }) == null);
    try std.testing.expect(blocker(.{
        .contract_selected = true,
        .active_contract = .mutate_file,
        .requirements = .{
            .requires_inspection = true,
            .requires_mutation = true,
            .requires_runtime_validation = false,
            .requires_browser_diagnostics = false,
        },
        .mutations = 1,
    }) == null);
}

test "mutation validation runtime and memory obligations block finalization" {
    try std.testing.expectEqual(Blocker.mutation_required, blocker(.{
        .contract_selected = true,
        .active_contract = .mutate_file,
        .requirements = .{
            .requires_inspection = false,
            .requires_mutation = true,
            .requires_runtime_validation = false,
            .requires_browser_diagnostics = false,
        },
    }).?);
    try std.testing.expectEqual(Blocker.runtime_validation_required, blocker(.{
        .contract_selected = true,
        .active_contract = .validate_work,
        .requirements = .{
            .requires_inspection = false,
            .requires_mutation = false,
            .requires_runtime_validation = true,
            .requires_browser_diagnostics = false,
        },
    }).?);
    try std.testing.expectEqual(Blocker.browser_diagnostics_required, blocker(.{
        .contract_selected = true,
        .active_contract = .inspect_runtime,
        .requirements = .{
            .requires_inspection = false,
            .requires_mutation = false,
            .requires_runtime_validation = false,
            .requires_browser_diagnostics = true,
        },
    }).?);
    try std.testing.expectEqual(Blocker.memory_promotion_required, blocker(.{
        .contract_selected = true,
        .active_contract = .memory,
        .requirements = .{
            .requires_inspection = false,
            .requires_mutation = false,
            .requires_runtime_validation = false,
            .requires_browser_diagnostics = false,
            .requires_memory_promotion = true,
        },
    }).?);
}

test "memory contract requires a memory lookup or promotion" {
    try std.testing.expectEqual(Blocker.memory_context_search_required, blocker(.{
        .contract_selected = true,
        .active_contract = .memory,
    }).?);
    try std.testing.expect(blocker(.{
        .contract_selected = true,
        .active_contract = .memory,
        .persistent_context_searches = 1,
    }) == null);
    try std.testing.expect(blocker(.{
        .contract_selected = true,
        .active_contract = .memory,
        .personal_memory_searches = 1,
    }) == null);
}
