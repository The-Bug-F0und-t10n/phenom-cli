const std = @import("std");

const agent_state = @import("agent_state.zig");
const collect_evidence = @import("collect_evidence.zig");
const contracts = @import("contracts.zig");
const finalization_gate = @import("finalization_gate.zig");
const tool_call = @import("tool_call.zig");
const working_context = @import("working_context.zig");

pub const ToolLoopState = struct {
    phase: agent_state.State = .turn_started,
    context: working_context.WorkingContext,
    session_searches: std.ArrayList([]u8),
    retrieved_skills: std.ArrayList([]u8),
    candidates: std.ArrayList(collect_evidence.CandidateItem),
    last_candidate_context: ?[]u8 = null,
    last_session_context: ?[]u8 = null,
    active_contract: contracts.ActiveContract,
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
    duplicate_repairs: usize = 0,
    contract_selected: bool = false,
    duplicate_contract_repairs: usize = 0,
    finalization_repairs: usize = 0,
    retrieved_skill_answer_repairs: usize = 0,
    search_web_question_repairs: usize = 0,
    clarification_soft_repairs: usize = 0,
    forced_exploratory_refinements: usize = 0,

    pub fn init(allocator: std.mem.Allocator) ToolLoopState {
        return .{
            .context = working_context.WorkingContext.init(allocator),
            .session_searches = std.ArrayList([]u8).empty,
            .retrieved_skills = std.ArrayList([]u8).empty,
            .candidates = std.ArrayList(collect_evidence.CandidateItem).empty,
            .active_contract = contracts.activeContract(.workflow).?,
        };
    }

    pub fn deinit(self: *ToolLoopState) void {
        for (self.session_searches.items) |terms| self.context.allocator.free(terms);
        self.session_searches.deinit(self.context.allocator);
        for (self.retrieved_skills.items) |skill| self.context.allocator.free(skill);
        self.retrieved_skills.deinit(self.context.allocator);
        for (self.candidates.items) |candidate| candidate.deinit(self.context.allocator);
        self.candidates.deinit(self.context.allocator);
        if (self.last_candidate_context) |text| self.context.allocator.free(text);
        if (self.last_session_context) |text| self.context.allocator.free(text);
        self.context.deinit();
    }

    pub fn hasExecutedArgs(self: ToolLoopState, path: ?[]const u8, terms: ?[]const u8, strategy: contracts.StrategyName, start_line: usize, max_lines: usize) bool {
        return self.context.hasDuplicate(.{
            .path = path,
            .terms = terms,
            .strategy = strategy,
            .start_line = start_line,
            .max_lines = max_lines,
            .evidence_text = "",
            .model_bytes = 0,
            .quality_score = 0,
        });
    }

    pub fn hasExecutedWebTarget(self: ToolLoopState, target: []const u8, strategy: contracts.StrategyName) bool {
        for (self.context.entries.items) |entry| {
            if (entry.strategy == strategy and entry.start_line == 1 and entry.max_lines == 1 and std.mem.eql(u8, entry.path, target)) return true;
        }
        return false;
    }

    pub fn hasFetchedWebEvidenceTarget(self: ToolLoopState, target: []const u8) bool {
        for (self.context.entries.items) |entry| {
            if (webEvidenceContainsTarget(entry.evidence_text, target)) return true;
        }
        return false;
    }

    pub fn rememberExecutedArgs(self: *ToolLoopState, path: ?[]const u8, terms: ?[]const u8, strategy: contracts.StrategyName, start_line: usize, max_lines: usize, context_id: ?[]const u8, evidence_text: []const u8, model_bytes: usize, quality_score: i32) !void {
        self.context.remember(.{
            .path = path,
            .terms = terms,
            .strategy = strategy,
            .start_line = start_line,
            .max_lines = max_lines,
            .context_id = context_id,
            .evidence_text = evidence_text,
            .model_bytes = model_bytes,
            .quality_score = quality_score,
        }) catch |err| switch (err) {
            error.DuplicateWorkingEvidence => return,
            else => return err,
        };
    }

    pub fn selectContract(self: *ToolLoopState, selected: contracts.ActiveContract, request: contracts.OperationalContractRequest) void {
        self.active_contract = selected;
        self.phase = agent_state.transition(self.phase, .select_contract);
        self.contract_selected = true;
        self.requirements = request;
        self.finalization_repairs = 0;
        self.retrieved_skill_answer_repairs = 0;
        self.search_web_question_repairs = 0;
        self.duplicate_contract_repairs = 0;
    }

    pub fn recordObservation(self: *ToolLoopState) void {
        self.phase = agent_state.transition(self.phase, .record_evidence);
        self.observations += 1;
        self.finalization_repairs = 0;
        self.search_web_question_repairs = 0;
    }

    pub fn closeToolPhase(self: *ToolLoopState) void {
        self.active_contract = contracts.activeContract(.answer_only).?;
        self.phase = agent_state.transition(self.phase, .close_tool_phase);
        self.finalization_repairs = 0;
        self.search_web_question_repairs = 0;
    }

    pub fn applyRuntimeOutcome(self: *ToolLoopState, outcome: agent_state.RuntimeOutcome) void {
        self.phase = agent_state.applyRuntimeOutcome(self.phase, outcome);
    }

    pub fn recordMutation(self: *ToolLoopState) void {
        self.phase = agent_state.transition(self.phase, .execute_tool);
        self.mutations += 1;
        self.finalization_repairs = 0;
    }

    pub fn recordRuntimeValidation(self: *ToolLoopState) void {
        self.phase = agent_state.transition(self.phase, .execute_tool);
        self.runtime_validations += 1;
        self.finalization_repairs = 0;
    }

    pub fn recordBrowserDiagnostics(self: *ToolLoopState) void {
        self.phase = agent_state.transition(self.phase, .execute_tool);
        self.browser_diagnostics += 1;
        self.finalization_repairs = 0;
    }

    pub fn recordMemoryPromotion(self: *ToolLoopState) void {
        self.phase = agent_state.transition(self.phase, .execute_tool);
        self.memory_promotions += 1;
        self.finalization_repairs = 0;
    }

    pub fn recordPersistentContextSearch(self: *ToolLoopState) void {
        self.phase = agent_state.transition(self.phase, .record_evidence);
        self.persistent_context_searches += 1;
        self.finalization_repairs = 0;
    }

    pub fn recordPersonalMemorySearch(self: *ToolLoopState) void {
        self.phase = agent_state.transition(self.phase, .record_evidence);
        self.personal_memory_searches += 1;
        self.finalization_repairs = 0;
    }

    pub fn rememberRetrievedSkills(self: *ToolLoopState, skills: []const []const u8) !void {
        for (skills) |skill| {
            const trimmed = std.mem.trim(u8, skill, " \t\r\n");
            if (trimmed.len == 0) continue;
            var exists = false;
            for (self.retrieved_skills.items) |existing| {
                if (std.mem.eql(u8, existing, trimmed)) {
                    exists = true;
                    break;
                }
            }
            if (exists) continue;
            const owned = try self.context.allocator.dupe(u8, trimmed);
            errdefer self.context.allocator.free(owned);
            try self.retrieved_skills.append(self.context.allocator, owned);
        }
    }

    pub fn finalizationProgress(self: *const ToolLoopState) finalization_gate.Progress {
        return .{
            .contract_selected = self.contract_selected,
            .active_contract = self.active_contract.name,
            .requirements = self.requirements,
            .observations = self.observations,
            .mutations = self.mutations,
            .runtime_validations = self.runtime_validations,
            .browser_diagnostics = self.browser_diagnostics,
            .memory_promotions = self.memory_promotions,
            .persistent_context_searches = self.persistent_context_searches,
            .personal_memory_searches = self.personal_memory_searches,
        };
    }

    pub fn finalizationBlocker(self: *const ToolLoopState) ?[]const u8 {
        return finalization_gate.blockerMessage(self.finalizationProgress());
    }

    pub fn hasBudgetForMoreEvidence(self: ToolLoopState) bool {
        return self.context.hasBudgetForMoreEvidence();
    }

    pub fn remainingBudget(self: ToolLoopState) usize {
        return self.context.remainingBudget();
    }

    pub fn shouldAllowMoreEvidence(self: ToolLoopState) bool {
        return self.context.shouldAllowMoreEvidence();
    }

    pub fn shouldRequireExploratoryRefinement(self: ToolLoopState, call: *const tool_call.ToolCall, path: ?[]const u8, strategy: contracts.StrategyName) bool {
        if (path != null or !self.shouldAllowMoreEvidence() or self.forced_exploratory_refinements != 0) return false;
        return switch (call.source orelse .auto) {
            .git, .web, .diagnostic, .file => false,
            .auto, .code, .rag => switch (strategy) {
                .diff, .history, .show, .reflog, .@"unreachable", .diagnostic => false,
                else => true,
            },
        };
    }

    pub fn hasSessionSearch(self: ToolLoopState, terms: []const u8) bool {
        for (self.session_searches.items) |existing| {
            if (std.ascii.eqlIgnoreCase(existing, terms)) return true;
        }
        return false;
    }

    pub fn rememberSessionSearch(self: *ToolLoopState, terms: []const u8) !void {
        if (self.hasSessionSearch(terms)) return error.DuplicateSessionSearch;
        const owned = try self.context.allocator.dupe(u8, terms);
        errdefer self.context.allocator.free(owned);
        try self.session_searches.append(self.context.allocator, owned);
    }

    pub fn rememberSessionContext(self: *ToolLoopState, text: []const u8) !void {
        const owned = try self.context.allocator.dupe(u8, text);
        errdefer self.context.allocator.free(owned);
        if (self.last_session_context) |old| self.context.allocator.free(old);
        self.last_session_context = owned;
    }

    pub fn rememberCandidates(self: *ToolLoopState, result: *const collect_evidence.CandidateResult) !void {
        var next = std.ArrayList(collect_evidence.CandidateItem).empty;
        var committed = false;
        errdefer if (!committed) {
            for (next.items) |candidate| candidate.deinit(self.context.allocator);
            next.deinit(self.context.allocator);
        };

        for (result.candidates.items) |candidate| {
            var cloned = try cloneCandidateItem(self.context.allocator, candidate);
            errdefer cloned.deinit(self.context.allocator);
            try next.append(self.context.allocator, cloned);
        }
        const owned = try self.context.allocator.dupe(u8, result.text);
        errdefer self.context.allocator.free(owned);

        for (self.candidates.items) |candidate| candidate.deinit(self.context.allocator);
        self.candidates.deinit(self.context.allocator);
        self.candidates = next;
        committed = true;

        if (self.last_candidate_context) |old| self.context.allocator.free(old);
        self.last_candidate_context = owned;
    }

    pub fn findCandidate(self: ToolLoopState, id: []const u8) ?collect_evidence.CandidateItem {
        for (self.candidates.items) |candidate| {
            if (std.ascii.eqlIgnoreCase(candidate.id, id)) return candidate;
        }
        return null;
    }
};

