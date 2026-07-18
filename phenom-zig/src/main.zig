const std = @import("std");

const audit = @import("audit.zig");
const apply_patch_tool = @import("apply_patch_tool.zig");
const cli = @import("cli.zig");
const collect_evidence = @import("collect_evidence.zig");
const context_profile = @import("context_profile.zig");
const contracts = @import("contracts.zig");
const config_file = @import("config_file.zig");
const diagnostic_runner = @import("diagnostic_runner.zig");
const evidence = @import("evidence.zig");
const fd_writer = @import("fd_writer.zig");
const gate = @import("gate.zig");
const http = @import("http.zig");
const micro_context = @import("micro_context.zig");
const model_context = @import("model_context.zig");
const persistent_context = @import("persistent_context.zig");
const product_guardrails = @import("product_guardrails.zig");
const reasoning_filter = @import("reasoning_filter.zig");
const render = @import("render.zig");
const session_context = @import("session_context.zig");
const tool_call = @import("tool_call.zig");
const tool_envelope = @import("tool_envelope.zig");
const tool_event = @import("tool_event.zig");
const tool_loop = @import("tool_loop.zig");
const tools = @import("tools.zig");
const tui = @import("tui.zig");
const ui_events = @import("ui_events.zig");
const working_context = @import("working_context.zig");

const c = @cImport({
    @cInclude("sys/stat.h");
    @cInclude("errno.h");
    @cInclude("stdlib.h");
});

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer it.deinit();

    var args_list = std.ArrayList([]const u8).empty;
    defer args_list.deinit(allocator);
    while (it.next()) |arg| {
        try args_list.append(allocator, arg);
    }

    var loaded_config = config_file.load(allocator, args_list.items) catch |err| {
        try cli.printUsage(fd_writer.FdWriter{ .fd = 2 });
        return err;
    };
    defer loaded_config.deinit(allocator);
    const config = loaded_config.config;

    switch (config.command) {
        .help => try cli.printUsage(fd_writer.FdWriter{ .fd = 1 }),
        .version => try (fd_writer.FdWriter{ .fd = 1 }).print("phenom-zig 0.2.0-dev\n", .{}),
        .chat => try runChat(allocator, init.io, config),
        .probe => try runProbe(allocator, config),
        .snapshot => try runSnapshot(),
    }
}

fn runProbe(allocator: std.mem.Allocator, config: cli.Config) !void {
    const stdout = fd_writer.FdWriter{ .fd = 1 };
    const result = http.probeBackend(allocator, config.host, config.backend);
    defer result.deinit(allocator);

    try stdout.writeAll("probe\n");
    try stdout.print("backend {s}\n", .{backendName(config.backend)});
    try stdout.print("endpoint {s}\n", .{result.endpoint});

    if (result.tcp_ok) {
        try stdout.writeAll("tcp success\n");
    } else {
        try stdout.print("tcp fail error={s}\n", .{result.error_name orelse "unknown"});
        try stdout.writeAll("result fail\n");
        std.process.exit(1);
    }

    if (result.http_ok) {
        try stdout.print("http success status={}\n", .{result.status orelse 0});
    } else {
        if (result.status) |status| {
            try stdout.print("http fail status={} error={s}\n", .{ status, result.error_name orelse "none" });
        } else {
            try stdout.print("http fail status=none error={s}\n", .{result.error_name orelse "unknown"});
        }
        try stdout.writeAll("result fail\n");
        std.process.exit(1);
    }

    if (result.server) |server| {
        try stdout.print("server {s}\n", .{server});
    }
    try stdout.writeAll("result success\n");
}

fn backendName(backend: cli.Backend) []const u8 {
    return switch (backend) {
        .ollama => "ollama",
        .llamacpp => "llamacpp",
    };
}

fn currentTerminalColumns() usize {
    return tui.terminalSize().cols;
}

fn runChat(allocator: std.mem.Allocator, io: std.Io, config: cli.Config) !void {
    const stdout = fd_writer.FdWriter{ .fd = 1 };
    if (!config.prompt_provided) return runInteractiveChat(allocator, io, config, stdout);
    try runChatTurn(allocator, io, config, stdout, config.prompt);
}

fn runInteractiveChat(allocator: std.mem.Allocator, io: std.Io, config: cli.Config, stdout: fd_writer.FdWriter) !void {
    var ui = tui.TerminalUi(@TypeOf(stdout)).init(allocator, stdout, !config.no_color);
    var attached = false;
    defer if (attached) ui.deinit();

    ui.attach() catch |err| switch (err) {
        error.NotATty => {
            try cli.printUsage(fd_writer.FdWriter{ .fd = 2 });
            return error.MissingPrompt;
        },
        else => return err,
    };
    attached = true;
    try makeDirIfMissing(".phenom-zig");
    var db = try audit.AuditDb.open(allocator, ".phenom-zig/phenom.db");
    defer db.close();
    try loadHistoryFromDb(allocator, &db, &ui);
    try ui.positionContent();
    const restored = try renderRestoredSession(allocator, &db, config.session, stdout, !config.no_color, tui.terminalSize().cols, true, ui.mutex());
    if (restored > 0) try ui.showPrompt();

    while (true) {
        const line = ui.readLine() catch |err| switch (err) {
            error.Cancelled => return,
            else => return err,
        };
        const prompt = line orelse {
            ui.deinit();
            attached = false;
            try stdout.writeAll("Session saved. Use phenom chat to continue.\n");
            return;
        };
        defer allocator.free(prompt);
        if (std.mem.trim(u8, prompt, " \t\r\n").len == 0) {
            try ui.showPrompt();
            continue;
        }
        const input = std.mem.trim(u8, prompt, " \t\r\n");
        try db.recordInputHistory(input);
        if (std.mem.eql(u8, input, "/exit")) {
            ui.deinit();
            attached = false;
            try stdout.writeAll("Session saved. Use phenom chat to continue.\n");
            return;
        }
        if (std.mem.eql(u8, input, "/reset")) {
            try ui.showPrompt();
            continue;
        }

        try ui.showStatus("Thinking");
        try ui.positionContent();
        try runChatTurnWithUi(allocator, io, config, stdout, prompt, &ui);
        try ui.showPrompt();
    }
}

fn runChatTurn(allocator: std.mem.Allocator, io: std.Io, config: cli.Config, stdout: fd_writer.FdWriter, prompt: []const u8) !void {
    try runChatTurnWithUi(allocator, io, config, stdout, prompt, null);
}

fn runChatTurnWithUi(allocator: std.mem.Allocator, io: std.Io, config: cli.Config, stdout: fd_writer.FdWriter, prompt: []const u8, ui: anytype) !void {
    const size = tui.terminalSize();
    const ui_ptr: ?*tui.TerminalUi(fd_writer.FdWriter) = ui;
    var transcript_writer = fd_writer.NewlineWriter(fd_writer.FdWriter){ .inner = stdout, .crlf = ui_ptr != null };
    var renderer = render.AppendOnlyRenderer(@TypeOf(&transcript_writer)).init(&transcript_writer, .{ .color = !config.no_color, .terminal_columns = size.cols, .user_label = userLabel() });
    var events = ui_events.EventBus.init(allocator);
    defer events.deinit();
    var render_sink = ui_events.RendererEventSink(@TypeOf(&renderer)){
        .renderer = &renderer,
        .write_mutex = if (ui_ptr) |active_ui| active_ui.mutex() else null,
        .terminal_columns = if (ui_ptr != null) currentTerminalColumns else null,
    };
    try events.on(&render_sink, @TypeOf(render_sink).handleOpaque);

    try makeDirIfMissing(".phenom-zig");
    var db = try audit.AuditDb.open(allocator, ".phenom-zig/phenom.db");
    defer db.close();

    if (ui_ptr) |active_ui| {
        active_ui.clearTokenUsage();
        active_ui.setTokenOutputLimit(config.max_tokens);
    }
    const turn_started_ms = ui_events.monotonicMillis();
    try db.recordEvent(config.session, "turn_start", prompt);
    try events.emit(.{ .user_message = prompt });
    try events.emit(.{ .think_start = "Thinking" });

    if (config.demo_read_file) |path| {
        const allowed = gate.isAllowed("read_file_range", &.{"read_file_range"});
        if (!allowed) return error.ToolDenied;
        if (ui_ptr) |active_ui| try active_ui.showStatus("Reading");
        const tool_start = try std.fmt.allocPrint(allocator, "read_file_range\t{s}", .{path});
        defer allocator.free(tool_start);
        try db.recordEvent(config.session, "tool_start", tool_start);
        try events.emit(.{ .tool_start = .{ .name = "read_file_range", .detail = path } });
        const range = try tools.readFileRange(allocator, path, 1, 12, 16 * 1024);
        defer range.deinit(allocator);
        const entry = try evidence.fromFileRange(allocator, range);
        var packet = evidence.EvidencePacket.init(allocator);
        defer packet.deinit();
        try packet.add(entry);
        const rendered = try packet.render(allocator);
        defer allocator.free(rendered);
        try db.recordEvent(config.session, "evidence", rendered);
        try events.emit(.{ .tool_result = .{ .name = "read_file_range", .output = rendered } });
        if (ui_ptr) |active_ui| try active_ui.showStatus("Thinking");
    }

    if (config.offline) {
        const response = offlineStubResponse();
        try events.emit(.{ .message_chunk = response });
        try db.recordEvent(config.session, "assistant_offline_stub", response);
        try recordAndEmitTurnDone(allocator, &db, config.session, &events, turn_started_ms, "ok", prompt, response);
    } else {
        var client = http.LocalModelClient{
            .allocator = allocator,
            .host = config.host,
            .backend = config.backend,
            .model = config.model,
            .max_tokens = config.max_tokens,
            .thinking = config.thinking,
        };
        const enable_tool_loop = true;
        var sink = StreamSink{
            .allocator = allocator,
            .events = &events,
            .db = &db,
            .session = config.session,
            .ui = ui_ptr,
            .filter = reasoning_filter.ReasoningFilter.init(allocator, http.resolveThinking(config.thinking, prompt) == .on),
            .visible = std.ArrayList(u8).empty,
            .visible_bytes = 0,
            .thinking_bytes = 0,
            .defer_visible = enable_tool_loop,
            .trim_visible_leading_whitespace = false,
        };
        defer sink.deinit();
        const model_context_text = try buildInitialModelContext(
            allocator,
            io,
            &db,
            config.session,
            prompt,
            enable_tool_loop,
        );
        defer if (model_context_text) |text| allocator.free(text);
        if (model_context_text) |text| try db.recordEvent(config.session, "model_context", text);
        if (model_context_text) |text| recordModelContextBudget(allocator, &db, config.session, text) catch |err| {
            const message = if (err == error.ModelContextBudgetExceeded)
                "context limit exceeded before model call"
            else
                @errorName(err);
            if (ui_ptr) |active_ui| try active_ui.showStatus(message);
            try events.emit(.{ .progress_update = message });
            try db.recordEvent(config.session, "model_error", @errorName(err));
            try recordAndEmitTurnDone(allocator, &db, config.session, &events, turn_started_ms, "model_context_error", prompt, sink.visible.items);
            if (config.fail_on_model_error) return err;
            return;
        };
        var dialogue_events = try db.loadRecentSessionEvents(allocator, config.session, 240);
        defer audit.freeAuditEvents(allocator, &dialogue_events);
        var dialogue_messages = try buildRecentChatMessages(allocator, dialogue_events.items, prompt);
        defer freeChatMessages(allocator, &dialogue_messages);

        const inference_input = http.InferenceInput{
            .user_prompt = prompt,
            .model_context = model_context_text,
            .dialogue = dialogue_messages.items,
        };
        client.streamInference(inference_input, &sink) catch |err| {
            const endpoint = client.endpointSummary(allocator) catch "unknown-endpoint";
            defer if (!std.mem.eql(u8, endpoint, "unknown-endpoint")) allocator.free(endpoint);
            const message = try std.fmt.allocPrint(
                allocator,
                "model connection failed: {s} endpoint={s}",
                .{ @errorName(err), endpoint },
            );
            defer allocator.free(message);
            try events.emit(.{ .progress_update = message });
            try db.recordEvent(config.session, "model_error", @errorName(err));
            try recordAndEmitTurnDone(allocator, &db, config.session, &events, turn_started_ms, "model_error", prompt, sink.visible.items);
            if (config.fail_on_model_error) return err;
            return;
        };
        try sink.flush();
        if (enable_tool_loop) {
            const handled_by_tool_loop = runToolLoopIterations(allocator, io, config, prompt, sink.raw_model.items, model_context_text, &client, &events, &db, ui_ptr, &sink) catch |err| blk: {
                const message = try std.fmt.allocPrint(allocator, "tool loop failed: {s}", .{@errorName(err)});
                defer allocator.free(message);
                try events.emit(.{ .progress_update = message });
                try db.recordEvent(config.session, "tool_loop_error", @errorName(err));
                if (config.fail_on_model_error) return err;
                break :blk true;
            };
            if (!handled_by_tool_loop) try sink.flushDeferredVisible();
        }
        if (sink.visible_bytes == 0) {
            if (ui_ptr) |active_ui| try active_ui.showStatus("no visible answer; thinking or max tokens");
            try events.emit(.{ .progress_update = "model emitted no visible final answer; reasoning was suppressed or generation ended inside <think>" });
            try db.recordEvent(config.session, "empty_visible_answer", "reasoning_suppressed_or_unclosed");
        }
        if (config.expect_contains) |expected| {
            if (std.mem.indexOf(u8, sink.visible.items, expected) == null) {
                const message = try std.fmt.allocPrint(
                    allocator,
                    "fail expected visible text missing: {s}",
                    .{expected},
                );
                defer allocator.free(message);
                try events.emit(.{ .progress_update = message });
                try db.recordEvent(config.session, "expectation_failed", expected);
                try recordAndEmitTurnDone(allocator, &db, config.session, &events, turn_started_ms, "expectation_failed", prompt, sink.visible.items);
                return error.ExpectedVisibleOutputMissing;
            }
            try db.recordEvent(config.session, "expectation_passed", expected);
            if (config.show_expect_status) {
                const message = try std.fmt.allocPrint(
                    allocator,
                    "success expected visible text found: {s}",
                    .{expected},
                );
                defer allocator.free(message);
                try events.emit(.{ .progress_update = message });
            }
        }
        try recordAndEmitTurnDone(allocator, &db, config.session, &events, turn_started_ms, "ok", prompt, sink.visible.items);
    }
}

fn recordAndEmitTurnDone(
    allocator: std.mem.Allocator,
    db: *audit.AuditDb,
    session: []const u8,
    events: *ui_events.EventBus,
    turn_started_ms: i64,
    status: []const u8,
    prompt: []const u8,
    visible: []const u8,
) !void {
    const elapsed_ms = ui_events.elapsedMillisSince(turn_started_ms);
    const quality = try buildTurnQuality(allocator, db, session, status, visible);
    defer quality.deinit(allocator);
    const body = try std.fmt.allocPrint(allocator, "status={s} elapsed_ms={} quality={s} flags={s}", .{ status, elapsed_ms, quality.quality, quality.flags });
    defer allocator.free(body);
    try db.recordEvent(session, "turn_done", body);
    try recordSessionFocusForTurn(allocator, db, session, prompt, quality.quality, quality.flags);
    try events.emit(.{ .turn_done = .{ .elapsed_ms = elapsed_ms } });
}

const TurnQuality = struct {
    quality: []u8,
    flags: []u8,

    fn deinit(self: TurnQuality, allocator: std.mem.Allocator) void {
        allocator.free(self.quality);
        allocator.free(self.flags);
    }
};

fn buildTurnQuality(
    allocator: std.mem.Allocator,
    db: *audit.AuditDb,
    session: []const u8,
    status: []const u8,
    visible: []const u8,
) !TurnQuality {
    var turn_events = try db.loadLatestTurnEvents(allocator, session, 512);
    defer audit.freeAuditEvents(allocator, &turn_events);

    const answered = std.mem.trim(u8, visible, " \t\r\n").len > 0;
    var used_session_context = false;
    var used_evidence = false;
    var used_persistent_context = false;
    var session_recall_contract = false;
    var initial_context_tool_required = false;
    for (turn_events.items) |event| {
        if (std.mem.eql(u8, event.kind, "session_context")) used_session_context = true;
        if (std.mem.eql(u8, event.kind, "evidence")) used_evidence = true;
        if (std.mem.eql(u8, event.kind, "tool_start") and std.mem.startsWith(u8, event.body, "search_session")) used_session_context = true;
        if (std.mem.eql(u8, event.kind, "tool_start") and std.mem.startsWith(u8, event.body, "collect_evidence")) used_evidence = true;
        if (std.mem.eql(u8, event.kind, "persistent_promotion")) used_persistent_context = true;
        if (std.mem.eql(u8, event.kind, "tool_start") and std.mem.startsWith(u8, event.body, "promote_context")) used_persistent_context = true;
        if (std.mem.eql(u8, event.kind, "model_context") and std.mem.indexOf(u8, event.body, "mode: session_recall") != null) session_recall_contract = true;
        if (std.mem.eql(u8, event.kind, "model_context") and initialContextRequiresTool(event.body)) initial_context_tool_required = true;
    }
    const ok_status = std.mem.eql(u8, status, "ok");
    const contract_missing_context = session_recall_contract and !used_session_context;
    const context_tool_missing = initial_context_tool_required and !used_session_context and !used_evidence and !used_persistent_context;
    const low_confidence = !ok_status or !answered or contract_missing_context;
    const effective_low_confidence = low_confidence or context_tool_missing;
    const quality: []const u8 = if (!ok_status or !answered)
        "failed"
    else if (effective_low_confidence)
        "uncertain"
    else
        "confirmed";
    const flags = try std.fmt.allocPrint(
        allocator,
        "answered={} used_session_context={} used_evidence={} used_persistent_context={} refusal=false contradicted_context=false contract_missing_context={} context_tool_missing={} low_confidence={}",
        .{ answered, used_session_context, used_evidence, used_persistent_context, contract_missing_context, context_tool_missing, effective_low_confidence },
    );
    errdefer allocator.free(flags);
    return .{
        .quality = try allocator.dupe(u8, quality),
        .flags = flags,
    };
}

fn recordSessionFocusForTurn(
    allocator: std.mem.Allocator,
    db: *audit.AuditDb,
    session: []const u8,
    prompt: []const u8,
    quality: []const u8,
    flags: []const u8,
) !void {
    const topic = try compactOperationalText(allocator, prompt, 360);
    defer allocator.free(topic);
    if (topic.len == 0) return;
    try db.recordSessionFocus(
        session,
        topic,
        "user_prompt",
        topic,
        quality,
        flags,
    );
}

