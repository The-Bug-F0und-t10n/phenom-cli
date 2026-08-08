const std = @import("std");

const context_profile = @import("context_profile.zig");
const contracts = @import("contracts.zig");
const initial_model_context = @import("initial_model_context.zig");
const model_context = @import("model_context.zig");

pub const FinalizationProgress = struct {
    active_contract: contracts.ActiveContract,
    active_schema: []const u8,
    observations: usize,
    mutations: usize,
    runtime_validations: usize,
    browser_diagnostics: usize,
    memory_promotions: usize,
    blocker: []const u8,
};

pub fn initialToolCall(allocator: std.mem.Allocator, initial_context: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}\n[PROTOCOL_REPAIR]\nPrevious output was prose, but this turn requires one context tool call before prose. For broad workspace/project map, emit collect_evidence stage=overview strategy=auto with no terms. For focused collect_evidence/search_session, set intent+concrete terms. For code identity, emit collect_evidence stage=candidates before expanding a selected candidate.\n",
        .{initial_context},
    );
}

pub fn initialRejectedTool(allocator: std.mem.Allocator, prompt: []const u8, raw_tool: []const u8) ![]u8 {
    const reason = try std.fmt.allocPrint(allocator, "The previous tool `{s}` is not active in the initial router contract.", .{raw_tool});
    defer allocator.free(reason);
    return model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .contracts = context_profile.toolSchema(.code_evidence, .initial),
        .obligations = &.{
            reason,
            "Initial router allows only set_operational_contract and search_session.",
            "For local workspace/source-code claims, select contract=collect_evidence first. For external/current facts, select contract=search_web or contract=rag_web with a model-selected query. For general answers, answer directly.",
        },
        .grounding = groundingRules(),
        .next_action = "Answer directly if no tool-backed context is needed, or emit one allowed set_operational_contract/search_session tool_call.",
    });
}

pub fn malformedToolCall(allocator: std.mem.Allocator, prompt: []const u8, active_contract: contracts.ActiveContract) ![]u8 {
    return model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .contracts = context_profile.activeContractSchemaFor(active_contract.name),
        .obligations = &.{
            "Previous visible tool_call was malformed and was not executed.",
            "If a tool is needed, emit one valid XML tool_call allowed by the active contract.",
            "If no tool-backed context is needed, answer directly without a tool_call.",
        },
        .grounding = groundingRules(),
        .next_action = "Answer directly, or emit exactly one valid active-contract tool_call. Do not mix prose around a tool_call.",
    });
}

pub fn missingCitation(allocator: std.mem.Allocator, prompt: []const u8) ![]u8 {
    return model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .contracts = context_profile.toolSchema(.code_evidence, .initial),
        .obligations = &.{
            "E#/S# citations are valid only when matching [EVIDENCE] or [SESSION_CONTEXT] blocks are present.",
            "The previous answer cited missing evidence. Collect evidence before citing, or answer without workspace/prior-session claims.",
        },
        .grounding = groundingRules(),
        .next_action = "Emit exactly one collect_evidence or search_session tool_call now. No prose.",
    });
}

pub fn persistentContextClaim(allocator: std.mem.Allocator, prompt: []const u8, active_contract: contracts.ActiveContract) ![]u8 {
    const memory_active = active_contract.name == .memory;
    return model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .contracts = if (memory_active)
            context_profile.memorySchema()
        else
            context_profile.activeContractSchemaFor(active_contract.name),
        .obligations = &.{
            "The previous answer made a MEMORY/SKILLS claim without retrieved persistent context.",
            "MEMORY/SKILLS availability/content/absence requires memory contract retrieval first.",
        },
        .grounding = groundingRules(),
        .next_action = if (memory_active)
            "Emit exactly one search_persistent_context target=both terms=<concrete terms from USER_TASK>. No prose."
        else
            "Emit exactly one set_operational_contract contract=memory terms=<concrete terms from USER_TASK>. No prose.",
    });
}

