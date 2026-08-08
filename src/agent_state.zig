const std = @import("std");

pub const State = enum {
    turn_started,
    contract_selected,
    tool_executed,
    evidence_recorded,
    finalizing,
    completed,
    failed,
};

pub const Event = enum {
    select_contract,
    execute_tool,
    record_evidence,
    close_tool_phase,
    complete_turn,
    fail_turn,
};

pub fn transition(current: State, event: Event) State {
    if (current == .failed or current == .completed) return current;
    return switch (event) {
        .select_contract => .contract_selected,
        .execute_tool => switch (current) {
            .turn_started => .tool_executed,
            else => .tool_executed,
        },
        .record_evidence => .evidence_recorded,
        .close_tool_phase => .finalizing,
        .complete_turn => .completed,
        .fail_turn => .failed,
    };
}

pub const InitialModelOutputSignals = struct {
    has_tool_envelope: bool = false,
    has_visible_output: bool = false,
    cites_missing_session_evidence: bool = false,
    claims_persistent_context_without_retrieval: bool = false,
    premature_clarification: bool = false,
};

pub const InitialModelOutputDecision = enum {
    process_tool_envelope,
    repair_missing_session_evidence,
    repair_persistent_context_claim,
    repair_premature_clarification,
    unhandled_model_output,
};

pub fn decideInitialModelOutput(signals: InitialModelOutputSignals) InitialModelOutputDecision {
    if (signals.has_tool_envelope) return .process_tool_envelope;
    if (!signals.has_visible_output) return .unhandled_model_output;
    if (signals.cites_missing_session_evidence) return .repair_missing_session_evidence;
    if (signals.claims_persistent_context_without_retrieval) return .repair_persistent_context_claim;
    if (signals.premature_clarification) return .repair_premature_clarification;
    return .unhandled_model_output;
}

pub const RuntimeOutcome = enum {
    unhandled,
    final_answer,
    stopped,
};

pub fn applyRuntimeOutcome(current: State, outcome: RuntimeOutcome) State {
    return switch (outcome) {
        .unhandled => current,
        .final_answer => transition(current, .complete_turn),
        .stopped => transition(current, .fail_turn),
    };
}

pub fn runtimeOutcomeHandled(outcome: RuntimeOutcome) bool {
    return outcome != .unhandled;
}

pub fn hasEnteredToolPhase(state: State) bool {
    return switch (state) {
        .tool_executed, .evidence_recorded, .finalizing, .completed => true,
        .turn_started, .contract_selected, .failed => false,
    };
}

test "agent state tracks normal contract tool finalization flow" {
    var state: State = .turn_started;
    state = transition(state, .select_contract);
    try std.testing.expectEqual(State.contract_selected, state);
    state = transition(state, .execute_tool);
    try std.testing.expectEqual(State.tool_executed, state);
    state = transition(state, .record_evidence);
    try std.testing.expectEqual(State.evidence_recorded, state);
    state = transition(state, .close_tool_phase);
    try std.testing.expectEqual(State.finalizing, state);
    state = transition(state, .complete_turn);
    try std.testing.expectEqual(State.completed, state);
}

test "terminal states are stable" {
    try std.testing.expectEqual(State.completed, transition(.completed, .fail_turn));
    try std.testing.expectEqual(State.failed, transition(.failed, .complete_turn));
}

test "tool phase predicate is explicit" {
    try std.testing.expect(!hasEnteredToolPhase(.turn_started));
    try std.testing.expect(!hasEnteredToolPhase(.contract_selected));
    try std.testing.expect(hasEnteredToolPhase(.tool_executed));
    try std.testing.expect(hasEnteredToolPhase(.evidence_recorded));
    try std.testing.expect(hasEnteredToolPhase(.finalizing));
}

test "initial model output decision prioritizes executable protocol then repairs" {
    try std.testing.expectEqual(InitialModelOutputDecision.process_tool_envelope, decideInitialModelOutput(.{
        .has_tool_envelope = true,
        .has_visible_output = true,
        .cites_missing_session_evidence = true,
    }));
    try std.testing.expectEqual(InitialModelOutputDecision.repair_missing_session_evidence, decideInitialModelOutput(.{
        .has_visible_output = true,
        .cites_missing_session_evidence = true,
        .claims_persistent_context_without_retrieval = true,
    }));
    try std.testing.expectEqual(InitialModelOutputDecision.repair_persistent_context_claim, decideInitialModelOutput(.{
        .has_visible_output = true,
        .claims_persistent_context_without_retrieval = true,
        .premature_clarification = true,
    }));
    try std.testing.expectEqual(InitialModelOutputDecision.repair_premature_clarification, decideInitialModelOutput(.{
        .has_visible_output = true,
        .premature_clarification = true,
    }));
    try std.testing.expectEqual(InitialModelOutputDecision.unhandled_model_output, decideInitialModelOutput(.{}));
}

test "runtime outcomes close the state machine explicitly" {
    try std.testing.expectEqual(State.completed, applyRuntimeOutcome(.finalizing, .final_answer));
    try std.testing.expectEqual(State.failed, applyRuntimeOutcome(.tool_executed, .stopped));
    try std.testing.expectEqual(State.turn_started, applyRuntimeOutcome(.turn_started, .unhandled));
    try std.testing.expect(runtimeOutcomeHandled(.final_answer));
    try std.testing.expect(!runtimeOutcomeHandled(.unhandled));
}