fn compactOperationalText(allocator: std.mem.Allocator, text: []const u8, max_bytes: usize) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var written: usize = 0;
    var last_space = false;
    for (text) |byte| {
        if (written >= max_bytes) break;
        const normalized: u8 = switch (byte) {
            '\n', '\r', '\t' => ' ',
            else => byte,
        };
        if (normalized == ' ') {
            if (last_space) continue;
            last_space = true;
        } else {
            last_space = false;
        }
        try out.append(allocator, normalized);
        written += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn buildInitialModelContext(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *audit.AuditDb,
    session: []const u8,
    prompt: []const u8,
    enable_tool_loop: bool,
) !?[]u8 {
    const include_persistent = modelContextEnabled();
    if (!include_persistent and !enable_tool_loop) return null;

    var persistent = persistent_context.Loaded.init(allocator);
    defer persistent.deinit();
    if (include_persistent) persistent = try persistent_context.loadFromCwd(allocator, io);

    if (!enable_tool_loop and persistent.memory.items.len == 0 and persistent.skills.items.len == 0) return null;

    var session_events = try db.loadRecentSessionEvents(allocator, session, 240);
    defer audit.freeAuditEvents(allocator, &session_events);

    const focus_text = try loadMergedSessionFocus(allocator, db, session, prompt, session_events.items);
    defer if (focus_text) |text| allocator.free(text);
    const focus_blocks = try session_context.toFocusBlocks(allocator, focus_text);
    defer allocator.free(focus_blocks);

    const recent_dialogue = try session_context.renderRecentDialogue(allocator, session_events.items, prompt);
    defer if (recent_dialogue) |text| allocator.free(text);
    const dialogue_blocks = try session_context.toDialogueBlocks(allocator, recent_dialogue);
    defer allocator.free(dialogue_blocks);

    const session_blocks = try session_context.toSessionBlocks(allocator, null);
    defer allocator.free(session_blocks);
    const profile = context_profile.select(.{
        .enable_tool_loop = enable_tool_loop,
    });

    return try model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .mode = context_profile.modeName(profile),
        .contracts = context_profile.toolSchema(profile, .initial),
        .evidence = &[_]model_context.EvidenceBlock{},
        .focus = focus_blocks,
        .dialogue = dialogue_blocks,
        .session = session_blocks,
        .memory = persistent.memory.items,
        .skills = persistent.skills.items,
        .grounding = groundingRules(),
        .next_action = if (enable_tool_loop and focus_text != null)
            "SESSION_FOCUS is present. First emit exactly one context tool call before prose: use search_session for prior-session facts, or collect_evidence for workspace/source-code facts. For search_session, set intent to the evidence you want, then set terms to concrete retrieval keys from SESSION_FOCUS/current reasoning, not the user's vague wording. The controller only executes the model-chosen contract."
        else if (enable_tool_loop)
            "First emit exactly one context tool call before prose: use collect_evidence for workspace/source-code facts, search_session for prior-session facts, or set_operational_contract with all booleans false if no context evidence is needed. For collect_evidence/search_session, set intent to the evidence you want, then set terms to concrete retrieval keys from current reasoning. The controller only executes the model-chosen contract."
        else
            "Apply persistent MEMORY/SKILLS only if relevant; answer the current user request directly.",
    });
}

fn loadMergedSessionFocus(
    allocator: std.mem.Allocator,
    db: *audit.AuditDb,
    session: []const u8,
    prompt: []const u8,
    session_events: []const audit.AuditEvent,
) !?[]u8 {
    var focus_rows = try db.loadRecentSessionFocus(allocator, session, 16);
    defer audit.freeSessionFocus(allocator, &focus_rows);
    const stored_focus_text = try session_context.renderSessionFocus(allocator, focus_rows.items);
    defer if (stored_focus_text) |text| allocator.free(text);
    const fallback_focus_text = try session_context.renderFallbackSessionFocusFromEvents(allocator, session_events, prompt);
    defer if (fallback_focus_text) |text| allocator.free(text);
    const long_summary_text = try session_context.renderLongSessionSummary(allocator, session_events, prompt);
    defer if (long_summary_text) |text| allocator.free(text);
    const fallback_context_text = try session_context.mergeSessionFocus(allocator, fallback_focus_text, long_summary_text);
    defer if (fallback_context_text) |text| allocator.free(text);
    return try session_context.mergeSessionFocus(allocator, stored_focus_text, fallback_context_text);
}

const max_tool_emergency_iterations = 8;
const max_tool_repairs = 1;
const max_duplicate_tool_repairs = 1;
const max_pathless_collect_budget: usize = 6 * 1024;
const max_model_context_send_bytes: usize = 24 * 1024;
const weak_evidence_quality_score: i32 = 64;

const ToolLoopNext = union(enum) {
    final_answer,
    tool_call: tool_call.ToolCall,
    stopped,
};

fn runToolLoopIterations(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: cli.Config,
    prompt: []const u8,
    model_output: []const u8,
    initial_context: ?[]const u8,
    client: *http.LocalModelClient,
    events: *ui_events.EventBus,
    db: *audit.AuditDb,
    ui_ptr: ?*tui.TerminalUi(fd_writer.FdWriter),
    first_sink: *StreamSink,
) !bool {
    var state = ToolLoopState.init(allocator);
    defer state.deinit();
    var maybe_envelope = tool_envelope.parseFirst(allocator, model_output, state.active_contract) catch |err| {
        try db.recordEvent(config.session, "tool_envelope_error", @errorName(err));
        return true;
    };
    if (maybe_envelope == null and initialContextRequiresTool(initial_context)) {
        first_sink.discardDeferredVisible();
        try db.recordEvent(config.session, "tool_repair", "initial context tool call missing");
        const repair_context = try renderInitialToolCallRepairContext(allocator, initial_context.?);
        defer allocator.free(repair_context);
        try db.recordEvent(config.session, "model_context", repair_context);
        const next = try streamDeferredRequiredToolLoopTurn(
            allocator,
            config,
            prompt,
            repair_context,
            "Your previous output was prose, but this turn requires a visible context tool_call before prose. Output exactly one collect_evidence, search_session, or set_operational_contract tool_call now. No prose.",
            client,
            events,
            db,
            ui_ptr,
            first_sink,
            state.active_contract,
        );
        switch (next) {
            .final_answer => return true,
            .stopped => return true,
            .tool_call => |next_call| {
                maybe_envelope = try tool_envelope.ToolCallEnvelope.fromAcceptedCall(allocator, state.active_contract, next_call);
            },
        }
    }
    if (maybe_envelope == null) return false;

    var tool_iterations: usize = 0;
    var repairs: usize = 0;
    while (maybe_envelope) |envelope_value| {
        var envelope = envelope_value;
        defer envelope.deinit(allocator);
        const envelope_audit = try envelope.renderAudit(allocator);
        defer allocator.free(envelope_audit);
        try db.recordEvent(config.session, "tool_envelope", envelope_audit);

        if (envelope.state == .rejected) {
            const body = try std.fmt.allocPrint(allocator, "{s}\t{s}", .{ envelope.raw_name, envelope.auditText() });
            defer allocator.free(body);
            try db.recordEvent(config.session, "tool_rejected", body);
            return true;
        }

        var call = envelope.takeCall() orelse {
            try db.recordEvent(config.session, "tool_rejected", "accepted envelope without call");
            return true;
        };
        defer call.deinit(allocator);

        const next = try runOneToolLoopStep(
            allocator,
            io,
            config,
            prompt,
            &call,
            client,
            events,
            db,
            ui_ptr,
            first_sink,
            &state,
            &tool_iterations,
            &repairs,
        );
        switch (next) {
            .final_answer => return true,
            .stopped => return true,
            .tool_call => |next_call| {
                maybe_envelope = try tool_envelope.ToolCallEnvelope.fromAcceptedCall(allocator, state.active_contract, next_call);
                continue;
            },
        }
    }
    return true;
}

fn initialContextRequiresTool(context: ?[]const u8) bool {
    const text = context orelse return false;
    return std.mem.indexOf(u8, text, "First emit exactly one context tool call before prose") != null;
}

fn renderInitialToolCallRepairContext(allocator: std.mem.Allocator, initial_context: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}\n[PROTOCOL_REPAIR]\nYour previous output was prose, but this turn requires a context tool call before prose. Emit exactly one tool_call now. For collect_evidence/search_session, set <parameter=intent> to the evidence you want to recover and <parameter=terms> to concrete retrieval keys from current reasoning/SESSION_FOCUS; do not copy the user's vague wording or schema placeholders. For code identity, emit collect_evidence with stage=candidates before expanding a selected candidate.\n",
        .{initial_context},
    );
}

fn renderCollectEvidenceSearchIntentRepairContext(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    contracts_text: []const u8,
) ![]u8 {
    return model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .contracts = contracts_text,
        .obligations = &.{
            "A pathless collect_evidence call must include <parameter=intent>what source-code evidence you want</parameter> and <parameter=terms>concrete retrieval keys for that intent</parameter>.",
            "The controller does not infer search terms from the user prompt. The model must choose the search intent and keys before evidence collection.",
        },
        .grounding = groundingRules(),
        .next_action = "Emit one corrected collect_evidence tool call with path, or with intent+terms and a valid strategy. Use strategy=symbol/lexical/auto according to the evidence you intend to recover.",
    });
}

fn runOneToolLoopStep(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: cli.Config,
    prompt: []const u8,
    call: *const tool_call.ToolCall,
    client: *http.LocalModelClient,
    events: *ui_events.EventBus,
    db: *audit.AuditDb,
    ui_ptr: ?*tui.TerminalUi(fd_writer.FdWriter),
    aggregate_sink: *StreamSink,
    state: *ToolLoopState,
    tool_iterations: *usize,
    repairs: *usize,
) !ToolLoopNext {
    if (!gate.isAllowed(call.name, state.active_contract.allowed_tools)) {
        try db.recordEvent(config.session, "tool_rejected", call.name);
        return .stopped;
    }
    if (std.mem.eql(u8, call.name, "set_operational_contract")) {
        return try runSetOperationalContractStep(allocator, config, prompt, call, client, events, db, ui_ptr, aggregate_sink, state, tool_iterations);
    }
    if (std.mem.eql(u8, call.name, "search_session")) {
        return try runSearchSessionStep(allocator, config, prompt, call, client, events, db, ui_ptr, aggregate_sink, state, tool_iterations);
    }
    if (std.mem.eql(u8, call.name, "apply_patch")) {
        return try runApplyPatchStep(allocator, io, config, prompt, call, client, events, db, ui_ptr, aggregate_sink, state, tool_iterations);
    }
    if (std.mem.eql(u8, call.name, "validate_syntax")) {
        return try runValidateSyntaxStep(allocator, config, prompt, call, client, events, db, ui_ptr, aggregate_sink, state, tool_iterations);
    }
    if (std.mem.eql(u8, call.name, "inspect_runtime")) {
        return try runInspectRuntimeStep(allocator, config, prompt, call, client, events, db, ui_ptr, aggregate_sink, state, tool_iterations);
    }
    if (std.mem.eql(u8, call.name, "promote_context")) {
        return try runPromoteContextStep(allocator, io, config, prompt, call, client, events, db, ui_ptr, aggregate_sink, state, tool_iterations);
    }
    if (!std.mem.eql(u8, call.name, "collect_evidence")) {
        try db.recordEvent(config.session, "tool_rejected", call.name);
        return .stopped;
    }

    if (isCollectEvidenceStage(call, "expand")) {
        return try runCollectEvidenceExpandStep(allocator, io, config, prompt, call, client, events, db, ui_ptr, aggregate_sink, state, tool_iterations);
    }

    const repaired_path = if (call.path == null) try singleStructuredPathFromPrompt(allocator, prompt) else null;
    defer if (repaired_path) |owned| allocator.free(owned);
    if (repaired_path) |owned| {
        const body = try std.fmt.allocPrint(allocator, "collect_evidence path<-prompt_structured_path {s}", .{owned});
        defer allocator.free(body);
        try db.recordEvent(config.session, "tool_arg_repair", body);
    }

    const path = call.path orelse repaired_path;
    const strategy = if (call.path == null and repaired_path != null and (call.strategy == null or call.strategy.? == .auto))
        contracts.StrategyName.path
    else
        call.strategy orelse if (path == null) contracts.StrategyName.auto else contracts.StrategyName.path;
    if (path == null and (strategy == .path or strategy == .diagnostic)) {
        if (repairs.* >= max_tool_repairs) {
            try db.recordEvent(config.session, "tool_rejected", "collect_evidence missing path after repair");
            return .stopped;
        }
        repairs.* += 1;
        try db.recordEvent(config.session, "tool_repair", "collect_evidence missing path");
        try events.emit(.{ .progress_update = "repairing tool call: collect_evidence requires path" });
        const repair_context = try model_context.renderModelTurnContext(allocator, .{
            .task = prompt,
            .contracts = if (state.contract_selected)
                activeToolSchema(state)
            else
                context_profile.toolSchema(.code_evidence, .initial),
            .obligations = &.{
                "This collect_evidence strategy must include <parameter=path>relative/file</parameter>.",
                "Do not answer with prose until evidence is collected or you decide evidence is unnecessary.",
            },
            .next_action = "Emit one corrected collect_evidence tool call with path, or answer directly if no file evidence is needed.",
        });
        defer allocator.free(repair_context);
        try db.recordEvent(config.session, "model_context", repair_context);
        return try streamDeferredToolLoopTurn(allocator, config, prompt, repair_context, client, events, db, ui_ptr, aggregate_sink, state.active_contract);
    }

    if (collectEvidenceNeedsSearchIntentRepair(call, path, strategy)) {
        if (repairs.* >= max_tool_repairs) {
            try db.recordEvent(config.session, "tool_rejected", "collect_evidence missing intent/terms after repair");
            return .stopped;
        }
        repairs.* += 1;
        try db.recordEvent(config.session, "tool_repair", "collect_evidence missing intent/terms");
        try events.emit(.{ .progress_update = "repairing tool call: collect_evidence requires search intent" });
        const repair_context = try renderCollectEvidenceSearchIntentRepairContext(
            allocator,
            prompt,
            if (state.contract_selected)
                activeToolSchema(state)
            else
                context_profile.toolSchema(.code_evidence, .initial),
        );
        defer allocator.free(repair_context);
        try db.recordEvent(config.session, "model_context", repair_context);
        return try streamDeferredRequiredToolLoopTurn(
            allocator,
            config,
            prompt,
            repair_context,
            "Your previous output did not provide the required corrected collect_evidence call. Output exactly one visible collect_evidence tool_call with path, or with intent+terms and strategy=auto|lexical|symbol. No prose.",
            client,
            events,
            db,
            ui_ptr,
            aggregate_sink,
            state.active_contract,
        );
    }

    if (isCollectEvidenceStage(call, "candidates")) {
        return try runCollectEvidenceCandidatesStep(allocator, io, config, prompt, call, client, events, db, ui_ptr, aggregate_sink, state, tool_iterations, strategy);
    }

    if (state.hasExecutedArgs(path, call.terms, strategy, call.start_line, call.max_lines)) {
        if (call.compact) {
            state.context.compactAll();
            try db.recordEvent(config.session, "working_context_compact", "duplicate compact=true");
        }
        if (state.duplicate_repairs >= max_duplicate_tool_repairs) {
            try db.recordEvent(config.session, "tool_loop_stop", "duplicate collect_evidence repeated after repair");
            return .stopped;
        }
        state.duplicate_repairs += 1;
        const duplicate_body = try std.fmt.allocPrint(allocator, "collect_evidence\t{s}", .{path orelse @tagName(strategy)});
        defer allocator.free(duplicate_body);
        try db.recordEvent(config.session, "tool_duplicate", duplicate_body);
        try db.recordEvent(config.session, "working_context_duplicate", duplicate_body);
        try events.emit(.{ .progress_update = "skipping duplicate collect_evidence; answering with existing evidence" });

        const duplicate_context = try renderCollectedEvidenceContext(
            allocator,
            prompt,
            &state.context,
            null,
            null,
            context_profile.toolSchema(.code_evidence, .after_collect_evidence),
            "The requested evidence was already collected in this turn. Answer now using the evidence above. Do not call tools again.",
        );
        defer allocator.free(duplicate_context);
        try db.recordEvent(config.session, "model_context", duplicate_context);
        return try streamDeferredToolLoopTurn(allocator, config, prompt, duplicate_context, client, events, db, ui_ptr, aggregate_sink, state.active_contract);
    }

    if (tool_iterations.* >= max_tool_emergency_iterations or !state.hasBudgetForMoreEvidence()) {
        try db.recordEvent(config.session, "tool_loop_stop", "evidence budget exhausted");
        try db.recordEvent(config.session, "working_context_budget", "evidence budget exhausted");
        return .stopped;
    }
    tool_iterations.* += 1;

    if (ui_ptr) |active_ui| try active_ui.showStatus("Reading");
    const tool_start = try renderCollectEvidenceAuditKey(allocator, path, call.intent, call.terms, strategy);
    defer allocator.free(tool_start);
    try db.recordEvent(config.session, "tool_start", tool_start);
    try events.emit(.{ .tool_start = .{ .name = "collect_evidence", .detail = path orelse @tagName(strategy) } });

    const result = collect_evidence.execute(allocator, io, .{
        .path = path,
        .intent = call.intent,
        .need = call.need,
        .terms = call.terms,
        .target_files = call.target_files,
        .scope_root = call.scope_root,
        .task = prompt,
        .strategy = strategy,
        .start_line = call.start_line,
        .max_lines = if (isCollectEvidenceStage(call, "minimum")) @min(call.max_lines, @as(usize, 8)) else call.max_lines,
        .budget_bytes = collectEvidenceExecutionBudget(path, state.remainingBudget()),
    }) catch |err| {
        try db.recordEvent(config.session, "tool_error", @errorName(err));
        try events.emit(.{ .tool_result = .{ .name = "collect_evidence", .output = @errorName(err) } });
        const follow_context = try renderCollectedEvidenceContext(
            allocator,
            prompt,
            &state.context,
            null,
            null,
            context_profile.toolSchema(.code_evidence, .after_collect_evidence),
            "collect_evidence encountered an error. Answer the current user request directly.",
        );
        defer allocator.free(follow_context);
        try db.recordEvent(config.session, "model_context", follow_context);
        return try streamDeferredToolLoopTurn(allocator, config, prompt, follow_context, client, events, db, ui_ptr, aggregate_sink, state.active_contract);
    };
    defer result.deinit(allocator);

    const model_evidence = try renderEvidenceAndMicroContext(allocator, result.evidence_text, result.micro_context_text);
    defer allocator.free(model_evidence);
    try db.recordEvent(config.session, "tool_event", result.tool_event_audit_text);
    try db.recordEvent(config.session, "evidence", model_evidence);
    try events.emit(.{ .tool_result = .{ .name = "collect_evidence", .output = model_evidence } });
    try state.rememberExecutedArgs(path, call.terms, strategy, call.start_line, call.max_lines, result.context_id, model_evidence, result.model_bytes, result.quality_score);
    const working_add = try std.fmt.allocPrint(
        allocator,
        "path={s} terms_bytes={} strategy={s} compact={} model_bytes={} quality={}",
        .{ path orelse "<auto>", if (call.terms) |terms| terms.len else 0, @tagName(strategy), call.compact, result.model_bytes, result.quality_score },
    );
    defer allocator.free(working_add);
    try db.recordEvent(config.session, "working_context_add", working_add);
    if (call.compact) {
        state.context.compactAll();
        try db.recordEvent(config.session, "working_context_compact", "collect_evidence compact=true");
    }

    const follow_context = try renderCollectedEvidenceContext(
        allocator,
        prompt,
        &state.context,
        null,
        null,
        if (state.shouldAllowMoreEvidence())
            activeToolSchema(state)
        else
            context_profile.toolSchema(.code_evidence, .after_collect_evidence),
        if (state.shouldAllowMoreEvidence() and result.quality_score < weak_evidence_quality_score)
            "The collected workspace evidence is weak or generic. Emit one refined collect_evidence call before answering: use stage=candidates for ambiguous source-code questions, choose concrete symbol/path/error terms from the evidence and task, and do not request the same terms again."
        else if (state.shouldAllowMoreEvidence())
            "Answer using only cited evidence above. Cite E# for workspace claims and S# for session claims. Do not add capabilities, files, tools, or architecture not present in evidence. If the user asks which function/type/file and the identifier is not present in E#, emit one refined collect_evidence call with intent+terms instead of guessing. Do not request the same file/range/session terms again."
        else
            "Answer the current user request using only cited evidence above. Do not add capabilities, files, tools, architecture, or prior-session facts not present in evidence. If evidence is insufficient, say what is evidenced and what is not. Do not call tools again in this turn.",
    );
    defer allocator.free(follow_context);
    try db.recordEvent(config.session, "model_context", follow_context);

    return try streamDeferredToolLoopTurn(allocator, config, prompt, follow_context, client, events, db, ui_ptr, aggregate_sink, state.active_contract);
}