pub fn retrievedSkillsAnswer(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    active_schema: []const u8,
    retrieved_skills: []const []const u8,
) ![]u8 {
    return model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .contracts = active_schema,
        .skills = retrieved_skills,
        .obligations = &.{
            "The previous answer contradicted retrieved SKILLS.",
            "Retrieved SKILLS directly govern this memory-contract turn.",
            "Answer only from retrieved SKILLS. Do not ask clarification. Do not add generic advice.",
        },
        .grounding = groundingRules(),
        .next_action = "Emit the final answer now, applying the retrieved SKILLS exactly. No tool_call.",
    });
}

pub fn unsupportedWorkspaceClaim(allocator: std.mem.Allocator, prompt: []const u8) ![]u8 {
    return model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .contracts =
        \\[TOOLS v1]
        \\collect_evidence(intent?, terms?, strategy=auto|lexical|symbol, stage=overview|candidates)
        ,
        .obligations = &.{
            "The previous visible answer made a workspace/source-code claim without [EVIDENCE].",
            "Broad workspace/project map uses stage=overview. Function/type/file identity uses stage=candidates, then expand one candidate.",
        },
        .grounding = groundingRules(),
        .next_action = "Emit exactly one collect_evidence tool_call now. Use stage=overview for project map; stage=candidates for identity. No prose.",
    });
}

pub fn workspaceClaimRouter(allocator: std.mem.Allocator, prompt: []const u8) ![]u8 {
    return model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .contracts = context_profile.toolSchema(.code_evidence, .initial),
        .obligations = &.{
            "The previous visible answer made a workspace/source-code claim before selecting an operational contract.",
            "The initial router cannot execute collect_evidence directly.",
            "Direct final answer remains valid only if it avoids local workspace/source-code claims.",
        },
        .grounding = groundingRules(),
        .next_action = "Emit set_operational_contract with requiresInspection=true for workspace/source-code claims, or answer directly without those claims. No prose before a required tool call.",
    });
}

pub fn collectEvidenceSearchIntentSchema() []const u8 {
    return
    \\[TOOLS v1]
    \\collect_evidence(intent?, need?, path?, targetFiles?, scopeRoot?, terms?, strategy=auto|path|lexical|symbol, stage=minimum|candidates|expand?, selectedCandidate?, selectedCandidates?, start_line=1, max_lines=12, compact=false)
    \\Only collect_evidence is active for this repair. The previous collect_evidence call was malformed; correct it with path, or with intent+terms.
    \\A pathless collect_evidence call must include <parameter=intent>what source-code evidence you want</parameter> and <parameter=terms>concrete code retrieval keys for that intent</parameter>.
    \\The controller does not infer search terms from the user prompt. The model must choose the search intent and keys before evidence collection.
    \\For function/type/file identity, prefer stage=candidates with strategy=symbol, then expand the best C# candidate.
    \\<tool_call><function=collect_evidence><parameter=intent>find concrete source definition</parameter><parameter=strategy>symbol</parameter><parameter=stage>candidates</parameter><parameter=terms>ConcreteSymbolOrPathTerms</parameter></function></tool_call>
    ;
}

pub fn applyPatchOnlyContract() contracts.ActiveContract {
    return .{
        .name = .mutate_file,
        .version = contracts.manifest_version,
        .allowed_tools = &.{"apply_patch"},
    };
}

pub fn applyPatchOnlySchema() []const u8 {
    return
    \\[TOOLS v1]
    \\apply_patch(operation=edit|create|delete|rename, path, destinationPath?, content?, contextId?, repeated search/replace?)
    \\Only apply_patch is active for this repair. For create, provide path and full content. For edit/delete/rename, evidence and MICRO_CONTEXT are already present; do not call collect_evidence again.
    \\<tool_call><function=apply_patch><parameter=operation>edit</parameter><parameter=path>relative/path</parameter><parameter=contextId>ctx_...</parameter><parameter=search>exact old text</parameter><parameter=replace>exact new text</parameter></function></tool_call>
    ;
}