fn cloneCandidateItem(allocator: std.mem.Allocator, candidate: collect_evidence.CandidateItem) !collect_evidence.CandidateItem {
    const id = try allocator.dupe(u8, candidate.id);
    errdefer allocator.free(id);
    const path = try allocator.dupe(u8, candidate.path);
    errdefer allocator.free(path);
    const source = try allocator.dupe(u8, candidate.source);
    errdefer allocator.free(source);
    const signature = try allocator.dupe(u8, candidate.signature);
    errdefer allocator.free(signature);
    const preview = try allocator.dupe(u8, candidate.preview);
    errdefer allocator.free(preview);
    return .{
        .id = id,
        .path = path,
        .start_line = candidate.start_line,
        .end_line = candidate.end_line,
        .score = candidate.score,
        .source = source,
        .signature = signature,
        .preview = preview,
    };
}

fn webEvidenceContainsTarget(text: []const u8, target: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        const idx = std.mem.indexOf(u8, trimmed, "target=") orelse continue;
        const start = idx + "target=".len;
        var end = start;
        while (end < trimmed.len and !std.ascii.isWhitespace(trimmed[end])) : (end += 1) {}
        const value = std.mem.trim(u8, trimmed[start..end], " \t\r\n");
        if (std.mem.eql(u8, value, target)) return true;
    }
    return false;
}