fn collectEvidenceNeedsSearchIntentRepair(
    call: *const tool_call.ToolCall,
    effective_path: ?[]const u8,
    strategy: contracts.StrategyName,
) bool {
    if (effective_path != null or strategy == .path) return false;
    if (call.intent == null or isSchemaPlaceholderText(call.intent.?)) return true;
    if (!collectEvidenceHasSearchTerms(call)) return true;
    if (call.terms) |value| if (isSchemaPlaceholderText(value)) return true;
    if (call.need) |value| if (isSchemaPlaceholderText(value)) return true;
    if (call.target_files) |value| if (isSchemaPlaceholderText(value)) return true;
    if (call.scope_root) |value| if (isSchemaPlaceholderText(value)) return true;
    return false;
}

fn collectEvidenceHasSearchTerms(call: *const tool_call.ToolCall) bool {
    return hasNonEmptyText(call.terms) or hasNonEmptyText(call.need) or hasNonEmptyText(call.target_files) or hasNonEmptyText(call.scope_root);
}

fn hasNonEmptyText(value: ?[]const u8) bool {
    const text = std.mem.trim(u8, value orelse return false, " \t\r\n");
    return text.len > 0;
}

fn isSchemaPlaceholderText(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const placeholders = [_][]const u8{
        "specific retrieval keys",
        "specific keys",
        "evidence to recover",
        "SymbolName FileName ErrorCode",
        "TopicName EntityName DecisionKey",
        "ConcreteSymbolOrPathTerms",
        "target files",
        "scope root",
    };
    for (placeholders) |placeholder| {
        if (std.ascii.eqlIgnoreCase(trimmed, placeholder)) return true;
    }
    return false;
}

fn collectEvidenceExecutionBudget(path: ?[]const u8, remaining_budget: usize) usize {
    if (path != null) return remaining_budget;
    return @min(remaining_budget, max_pathless_collect_budget);
}

fn isCollectEvidenceStage(call: *const tool_call.ToolCall, stage: []const u8) bool {
    const raw = call.stage orelse return false;
    return std.ascii.eqlIgnoreCase(raw, stage);
}

fn runCollectEvidenceCandidatesStep(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: cli.Config,
    prompt: []const u8,
    call: *const tool_call.ToolCall,
    client: *http.LocalModelClient,
    events: *ui_events.EventBus,
    db: *audit.AuditDb,
    ui_ptr: ?*tui.TerminalUi(fd_writer.FdWriter),
    aggregate_sink: *StreamSink,
    state: *ToolLoopState,
    tool_iterations: *usize,
    strategy: contracts.StrategyName,
) !ToolLoopNext {
    if (tool_iterations.* >= max_tool_emergency_iterations or !state.hasBudgetForMoreEvidence()) {
        try db.recordEvent(config.session, "tool_loop_stop", "candidate budget exhausted");
        return .stopped;
    }
    tool_iterations.* += 1;

    if (ui_ptr) |active_ui| try active_ui.showStatus("Reading");
    const tool_start = try std.fmt.allocPrint(allocator, "collect_evidence\tstage=candidates strategy={s} intent_bytes={} terms_bytes={}", .{
        @tagName(strategy),
        if (call.intent) |value| value.len else 0,
        if (call.terms) |value| value.len else 0,
    });
    defer allocator.free(tool_start);
    try db.recordEvent(config.session, "tool_start", tool_start);
    try events.emit(.{ .tool_start = .{ .name = "collect_evidence", .detail = "candidates" } });

    var result = collect_evidence.executeCandidates(allocator, io, .{
        .intent = call.intent,
        .need = call.need,
        .terms = call.terms,
        .target_files = call.target_files,
        .scope_root = call.scope_root,
        .task = prompt,
        .strategy = strategy,
        .budget_bytes = collectEvidenceExecutionBudget(null, state.remainingBudget()),
    }) catch |err| {
        try db.recordEvent(config.session, "tool_error", @errorName(err));
        try events.emit(.{ .tool_result = .{ .name = "collect_evidence", .output = @errorName(err) } });
        return .stopped;
    };
    defer result.deinit(allocator);

    try state.rememberCandidates(&result);
    try db.recordEvent(config.session, "tool_event", result.audit_text);
    try db.recordEvent(config.session, "candidate_context", result.text);
    try events.emit(.{ .tool_result = .{ .name = "collect_evidence", .output = result.text } });

    const candidate_block = [_]model_context.CandidateBlock{.{ .text = result.text }};
    const follow_context = try model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .contracts = context_profile.candidateExpandSchema(),
        .candidates = &candidate_block,
        .grounding = groundingRules(),
        .next_action = "Output exactly one visible XML tool_call now: collect_evidence stage=expand selectedCandidate=C#. Do not answer in prose. Do not put the tool_call only in thinking.",
    });
    defer allocator.free(follow_context);
    try db.recordEvent(config.session, "model_context", follow_context);
    return try streamDeferredRequiredToolLoopTurn(
        allocator,
        config,
        prompt,
        follow_context,
        "Your previous output did not provide the required visible XML tool_call. Output exactly one collect_evidence tool_call with stage=expand and selectedCandidate=C# now. No prose.",
        client,
        events,
        db,
        ui_ptr,
        aggregate_sink,
        state.active_contract,
    );
}

fn runCollectEvidenceExpandStep(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: cli.Config,
    prompt: []const u8,
    call: *const tool_call.ToolCall,
    client: *http.LocalModelClient,
    events: *ui_events.EventBus,
    db: *audit.AuditDb,
    ui_ptr: ?*tui.TerminalUi(fd_writer.FdWriter),
    aggregate_sink: *StreamSink,
    state: *ToolLoopState,
    tool_iterations: *usize,
) !ToolLoopNext {
    const selected = call.selected_candidate orelse firstSelectedCandidate(call.selected_candidates) orelse {
        try db.recordEvent(config.session, "tool_repair", "collect_evidence expand missing selectedCandidate");
        const repair_context = try renderCandidateSelectionContext(
            allocator,
            prompt,
            state,
            "Emit collect_evidence with stage=expand and selectedCandidate=C# from the provided candidates.",
        );
        defer allocator.free(repair_context);
        try db.recordEvent(config.session, "model_context", repair_context);
        return try streamDeferredRequiredToolLoopTurn(
            allocator,
            config,
            prompt,
            repair_context,
            "Emit exactly one collect_evidence tool call with stage=expand and selectedCandidate=C#.",
            client,
            events,
            db,
            ui_ptr,
            aggregate_sink,
            state.active_contract,
        );
    };
    const candidate = state.findCandidate(selected) orelse {
        try db.recordEvent(config.session, "tool_rejected", "collect_evidence unknown selectedCandidate");
        const repair_context = try renderCandidateSelectionContext(
            allocator,
            prompt,
            state,
            "selectedCandidate was not in the provided C# list. Emit collect_evidence stage=expand with one visible C# candidate, or emit stage=candidates again with refined intent+terms.",
        );
        defer allocator.free(repair_context);
        try db.recordEvent(config.session, "model_context", repair_context);
        return try streamDeferredRequiredToolLoopTurn(
            allocator,
            config,
            prompt,
            repair_context,
            "Emit exactly one collect_evidence tool call with a visible selectedCandidate=C#, or stage=candidates with refined intent+terms.",
            client,
            events,
            db,
            ui_ptr,
            aggregate_sink,
            state.active_contract,
        );
    };

    if (tool_iterations.* >= max_tool_emergency_iterations or !state.hasBudgetForMoreEvidence()) {
        try db.recordEvent(config.session, "tool_loop_stop", "expand budget exhausted");
        return .stopped;
    }
    tool_iterations.* += 1;

    const max_lines = if (call.max_lines == 12)
        @min(@as(usize, 32), candidate.end_line - candidate.start_line + 1)
    else
        call.max_lines;
    if (state.hasExecutedArgs(candidate.path, call.terms, .path, candidate.start_line, max_lines)) {
        try db.recordEvent(config.session, "tool_loop_stop", "duplicate candidate expansion");
        return .stopped;
    }

    if (ui_ptr) |active_ui| try active_ui.showStatus("Reading");
    const tool_start = try std.fmt.allocPrint(allocator, "collect_evidence\tstage=expand selected={s} path={s}", .{ selected, candidate.path });
    defer allocator.free(tool_start);
    try db.recordEvent(config.session, "tool_start", tool_start);
    try events.emit(.{ .tool_start = .{ .name = "collect_evidence", .detail = candidate.path } });

    const result = collect_evidence.execute(allocator, io, .{
        .path = candidate.path,
        .terms = call.terms,
        .task = prompt,
        .strategy = .path,
        .start_line = candidate.start_line,
        .max_lines = max_lines,
        .budget_bytes = collectEvidenceExecutionBudget(candidate.path, state.remainingBudget()),
    }) catch |err| {
        try db.recordEvent(config.session, "tool_error", @errorName(err));
        try events.emit(.{ .tool_result = .{ .name = "collect_evidence", .output = @errorName(err) } });
        return .stopped;
    };
    defer result.deinit(allocator);

    const model_evidence = try renderEvidenceAndMicroContext(allocator, result.evidence_text, result.micro_context_text);
    defer allocator.free(model_evidence);
    try db.recordEvent(config.session, "tool_event", result.tool_event_audit_text);
    try db.recordEvent(config.session, "evidence", model_evidence);
    try events.emit(.{ .tool_result = .{ .name = "collect_evidence", .output = model_evidence } });
    try state.rememberExecutedArgs(candidate.path, call.terms, .path, candidate.start_line, max_lines, result.context_id, model_evidence, result.model_bytes, result.quality_score);

    const follow_context = try renderCollectedEvidenceContext(
        allocator,
        prompt,
        &state.context,
        null,
        null,
        if (state.shouldAllowMoreEvidence())
            activeToolSchema(state)
        else
            context_profile.toolSchema(.code_evidence, .after_collect_evidence),
        if (state.shouldAllowMoreEvidence() and result.quality_score < weak_evidence_quality_score)
            "The expanded candidate evidence is weak or generic. Emit one more collect_evidence call with a different selectedCandidate or refined intent+terms before answering."
        else
            "Answer using only cited E# evidence from the expanded candidate. If evidence is insufficient and budget remains, emit one more collect_evidence call with a different selectedCandidate or refined intent+terms.",
    );
    defer allocator.free(follow_context);
    try db.recordEvent(config.session, "model_context", follow_context);
    return try streamDeferredToolLoopTurn(allocator, config, prompt, follow_context, client, events, db, ui_ptr, aggregate_sink, state.active_contract);
}

fn firstSelectedCandidate(selected_candidates: ?[]const u8) ?[]const u8 {
    var raw = selected_candidates orelse return null;
    raw = std.mem.trim(u8, raw, " \t\r\n");
    if (raw.len == 0) return null;
    var it = std.mem.tokenizeAny(u8, raw, " ,;\t\r\n");
    return it.next();
}

fn renderCandidateSelectionContext(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    state: *const ToolLoopState,
    next_action: []const u8,
) ![]u8 {
    if (state.last_candidate_context) |candidate_context| {
        const candidate_block = [_]model_context.CandidateBlock{.{ .text = candidate_context }};
        return model_context.renderModelTurnContext(allocator, .{
            .task = prompt,
            .contracts = context_profile.candidateExpandSchema(),
            .candidates = &candidate_block,
            .grounding = groundingRules(),
            .next_action = next_action,
        });
    }
    return model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .contracts = activeToolSchema(state),
        .obligations = &.{
            "No candidate list is active in this turn.",
            "Do not guess a selectedCandidate that was not returned by collect_evidence stage=candidates.",
        },
        .grounding = groundingRules(),
        .next_action = "Emit collect_evidence with stage=candidates, intent, terms, and strategy=symbol|lexical before any expand call.",
    });
}

fn runSetOperationalContractStep(
    allocator: std.mem.Allocator,
    config: cli.Config,
    prompt: []const u8,
    call: *const tool_call.ToolCall,
    client: *http.LocalModelClient,
    events: *ui_events.EventBus,
    db: *audit.AuditDb,
    ui_ptr: ?*tui.TerminalUi(fd_writer.FdWriter),
    aggregate_sink: *StreamSink,
    state: *ToolLoopState,
    tool_iterations: *usize,
) !ToolLoopNext {
    if (tool_iterations.* >= max_tool_emergency_iterations) {
        try db.recordEvent(config.session, "tool_loop_stop", "contract budget exhausted");
        return .stopped;
    }
    tool_iterations.* += 1;

    if (state.contract_selected) {
        if (state.duplicate_contract_repairs >= max_duplicate_tool_repairs) {
            try db.recordEvent(config.session, "tool_loop_stop", "duplicate set_operational_contract repeated after repair");
            return .stopped;
        }
        state.duplicate_contract_repairs += 1;
        try db.recordEvent(config.session, "contract_duplicate", "set_operational_contract");
        const duplicate_context = try model_context.renderModelTurnContext(allocator, .{
            .task = prompt,
            .contracts = activeToolSchema(state),
            .obligations = &.{
                "The operational contract was already selected in this turn.",
                "Do not call set_operational_contract again unless a later tool result changes the operational need.",
            },
            .grounding = groundingRules(),
            .next_action = "Continue inside the existing contract. Call collect_evidence/search_session if evidence is needed, otherwise answer the user now.",
        });
        defer allocator.free(duplicate_context);
        try db.recordEvent(config.session, "model_context", duplicate_context);
        return try streamDeferredToolLoopTurn(allocator, config, prompt, duplicate_context, client, events, db, ui_ptr, aggregate_sink, state.active_contract);
    }

    if (call.requires_inspection == null or
        call.requires_mutation == null or
        call.requires_runtime_validation == null or
        call.requires_browser_diagnostics == null)
    {
        try db.recordEvent(config.session, "tool_repair", "set_operational_contract missing required booleans");
        const repair_context = try model_context.renderModelTurnContext(allocator, .{
            .task = prompt,
            .contracts = context_profile.toolSchema(.code_evidence, .initial),
            .obligations = &.{
                "set_operational_contract requires requiresInspection, requiresMutation, requiresRuntimeValidation, and requiresBrowserDiagnostics.",
            },
            .next_action = "Emit one corrected set_operational_contract call with all required boolean fields, or call collect_evidence if inspection is enough.",
        });
        defer allocator.free(repair_context);
        try db.recordEvent(config.session, "model_context", repair_context);
        return try streamDeferredToolLoopTurn(allocator, config, prompt, repair_context, client, events, db, ui_ptr, aggregate_sink, state.active_contract);
    }

    const request = contracts.OperationalContractRequest{
        .requires_inspection = call.requires_inspection.?,
        .requires_mutation = call.requires_mutation.?,
        .requires_runtime_validation = call.requires_runtime_validation.?,
        .requires_browser_diagnostics = call.requires_browser_diagnostics.?,
        .requires_memory_promotion = call.requires_memory_promotion orelse false,
    };
    const selected_name = contracts.selectOperationalContract(request);
    const selected = contracts.activeContract(selected_name) orelse return error.MissingContract;
    state.active_contract = selected;
    state.contract_selected = true;

    const allowed = try renderAllowedTools(allocator, selected.allowed_tools);
    defer allocator.free(allowed);
    const audit_body = try std.fmt.allocPrint(
        allocator,
        "contract={s} requiresInspection={} requiresMutation={} requiresRuntimeValidation={} requiresBrowserDiagnostics={} allowed_tools={s} reason={s}",
        .{
            @tagName(selected.name),
            request.requires_inspection,
            request.requires_mutation,
            request.requires_runtime_validation,
            request.requires_browser_diagnostics,
            allowed,
            call.reason orelse "",
        },
    );
    defer allocator.free(audit_body);
    try db.recordEvent(config.session, "contract_selected", audit_body);
    try events.emit(.{ .tool_start = .{ .name = "set_operational_contract", .detail = @tagName(selected.name) } });
    try events.emit(.{ .tool_result = .{ .name = "set_operational_contract", .output = audit_body } });

    const follow_context = try model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .contracts = activeToolSchema(state),
        .obligations = &.{
            "The operational contract is now active for this turn.",
            "Only advertised tools may be called. The controller rejects tools outside the selected contract.",
        },
        .grounding = groundingRules(),
        .next_action = "Proceed inside the active contract. If workspace evidence is needed, call collect_evidence with model-chosen terms/path. If mutating from collected context, include contextId in apply_patch.",
    });
    defer allocator.free(follow_context);
    try db.recordEvent(config.session, "model_context", follow_context);
    return try streamDeferredToolLoopTurn(allocator, config, prompt, follow_context, client, events, db, ui_ptr, aggregate_sink, state.active_contract);
}