pub fn validateSyntaxOnlyContract() contracts.ActiveContract {
    return .{
        .name = .validate_work,
        .version = contracts.manifest_version,
        .allowed_tools = &.{"validate_syntax"},
    };
}

pub fn validateSyntaxOnlySchema() []const u8 {
    return
    \\[TOOLS v1]
    \\validate_syntax(path)
    \\Only validate_syntax is active for this repair. Patch was already applied; do not call collect_evidence.
    \\<tool_call><function=validate_syntax><parameter=path>relative/path.zig</parameter></function></tool_call>
    ;
}

pub fn validationRequiredAfterPatch(allocator: std.mem.Allocator, prompt: []const u8) ![]u8 {
    return model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .contracts = validateSyntaxOnlySchema(),
        .obligations = &.{
            "Patch was already applied.",
            "Validation is required before final answer.",
            "Do not call collect_evidence for validation in this repair.",
        },
        .grounding = groundingRules(),
        .next_action_v1 = .{
            .kind = .validate_work,
            .text = "Emit exactly one validate_syntax tool_call for the changed Zig file. No prose.",
        },
    });
}

pub fn patchFailure(allocator: std.mem.Allocator, prompt: []const u8, active_schema: []const u8) ![]u8 {
    return model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .contracts = active_schema,
        .obligations = &.{
            "Patch failed. If the context is stale, recollect evidence before another patch.",
            "For edit, every search must be exact and unique in the original file. For delete/rename, include fresh contextId.",
        },
        .grounding = groundingRules(),
        .next_action = "Emit one corrected apply_patch call, or collect_evidence again if context is stale.",
    });
}

pub fn patchCallRepair(allocator: std.mem.Allocator, prompt: []const u8, active_schema: []const u8, reason: []const u8) ![]u8 {
    return model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .contracts = active_schema,
        .obligations = &.{reason},
        .grounding = groundingRules(),
        .next_action = "Emit one corrected apply_patch call. For edit use path, contextId, repeated search/replace hunks. For create use operation=create and content. For delete/rename use fresh contextId.",
    });
}

pub fn patchAppliedFollowup(allocator: std.mem.Allocator, prompt: []const u8) ![]u8 {
    return model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .contracts = context_profile.activeContractSchemaFor(.validate_work),
        .obligations = &.{
            "Patch has been applied. Validate changed code when possible before final answer.",
        },
        .grounding = groundingRules(),
        .next_action = "Call validate_syntax for changed Zig files, or answer with the patch result if validation is not applicable.",
    });
}

pub fn validationCallRepair(allocator: std.mem.Allocator, prompt: []const u8, active_schema: []const u8) ![]u8 {
    return model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .contracts = active_schema,
        .obligations = &.{"validate_syntax requires path."},
        .next_action = "Emit validate_syntax with a relative Zig path, or answer if validation is not applicable.",
    });
}

pub fn validationFollowup(allocator: std.mem.Allocator, prompt: []const u8, evidence_text: []const u8) ![]u8 {
    const validation_block = [_]model_context.EvidenceBlock{.{ .text = evidence_text }};
    return model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .evidence = &validation_block,
        .grounding = groundingRules(),
        .next_action = "Answer with the patch and validation result. Cite validation evidence if it reports errors.",
    });
}

pub fn runtimeInspectionFollowup(allocator: std.mem.Allocator, prompt: []const u8, evidence_text: []const u8) ![]u8 {
    return model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .evidence = &.{.{ .text = evidence_text }},
        .obligations = &.{"Runtime inspection is bounded HTTP status/body evidence. Do not claim DOM/browser automation ran."},
        .grounding = groundingRules(),
        .next_action = "Answer using the HTTP runtime inspection evidence. State browser DOM automation was not executed.",
    });
}