test "tool loop state records evidence idempotently" {
    var state = ToolLoopState.init(std.testing.allocator);
    defer state.deinit();

    try state.rememberExecutedArgs("README.md", null, .path, 1, 12, "ctx_readme", "[EVIDENCE]\n- README.md L1-L12 hash=abc\n", 120, 72);
    try state.rememberExecutedArgs("README.md", null, .path, 1, 12, "ctx_dup", "[EVIDENCE]\n- duplicate\n", 50, 1);

    try std.testing.expect(state.hasExecutedArgs("README.md", null, .path, 1, 12));
    try std.testing.expectEqual(@as(usize, 1), state.context.entries.items.len);
    try std.testing.expectEqualStrings("ctx_readme", state.context.entries.items[0].context_id);
}

test "tool loop state exposes finalization gate progress" {
    var state = ToolLoopState.init(std.testing.allocator);
    defer state.deinit();

    state.selectContract(contracts.activeContract(.collect_evidence).?, .{
        .requires_inspection = true,
        .requires_mutation = false,
        .requires_runtime_validation = false,
        .requires_browser_diagnostics = false,
        .requires_memory_promotion = false,
    });
    try std.testing.expectEqualStrings("inspection evidence is required before finalization", state.finalizationBlocker().?);
    state.recordObservation();
    try std.testing.expect(state.finalizationBlocker() == null);
}