fn runApplyPatchStep(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: cli.Config,
    prompt: []const u8,
    call: *const tool_call.ToolCall,
    client: *http.LocalModelClient,
    events: *ui_events.EventBus,
    db: *audit.AuditDb,
    ui_ptr: ?*tui.TerminalUi(fd_writer.FdWriter),
    aggregate_sink: *StreamSink,
    state: *ToolLoopState,
    tool_iterations: *usize,
) !ToolLoopNext {
    if (tool_iterations.* >= max_tool_emergency_iterations) return .stopped;
    tool_iterations.* += 1;

    const path = call.path orelse return try repairPatchCall(allocator, config, prompt, client, events, db, ui_ptr, aggregate_sink, state, "apply_patch requires path.");
    const operation = parsePatchOperation(call.operation) catch return try repairPatchCall(allocator, config, prompt, client, events, db, ui_ptr, aggregate_sink, state, "apply_patch operation must be edit, create, delete, or rename.");
    const patch_args = buildPatchArgs(allocator, operation, path, call) catch |err| {
        return try repairPatchCall(allocator, config, prompt, client, events, db, ui_ptr, aggregate_sink, state, @errorName(err));
    };
    defer if (patch_args.hunks.len > 0) allocator.free(patch_args.hunks);

    if (ui_ptr) |active_ui| try active_ui.showStatus("Writing");
    const tool_start = try std.fmt.allocPrint(allocator, "apply_patch operation={s} path={s}", .{ @tagName(operation), path });
    defer allocator.free(tool_start);
    try db.recordEvent(config.session, "tool_start", tool_start);
    try events.emit(.{ .tool_start = .{ .name = "apply_patch", .detail = path } });

    const result = apply_patch_tool.execute(allocator, io, patch_args, &state.context) catch |err| {
        try db.recordEvent(config.session, "tool_error", @errorName(err));
        try events.emit(.{ .tool_result = .{ .name = "apply_patch", .output = @errorName(err) } });
        const repair_context = try model_context.renderModelTurnContext(allocator, .{
            .task = prompt,
            .contracts = activeToolSchema(state),
            .obligations = &.{
                "Patch failed. If the context is stale, recollect evidence before another patch.",
                "For edit, every search must be exact and unique in the original file. For delete/rename, include fresh contextId.",
            },
            .grounding = groundingRules(),
            .next_action = "Emit one corrected apply_patch call, or collect_evidence again if context is stale.",
        });
        defer allocator.free(repair_context);
        try db.recordEvent(config.session, "model_context", repair_context);
        return try streamDeferredToolLoopTurn(allocator, config, prompt, repair_context, client, events, db, ui_ptr, aggregate_sink, state.active_contract);
    };
    defer result.deinit(allocator);

    try db.recordEvent(config.session, "tool_event", result.audit_text);
    try db.recordEvent(config.session, "patch_result", result.text);
    try events.emit(.{ .tool_result = .{ .name = "apply_patch", .output = result.text } });

    const follow_context = try model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .contracts = context_profile.activeContractSchemaFor(.validate_work),
        .obligations = &.{
            "Patch has been applied. Validate changed code when possible before final answer.",
        },
        .grounding = groundingRules(),
        .next_action = "Call validate_syntax for changed Zig files, or answer with the patch result if validation is not applicable.",
    });
    defer allocator.free(follow_context);
    try db.recordEvent(config.session, "model_context", follow_context);
    state.active_contract = contracts.activeContract(.validate_work).?;
    return try streamDeferredToolLoopTurn(allocator, config, prompt, follow_context, client, events, db, ui_ptr, aggregate_sink, state.active_contract);
}

fn repairPatchCall(
    allocator: std.mem.Allocator,
    config: cli.Config,
    prompt: []const u8,
    client: *http.LocalModelClient,
    events: *ui_events.EventBus,
    db: *audit.AuditDb,
    ui_ptr: ?*tui.TerminalUi(fd_writer.FdWriter),
    aggregate_sink: *StreamSink,
    state: *ToolLoopState,
    reason: []const u8,
) !ToolLoopNext {
    try db.recordEvent(config.session, "tool_repair", reason);
    const repair_context = try model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .contracts = activeToolSchema(state),
        .obligations = &.{reason},
        .grounding = groundingRules(),
        .next_action = "Emit one corrected apply_patch call. For edit use path, contextId, repeated search/replace hunks. For create use operation=create and content. For delete/rename use fresh contextId.",
    });
    defer allocator.free(repair_context);
    try db.recordEvent(config.session, "model_context", repair_context);
    return try streamDeferredToolLoopTurn(allocator, config, prompt, repair_context, client, events, db, ui_ptr, aggregate_sink, state.active_contract);
}

fn parsePatchOperation(value: ?[]const u8) !apply_patch_tool.Operation {
    const operation = value orelse return .edit;
    if (std.ascii.eqlIgnoreCase(operation, "edit")) return .edit;
    if (std.ascii.eqlIgnoreCase(operation, "create")) return .create;
    if (std.ascii.eqlIgnoreCase(operation, "delete")) return .delete;
    if (std.ascii.eqlIgnoreCase(operation, "rename")) return .rename;
    return error.InvalidPatchOperation;
}

fn buildPatchArgs(
    allocator: std.mem.Allocator,
    operation: apply_patch_tool.Operation,
    path: []const u8,
    call: *const tool_call.ToolCall,
) !apply_patch_tool.Args {
    return switch (operation) {
        .edit => .{
            .operation = .edit,
            .path = path,
            .hunks = try buildEditHunks(allocator, call),
        },
        .create => .{
            .operation = .create,
            .path = path,
            .content = call.content orelse return error.MissingPatchContent,
            .hunks = &.{},
        },
        .delete => .{
            .operation = .delete,
            .path = path,
            .hunks = try buildContextOnlyHunk(allocator, call),
        },
        .rename => .{
            .operation = .rename,
            .path = path,
            .destination_path = call.destination_path orelse return error.MissingPatchDestination,
            .hunks = try buildContextOnlyHunk(allocator, call),
        },
    };
}

fn buildEditHunks(allocator: std.mem.Allocator, call: *const tool_call.ToolCall) ![]const apply_patch_tool.Hunk {
    const searches = call.searches;
    const replaces = call.replaces;
    if (searches.len == 0) return error.MissingPatchSearch;
    if (searches.len != replaces.len) return error.PatchHunkCountMismatch;
    if (call.context_ids.len != 1 and call.context_ids.len != searches.len) return error.PatchContextCountMismatch;

    const hunks = try allocator.alloc(apply_patch_tool.Hunk, searches.len);
    errdefer allocator.free(hunks);
    for (searches, 0..) |search, idx| {
        hunks[idx] = .{
            .search = search,
            .replace = replaces[idx],
            .context_id = if (call.context_ids.len == 1) call.context_ids[0] else call.context_ids[idx],
        };
    }
    return hunks;
}

fn buildContextOnlyHunk(allocator: std.mem.Allocator, call: *const tool_call.ToolCall) ![]const apply_patch_tool.Hunk {
    const context_id = if (call.context_ids.len > 0) call.context_ids[0] else return error.MissingPatchContextId;
    const hunks = try allocator.alloc(apply_patch_tool.Hunk, 1);
    hunks[0] = .{ .search = "", .replace = "", .context_id = context_id };
    return hunks;
}

fn runValidateSyntaxStep(
    allocator: std.mem.Allocator,
    config: cli.Config,
    prompt: []const u8,
    call: *const tool_call.ToolCall,
    client: *http.LocalModelClient,
    events: *ui_events.EventBus,
    db: *audit.AuditDb,
    ui_ptr: ?*tui.TerminalUi(fd_writer.FdWriter),
    aggregate_sink: *StreamSink,
    state: *ToolLoopState,
    tool_iterations: *usize,
) !ToolLoopNext {
    if (tool_iterations.* >= max_tool_emergency_iterations) return .stopped;
    tool_iterations.* += 1;
    const path = call.path orelse return try repairValidationCall(allocator, config, prompt, client, events, db, ui_ptr, aggregate_sink, state);

    try db.recordEvent(config.session, "tool_start", "validate_syntax");
    try events.emit(.{ .tool_start = .{ .name = "validate_syntax", .detail = path } });
    const diagnostic = diagnostic_runner.run(allocator, path, state.remainingBudget()) catch |err| {
        try db.recordEvent(config.session, "tool_error", @errorName(err));
        try events.emit(.{ .tool_result = .{ .name = "validate_syntax", .output = @errorName(err) } });
        return .stopped;
    };
    defer diagnostic.deinit(allocator);

    var packet = evidence.EvidencePacket.init(allocator);
    defer packet.deinit();
    try packet.add(try collect_evidence.cloneEvidenceEntry(allocator, diagnostic.entry));
    const evidence_text = try packet.render(allocator);
    defer allocator.free(evidence_text);
    try db.recordEvent(config.session, "tool_event", diagnostic.audit_text);
    try db.recordEvent(config.session, "validation", evidence_text);
    try events.emit(.{ .tool_result = .{ .name = "validate_syntax", .output = evidence_text } });

    const validation_block = [_]model_context.EvidenceBlock{.{ .text = evidence_text }};
    const follow_context = try model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .evidence = &validation_block,
        .grounding = groundingRules(),
        .next_action = "Answer with the patch and validation result. Cite validation evidence if it reports errors.",
    });
    defer allocator.free(follow_context);
    try db.recordEvent(config.session, "model_context", follow_context);
    return try streamDeferredToolLoopTurn(allocator, config, prompt, follow_context, client, events, db, ui_ptr, aggregate_sink, state.active_contract);
}

fn repairValidationCall(
    allocator: std.mem.Allocator,
    config: cli.Config,
    prompt: []const u8,
    client: *http.LocalModelClient,
    events: *ui_events.EventBus,
    db: *audit.AuditDb,
    ui_ptr: ?*tui.TerminalUi(fd_writer.FdWriter),
    aggregate_sink: *StreamSink,
    state: *ToolLoopState,
) !ToolLoopNext {
    try db.recordEvent(config.session, "tool_repair", "validate_syntax missing path");
    const repair_context = try model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .contracts = activeToolSchema(state),
        .obligations = &.{"validate_syntax requires path."},
        .next_action = "Emit validate_syntax with a relative Zig path, or answer if validation is not applicable.",
    });
    defer allocator.free(repair_context);
    try db.recordEvent(config.session, "model_context", repair_context);
    return try streamDeferredToolLoopTurn(allocator, config, prompt, repair_context, client, events, db, ui_ptr, aggregate_sink, state.active_contract);
}

fn runInspectRuntimeStep(
    allocator: std.mem.Allocator,
    config: cli.Config,
    prompt: []const u8,
    call: *const tool_call.ToolCall,
    client: *http.LocalModelClient,
    events: *ui_events.EventBus,
    db: *audit.AuditDb,
    ui_ptr: ?*tui.TerminalUi(fd_writer.FdWriter),
    aggregate_sink: *StreamSink,
    state: *ToolLoopState,
    tool_iterations: *usize,
) !ToolLoopNext {
    _ = call;
    if (tool_iterations.* >= max_tool_emergency_iterations) return .stopped;
    tool_iterations.* += 1;
    const result =
        \\[RUNTIME_INSPECTION]
        \\status=unavailable
        \\reason=runtime/browser executor is not implemented in this Zig controller pass
    ;
    try db.recordEvent(config.session, "tool_event", result);
    try events.emit(.{ .tool_result = .{ .name = "inspect_runtime", .output = result } });
    const follow_context = try model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .obligations = &.{"Runtime/browser inspection is unavailable in this controller pass; do not claim it ran."},
        .grounding = groundingRules(),
        .next_action = "Answer with available evidence and state that runtime inspection was not executed.",
    });
    defer allocator.free(follow_context);
    try db.recordEvent(config.session, "model_context", follow_context);
    return try streamDeferredToolLoopTurn(allocator, config, prompt, follow_context, client, events, db, ui_ptr, aggregate_sink, state.active_contract);
}

fn runPromoteContextStep(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: cli.Config,
    prompt: []const u8,
    call: *const tool_call.ToolCall,
    client: *http.LocalModelClient,
    events: *ui_events.EventBus,
    db: *audit.AuditDb,
    ui_ptr: ?*tui.TerminalUi(fd_writer.FdWriter),
    aggregate_sink: *StreamSink,
    state: *ToolLoopState,
    tool_iterations: *usize,
) !ToolLoopNext {
    if (tool_iterations.* >= max_tool_emergency_iterations) return .stopped;
    tool_iterations.* += 1;

    const target = call.target orelse return try repairPromoteContextCall(allocator, config, prompt, client, events, db, ui_ptr, aggregate_sink, state, "promote_context requires target=memory|skills.");
    const text = call.text orelse return try repairPromoteContextCall(allocator, config, prompt, client, events, db, ui_ptr, aggregate_sink, state, "promote_context requires concise text to persist.");
    const promotion_target: persistent_context.PromotionTarget = if (std.ascii.eqlIgnoreCase(target, "memory"))
        .memory
    else if (std.ascii.eqlIgnoreCase(target, "skills"))
        .skills
    else
        return try repairPromoteContextCall(allocator, config, prompt, client, events, db, ui_ptr, aggregate_sink, state, "promote_context target must be memory or skills.");

    try db.recordEvent(config.session, "tool_start", "promote_context");
    try events.emit(.{ .tool_start = .{ .name = "promote_context", .detail = @tagName(promotion_target) } });
    const result = persistent_context.promoteFromCwd(allocator, io, .{
        .target = promotion_target,
        .text = text,
    }) catch |err| {
        try db.recordEvent(config.session, "tool_error", @errorName(err));
        try events.emit(.{ .tool_result = .{ .name = "promote_context", .output = @errorName(err) } });
        const repair_context = try model_context.renderModelTurnContext(allocator, .{
            .task = prompt,
            .contracts = activeToolSchema(state),
            .obligations = &.{"Promotion failed. Do not promote raw tool output, oversized entries, or unverified claims."},
            .grounding = groundingRules(),
            .next_action = "Emit corrected promote_context with target=memory|skills and short verified text, or answer without promotion.",
        });
        defer allocator.free(repair_context);
        try db.recordEvent(config.session, "model_context", repair_context);
        return try streamDeferredToolLoopTurn(allocator, config, prompt, repair_context, client, events, db, ui_ptr, aggregate_sink, state.active_contract);
    };
    defer allocator.free(result);

    try db.recordEvent(config.session, "persistent_promotion", result);
    try events.emit(.{ .tool_result = .{ .name = "promote_context", .output = result } });
    const follow_context = try model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .grounding = groundingRules(),
        .next_action = "Answer that the explicit persistent context promotion was recorded. Do not claim raw tool output was stored.",
    });
    defer allocator.free(follow_context);
    try db.recordEvent(config.session, "model_context", follow_context);
    return try streamDeferredToolLoopTurn(allocator, config, prompt, follow_context, client, events, db, ui_ptr, aggregate_sink, state.active_contract);
}

fn repairPromoteContextCall(
    allocator: std.mem.Allocator,
    config: cli.Config,
    prompt: []const u8,
    client: *http.LocalModelClient,
    events: *ui_events.EventBus,
    db: *audit.AuditDb,
    ui_ptr: ?*tui.TerminalUi(fd_writer.FdWriter),
    aggregate_sink: *StreamSink,
    state: *ToolLoopState,
    reason: []const u8,
) !ToolLoopNext {
    try db.recordEvent(config.session, "tool_repair", reason);
    const repair_context = try model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .contracts = activeToolSchema(state),
        .obligations = &.{reason},
        .grounding = groundingRules(),
        .next_action = "Emit promote_context(target=memory|skills,text) with explicit user-confirmed content, or answer without promotion.",
    });
    defer allocator.free(repair_context);
    try db.recordEvent(config.session, "model_context", repair_context);
    return try streamDeferredToolLoopTurn(allocator, config, prompt, repair_context, client, events, db, ui_ptr, aggregate_sink, state.active_contract);
}

fn runSearchSessionStep(
    allocator: std.mem.Allocator,
    config: cli.Config,
    prompt: []const u8,
    call: *const tool_call.ToolCall,
    client: *http.LocalModelClient,
    events: *ui_events.EventBus,
    db: *audit.AuditDb,
    ui_ptr: ?*tui.TerminalUi(fd_writer.FdWriter),
    aggregate_sink: *StreamSink,
    state: *ToolLoopState,
    tool_iterations: *usize,
) !ToolLoopNext {
    const terms = call.terms orelse "";
    if (terms.len == 0 or isSchemaPlaceholderText(terms)) {
        try db.recordEvent(config.session, "tool_repair", "search_session missing terms");
        const repair_context = try renderCollectedEvidenceContext(
            allocator,
            prompt,
            &state.context,
            null,
            null,
            context_profile.toolSchema(.session_recall, .active_contract),
            "Emit one corrected search_session tool call with concrete <parameter=terms>for the prior session fact you need</parameter>, or answer using current evidence only. Do not copy schema placeholders.",
        );
        defer allocator.free(repair_context);
        try db.recordEvent(config.session, "model_context", repair_context);
        return try streamDeferredToolLoopTurn(allocator, config, prompt, repair_context, client, events, db, ui_ptr, aggregate_sink, state.active_contract);
    }
    const scope = resolveSessionSearchScope(call.scope, call.session) catch {
        try db.recordEvent(config.session, "tool_repair", "search_session invalid scope");
        const repair_context = try renderCollectedEvidenceContext(
            allocator,
            prompt,
            &state.context,
            null,
            null,
            context_profile.toolSchema(.session_recall, .active_contract),
            "Emit one corrected search_session tool call with scope=current or scope=all, or provide a session id. Do not invent session facts.",
        );
        defer allocator.free(repair_context);
        try db.recordEvent(config.session, "model_context", repair_context);
        return try streamDeferredToolLoopTurn(allocator, config, prompt, repair_context, client, events, db, ui_ptr, aggregate_sink, state.active_contract);
    };
    const search_key = try renderSessionSearchKey(allocator, scope, call.session, terms);
    defer allocator.free(search_key);
    if (state.hasSessionSearch(search_key)) {
        try db.recordEvent(config.session, "session_context_duplicate", search_key);
        const duplicate_context = try renderCollectedEvidenceContext(
            allocator,
            prompt,
            &state.context,
            state.last_session_context,
            null,
            context_profile.toolSchema(.session_recall, .after_search_session),
            "The requested session search was already performed in this turn. Answer using existing E#/S# evidence, or state what remains unknown.",
        );
        defer allocator.free(duplicate_context);
        try db.recordEvent(config.session, "model_context", duplicate_context);
        return try streamDeferredToolLoopTurn(allocator, config, prompt, duplicate_context, client, events, db, ui_ptr, aggregate_sink, state.active_contract);
    }
    if (tool_iterations.* >= max_tool_emergency_iterations or !state.hasBudgetForMoreEvidence()) {
        try db.recordEvent(config.session, "tool_loop_stop", "session/evidence budget exhausted");
        return .stopped;
    }
    tool_iterations.* += 1;
    try state.rememberSessionSearch(search_key);

    if (ui_ptr) |active_ui| try active_ui.showStatus("Reading");
    const search_audit_key = try renderSessionSearchAuditKey(allocator, scope, call.session, call.intent, terms);
    defer allocator.free(search_audit_key);
    const tool_start = try std.fmt.allocPrint(allocator, "search_session\t{s}", .{search_audit_key});
    defer allocator.free(tool_start);
    try events.emit(.{ .tool_start = .{ .name = "search_session", .detail = search_key } });

    var hits = switch (scope) {
        .current => try db.searchSessionEventsFts(allocator, config.session, terms, prompt, 6),
        .all => try db.searchAllSessionEventsFts(allocator, terms, prompt, 6),
        .session => try db.searchSessionEventsFts(allocator, call.session.?, terms, prompt, 6),
    };
    defer audit.freeSessionSearchHits(allocator, &hits);
    try db.recordEvent(config.session, "tool_start", tool_start);
    const result = try session_context.renderSearchHits(allocator, hits.items);
    defer result.deinit(allocator);
    try db.recordEvent(config.session, "session_context", result.text);
    try events.emit(.{ .tool_result = .{ .name = "search_session", .output = result.text } });
    try state.rememberSessionContext(result.text);

    var session_events = try db.loadRecentSessionEvents(allocator, config.session, 240);
    defer audit.freeAuditEvents(allocator, &session_events);
    const focus_text = try loadMergedSessionFocus(allocator, db, config.session, prompt, session_events.items);
    defer if (focus_text) |text| allocator.free(text);

    const follow_context = try renderCollectedEvidenceContext(
        allocator,
        prompt,
        &state.context,
        result.text,
        focus_text,
        context_profile.toolSchema(.session_recall, .after_search_session),
        "Use SESSION_CONTEXT as retrieved prior-session evidence. SESSION_FOCUS is a routing map, not evidence; if retrieved S# is only a prior failed/irrelevant recall attempt, emit one more targeted search_session call with intent plus concrete keys from SESSION_FOCUS/current reasoning. Cite S# for session claims and E# for workspace claims. Do not claim unsupported facts.",
    );
    defer allocator.free(follow_context);
    try db.recordEvent(config.session, "model_context", follow_context);
    return try streamDeferredToolLoopTurn(allocator, config, prompt, follow_context, client, events, db, ui_ptr, aggregate_sink, state.active_contract);
}