pub fn clarificationSoft(allocator: std.mem.Allocator, prompt: []const u8, active_schema: []const u8) ![]u8 {
    return model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .contracts = active_schema,
        .obligations = &.{
            "Clarification is valid only when it resolves a real user decision.",
            "Do not write files, patch files, run validation, or perform side-effecting actions for this repair.",
        },
        .grounding = groundingRules(),
        .next_action = "The previous answer asked generic clarification before exploration. If an advertised read-only tool can verify, triangulate, or reduce uncertainty, emit exactly one exploratory tool_call. Otherwise answer with one specific clarification and why available context/tools cannot resolve it.",
    });
}

pub fn finalization(allocator: std.mem.Allocator, prompt: []const u8, progress: FinalizationProgress) ![]u8 {
    const operational_state = try std.fmt.allocPrint(
        allocator,
        "contract={s} observations={} mutations={} runtime_validations={} browser_diagnostics={} memory_promotions={} blocker={s}",
        .{
            @tagName(progress.active_contract.name),
            progress.observations,
            progress.mutations,
            progress.runtime_validations,
            progress.browser_diagnostics,
            progress.memory_promotions,
            progress.blocker,
        },
    );
    defer allocator.free(operational_state);
    return model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .contracts = progress.active_schema,
        .obligations = &.{
            operational_state,
            "The previous visible answer was not accepted because the selected operational contract is not satisfied.",
            "Choose the smallest allowed tool call that satisfies the blocker. Do not answer in prose before that tool result.",
        },
        .grounding = groundingRules(),
        .next_action = "Emit exactly one allowed tool_call now. No prose.",
    });
}

pub fn emptyWebEvidenceAnswer(allocator: std.mem.Allocator, follow_context: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}\n[EMPTY_WEB_EVIDENCE_ANSWER_REPAIR]\nPrevious visible answer was blocked because WEB_DOSSIER has no excerpt that directly supports the requested fact.\nAnswer visibly in the user's language from USER_TASK. State that web_search ran but returned no direct supporting evidence for the requested fact. Do not invent numbers, dates, versions, URLs, titles, or claims absent from WEB_DOSSIER. Do not emit tool calls, <think>, </think>, or protocol tags.\n",
        .{follow_context},
    );
}

pub fn unsupportedWebAnswer(allocator: std.mem.Allocator, follow_context: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}\n[ANSWER_REPAIR]\nPrevious visible answer was blocked because it cited/used web context without reusing any substantial WEB_DOSSIER excerpt term.\nAnswer visibly in the user's language from USER_TASK using only source_url and excerpt lines in WEB_DOSSIER. If the excerpt does not directly support the requested claim, state that limitation. Do not emit tool calls, <think>, </think>, or protocol tags.\n",
        .{follow_context},
    );
}

pub fn toolPhaseClosedAnswer(allocator: std.mem.Allocator, follow_context: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}\n[ANSWER_REPAIR]\nThe previous visible output emitted a tool call after the tool phase was closed. Answer visibly in the user's language from USER_TASK using the collected evidence. Do not emit JSON, tool calls, <think>, </think>, or protocol tags.\n",
        .{follow_context},
    );
}

fn groundingRules() []const []const u8 {
    return initial_model_context.groundingRules();
}

test "malformed tool call repair uses active contract schema" {
    const active = contracts.activeContract(.workflow) orelse return error.MissingContract;
    const repair = try malformedToolCall(std.testing.allocator, "use uma tool se precisar", active);
    defer std.testing.allocator.free(repair);
    try std.testing.expect(std.mem.indexOf(u8, repair, "Previous visible tool_call was malformed") != null);
    try std.testing.expect(std.mem.indexOf(u8, repair, "set_operational_contract") != null);
    try std.testing.expect(std.mem.indexOf(u8, repair, "<parse_error>") == null);
}