test "tool loop state owns session and candidate scratch data" {
    var state = ToolLoopState.init(std.testing.allocator);
    defer state.deinit();

    try state.rememberSessionSearch("scope=current terms=renderer");
    try std.testing.expect(state.hasSessionSearch("SCOPE=CURRENT TERMS=RENDERER"));
    try state.rememberSessionContext("[SESSION_EVIDENCE]\n- S1 renderer\n");
    try std.testing.expect(state.last_session_context != null);

    var candidates = std.ArrayList(collect_evidence.CandidateItem).empty;
    var result_owns_candidates = false;
    errdefer if (!result_owns_candidates) {
        for (candidates.items) |candidate| candidate.deinit(std.testing.allocator);
        candidates.deinit(std.testing.allocator);
    };
    try candidates.append(std.testing.allocator, .{
        .id = try std.testing.allocator.dupe(u8, "C1"),
        .path = try std.testing.allocator.dupe(u8, "src/main.zig"),
        .start_line = 1,
        .end_line = 12,
        .score = 100,
        .source = try std.testing.allocator.dupe(u8, "symbol_ast"),
        .signature = try std.testing.allocator.dupe(u8, "pub fn main"),
        .preview = try std.testing.allocator.dupe(u8, "main"),
    });
    var result = collect_evidence.CandidateResult{
        .text = try std.testing.allocator.dupe(u8, "[CANDIDATES]\n- C1 path=src/main.zig\n"),
        .audit_text = try std.testing.allocator.dupe(u8, "[TOOL_EVENT]\n"),
        .model_bytes = 32,
        .candidates = candidates,
    };
    result_owns_candidates = true;
    defer result.deinit(std.testing.allocator);

    try state.rememberCandidates(&result);
    try std.testing.expectEqualStrings("src/main.zig", state.findCandidate("c1").?.path);
    try std.testing.expect(state.last_candidate_context != null);
}