const SessionSearchScope = enum {
    current,
    all,
    session,
};

fn resolveSessionSearchScope(scope: ?[]const u8, session: ?[]const u8) !SessionSearchScope {
    if (session != null) return .session;
    const raw = scope orelse return .current;
    if (std.ascii.eqlIgnoreCase(raw, "current")) return .current;
    if (std.ascii.eqlIgnoreCase(raw, "all")) return .all;
    return error.InvalidSessionSearchScope;
}

fn renderSessionSearchKey(allocator: std.mem.Allocator, scope: SessionSearchScope, session: ?[]const u8, terms: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "scope={s} session={s} terms={s}", .{
        @tagName(scope),
        session orelse "",
        terms,
    });
}

fn renderSessionSearchAuditKey(allocator: std.mem.Allocator, scope: SessionSearchScope, session: ?[]const u8, intent: ?[]const u8, terms: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "scope={s} session={s} intent={s} terms={s}", .{
        @tagName(scope),
        session orelse "",
        intent orelse "",
        terms,
    });
}

fn renderCollectEvidenceAuditKey(
    allocator: std.mem.Allocator,
    path: ?[]const u8,
    intent: ?[]const u8,
    terms: ?[]const u8,
    strategy: contracts.StrategyName,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "collect_evidence\tpath={s} strategy={s} intent_bytes={} terms_bytes={}", .{
        path orelse "",
        @tagName(strategy),
        if (intent) |value| value.len else 0,
        if (terms) |value| value.len else 0,
    });
}

fn renderAllowedTools(allocator: std.mem.Allocator, allowed_tools: []const []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (allowed_tools, 0..) |tool, idx| {
        if (idx > 0) try out.appendSlice(allocator, ",");
        try out.appendSlice(allocator, tool);
    }
    return out.toOwnedSlice(allocator);
}

fn recordModelContextBudget(
    allocator: std.mem.Allocator,
    db: *audit.AuditDb,
    session: []const u8,
    rendered: []const u8,
) !void {
    try model_context.assertNoRawContextLeak(rendered);
    const buckets = model_context.measureRenderedContextBytes(rendered);
    if (buckets.total_context > max_model_context_send_bytes) return error.ModelContextBudgetExceeded;
    const body = try std.fmt.allocPrint(
        allocator,
        "pre_send=true tokenizer=unavailable token_estimate=false system_bytes={} header_bytes={} contracts_bytes={} skills_bytes={} memory_bytes={} candidates_bytes={} evidence_bytes={} focus_bytes={} dialogue_bytes={} session_bytes={} obligations_bytes={} grounding_bytes={} next_action_bytes={} total_context_bytes={} context_limit_bytes={}",
        .{
            buckets.system,
            buckets.header,
            buckets.contracts,
            buckets.skills,
            buckets.memory,
            buckets.candidates,
            buckets.evidence,
            buckets.focus,
            buckets.dialogue,
            buckets.session,
            buckets.obligations,
            buckets.grounding,
            buckets.next_action,
            buckets.total_context,
            max_model_context_send_bytes,
        },
    );
    defer allocator.free(body);
    try db.recordEvent(session, "model_context_budget", body);
}

fn streamDeferredToolLoopTurn(
    allocator: std.mem.Allocator,
    config: cli.Config,
    prompt: []const u8,
    follow_context: []const u8,
    client: *http.LocalModelClient,
    events: *ui_events.EventBus,
    db: *audit.AuditDb,
    ui_ptr: ?*tui.TerminalUi(fd_writer.FdWriter),
    aggregate_sink: *StreamSink,
    active_contract: contracts.ActiveContract,
) !ToolLoopNext {
    return streamDeferredToolLoopTurnInternal(
        allocator,
        config,
        prompt,
        follow_context,
        null,
        client,
        events,
        db,
        ui_ptr,
        aggregate_sink,
        active_contract,
    );
}

fn streamDeferredRequiredToolLoopTurn(
    allocator: std.mem.Allocator,
    config: cli.Config,
    prompt: []const u8,
    follow_context: []const u8,
    repair_message: []const u8,
    client: *http.LocalModelClient,
    events: *ui_events.EventBus,
    db: *audit.AuditDb,
    ui_ptr: ?*tui.TerminalUi(fd_writer.FdWriter),
    aggregate_sink: *StreamSink,
    active_contract: contracts.ActiveContract,
) !ToolLoopNext {
    return streamDeferredToolLoopTurnInternal(
        allocator,
        config,
        prompt,
        follow_context,
        repair_message,
        client,
        events,
        db,
        ui_ptr,
        aggregate_sink,
        active_contract,
    );
}

fn streamDeferredToolLoopTurnInternal(
    allocator: std.mem.Allocator,
    config: cli.Config,
    prompt: []const u8,
    follow_context: []const u8,
    required_tool_repair: ?[]const u8,
    client: *http.LocalModelClient,
    events: *ui_events.EventBus,
    db: *audit.AuditDb,
    ui_ptr: ?*tui.TerminalUi(fd_writer.FdWriter),
    aggregate_sink: *StreamSink,
    active_contract: contracts.ActiveContract,
) !ToolLoopNext {
    if (ui_ptr) |active_ui| {
        active_ui.setTokenOutputLimit(config.max_tokens);
        try active_ui.showStatus("Thinking");
    }
    var follow_sink = StreamSink{
        .allocator = allocator,
        .events = events,
        .db = db,
        .session = config.session,
        .ui = ui_ptr,
        .filter = reasoning_filter.ReasoningFilter.init(allocator, http.resolveThinking(config.thinking, prompt) == .on),
        .visible = std.ArrayList(u8).empty,
        .visible_bytes = 0,
        .thinking_bytes = 0,
        .defer_visible = true,
        .trim_visible_leading_whitespace = false,
    };
    defer follow_sink.deinit();
    recordModelContextBudget(allocator, db, config.session, follow_context) catch |err| {
        const message = if (err == error.ModelContextBudgetExceeded)
            "context limit exceeded before model call"
        else
            @errorName(err);
        if (ui_ptr) |active_ui| try active_ui.showStatus(message);
        try events.emit(.{ .progress_update = message });
        try db.recordEvent(config.session, "model_error", @errorName(err));
        return .stopped;
    };
    try client.streamInference(.{ .user_prompt = prompt, .model_context = follow_context }, &follow_sink);
    try follow_sink.flush();

    var envelope = (tool_envelope.parseFirst(allocator, follow_sink.raw_model.items, active_contract) catch |err| {
        try db.recordEvent(config.session, "tool_envelope_error", @errorName(err));
        return .stopped;
    }) orelse {
        if (required_tool_repair) |repair_message| {
            follow_sink.discardDeferredVisible();
            if (repair_message.len == 0) {
                try db.recordEvent(config.session, "tool_loop_stop", "required follow-up tool call missing after repair");
                return .stopped;
            }
            try db.recordEvent(config.session, "tool_repair", "required follow-up tool call missing");
            const repair_context = try std.fmt.allocPrint(
                allocator,
                "{s}\n[PROTOCOL_REPAIR]\n{s}\n",
                .{ follow_context, repair_message },
            );
            defer allocator.free(repair_context);
            try db.recordEvent(config.session, "model_context", repair_context);
            return streamDeferredToolLoopTurnInternal(
                allocator,
                config,
                prompt,
                repair_context,
                "",
                client,
                events,
                db,
                ui_ptr,
                aggregate_sink,
                active_contract,
            );
        }
        try follow_sink.flushDeferredVisible();
        try aggregate_sink.visible.appendSlice(allocator, follow_sink.visible.items);
        aggregate_sink.visible_bytes += follow_sink.visible_bytes;
        return .final_answer;
    };
    defer envelope.deinit(allocator);
    const envelope_audit = try envelope.renderAudit(allocator);
    defer allocator.free(envelope_audit);
    try db.recordEvent(config.session, "tool_envelope", envelope_audit);

    if (envelope.state == .rejected) {
        const body = try std.fmt.allocPrint(allocator, "{s}\t{s}", .{ envelope.raw_name, envelope.auditText() });
        defer allocator.free(body);
        try db.recordEvent(config.session, "tool_rejected", body);
        return .stopped;
    }
    if (envelope.takeCall()) |call| return .{ .tool_call = call };
    try db.recordEvent(config.session, "tool_rejected", "accepted envelope without call");
    return .stopped;
}

fn currentActiveContract() contracts.ActiveContract {
    return contracts.activeContract(.collect_evidence).?;
}

fn singleStructuredPathFromPrompt(allocator: std.mem.Allocator, prompt: []const u8) !?[]u8 {
    var found: ?[]u8 = null;
    errdefer if (found) |owned| allocator.free(owned);

    var it = std.mem.tokenizeAny(u8, prompt, " \t\r\n\"'`()[]{}<>:;,!?");
    while (it.next()) |raw| {
        const candidate = trimPathToken(raw);
        if (!isStructuredPathToken(candidate)) continue;
        if (found) |owned| {
            allocator.free(owned);
            found = null;
            return null;
        }
        found = try allocator.dupe(u8, candidate);
    }
    return found;
}

fn trimPathToken(raw: []const u8) []const u8 {
    return std.mem.trim(u8, raw, " \t\r\n\"'`()[]{}<>:;,.!?");
}

fn isStructuredPathToken(token: []const u8) bool {
    if (token.len == 0) return false;
    if (std.fs.path.isAbsolute(token)) return false;
    if (hasTraversalComponent(token)) return false;
    if (std.mem.indexOfScalar(u8, token, '/') == null and std.mem.indexOfScalar(u8, token, '.') == null) return false;
    if (std.mem.endsWith(u8, token, ".")) return false;
    if (std.mem.startsWith(u8, token, ".")) return false;
    return hasKnownTextExtension(token);
}

fn hasTraversalComponent(path: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return true;
    }
    return false;
}

fn hasKnownTextExtension(path: []const u8) bool {
    const exts = [_][]const u8{ ".zig", ".ts", ".js", ".md", ".json", ".toml", ".txt", ".lua", ".py", ".rs", ".c", ".h", ".cpp", ".hpp" };
    for (exts) |ext| {
        if (std.mem.endsWith(u8, path, ext)) return true;
    }
    return false;
}