test "persistent context repair switches or searches memory contract" {
    const workflow = contracts.activeContract(.workflow) orelse return error.MissingContract;
    const switch_repair = try persistentContextClaim(std.testing.allocator, "qual protocolo local?", workflow);
    defer std.testing.allocator.free(switch_repair);
    try std.testing.expect(std.mem.indexOf(u8, switch_repair, "contract=memory") != null);

    const memory = contracts.activeContract(.memory) orelse return error.MissingContract;
    const search_repair = try persistentContextClaim(std.testing.allocator, "qual protocolo local?", memory);
    defer std.testing.allocator.free(search_repair);
    try std.testing.expect(std.mem.indexOf(u8, search_repair, "search_persistent_context") != null);
}

test "tool step repair contexts keep narrow tool schemas" {
    const patch_contract = applyPatchOnlyContract();
    try std.testing.expect(patch_contract.allows("apply_patch"));
    try std.testing.expect(!patch_contract.allows("collect_evidence"));

    const validation_contract = validateSyntaxOnlyContract();
    try std.testing.expect(validation_contract.allows("validate_syntax"));
    try std.testing.expect(!validation_contract.allows("collect_evidence"));

    const validation_repair = try validationRequiredAfterPatch(std.testing.allocator, "corrija src/main.zig");
    defer std.testing.allocator.free(validation_repair);
    try std.testing.expect(std.mem.indexOf(u8, validation_repair, "validate_syntax") != null);
    try std.testing.expect(std.mem.indexOf(u8, validation_repair, "Patch was already applied") != null);

    const patch_followup = try patchAppliedFollowup(std.testing.allocator, "corrija src/main.zig");
    defer std.testing.allocator.free(patch_followup);
    try std.testing.expect(std.mem.indexOf(u8, patch_followup, "Validate changed code") != null);
}

test "validation and runtime followups include evidence" {
    const validation = try validationFollowup(std.testing.allocator, "corrija", "[EVIDENCE]\nstatus=ok\n");
    defer std.testing.allocator.free(validation);
    try std.testing.expect(std.mem.indexOf(u8, validation, "status=ok") != null);

    const runtime = try runtimeInspectionFollowup(std.testing.allocator, "inspecione", "[RUNTIME_INSPECTION]\nstatus=200\n");
    defer std.testing.allocator.free(runtime);
    try std.testing.expect(std.mem.indexOf(u8, runtime, "status=200") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime, "Do not claim DOM/browser automation ran") != null);
}

test "web answer repairs preserve original context" {
    const context = "[TURN_CONTEXT v1]\ntask=idioma zeta\n[WEB_DOSSIER v1]\nexcerpt=\n";
    const empty = try emptyWebEvidenceAnswer(std.testing.allocator, context);
    defer std.testing.allocator.free(empty);
    try std.testing.expect(std.mem.indexOf(u8, empty, "[EMPTY_WEB_EVIDENCE_ANSWER_REPAIR]") != null);
    try std.testing.expect(std.mem.indexOf(u8, empty, "idioma zeta") != null);

    const unsupported = try unsupportedWebAnswer(std.testing.allocator, context);
    defer std.testing.allocator.free(unsupported);
    try std.testing.expect(std.mem.indexOf(u8, unsupported, "[ANSWER_REPAIR]") != null);
    try std.testing.expect(std.mem.indexOf(u8, unsupported, "WEB_DOSSIER") != null);
}

test "finalization repair exposes active schema and blocker" {
    const active = contracts.activeContract(.collect_evidence) orelse return error.MissingContract;
    const rendered = try finalization(std.testing.allocator, "qual funcao coleta evidencia?", .{
        .active_contract = active,
        .active_schema = context_profile.activeContractSchemaFor(active.name),
        .observations = 0,
        .mutations = 0,
        .runtime_validations = 0,
        .browser_diagnostics = 0,
        .memory_promotions = 0,
        .blocker = "inspection evidence is required before finalization",
    });
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "[CONTRACTS]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "collect_evidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "inspection evidence is required") != null);
}
