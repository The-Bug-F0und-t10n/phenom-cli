const std = @import("std");

const audit = @import("audit.zig");
const cli = @import("cli.zig");
const collect_evidence = @import("collect_evidence.zig");
const context_profile = @import("context_profile.zig");
const contracts = @import("contracts.zig");
const config_file = @import("config_file.zig");
const evidence = @import("evidence.zig");
const fd_writer = @import("fd_writer.zig");
const gate = @import("gate.zig");
const http = @import("http.zig");
const micro_context = @import("micro_context.zig");
const model_context = @import("model_context.zig");
const persistent_context = @import("persistent_context.zig");
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

    if (ui_ptr) |active_ui| active_ui.clearTokenUsage();
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
            const handled_by_tool_loop = runToolLoopIterations(allocator, io, config, prompt, sink.raw_visible.items, &client, &events, &db, ui_ptr, &sink) catch |err| blk: {
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
    var session_recall_contract = false;
    for (turn_events.items) |event| {
        if (std.mem.eql(u8, event.kind, "session_context")) used_session_context = true;
        if (std.mem.eql(u8, event.kind, "evidence")) used_evidence = true;
        if (std.mem.eql(u8, event.kind, "tool_start") and std.mem.startsWith(u8, event.body, "search_session")) used_session_context = true;
        if (std.mem.eql(u8, event.kind, "tool_start") and std.mem.startsWith(u8, event.body, "collect_evidence")) used_evidence = true;
        if (std.mem.eql(u8, event.kind, "model_context") and std.mem.indexOf(u8, event.body, "mode: session_recall") != null) session_recall_contract = true;
    }
    const ok_status = std.mem.eql(u8, status, "ok");
    const contract_missing_context = session_recall_contract and !used_session_context;
    const low_confidence = !ok_status or !answered or contract_missing_context;
    const quality: []const u8 = if (!ok_status or !answered)
        "failed"
    else if (low_confidence)
        "uncertain"
    else
        "confirmed";
    const flags = try std.fmt.allocPrint(
        allocator,
        "answered={} used_session_context={} used_evidence={} refusal=false contradicted_context=false contract_missing_context={} low_confidence={}",
        .{ answered, used_session_context, used_evidence, contract_missing_context, low_confidence },
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

    var focus_rows = try db.loadRecentSessionFocus(allocator, session, 16);
    defer audit.freeSessionFocus(allocator, &focus_rows);
    var focus_text = try session_context.renderSessionFocus(allocator, focus_rows.items);
    if (focus_text == null) {
        focus_text = try session_context.renderFallbackSessionFocusFromEvents(allocator, session_events.items, prompt);
    }
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
            "SESSION_FOCUS is present. First emit exactly one context tool call before prose: use search_session for prior-session facts, or collect_evidence for workspace/source-code facts. The model chooses the tool and terms; the controller only executes it."
        else if (enable_tool_loop)
            "Infer the user's intent. If the answer requires workspace/source-code facts, call collect_evidence with model-chosen terms or path. If the answer requires prior-session facts, call search_session with model-chosen terms before answering. Otherwise answer directly."
        else
            "Apply persistent MEMORY/SKILLS only if relevant; answer the current user request directly.",
    });
}