const ToolLoopState = struct {
    context: working_context.WorkingContext,
    session_searches: std.ArrayList([]u8),
    candidates: std.ArrayList(collect_evidence.CandidateItem),
    last_candidate_context: ?[]u8 = null,
    last_session_context: ?[]u8 = null,
    active_contract: contracts.ActiveContract,
    duplicate_repairs: usize = 0,
    contract_selected: bool = false,
    duplicate_contract_repairs: usize = 0,

    fn init(allocator: std.mem.Allocator) ToolLoopState {
        return .{
            .context = working_context.WorkingContext.init(allocator),
            .session_searches = std.ArrayList([]u8).empty,
            .candidates = std.ArrayList(collect_evidence.CandidateItem).empty,
            .active_contract = currentActiveContract(),
        };
    }

    fn deinit(self: *ToolLoopState) void {
        for (self.session_searches.items) |terms| self.context.allocator.free(terms);
        self.session_searches.deinit(self.context.allocator);
        for (self.candidates.items) |candidate| candidate.deinit(self.context.allocator);
        self.candidates.deinit(self.context.allocator);
        if (self.last_candidate_context) |text| self.context.allocator.free(text);
        if (self.last_session_context) |text| self.context.allocator.free(text);
        self.context.deinit();
    }

    fn hasExecutedArgs(self: ToolLoopState, path: ?[]const u8, terms: ?[]const u8, strategy: contracts.StrategyName, start_line: usize, max_lines: usize) bool {
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

    fn rememberExecutedArgs(self: *ToolLoopState, path: ?[]const u8, terms: ?[]const u8, strategy: contracts.StrategyName, start_line: usize, max_lines: usize, context_id: ?[]const u8, evidence_text: []const u8, model_bytes: usize, quality_score: i32) !void {
        try self.context.remember(.{
            .path = path,
            .terms = terms,
            .strategy = strategy,
            .start_line = start_line,
            .max_lines = max_lines,
            .context_id = context_id,
            .evidence_text = evidence_text,
            .model_bytes = model_bytes,
            .quality_score = quality_score,
        });
    }

    fn hasBudgetForMoreEvidence(self: ToolLoopState) bool {
        return self.context.hasBudgetForMoreEvidence();
    }

    fn remainingBudget(self: ToolLoopState) usize {
        return self.context.remainingBudget();
    }

    fn shouldAllowMoreEvidence(self: ToolLoopState) bool {
        return self.context.shouldAllowMoreEvidence();
    }

    fn hasSessionSearch(self: ToolLoopState, terms: []const u8) bool {
        for (self.session_searches.items) |existing| {
            if (std.ascii.eqlIgnoreCase(existing, terms)) return true;
        }
        return false;
    }

    fn rememberSessionSearch(self: *ToolLoopState, terms: []const u8) !void {
        if (self.hasSessionSearch(terms)) return error.DuplicateSessionSearch;
        const owned = try self.context.allocator.dupe(u8, terms);
        errdefer self.context.allocator.free(owned);
        try self.session_searches.append(self.context.allocator, owned);
    }

    fn rememberSessionContext(self: *ToolLoopState, text: []const u8) !void {
        const owned = try self.context.allocator.dupe(u8, text);
        errdefer self.context.allocator.free(owned);
        if (self.last_session_context) |old| self.context.allocator.free(old);
        self.last_session_context = owned;
    }

    fn rememberCandidates(self: *ToolLoopState, result: *const collect_evidence.CandidateResult) !void {
        var next = std.ArrayList(collect_evidence.CandidateItem).empty;
        var committed = false;
        errdefer if (!committed) {
            for (next.items) |candidate| candidate.deinit(self.context.allocator);
            next.deinit(self.context.allocator);
        };

        for (result.candidates.items) |candidate| {
            {
                var cloned = try cloneCandidateItem(self.context.allocator, candidate);
                errdefer cloned.deinit(self.context.allocator);
                try next.append(self.context.allocator, cloned);
            }
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

    fn findCandidate(self: ToolLoopState, id: []const u8) ?collect_evidence.CandidateItem {
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

fn renderCollectedEvidenceContext(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    context: *const working_context.WorkingContext,
    session_text: ?[]const u8,
    focus_text: ?[]const u8,
    contracts_text: []const u8,
    next_action: []const u8,
) ![]u8 {
    const evidence_blocks = try context.renderEvidenceBlocks(allocator);
    defer allocator.free(evidence_blocks);
    const session_blocks = try session_context.toSessionBlocks(allocator, session_text);
    defer allocator.free(session_blocks);
    const focus_blocks = try session_context.toFocusBlocks(allocator, focus_text);
    defer allocator.free(focus_blocks);
    return model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .contracts = contracts_text,
        .evidence = evidence_blocks,
        .focus = focus_blocks,
        .session = session_blocks,
        .obligations = &.{
            "Use only collected evidence for claims about this workspace or prior session.",
        },
        .grounding = groundingRules(),
        .next_action = next_action,
    });
}

fn renderEvidenceAndMicroContext(allocator: std.mem.Allocator, evidence_text: []const u8, micro_context_text: []const u8) ![]u8 {
    if (micro_context_text.len == 0) return allocator.dupe(u8, evidence_text);
    return std.fmt.allocPrint(allocator, "{s}\n{s}", .{ evidence_text, micro_context_text });
}

fn collectEvidenceToolSchema(include_contract_tool: bool) []const u8 {
    return if (include_contract_tool)
        context_profile.toolSchema(.code_evidence, .initial)
    else
        context_profile.toolSchema(.code_evidence, .active_contract);
}

fn activeToolSchema(state: *const ToolLoopState) []const u8 {
    return context_profile.activeContractSchemaFor(state.active_contract.name);
}

fn groundingRules() []const []const u8 {
    return &.{
        "Workspace/source-code claims must cite E# evidence from [EVIDENCE].",
        "For code identity questions, only name a function/type/file when that identifier or declaration/callsite appears in E# evidence. If the collected E# does not contain the needed identifier, refine with another collect_evidence call while budget remains.",
        "Use [RECENT_DIALOGUE] for continuity only; use [SESSION_FOCUS] only as a routing map. Exact claims about what was said or done in prior conversation must cite S# evidence from [SESSION_CONTEXT].",
        "collect_evidence intent states what workspace/source-code evidence to recover; pathless collect_evidence terms are retrieval keys for that intent, not the user's vague wording.",
        "search_session intent states what evidence to recover; search_session terms are retrieval keys for that intent, not the user's vague wording.",
        "Do not answer that conversation history is unavailable while search_session is available; call search_session first when prior conversation context is required.",
        "If no E#/S# supports a workspace or exact prior-session claim, say that claim is not evidenced in the provided context.",
    };
}

fn modelContextEnabled() bool {
    const raw = c.getenv("PHENOM_MODEL_CONTEXT_V1") orelse return false;
    return modelContextValueEnabled(std.mem.span(raw));
}

fn modelContextValueEnabled(value: []const u8) bool {
    return std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true") or std.ascii.eqlIgnoreCase(value, "on");
}

fn renderRestoredSession(
    allocator: std.mem.Allocator,
    db: *audit.AuditDb,
    session: []const u8,
    writer: anytype,
    color: bool,
    columns: usize,
    crlf: bool,
    write_mutex: ?*std.atomic.Mutex,
) !usize {
    var events = try db.loadRecentSessionTurnEvents(allocator, session, max_restored_session_turns);
    defer audit.freeAuditEvents(allocator, &events);
    if (events.items.len == 0) return 0;

    var transcript_writer = fd_writer.NewlineWriter(@TypeOf(writer)){ .inner = writer, .crlf = crlf };
    var renderer = render.AppendOnlyRenderer(@TypeOf(&transcript_writer)).init(&transcript_writer, .{
        .color = color,
        .terminal_columns = columns,
        .user_label = userLabel(),
    });
    var bus = ui_events.EventBus.init(allocator);
    defer bus.deinit();
    var render_sink = ui_events.RendererEventSink(@TypeOf(&renderer)){
        .renderer = &renderer,
        .write_mutex = write_mutex,
        .terminal_columns = if (write_mutex != null) currentTerminalColumns else null,
    };
    try bus.on(&render_sink, @TypeOf(render_sink).handleOpaque);

    var restored_turn_open = false;
    var restored_turn_started_s: ?i64 = null;
    var restored_assistant = std.ArrayList(u8).empty;
    defer restored_assistant.deinit(allocator);
    for (events.items) |event| {
        if (std.mem.eql(u8, event.kind, "turn_start")) {
            if (restored_turn_open) {
                try flushRestoredAssistant(&bus, &restored_assistant);
                try bus.emit(.{ .think_end = {} });
            }
            try bus.emit(.{ .user_message = event.body });
            try bus.emit(.{ .think_start = "Thinking" });
            restored_turn_open = true;
            restored_turn_started_s = event.created_at_unix_s;
        } else if (std.mem.eql(u8, event.kind, "assistant_delta") or std.mem.eql(u8, event.kind, "assistant_offline_stub")) {
            try restored_assistant.appendSlice(allocator, event.body);
            restored_turn_open = true;
        } else if (std.mem.eql(u8, event.kind, "tool_start")) {
            try flushRestoredAssistant(&bus, &restored_assistant);
            const parsed = parseRestoredToolStart(event.body);
            try bus.emit(.{ .tool_start = .{ .name = parsed.name, .detail = parsed.detail } });
            restored_turn_open = true;
        } else if (std.mem.eql(u8, event.kind, "evidence")) {
            try flushRestoredAssistant(&bus, &restored_assistant);
            try bus.emit(.{ .tool_result = .{ .name = "read_file_range", .output = event.body } });
            restored_turn_open = true;
        } else if (std.mem.eql(u8, event.kind, "model_error")) {
            try flushRestoredAssistant(&bus, &restored_assistant);
            try bus.emit(.{ .progress_update = event.body });
            restored_turn_open = true;
        } else if (std.mem.eql(u8, event.kind, "empty_visible_answer")) {
            try flushRestoredAssistant(&bus, &restored_assistant);
            try bus.emit(.{ .progress_update = "model emitted no visible final answer; reasoning was suppressed or generation ended inside <think>" });
            restored_turn_open = true;
        } else if (std.mem.eql(u8, event.kind, "expectation_failed")) {
            try flushRestoredAssistant(&bus, &restored_assistant);
            try bus.emit(.{ .progress_update = event.body });
            restored_turn_open = true;
        } else if (std.mem.eql(u8, event.kind, "expectation_passed")) {
            restored_turn_open = true;
        } else if (std.mem.eql(u8, event.kind, "turn_done")) {
            try flushRestoredAssistant(&bus, &restored_assistant);
            try bus.emit(.{ .turn_done = .{ .elapsed_ms = restoredElapsedMs(event.body, restored_turn_started_s, event.created_at_unix_s) } });
            restored_turn_open = false;
            restored_turn_started_s = null;
        }
    }
    if (restored_turn_open) {
        try flushRestoredAssistant(&bus, &restored_assistant);
        try bus.emit(.{ .think_end = {} });
    }
    return events.items.len;
}

fn flushRestoredAssistant(bus: *ui_events.EventBus, pending: *std.ArrayList(u8)) !void {
    if (pending.items.len == 0) return;
    try bus.emit(.{ .message_chunk = pending.items });
    pending.clearRetainingCapacity();
}

const RestoredToolStart = struct {
    name: []const u8,
    detail: []const u8,
};

fn parseRestoredToolStart(body: []const u8) RestoredToolStart {
    if (std.mem.indexOfScalar(u8, body, '\t')) |idx| {
        return .{ .name = body[0..idx], .detail = body[idx + 1 ..] };
    }
    return .{ .name = body, .detail = "" };
}

fn parseElapsedMs(body: []const u8) ?u64 {
    const needle = "elapsed_ms=";
    const start = std.mem.indexOf(u8, body, needle) orelse return null;
    var end = start + needle.len;
    while (end < body.len and body[end] >= '0' and body[end] <= '9') : (end += 1) {}
    if (end == start + needle.len) return null;
    return std.fmt.parseInt(u64, body[start + needle.len .. end], 10) catch null;
}

fn restoredElapsedMs(body: []const u8, started_s: ?i64, done_s: ?i64) ?u64 {
    if (parseElapsedMs(body)) |elapsed_ms| return elapsed_ms;
    const start = started_s orelse return null;
    const done = done_s orelse return null;
    if (done < start) return null;
    return @as(u64, @intCast(done - start)) * 1000;
}

fn offlineStubResponse() []const u8 {
    return "[offline stub] model not called";
}

fn userLabel() []const u8 {
    if (c.getenv("USER")) |value| {
        const span = std.mem.span(value);
        if (span.len > 0) return span;
    }
    return "user";
}

fn loadHistoryFromDb(allocator: std.mem.Allocator, db: *audit.AuditDb, ui: anytype) !void {
    var lines = try db.loadInputHistoryNewestFirst(allocator, 200);
    defer audit.freeHistoryLines(allocator, &lines);
    try ui.editor.loadHistoryNewestFirst(lines.items);
}

const max_chat_history_messages: usize = 8;
const max_chat_message_bytes: usize = 1200;
const chat_truncated_marker = " [TRUNCATED]";
const max_restored_session_turns: usize = 40;

fn buildRecentChatMessages(allocator: std.mem.Allocator, events: []const audit.AuditEvent, current_prompt: []const u8) !std.ArrayList(http.ChatMessage) {
    var messages = std.ArrayList(http.ChatMessage).empty;
    errdefer freeChatMessages(allocator, &messages);
    const current_prompt_index = latestCurrentPromptIndex(events, current_prompt);
    var turn_messages_start: usize = 0;
    var skip_current_turn = false;

    for (events, 0..) |event, idx| {
        if (std.mem.eql(u8, event.kind, "turn_start")) {
            turn_messages_start = messages.items.len;
            skip_current_turn = current_prompt_index != null and idx == current_prompt_index.?;
            if (skip_current_turn) continue;
            try appendChatHistoryMessage(allocator, &messages, .user, event.body);
        } else if (std.mem.eql(u8, event.kind, "assistant_delta")) {
            if (skip_current_turn) continue;
            try appendChatHistoryMessage(allocator, &messages, .assistant, event.body);
        } else if (std.mem.eql(u8, event.kind, "turn_done")) {
            if (session_context.isFailedTurnDone(event.body)) {
                truncateChatMessages(allocator, &messages, turn_messages_start);
            }
            turn_messages_start = messages.items.len;
            skip_current_turn = false;
        }
        while (messages.items.len > max_chat_history_messages) {
            allocator.free(messages.orderedRemove(0).content);
        }
    }

    return messages;
}

fn appendChatHistoryMessage(allocator: std.mem.Allocator, messages: *std.ArrayList(http.ChatMessage), role: http.ChatRole, text: []const u8) !void {
    if (text.len == 0) return;
    const safe = try session_context.compactDialogueMessage(allocator, text);
    errdefer allocator.free(safe);
    if (safe.len == 0) {
        allocator.free(safe);
        return;
    }
    if (role == .assistant and messages.items.len > 0 and messages.items[messages.items.len - 1].role == .assistant) {
        const old = messages.items[messages.items.len - 1].content;
        const merged = try mergeChatContent(allocator, old, safe);
        allocator.free(old);
        allocator.free(safe);
        messages.items[messages.items.len - 1].content = merged;
        return;
    }
    try messages.append(allocator, .{ .role = role, .content = safe });
}

fn mergeChatContent(allocator: std.mem.Allocator, old: []const u8, extra: []const u8) ![]u8 {
    if (old.len >= max_chat_message_bytes or std.mem.endsWith(u8, old, chat_truncated_marker)) return allocator.dupe(u8, old);
    const remaining = max_chat_message_bytes - old.len;
    const take = @min(remaining, extra.len);
    const truncated = take < extra.len;
    const marker_len = if (truncated) chat_truncated_marker.len else 0;
    const merged = try allocator.alloc(u8, old.len + take + marker_len);
    @memcpy(merged[0..old.len], old);
    if (take > 0) @memcpy(merged[old.len .. old.len + take], extra[0..take]);
    if (truncated) @memcpy(merged[old.len + take ..], chat_truncated_marker);
    return merged;
}

fn freeChatMessages(allocator: std.mem.Allocator, messages: *std.ArrayList(http.ChatMessage)) void {
    for (messages.items) |message| allocator.free(message.content);
    messages.deinit(allocator);
}

fn truncateChatMessages(allocator: std.mem.Allocator, messages: *std.ArrayList(http.ChatMessage), new_len: usize) void {
    var i = new_len;
    while (i < messages.items.len) : (i += 1) {
        allocator.free(messages.items[i].content);
    }
    messages.shrinkRetainingCapacity(new_len);
}

fn latestCurrentPromptIndex(events: []const audit.AuditEvent, current_prompt: []const u8) ?usize {
    var i = events.len;
    while (i > 0) {
        i -= 1;
        const event = events[i];
        if (std.mem.eql(u8, event.kind, "turn_start") and std.mem.eql(u8, event.body, current_prompt)) return i;
    }
    return null;
}

const StreamSink = struct {
    allocator: std.mem.Allocator,
    events: *ui_events.EventBus,
    db: *audit.AuditDb,
    session: []const u8,
    ui: ?*tui.TerminalUi(fd_writer.FdWriter),
    filter: reasoning_filter.ReasoningFilter,
    visible: std.ArrayList(u8),
    raw_model: std.ArrayList(u8) = std.ArrayList(u8).empty,
    raw_visible: std.ArrayList(u8) = std.ArrayList(u8).empty,
    visible_bytes: usize,
    thinking_bytes: usize,
    defer_visible: bool = false,
    trim_visible_leading_whitespace: bool = false,

    pub fn deinit(ctx: *StreamSink) void {
        ctx.filter.deinit();
        ctx.visible.deinit(ctx.allocator);
        ctx.raw_model.deinit(ctx.allocator);
        ctx.raw_visible.deinit(ctx.allocator);
    }

    pub fn onDelta(ctx: *StreamSink, delta: []const u8) !void {
        try ctx.raw_model.appendSlice(ctx.allocator, delta);
        try ctx.filter.feed(delta, ctx);
    }

    pub fn onTokenUsage(ctx: *StreamSink, usage: http.TokenUsage) !void {
        try ctx.events.emit(.{ .token_update = .{
            .total = usage.total,
            .input = usage.input,
            .output = usage.output,
            .tokens_per_second = usage.tokens_per_second,
        } });
        if (ctx.ui) |ui| try ui.showTokenUsage(usage.input, usage.output, usage.total, usage.tokens_per_second);
        if (!usage.final) return;
        const body = if (usage.tokens_per_second) |tps|
            try std.fmt.allocPrint(ctx.allocator, "input={} output={} total={} tokens_per_second={d:.2} exact=true final=true", .{ usage.input, usage.output, usage.total, tps })
        else
            try std.fmt.allocPrint(ctx.allocator, "input={} output={} total={} tokens_per_second=null exact=true final=true", .{ usage.input, usage.output, usage.total });
        defer ctx.allocator.free(body);
        try ctx.db.recordEvent(ctx.session, "token_usage", body);
    }

    pub fn flush(ctx: *StreamSink) !void {
        try ctx.filter.flush(ctx);
    }

    pub fn writeVisible(ctx: *StreamSink, visible: []const u8) !void {
        const text = trimLeadingWhitespaceAfterThinking(visible, &ctx.trim_visible_leading_whitespace);
        if (text.len == 0) return;
        try ctx.raw_visible.appendSlice(ctx.allocator, text);
        if (ctx.defer_visible) return;
        try ctx.emitVisibleText(text);
    }

    pub fn flushDeferredVisible(ctx: *StreamSink) !void {
        if (!ctx.defer_visible or ctx.raw_visible.items.len == 0) return;
        ctx.defer_visible = false;
        try ctx.emitVisibleText(ctx.raw_visible.items);
    }

    pub fn discardDeferredVisible(ctx: *StreamSink) void {
        if (!ctx.defer_visible) return;
        ctx.raw_visible.clearRetainingCapacity();
    }

    fn emitVisibleText(ctx: *StreamSink, text: []const u8) !void {
        ctx.visible_bytes += text.len;
        try ctx.visible.appendSlice(ctx.allocator, text);
        if (ctx.ui) |ui| try ui.showStatus("Responding");
        try ctx.events.emit(.{ .message_chunk = text });
        if (ctx.ui) |ui| try ui.pulseStatus();
        try ctx.db.recordEvent(ctx.session, "assistant_delta", text);
    }

    pub fn writeThinking(ctx: *StreamSink, thinking: []const u8) !void {
        ctx.thinking_bytes += thinking.len;
        if (ctx.ui) |ui| try ui.showStatus("Thinking");
        try ctx.events.emit(.{ .reasoning_chunk = thinking });
        if (ctx.ui) |ui| try ui.pulseStatus();
        try ctx.db.recordEvent(ctx.session, "assistant_thinking_delta", thinking);
    }

    pub fn endThinking(ctx: *StreamSink) !void {
        ctx.trim_visible_leading_whitespace = true;
    }
};

fn trimLeadingWhitespaceAfterThinking(text: []const u8, active: *bool) []const u8 {
    if (!active.*) return text;
    var start: usize = 0;
    while (start < text.len and isAsciiSpace(text[start])) : (start += 1) {}
    if (start < text.len) active.* = false;
    return text[start..];
}

fn isAsciiSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

fn runSnapshot() !void {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.heap.page_allocator);
    const writer = fd_writer.BufferWriter{ .allocator = std.heap.page_allocator, .list = &buffer };
    var renderer = render.AppendOnlyRenderer(@TypeOf(writer)).init(writer, .{ .color = false });
    try renderer.user("ola");
    try renderer.assistantStart();
    try renderer.assistantDelta("ok");
    try renderer.done();
    try (fd_writer.FdWriter{ .fd = 1 }).writeAll(buffer.items);
}

fn makeDirIfMissing(path: []const u8) !void {
    var buf: [256]u8 = undefined;
    if (path.len + 1 > buf.len) return error.PathTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    if (c.mkdir(@ptrCast(&buf), 0o755) != 0) {
        if (c.__errno_location().* != c.EEXIST) return error.MkdirFailed;
    }
}

test {
    _ = audit;
    _ = apply_patch_tool;
    _ = cli;
    _ = collect_evidence;
    _ = contracts;
    _ = evidence;
    _ = fd_writer;
    _ = gate;
    _ = http;
    _ = micro_context;
    _ = model_context;
    _ = persistent_context;
    _ = product_guardrails;
    _ = reasoning_filter;
    _ = render;
    _ = tool_call;
    _ = tool_event;
    _ = tool_loop;
    _ = tools;
    _ = tui;
    _ = ui_events;
    _ = working_context;
}

test "offline stub is explicit and not ok" {
    const response = offlineStubResponse();
    try std.testing.expect(!std.mem.eql(u8, response, "ok"));
    try std.testing.expect(std.mem.indexOf(u8, response, "offline") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "model not called") != null);
}

test "visible output trims only leading whitespace after thinking" {
    var active = true;
    try std.testing.expectEqualStrings("Olá", trimLeadingWhitespaceAfterThinking("\n\n Olá", &active));
    try std.testing.expect(!active);

    active = true;
    try std.testing.expectEqualStrings("", trimLeadingWhitespaceAfterThinking("\r\n\t ", &active));
    try std.testing.expect(active);
    try std.testing.expectEqualStrings("final", trimLeadingWhitespaceAfterThinking("final", &active));
    try std.testing.expect(!active);
}

test "restored sqlite session is rendered through styled transcript events" {
    var db = try audit.AuditDb.open(std.testing.allocator, ":memory:");
    defer db.close();

    try db.recordEvent("restore", "turn_start", "analise");
    try db.recordEvent("restore", "assistant_thinking_delta", "vou ler");
    try db.recordEvent("restore", "tool_start", "read_file_range\tREADME.md");
    try db.recordEvent("restore", "evidence", "[EVIDENCE]\nREADME.md:1\n");
    try db.recordEvent("restore", "assistant_delta", "resposta");
    try db.recordEvent("restore", "assistant_delta",
        \\
        \\# Plano
        \\- Item com **ne
    );
    try db.recordEvent("restore", "assistant_delta",
        \\grito** e `codigo`
        \\| Arquivo | Estado |
        \\| --- | --- |
        \\| src/main.zig | ok |
    );
    try db.recordEvent("restore", "turn_done", "status=ok elapsed_ms=1234");

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);
    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };

    const count = try renderRestoredSession(std.testing.allocator, &db, "restore", writer, false, 80, false, null);
    try std.testing.expectEqual(@as(usize, 7), count);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "> [") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "analise") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "thinking") == null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "vou ler") == null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "Reading") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "README.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "[EVIDENCE]") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "resposta") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, " # Plano") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, " • Item com negrito e codigo") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "**negrito**") == null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "`codigo`") == null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, " │ Arquivo") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, " │ src/main.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "Worked for 1s") != null);
    try std.testing.expectEqual(@as(usize, 1), countNeedle(buffer.items, "▸ Reading"));
    try std.testing.expectEqual(@as(?u64, 1234), parseElapsedMs("status=ok elapsed_ms=1234"));
    try std.testing.expectEqual(@as(?u64, null), parseElapsedMs("ok"));
    try std.testing.expectEqual(@as(?u64, 2000), restoredElapsedMs("ok", 100, 102));
    try std.testing.expectEqual(@as(?u64, null), restoredElapsedMs("ok", 102, 100));
}

test "model context env parser is opt in only" {
    try std.testing.expect(modelContextValueEnabled("1"));
    try std.testing.expect(modelContextValueEnabled("true"));
    try std.testing.expect(modelContextValueEnabled("on"));
    try std.testing.expect(!modelContextValueEnabled(""));
    try std.testing.expect(!modelContextValueEnabled("0"));
    try std.testing.expect(!modelContextValueEnabled("false"));
}