const max_tool_emergency_iterations = 8;
const max_tool_repairs = 1;
const max_duplicate_tool_repairs = 1;

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
    if (!std.mem.eql(u8, call.name, "collect_evidence")) {
        try db.recordEvent(config.session, "tool_rejected", call.name);
        return .stopped;
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
    if (path == null and strategy == .path) {
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
                context_profile.toolSchema(.code_evidence, .active_contract)
            else
                context_profile.toolSchema(.code_evidence, .initial),
            .obligations = &.{
                "A collect_evidence call must include <parameter=path>relative/file</parameter>.",
                "Do not answer with prose until evidence is collected or you decide evidence is unnecessary.",
            },
            .next_action = "Emit one corrected collect_evidence tool call with path, or answer directly if no file evidence is needed.",
        });
        defer allocator.free(repair_context);
        try db.recordEvent(config.session, "model_context", repair_context);
        return try streamDeferredToolLoopTurn(allocator, config, prompt, repair_context, client, events, db, ui_ptr, aggregate_sink, state.active_contract);
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
    const tool_start = try std.fmt.allocPrint(allocator, "collect_evidence\t{s}", .{path orelse @tagName(strategy)});
    defer allocator.free(tool_start);
    try db.recordEvent(config.session, "tool_start", tool_start);
    try events.emit(.{ .tool_start = .{ .name = "collect_evidence", .detail = path orelse @tagName(strategy) } });

    const result = collect_evidence.execute(allocator, io, .{
        .path = path,
        .terms = call.terms,
        .task = prompt,
        .strategy = strategy,
        .start_line = call.start_line,
        .max_lines = call.max_lines,
        .budget_bytes = state.remainingBudget(),
    }) catch |err| {
        try db.recordEvent(config.session, "tool_error", @errorName(err));
        try events.emit(.{ .tool_result = .{ .name = "collect_evidence", .output = @errorName(err) } });
        const follow_context = try renderCollectedEvidenceContext(
            allocator,
            prompt,
            &state.context,
            null,
            context_profile.toolSchema(.code_evidence, .after_collect_evidence),
            "collect_evidence encountered an error. Answer the current user request directly.",
        );
        defer allocator.free(follow_context);
        try db.recordEvent(config.session, "model_context", follow_context);
        return try streamDeferredToolLoopTurn(allocator, config, prompt, follow_context, client, events, db, ui_ptr, aggregate_sink, state.active_contract);
    };
    defer result.deinit(allocator);

    try db.recordEvent(config.session, "tool_event", result.tool_event_audit_text);
    try db.recordEvent(config.session, "evidence", result.evidence_text);
    try events.emit(.{ .tool_result = .{ .name = "collect_evidence", .output = result.evidence_text } });
    try state.rememberExecutedArgs(path, call.terms, strategy, call.start_line, call.max_lines, result.context_id, result.evidence_text, result.model_bytes, result.quality_score);
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
        context_profile.toolSchema(.code_evidence, .after_collect_evidence),
        if (state.shouldAllowMoreEvidence())
            "Answer using only cited evidence above. Cite E# for workspace claims and S# for session claims. Do not add capabilities, files, tools, or architecture not present in evidence. If a different evidence range is strictly required and budget remains, emit one collect_evidence or search_session call. Do not request the same file/range/session terms again."
        else
            "Answer the current user request using only cited evidence above. Do not add capabilities, files, tools, architecture, or prior-session facts not present in evidence. If evidence is insufficient, say what is evidenced and what is not. Do not call tools again in this turn.",
    );
    defer allocator.free(follow_context);
    try db.recordEvent(config.session, "model_context", follow_context);

    return try streamDeferredToolLoopTurn(allocator, config, prompt, follow_context, client, events, db, ui_ptr, aggregate_sink, state.active_contract);
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
            .contracts = context_profile.toolSchema(.code_evidence, .active_contract),
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
        .contracts = context_profile.toolSchema(.code_evidence, .active_contract),
        .obligations = &.{
            "The operational contract is now active for this turn.",
            "Only advertised tools may be called. Future mutation/validation executors remain blocked until their contracts are implemented.",
        },
        .grounding = groundingRules(),
        .next_action = "Proceed inside the active contract. If workspace evidence is needed, call collect_evidence with model-chosen terms/path. Do not call mutation tools unless they are advertised.",
    });
    defer allocator.free(follow_context);
    try db.recordEvent(config.session, "model_context", follow_context);
    return try streamDeferredToolLoopTurn(allocator, config, prompt, follow_context, client, events, db, ui_ptr, aggregate_sink, state.active_contract);
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
    if (terms.len == 0) {
        try db.recordEvent(config.session, "tool_repair", "search_session missing terms");
        const repair_context = try renderCollectedEvidenceContext(
            allocator,
            prompt,
            &state.context,
            null,
            context_profile.toolSchema(.session_recall, .active_contract),
            "Emit one corrected search_session tool call with <parameter=terms>describing what prior session fact you need</parameter>, or answer using current evidence only.",
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
    const tool_start = try std.fmt.allocPrint(allocator, "search_session\t{s}", .{search_key});
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

    const follow_context = try renderCollectedEvidenceContext(
        allocator,
        prompt,
        &state.context,
        result.text,
        context_profile.toolSchema(.session_recall, .after_search_session),
        "Use SESSION_CONTEXT as retrieved prior-session evidence. Cite S# when stating what was said or done in a session; S# includes session ids when search crossed sessions. Cite E# for workspace facts. For technical judgment, use retrieved context plus the current user request; do not claim unsupported workspace/session facts. If more evidence is needed and budget remains, emit one targeted collect_evidence or search_session call.",
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

fn renderAllowedTools(allocator: std.mem.Allocator, allowed_tools: []const []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (allowed_tools, 0..) |tool, idx| {
        if (idx > 0) try out.appendSlice(allocator, ",");
        try out.appendSlice(allocator, tool);
    }
    return out.toOwnedSlice(allocator);
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
    if (ui_ptr) |active_ui| try active_ui.showStatus("Thinking");
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
    try client.streamInference(.{ .user_prompt = prompt, .model_context = follow_context }, &follow_sink);
    try follow_sink.flush();

    var envelope = (tool_envelope.parseFirst(allocator, follow_sink.raw_visible.items, active_contract) catch |err| {
        try db.recordEvent(config.session, "tool_envelope_error", @errorName(err));
        return .stopped;
    }) orelse {
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
    last_session_context: ?[]u8 = null,
    active_contract: contracts.ActiveContract,
    duplicate_repairs: usize = 0,
    contract_selected: bool = false,
    duplicate_contract_repairs: usize = 0,

    fn init(allocator: std.mem.Allocator) ToolLoopState {
        return .{
            .context = working_context.WorkingContext.init(allocator),
            .session_searches = std.ArrayList([]u8).empty,
            .active_contract = currentActiveContract(),
        };
    }

    fn deinit(self: *ToolLoopState) void {
        for (self.session_searches.items) |terms| self.context.allocator.free(terms);
        self.session_searches.deinit(self.context.allocator);
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
};

fn renderCollectedEvidenceContext(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    context: *const working_context.WorkingContext,
    session_text: ?[]const u8,
    contracts_text: []const u8,
    next_action: []const u8,
) ![]u8 {
    const evidence_blocks = try context.renderEvidenceBlocks(allocator);
    defer allocator.free(evidence_blocks);
    const session_blocks = try session_context.toSessionBlocks(allocator, session_text);
    defer allocator.free(session_blocks);
    return model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .contracts = contracts_text,
        .evidence = evidence_blocks,
        .session = session_blocks,
        .obligations = &.{
            "Use only collected evidence for claims about this workspace or prior session.",
        },
        .grounding = groundingRules(),
        .next_action = next_action,
    });
}

fn collectEvidenceToolSchema(include_contract_tool: bool) []const u8 {
    return if (include_contract_tool)
        context_profile.toolSchema(.code_evidence, .initial)
    else
        context_profile.toolSchema(.code_evidence, .active_contract);
}

fn groundingRules() []const []const u8 {
    return &.{
        "Workspace/source-code claims must cite E# evidence from [EVIDENCE].",
        "Use [RECENT_DIALOGUE] for continuity only; use [SESSION_FOCUS] only as a routing map. Exact claims about what was said or done in prior conversation must cite S# evidence from [SESSION_CONTEXT].",
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
    var events = try db.loadSessionEvents(allocator, session, 5000);
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
    for (events.items) |event| {
        if (std.mem.eql(u8, event.kind, "turn_start")) {
            if (restored_turn_open) try bus.emit(.{ .think_end = {} });
            try bus.emit(.{ .user_message = event.body });
            try bus.emit(.{ .think_start = "Thinking" });
            restored_turn_open = true;
            restored_turn_started_s = event.created_at_unix_s;
        } else if (std.mem.eql(u8, event.kind, "assistant_thinking_delta")) {
            try bus.emit(.{ .reasoning_chunk = event.body });
            restored_turn_open = true;
        } else if (std.mem.eql(u8, event.kind, "assistant_delta") or std.mem.eql(u8, event.kind, "assistant_offline_stub")) {
            try bus.emit(.{ .message_chunk = event.body });
            restored_turn_open = true;
        } else if (std.mem.eql(u8, event.kind, "tool_start")) {
            const parsed = parseRestoredToolStart(event.body);
            try bus.emit(.{ .tool_start = .{ .name = parsed.name, .detail = parsed.detail } });
            restored_turn_open = true;
        } else if (std.mem.eql(u8, event.kind, "evidence")) {
            try bus.emit(.{ .tool_result = .{ .name = "read_file_range", .output = event.body } });
            restored_turn_open = true;
        } else if (std.mem.eql(u8, event.kind, "model_error")) {
            try bus.emit(.{ .progress_update = event.body });
            restored_turn_open = true;
        } else if (std.mem.eql(u8, event.kind, "empty_visible_answer")) {
            try bus.emit(.{ .progress_update = "model emitted no visible final answer; reasoning was suppressed or generation ended inside <think>" });
            restored_turn_open = true;
        } else if (std.mem.eql(u8, event.kind, "expectation_failed")) {
            try bus.emit(.{ .progress_update = event.body });
            restored_turn_open = true;
        } else if (std.mem.eql(u8, event.kind, "expectation_passed")) {
            restored_turn_open = true;
        } else if (std.mem.eql(u8, event.kind, "turn_done")) {
            try bus.emit(.{ .turn_done = .{ .elapsed_ms = restoredElapsedMs(event.body, restored_turn_started_s, event.created_at_unix_s) } });
            restored_turn_open = false;
            restored_turn_started_s = null;
        }
    }
    if (restored_turn_open) try bus.emit(.{ .think_end = {} });
    return events.items.len;
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
    raw_visible: std.ArrayList(u8) = std.ArrayList(u8).empty,
    visible_bytes: usize,
    thinking_bytes: usize,
    defer_visible: bool = false,
    trim_visible_leading_whitespace: bool = false,

    pub fn deinit(ctx: *StreamSink) void {
        ctx.filter.deinit();
        ctx.visible.deinit(ctx.allocator);
        ctx.raw_visible.deinit(ctx.allocator);
    }

    pub fn onDelta(ctx: *StreamSink, delta: []const u8) !void {
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
    try db.recordEvent("restore", "turn_done", "status=ok elapsed_ms=1234");

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);
    const writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &buffer };

    const count = try renderRestoredSession(std.testing.allocator, &db, "restore", writer, false, 80, false, null);
    try std.testing.expectEqual(@as(usize, 6), count);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "> [") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "analise") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "thinking") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "vou ler") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "Reading") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "README.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "[EVIDENCE]") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "resposta") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, schema, "The model decides search intent") != null);
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
        context_profile.toolSchema(.session_recall, .after_search_session),
        "The requested session search was already performed in this turn. Answer using existing E#/S# evidence.",
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "[SESSION_CONTEXT]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "S1:") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Matheus 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "already performed") != null);
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
    try std.testing.expectEqualStrings("set_operational_contract,collect_evidence,search_session", rendered);
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

test "grounding rules separate dialogue continuity from exact session evidence" {
    const rules = groundingRules();
    try std.testing.expect(std.mem.indexOf(u8, rules[1], "[RECENT_DIALOGUE]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rules[1], "continuity") != null);
    try std.testing.expect(std.mem.indexOf(u8, rules[1], "S#") != null);
    try std.testing.expect(std.mem.indexOf(u8, rules[2], "search_session") != null);
    try std.testing.expect(std.mem.indexOf(u8, rules[2], "history is unavailable") != null);
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