test "tool loop schema is compact and offered without linguistic gating" {
    const schema = collectEvidenceToolSchema(true);
    try std.testing.expect(std.mem.indexOf(u8, schema, "set_operational_contract") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "requiresRuntimeValidation") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "collect_evidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "strategy=auto") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "lexical") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "symbol") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "semantic") == null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "diagnostic") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "strategy=runtime") == null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "strategy=diff") == null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "search_session") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "scope=current|all") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "Model chooses intent/terms") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "stage=candidates") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "selectedCandidate") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "apply_patch") == null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "grep_file") == null);
    const post_contract_schema = collectEvidenceToolSchema(false);
    try std.testing.expect(std.mem.indexOf(u8, post_contract_schema, "set_operational_contract(") == null);
    try std.testing.expect(std.mem.indexOf(u8, post_contract_schema, "Do not call set_operational_contract again") != null);

    var db = try audit.AuditDb.open(std.testing.allocator, ":memory:");
    defer db.close();
    try db.recordEvent("schema-test", "turn_start", "falamos de groundedness");
    try db.recordEvent("schema-test", "assistant_delta", "resposta anterior");
    const with_tools = (try buildInitialModelContext(std.testing.allocator, std.testing.io, &db, "schema-test", "ola tudo bem", true)) orelse return error.MissingContext;
    defer std.testing.allocator.free(with_tools);
    try std.testing.expect(std.mem.indexOf(u8, with_tools, "mode: code_evidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_tools, "[SESSION_FOCUS]") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_tools, "collect_evidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_tools, "search_session") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_tools, "[CONTRACTS]") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_tools, "[RECENT_DIALOGUE]") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_tools, "user: falamos de groundedness") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_tools, "assistant: resposta anterior") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_tools, "S1:") == null);
    try std.testing.expect(std.mem.indexOf(u8, with_tools, "[GROUNDING]") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_tools, "context tool call before prose") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_tools, "use search_session for prior-session facts") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_tools, "collect_evidence for workspace/source-code facts") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_tools, "set intent to the evidence you want") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_tools, "concrete retrieval keys") != null);

    try std.testing.expect((try buildInitialModelContext(std.testing.allocator, std.testing.io, &db, "schema-test-empty", "analise esse projeto", false)) == null);
}

test "search session scope is model selected without linguistic inference" {
    try std.testing.expectEqual(SessionSearchScope.current, try resolveSessionSearchScope(null, null));
    try std.testing.expectEqual(SessionSearchScope.current, try resolveSessionSearchScope("current", null));
    try std.testing.expectEqual(SessionSearchScope.all, try resolveSessionSearchScope("all", null));
    try std.testing.expectEqual(SessionSearchScope.session, try resolveSessionSearchScope(null, "session-1"));
    try std.testing.expectEqual(SessionSearchScope.session, try resolveSessionSearchScope("all", "session-1"));
    try std.testing.expectError(error.InvalidSessionSearchScope, resolveSessionSearchScope("nearby", null));

    const key = try renderSessionSearchKey(std.testing.allocator, .all, null, "w-90 bootstrap");
    defer std.testing.allocator.free(key);
    try std.testing.expectEqualStrings("scope=all session= terms=w-90 bootstrap", key);
    const audit_key = try renderSessionSearchAuditKey(std.testing.allocator, .all, "old-session", "recover prior layout decision", "w-90 bootstrap");
    defer std.testing.allocator.free(audit_key);
    try std.testing.expectEqualStrings("scope=all session=old-session intent=recover prior layout decision terms=w-90 bootstrap", audit_key);
}

test "session recall missing search_session is turn quality without text heuristics" {
    var db = try audit.AuditDb.open(std.testing.allocator, ":memory:");
    defer db.close();
    try db.recordEvent("quality", "turn_start", "eu estava falando sobre o que?");
    try db.recordEvent("quality", "model_context", "[TURN_CONTEXT v1]\nmode: session_recall\n");
    const quality = try buildTurnQuality(std.testing.allocator, &db, "quality", "ok", "resposta qualquer");
    defer quality.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("uncertain", quality.quality);
    try std.testing.expect(std.mem.indexOf(u8, quality.flags, "refusal=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, quality.flags, "contract_missing_context=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, quality.flags, "low_confidence=true") != null);
}

test "missing required initial context tool marks turn low confidence" {
    var db = try audit.AuditDb.open(std.testing.allocator, ":memory:");
    defer db.close();
    try db.recordEvent("quality-tool", "turn_start", "quais topicos conversamos?");
    try db.recordEvent("quality-tool", "model_context",
        \\[TURN_CONTEXT v1]
        \\[NEXT_ACTION]
        \\First emit exactly one context tool call before prose.
    );
    const quality = try buildTurnQuality(std.testing.allocator, &db, "quality-tool", "ok", "resposta em prosa sem tool");
    defer quality.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("uncertain", quality.quality);
    try std.testing.expect(std.mem.indexOf(u8, quality.flags, "context_tool_missing=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, quality.flags, "low_confidence=true") != null);
}

test "persistent promotion satisfies required context tool contract" {
    var db = try audit.AuditDb.open(std.testing.allocator, ":memory:");
    defer db.close();
    try db.recordEvent("quality-memory", "turn_start", "lembre esta regra");
    try db.recordEvent("quality-memory", "model_context",
        \\[TURN_CONTEXT v1]
        \\[NEXT_ACTION]
        \\First emit exactly one context tool call before prose.
    );
    try db.recordEvent("quality-memory", "tool_start", "promote_context");
    try db.recordEvent("quality-memory", "persistent_promotion", "target=skills path=SKILLS.md status=promoted bytes=29");
    const quality = try buildTurnQuality(std.testing.allocator, &db, "quality-memory", "ok", "Regra persistida.");
    defer quality.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("confirmed", quality.quality);
    try std.testing.expect(std.mem.indexOf(u8, quality.flags, "used_persistent_context=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, quality.flags, "context_tool_missing=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, quality.flags, "low_confidence=false") != null);
}

test "initial model context does not run prompt based session fts" {
    var db = try audit.AuditDb.open(std.testing.allocator, ":memory:");
    defer db.close();

    try db.recordEvent("long-session", "turn_start", "combinamos que renderer append-only preserva copia direta");
    try db.recordEvent("long-session", "assistant_delta", "acordo: renderer append-only deve manter terminal copiavel");
    try db.recordEvent("long-session", "turn_start", "renderer append-only pergunta atual");
    try db.recordEvent("other-session", "assistant_delta", "renderer append-only fora da sessao");

    const rendered = (try buildInitialModelContext(
        std.testing.allocator,
        std.testing.io,
        &db,
        "long-session",
        "renderer append-only pergunta atual",
        true,
    )) orelse return error.MissingContext;
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "[RECENT_DIALOGUE]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "source=sqlite_audit_fts") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "semantic_search=fts5_bm25") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "- S1") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "renderer append-only deve manter terminal copiavel") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "turn_start: renderer append-only pergunta atual") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "fora da sessao") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[MEMORY]") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[SKILLS]") == null);
    try std.testing.expect(rendered.len < 5000);
}

test "initial model context includes long session summary without failed or current turns" {
    var db = try audit.AuditDb.open(std.testing.allocator, ":memory:");
    defer db.close();

    var i: usize = 0;
    while (i < 7) : (i += 1) {
        const prompt = try std.fmt.allocPrint(std.testing.allocator, "topico longo {}", .{i});
        defer std.testing.allocator.free(prompt);
        const answer = try std.fmt.allocPrint(std.testing.allocator, "resumo confirmado {}", .{i});
        defer std.testing.allocator.free(answer);
        try db.recordEvent("long-summary", "turn_start", prompt);
        try db.recordEvent("long-summary", "assistant_delta", answer);
        try db.recordEvent("long-summary", "turn_done", "status=ok low_confidence=false");
    }
    try db.recordEvent("long-summary", "turn_start", "turno falho antigo");
    try db.recordEvent("long-summary", "assistant_delta", "nao tenho acesso");
    try db.recordEvent("long-summary", "turn_done", "status=ok low_confidence=true");
    try db.recordEvent("long-summary", "turn_start", "pedido atual ambiguo");

    const rendered = (try buildInitialModelContext(
        std.testing.allocator,
        std.testing.io,
        &db,
        "long-summary",
        "pedido atual ambiguo",
        true,
    )) orelse return error.MissingContext;
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "[SESSION_FOCUS]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "long_session=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "resumo confirmado 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "resumo confirmado 0") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "turno falho antigo") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "topic: pedido atual ambiguo") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "user: pedido atual ambiguo") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "S1:") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[MEMORY]") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[SKILLS]") == null);
}

test "initial model context combines stored focus with legacy turn topics" {
    var db = try audit.AuditDb.open(std.testing.allocator, ":memory:");
    defer db.close();

    try db.recordEvent("mixed-focus", "turn_start", "qual a matematica perfeita de Matheus 1 na biblia");
    try db.recordEvent("mixed-focus", "assistant_delta", "falamos sobre Mateus 1");
    try db.recordEvent("mixed-focus", "turn_done", "status=ok elapsed_ms=1000");
    try db.recordEvent("mixed-focus", "turn_start", "o que este projeto implementa?");
    try db.recordEvent("mixed-focus", "assistant_delta", "projeto em Zig");
    try db.recordEvent("mixed-focus", "turn_done", "status=ok elapsed_ms=1000");
    try db.recordSessionFocus(
        "mixed-focus",
        "projeto Zig",
        "user_prompt",
        "o que este projeto implementa?",
        "confirmed",
        "answered=true low_confidence=false",
    );

    const rendered = (try buildInitialModelContext(
        std.testing.allocator,
        std.testing.io,
        &db,
        "mixed-focus",
        "voce lembra do que estavamos conversando?",
        true,
    )) orelse return error.MissingContext;
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "[SESSION_FOCUS]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "topic: projeto Zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "topic: qual a matematica perfeita de Matheus 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "source=sqlite_audit_fts") == null);
    try std.testing.expect(rendered.len < 6000);
}

test "recent chat messages preserve roles and exclude only current prompt event" {
    var events = std.ArrayList(audit.AuditEvent).empty;
    defer audit.freeAuditEvents(std.testing.allocator, &events);
    try events.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "turn_start"),
        .body = try std.testing.allocator.dupe(u8, "ola"),
    });
    try events.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "assistant_delta"),
        .body = try std.testing.allocator.dupe(u8, "Ola!"),
    });
    try events.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "turn_start"),
        .body = try std.testing.allocator.dupe(u8, "qual e meu nome?"),
    });
    try events.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "assistant_delta"),
        .body = try std.testing.allocator.dupe(u8, "Voce aparece como ashirak."),
    });
    try events.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "turn_start"),
        .body = try std.testing.allocator.dupe(u8, "ola"),
    });

    var messages = try buildRecentChatMessages(std.testing.allocator, events.items, "ola");
    defer freeChatMessages(std.testing.allocator, &messages);

    try std.testing.expectEqual(@as(usize, 4), messages.items.len);
    try std.testing.expectEqual(http.ChatRole.user, messages.items[0].role);
    try std.testing.expectEqualStrings("ola", messages.items[0].content);
    try std.testing.expectEqual(http.ChatRole.assistant, messages.items[1].role);
    try std.testing.expectEqualStrings("Ola!", messages.items[1].content);
    try std.testing.expectEqual(http.ChatRole.user, messages.items[2].role);
    try std.testing.expectEqualStrings("qual e meu nome?", messages.items[2].content);
    try std.testing.expectEqual(http.ChatRole.assistant, messages.items[3].role);
    try std.testing.expectEqualStrings("Voce aparece como ashirak.", messages.items[3].content);
}

test "recent chat messages exclude failed assistant turns by audit status" {
    var events = std.ArrayList(audit.AuditEvent).empty;
    defer audit.freeAuditEvents(std.testing.allocator, &events);
    try events.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "turn_start"),
        .body = try std.testing.allocator.dupe(u8, "qual a matematica perfeita de Matheus 1 na biblia"),
    });
    try events.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "assistant_delta"),
        .body = try std.testing.allocator.dupe(u8, "falamos sobre Mateus 1"),
    });
    try events.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "turn_done"),
        .body = try std.testing.allocator.dupe(u8, "status=ok elapsed_ms=1000"),
    });
    try events.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "turn_start"),
        .body = try std.testing.allocator.dupe(u8, "eu estava falando sobre o que com voce?"),
    });
    try events.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "assistant_delta"),
        .body = try std.testing.allocator.dupe(u8, "Nao tenho acesso ao historico."),
    });
    try events.append(std.testing.allocator, .{
        .kind = try std.testing.allocator.dupe(u8, "turn_done"),
        .body = try std.testing.allocator.dupe(u8, "status=expectation_failed elapsed_ms=8000"),
    });

    var messages = try buildRecentChatMessages(std.testing.allocator, events.items, "eu estava falando sobre o que com voce?");
    defer freeChatMessages(std.testing.allocator, &messages);

    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
    try std.testing.expectEqual(http.ChatRole.user, messages.items[0].role);
    try std.testing.expectEqualStrings("qual a matematica perfeita de Matheus 1 na biblia", messages.items[0].content);
    try std.testing.expectEqual(http.ChatRole.assistant, messages.items[1].role);
    try std.testing.expectEqualStrings("falamos sobre Mateus 1", messages.items[1].content);
}

test "recent chat assistant merge is bounded" {
    const old = try std.testing.allocator.alloc(u8, max_chat_message_bytes - 2);
    defer std.testing.allocator.free(old);
    @memset(old, 'a');
    const merged = try mergeChatContent(std.testing.allocator, old, "bbbb");
    defer std.testing.allocator.free(merged);

    try std.testing.expect(merged.len <= max_chat_message_bytes + chat_truncated_marker.len);
    try std.testing.expect(std.mem.endsWith(u8, merged, chat_truncated_marker));
}

test "deferred stream sink buffers tool call text before rendering" {
    var db = try audit.AuditDb.open(std.testing.allocator, ":memory:");
    defer db.close();

    var bus = ui_events.EventBus.init(std.testing.allocator);
    defer bus.deinit();
    var recorder = EventRecorder{};
    try bus.on(&recorder, EventRecorder.handleOpaque);

    var sink = StreamSink{
        .allocator = std.testing.allocator,
        .events = &bus,
        .db = &db,
        .session = "defer-test",
        .ui = null,
        .filter = reasoning_filter.ReasoningFilter.init(std.testing.allocator, false),
        .visible = std.ArrayList(u8).empty,
        .visible_bytes = 0,
        .thinking_bytes = 0,
        .defer_visible = true,
    };
    defer sink.deinit();

    const xml =
        \\<tool_call>
        \\<function=collect_evidence>
        \\<parameter=path>README.md</parameter>
        \\<parameter=strategy>path</parameter>
        \\</function>
        \\</tool_call>
    ;
    try sink.writeVisible(xml);
    try std.testing.expectEqual(@as(usize, 0), recorder.message_chunks);
    try std.testing.expectEqual(@as(usize, 0), sink.visible_bytes);
    try std.testing.expect(std.mem.indexOf(u8, sink.raw_visible.items, "<tool_call>") != null);

    const call = (try tool_call.parseFirst(std.testing.allocator, sink.raw_visible.items)) orelse return error.NoToolCall;
    defer call.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("collect_evidence", call.name);
    try std.testing.expectEqualStrings("README.md", call.path.?);
}

test "deferred stream sink keeps hidden tool calls parseable" {
    var db = try audit.AuditDb.open(std.testing.allocator, ":memory:");
    defer db.close();

    var bus = ui_events.EventBus.init(std.testing.allocator);
    defer bus.deinit();
    var sink = StreamSink{
        .allocator = std.testing.allocator,
        .events = &bus,
        .db = &db,
        .session = "hidden-tool-test",
        .ui = null,
        .filter = reasoning_filter.ReasoningFilter.init(std.testing.allocator, false),
        .visible = std.ArrayList(u8).empty,
        .visible_bytes = 0,
        .thinking_bytes = 0,
        .defer_visible = true,
    };
    defer sink.deinit();

    try sink.onDelta(
        \\<think><tool_call><function=collect_evidence><parameter=stage>expand</parameter><parameter=selectedCandidate>C2</parameter></function></tool_call></think>
    );
    try sink.flush();

    try std.testing.expect(std.mem.indexOf(u8, sink.raw_visible.items, "<tool_call>") == null);
    try std.testing.expect(std.mem.indexOf(u8, sink.raw_model.items, "<tool_call>") != null);
    const call = (try tool_call.parseFirst(std.testing.allocator, sink.raw_model.items)) orelse return error.NoToolCall;
    defer call.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("expand", call.stage.?);
    try std.testing.expectEqualStrings("C2", call.selected_candidate.?);
}

test "deferred stream sink flushes normal answer exactly once" {
    var db = try audit.AuditDb.open(std.testing.allocator, ":memory:");
    defer db.close();

    var bus = ui_events.EventBus.init(std.testing.allocator);
    defer bus.deinit();
    var recorder = EventRecorder{};
    try bus.on(&recorder, EventRecorder.handleOpaque);

    var sink = StreamSink{
        .allocator = std.testing.allocator,
        .events = &bus,
        .db = &db,
        .session = "defer-answer-test",
        .ui = null,
        .filter = reasoning_filter.ReasoningFilter.init(std.testing.allocator, false),
        .visible = std.ArrayList(u8).empty,
        .visible_bytes = 0,
        .thinking_bytes = 0,
        .defer_visible = true,
    };
    defer sink.deinit();

    try sink.writeVisible("resposta final");
    try std.testing.expectEqual(@as(usize, 0), recorder.message_chunks);
    try sink.flushDeferredVisible();
    try std.testing.expectEqual(@as(usize, 1), recorder.message_chunks);
    try std.testing.expectEqualStrings("resposta final", sink.visible.items);
    try sink.flushDeferredVisible();
    try std.testing.expectEqual(@as(usize, 1), recorder.message_chunks);
}

test "deferred stream sink can discard protocol violating prose" {
    var db = try audit.AuditDb.open(std.testing.allocator, ":memory:");
    defer db.close();

    var bus = ui_events.EventBus.init(std.testing.allocator);
    defer bus.deinit();
    var sink = StreamSink{
        .allocator = std.testing.allocator,
        .events = &bus,
        .db = &db,
        .session = "discard",
        .ui = null,
        .filter = reasoning_filter.ReasoningFilter.init(std.testing.allocator, false),
        .visible = std.ArrayList(u8).empty,
        .visible_bytes = 0,
        .thinking_bytes = 0,
        .defer_visible = true,
        .trim_visible_leading_whitespace = false,
    };
    defer sink.deinit();

    try sink.writeVisible("resposta sem tool");
    sink.discardDeferredVisible();
    try std.testing.expectEqual(@as(usize, 0), sink.raw_visible.items.len);
    try sink.flushDeferredVisible();
    try std.testing.expectEqual(@as(usize, 0), sink.visible_bytes);
}

test "initial context repair preserves context and asks for intent terms split" {
    const initial =
        \\[TURN_CONTEXT v1]
        \\[NEXT_ACTION]
        \\First emit exactly one context tool call before prose.
    ;
    try std.testing.expect(initialContextRequiresTool(initial));
    const repair = try renderInitialToolCallRepairContext(std.testing.allocator, initial);
    defer std.testing.allocator.free(repair);
    try std.testing.expect(std.mem.indexOf(u8, repair, "[PROTOCOL_REPAIR]") != null);
    try std.testing.expect(std.mem.indexOf(u8, repair, "<parameter=intent>") != null);
    try std.testing.expect(std.mem.indexOf(u8, repair, "<parameter=terms>") != null);
    try std.testing.expect(std.mem.indexOf(u8, repair, "do not copy the user's vague wording") != null);
}

test "model context budget audit records pre-send buckets without token estimates" {
    var db = try audit.AuditDb.open(std.testing.allocator, ":memory:");
    defer db.close();
    const rendered = try model_context.renderModelTurnContext(std.testing.allocator, .{
        .task = "corrigir",
        .contracts = "tools: collect_evidence",
        .evidence = &[_]model_context.EvidenceBlock{.{ .text = "packet_version=v1\n- E1 kind=file_range source=src/a.zig range=L1-L1 status=ok confidence=medium hash=1\nconst x = 1;" }},
        .next_action_v1 = .{ .kind = .collect_context, .required_tool_calls = 1, .text = "collect evidence" },
    });
    defer std.testing.allocator.free(rendered);

    try recordModelContextBudget(std.testing.allocator, &db, "budget-audit", rendered);
    var events = try db.loadSessionEvents(std.testing.allocator, "budget-audit", 8);
    defer audit.freeAuditEvents(std.testing.allocator, &events);

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqualStrings("model_context_budget", events.items[0].kind);
    try std.testing.expect(std.mem.indexOf(u8, events.items[0].body, "pre_send=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, events.items[0].body, "tokenizer=unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, events.items[0].body, "token_estimate=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, events.items[0].body, "evidence_bytes=") != null);
    try std.testing.expect(std.mem.indexOf(u8, events.items[0].body, "next_action_bytes=") != null);
}

test "model context budget blocks oversized pre-send context" {
    var db = try audit.AuditDb.open(std.testing.allocator, ":memory:");
    defer db.close();
    var large = std.ArrayList(u8).empty;
    defer large.deinit(std.testing.allocator);
    try large.appendSlice(std.testing.allocator, "[TURN_CONTEXT v1]\ntask: x\n");
    while (large.items.len <= max_model_context_send_bytes) {
        try large.appendSlice(std.testing.allocator, "x");
    }

    try std.testing.expectError(error.ModelContextBudgetExceeded, recordModelContextBudget(std.testing.allocator, &db, "budget-fail", large.items));
}

test "pathless collect evidence requires model search intent and terms" {
    const weak_xml =
        \\<tool_call>
        \\<function=collect_evidence>
        \\<parameter=strategy>auto</parameter>
        \\</function>
        \\</tool_call>
    ;
    const weak = (try tool_call.parseFirst(std.testing.allocator, weak_xml)) orelse return error.NoToolCall;
    defer weak.deinit(std.testing.allocator);
    try std.testing.expect(collectEvidenceNeedsSearchIntentRepair(&weak, null, .auto));

    const focused_xml =
        \\<tool_call>
        \\<function=collect_evidence>
        \\<parameter=intent>find CLI renderer implementation</parameter>
        \\<parameter=strategy>symbol</parameter>
        \\<parameter=terms>renderer render output TerminalUi markdown diff</parameter>
        \\</function>
        \\</tool_call>
    ;
    const focused = (try tool_call.parseFirst(std.testing.allocator, focused_xml)) orelse return error.NoToolCall;
    defer focused.deinit(std.testing.allocator);
    try std.testing.expect(!collectEvidenceNeedsSearchIntentRepair(&focused, null, .symbol));

    const focused_v2_xml =
        \\<tool_call>
        \\<function=collect_evidence>
        \\<parameter=intent>find mutation contract executor</parameter>
        \\<parameter=strategy>lexical</parameter>
        \\<parameter=need>apply_patch route</parameter>
        \\<parameter=targetFiles>src/main.zig</parameter>
        \\</function>
        \\</tool_call>
    ;
    const focused_v2 = (try tool_call.parseFirst(std.testing.allocator, focused_v2_xml)) orelse return error.NoToolCall;
    defer focused_v2.deinit(std.testing.allocator);
    try std.testing.expect(!collectEvidenceNeedsSearchIntentRepair(&focused_v2, null, .lexical));

    const placeholder_xml =
        \\<tool_call>
        \\<function=collect_evidence>
        \\<parameter=intent>definition candidates to compare</parameter>
        \\<parameter=strategy>symbol</parameter>
        \\<parameter=stage>candidates</parameter>
        \\<parameter=terms>specific retrieval keys</parameter>
        \\</function>
        \\</tool_call>
    ;
    const placeholder = (try tool_call.parseFirst(std.testing.allocator, placeholder_xml)) orelse return error.NoToolCall;
    defer placeholder.deinit(std.testing.allocator);
    try std.testing.expect(collectEvidenceNeedsSearchIntentRepair(&placeholder, null, .symbol));

    const path_xml =
        \\<tool_call>
        \\<function=collect_evidence>
        \\<parameter=path>src/main.zig</parameter>
        \\<parameter=strategy>path</parameter>
        \\</function>
        \\</tool_call>
    ;
    const path = (try tool_call.parseFirst(std.testing.allocator, path_xml)) orelse return error.NoToolCall;
    defer path.deinit(std.testing.allocator);
    try std.testing.expect(!collectEvidenceNeedsSearchIntentRepair(&path, path.path, .path));
}

test "pathless collect evidence uses exploratory budget cap" {
    try std.testing.expectEqual(@as(usize, max_pathless_collect_budget), collectEvidenceExecutionBudget(null, defaultContextBudgetForTest()));
    try std.testing.expectEqual(@as(usize, 512), collectEvidenceExecutionBudget(null, 512));
    try std.testing.expectEqual(@as(usize, defaultContextBudgetForTest()), collectEvidenceExecutionBudget("src/main.zig", defaultContextBudgetForTest()));
}

fn defaultContextBudgetForTest() usize {
    return 18 * 1024;
}

test "collect evidence search intent repair explains model responsibility" {
    const repair = try renderCollectEvidenceSearchIntentRepairContext(
        std.testing.allocator,
        "qual e a funcao que renderiza o cli?",
        context_profile.toolSchema(.code_evidence, .initial),
    );
    defer std.testing.allocator.free(repair);
    try std.testing.expect(std.mem.indexOf(u8, repair, "pathless collect_evidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, repair, "<parameter=intent>") != null);
    try std.testing.expect(std.mem.indexOf(u8, repair, "<parameter=terms>") != null);
    try std.testing.expect(std.mem.indexOf(u8, repair, "controller does not infer search terms") != null);
}

test "tool loop state detects duplicate collect evidence calls and preserves evidence" {
    const xml =
        \\<tool_call>
        \\<function=collect_evidence>
        \\<parameter=path>README.md</parameter>
        \\<parameter=strategy>path</parameter>
        \\<parameter=start_line>1</parameter>
        \\<parameter=max_lines>12</parameter>
        \\</function>
        \\</tool_call>
    ;
    const call = (try tool_call.parseFirst(std.testing.allocator, xml)) orelse return error.NoToolCall;
    defer call.deinit(std.testing.allocator);

    var state = ToolLoopState.init(std.testing.allocator);
    defer state.deinit();
    const strategy = call.strategy orelse contracts.StrategyName.path;
    try std.testing.expect(!state.hasExecutedArgs(call.path, call.terms, strategy, call.start_line, call.max_lines));
    try state.rememberExecutedArgs(call.path, call.terms, strategy, call.start_line, call.max_lines, "ctx_readme", "[EVIDENCE]\n- README.md L1-L12 hash=abc\n", 120, 72);
    try std.testing.expect(state.hasExecutedArgs(call.path, call.terms, strategy, call.start_line, call.max_lines));
    try std.testing.expectEqual(@as(usize, 1), state.context.entries.items.len);
    try std.testing.expect(std.mem.indexOf(u8, state.context.entries.items[0].evidence_text, "README.md") != null);
}

test "tool loop state keeps session evidence for duplicate search repair" {
    var state = ToolLoopState.init(std.testing.allocator);
    defer state.deinit();
    const key = "scope=all session= terms=matematica perfeita Mateus 1 biblia";
    const session_text =
        \\[SESSION_EVIDENCE]
        \\source=sqlite_audit_fts temporary=true raw_context_persisted=false semantic_search=fts5_bm25
        \\- S1 score=27.4210 session=default turn_start: qual a matematica perfeita de Matheus 1 na biblia
    ;

    try state.rememberSessionSearch(key);
    try state.rememberSessionContext(session_text);
    try std.testing.expect(state.hasSessionSearch(key));
    try std.testing.expect(state.last_session_context != null);

    const rendered = try renderCollectedEvidenceContext(
        std.testing.allocator,
        "eu estava falando sobre o que com voce?",
        &state.context,
        state.last_session_context,
        null,
        context_profile.toolSchema(.session_recall, .after_search_session),
        "The requested session search was already performed in this turn. Answer using existing E#/S# evidence.",
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "[SESSION_CONTEXT]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "S1:") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Matheus 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "already performed") != null);
}

test "candidate selection repair reuses temporary candidates only" {
    var state = ToolLoopState.init(std.testing.allocator);
    defer state.deinit();

    var candidates = std.ArrayList(collect_evidence.CandidateItem).empty;
    var candidates_owned_by_result = false;
    errdefer if (!candidates_owned_by_result) {
        for (candidates.items) |candidate| candidate.deinit(std.testing.allocator);
        candidates.deinit(std.testing.allocator);
    };
    try candidates.append(std.testing.allocator, .{
        .id = try std.testing.allocator.dupe(u8, "C1"),
        .path = try std.testing.allocator.dupe(u8, "src/render.zig"),
        .start_line = 10,
        .end_line = 20,
        .score = 80,
        .source = try std.testing.allocator.dupe(u8, "symbol_ast"),
        .signature = try std.testing.allocator.dupe(u8, "pub fn AppendOnlyRenderer"),
        .preview = try std.testing.allocator.dupe(u8, "symbol_ast"),
    });
    var result = collect_evidence.CandidateResult{
        .text = try std.testing.allocator.dupe(u8, "[CANDIDATES]\n- C1 path=src/render.zig\n"),
        .audit_text = try std.testing.allocator.dupe(u8, "[TOOL_EVENT]\ntool=collect_evidence\n"),
        .model_bytes = 38,
        .candidates = candidates,
    };
    candidates_owned_by_result = true;
    defer result.deinit(std.testing.allocator);

    try state.rememberCandidates(&result);
    try std.testing.expectEqual(@as(usize, 0), state.context.entries.items.len);
    const rendered = try renderCandidateSelectionContext(
        std.testing.allocator,
        "qual funcao renderiza o cli?",
        &state,
        "select one candidate",
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "[CANDIDATES_CONTEXT]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[CANDIDATES]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "C1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "select one candidate") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\n[EVIDENCE]\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "E1:") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[MEMORY]") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[SKILLS]") == null);
}

test "structured prompt path repair extracts only one explicit path" {
    const repaired = (try singleStructuredPathFromPrompt(std.testing.allocator, "Use collect_evidence no arquivo README.md")) orelse return error.MissingPath;
    defer std.testing.allocator.free(repaired);
    try std.testing.expectEqualStrings("README.md", repaired);
    const punctuated = (try singleStructuredPathFromPrompt(std.testing.allocator, "a evidencia alvo e README.md.")) orelse return error.MissingPath;
    defer std.testing.allocator.free(punctuated);
    try std.testing.expectEqualStrings("README.md", punctuated);
    try std.testing.expect((try singleStructuredPathFromPrompt(std.testing.allocator, "compare README.md e TASKS.md")) == null);
    try std.testing.expect((try singleStructuredPathFromPrompt(std.testing.allocator, "analise o arquivo")) == null);
    try std.testing.expect((try singleStructuredPathFromPrompt(std.testing.allocator, "../README.md")) == null);
    const dotted = (try singleStructuredPathFromPrompt(std.testing.allocator, "analise foo..txt")) orelse return error.MissingPath;
    defer std.testing.allocator.free(dotted);
    try std.testing.expectEqualStrings("foo..txt", dotted);
}

test "tool loop state dedupe uses repaired effective path" {
    var state = ToolLoopState.init(std.testing.allocator);
    defer state.deinit();
    try state.rememberExecutedArgs("README.md", null, .path, 1, 12, "ctx_readme", "[EVIDENCE]\n- README.md L1-L12 hash=abc\n", 120, 72);
    try std.testing.expect(state.hasExecutedArgs("README.md", null, .path, 1, 12));
    try std.testing.expect(!state.hasExecutedArgs(null, null, .auto, 1, 12));
    try state.rememberExecutedArgs(null, "render", .auto, 1, 12, "ctx_render", "[EVIDENCE]\n- src/render.zig L1-L12 hash=abc\n", 120, 40);
    try std.testing.expect(state.hasExecutedArgs(null, "render", .auto, 1, 12));
    try std.testing.expect(!state.hasExecutedArgs(null, "http", .auto, 1, 12));
}

test "duplicate evidence context keeps evidence and tool schema" {
    var state = ToolLoopState.init(std.testing.allocator);
    defer state.deinit();
    try state.rememberExecutedArgs("README.md", null, .path, 1, 12, "ctx_readme", "[EVIDENCE]\n- README.md L1-L12 hash=abc\n", 120, 72);
    const rendered = try renderCollectedEvidenceContext(
        std.testing.allocator,
        "responda",
        &state.context,
        null,
        null,
        context_profile.toolSchema(.code_evidence, .after_collect_evidence),
        "Answer now. Do not call tools again.",
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "[EVIDENCE]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "README.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[TOOLS v1]") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "collect_evidence(") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "set_operational_contract") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Use only collected evidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Do not call tools again") != null);
}

test "model evidence includes micro context id for patch safety" {
    const rendered = try renderEvidenceAndMicroContext(
        std.testing.allocator,
        "[EVIDENCE]\n- src/a.zig L1-L2 hash=abc\n",
        "[MICRO_CONTEXT id=ctx_123 path=src/a.zig lines=1-2 total_lines=2 sha256=abc source_tool=collect_evidence budget_bytes=128]\nold\n",
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[EVIDENCE]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[MICRO_CONTEXT") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "ctx_123") != null);
}

test "tool loop state starts with model-visible operational contract gate" {
    var state = ToolLoopState.init(std.testing.allocator);
    defer state.deinit();
    try std.testing.expectEqual(contracts.ContractName.collect_evidence, state.active_contract.name);
    try std.testing.expect(state.active_contract.allows("set_operational_contract"));
    try std.testing.expect(state.active_contract.allows("collect_evidence"));
    try std.testing.expect(!state.active_contract.allows("apply_patch"));
}

test "allowed tools render compact audit list" {
    const active = contracts.activeContract(.mutate_file) orelse return error.MissingContract;
    const rendered = try renderAllowedTools(std.testing.allocator, active.allowed_tools);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("collect_evidence,search_session,apply_patch", rendered);
}

test "active tool schema follows selected contract" {
    var state = ToolLoopState.init(std.testing.allocator);
    defer state.deinit();
    state.active_contract = contracts.activeContract(.mutate_file).?;
    try std.testing.expect(std.mem.indexOf(u8, activeToolSchema(&state), "apply_patch") != null);

    state.active_contract = contracts.activeContract(.validate_work).?;
    try std.testing.expect(std.mem.indexOf(u8, activeToolSchema(&state), "validate_syntax") != null);
    try std.testing.expect(std.mem.indexOf(u8, activeToolSchema(&state), "apply_patch") == null);

    state.active_contract = contracts.activeContract(.memory).?;
    try std.testing.expect(std.mem.indexOf(u8, activeToolSchema(&state), "promote_context") != null);
    try std.testing.expect(std.mem.indexOf(u8, activeToolSchema(&state), "apply_patch") == null);
}

test "plural selected candidates uses first candidate id" {
    try std.testing.expectEqualStrings("C2", firstSelectedCandidate("C2,C3").?);
    try std.testing.expectEqualStrings("C4", firstSelectedCandidate(" C4 C5 ").?);
    try std.testing.expect(firstSelectedCandidate(null) == null);
}

test "collected evidence context renders compact anchors without memory skills or old full text" {
    var state = ToolLoopState.init(std.testing.allocator);
    defer state.deinit();
    try state.rememberExecutedArgs("README.md", null, .path, 1, 12, "ctx_readme", "[EVIDENCE]\n- README.md L1-L12 hash=abc\nold full text should disappear\n", 180, 72);
    state.context.compactAll();
    const rendered = try renderCollectedEvidenceContext(
        std.testing.allocator,
        "responda",
        &state.context,
        null,
        null,
        context_profile.toolSchema(.code_evidence, .after_collect_evidence),
        "Answer from compact anchors.",
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "[EVIDENCE_ANCHOR]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "old full text should disappear") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[MEMORY]") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[SKILLS]") == null);
}

test "collected context can include temporary session evidence without memory" {
    var state = ToolLoopState.init(std.testing.allocator);
    defer state.deinit();
    const rendered = try renderCollectedEvidenceContext(
        std.testing.allocator,
        "o que combinamos?",
        &state.context,
        "[SESSION_EVIDENCE]\n- S1 score=10 turn_start: combinamos groundedness\n",
        null,
        context_profile.toolSchema(.session_recall, .after_search_session),
        "Answer with S# citations.",
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "[SESSION_CONTEXT]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "combinamos groundedness") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[MEMORY]") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[SKILLS]") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Exact claims about what was said") != null);
}

test "session evidence context keeps focus map for corrective searches" {
    var state = ToolLoopState.init(std.testing.allocator);
    defer state.deinit();
    const rendered = try renderCollectedEvidenceContext(
        std.testing.allocator,
        "voce lembra do que estavamos conversando?",
        &state.context,
        "[SESSION_EVIDENCE]\n- S1 score=1 assistant: tentativa antiga sem assunto util\n",
        "source=sqlite_session_focus temporary=true raw_context_persisted=false operational_summary=true not_evidence=true\n- F1 quality=confirmed\n  topic: Mateus 1\n",
        context_profile.toolSchema(.session_recall, .after_search_session),
        "Use SESSION_FOCUS for another search with intent plus concrete keys if S# is not useful.",
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "[SESSION_CONTEXT]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[SESSION_FOCUS]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "topic: Mateus 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "not_evidence=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "concrete keys") != null);
}

test "grounding rules separate dialogue continuity from exact session evidence" {
    const rules = groundingRules();
    try std.testing.expect(std.mem.indexOf(u8, rules[2], "[RECENT_DIALOGUE]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rules[2], "continuity") != null);
    try std.testing.expect(std.mem.indexOf(u8, rules[2], "S#") != null);
    try std.testing.expect(std.mem.indexOf(u8, rules[3], "collect_evidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, rules[3], "retrieval keys") != null);
    try std.testing.expect(std.mem.indexOf(u8, rules[4], "search_session") != null);
    try std.testing.expect(std.mem.indexOf(u8, rules[4], "retrieval keys") != null);
    try std.testing.expect(std.mem.indexOf(u8, rules[5], "history is unavailable") != null);
}

const EventRecorder = struct {
    message_chunks: usize = 0,

    fn handleOpaque(ctx: *anyopaque, event: ui_events.Event) !void {
        const self: *EventRecorder = @ptrCast(@alignCast(ctx));
        switch (event) {
            .message_chunk => self.message_chunks += 1,
            else => {},
        }
    }
};

fn countNeedle(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    var count: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOf(u8, haystack[start..], needle)) |idx| {
        count += 1;
        start += idx + needle.len;
    }
    return count;
}
