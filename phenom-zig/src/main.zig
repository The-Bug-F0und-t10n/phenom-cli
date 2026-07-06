const std = @import("std");

const audit = @import("audit.zig");
const cli = @import("cli.zig");
const collect_evidence = @import("collect_evidence.zig");
const contracts = @import("contracts.zig");
const config_file = @import("config_file.zig");
const evidence = @import("evidence.zig");
const evidence_ranker = @import("evidence_ranker.zig");
const fd_writer = @import("fd_writer.zig");
const gate = @import("gate.zig");
const http = @import("http.zig");
const micro_context = @import("micro_context.zig");
const model_context = @import("model_context.zig");
const persistent_context = @import("persistent_context.zig");
const reasoning_filter = @import("reasoning_filter.zig");
const render = @import("render.zig");
const tool_call = @import("tool_call.zig");
const tool_event = @import("tool_event.zig");
const tool_loop = @import("tool_loop.zig");
const tools = @import("tools.zig");
const tui = @import("tui.zig");
const ui_events = @import("ui_events.zig");

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
        .version => try (fd_writer.FdWriter{ .fd = 1 }).print("phenom-zig spike 0.1.0\n", .{}),
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
    } else {
        var client = http.LocalModelClient{
            .allocator = allocator,
            .host = config.host,
            .backend = config.backend,
            .model = config.model,
            .max_tokens = config.max_tokens,
            .thinking = config.thinking,
        };
        const enable_tool_loop = toolLoopEnabled();
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
        const model_context_text = try buildInitialModelContext(allocator, io, prompt, enable_tool_loop);
        defer if (model_context_text) |text| allocator.free(text);
        if (model_context_text) |text| try db.recordEvent(config.session, "model_context", text);

        const inference_input = http.InferenceInput{
            .user_prompt = prompt,
            .model_context = model_context_text,
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
            try recordAndEmitTurnDone(allocator, &db, config.session, &events, turn_started_ms, "model_error");
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
                try recordAndEmitTurnDone(allocator, &db, config.session, &events, turn_started_ms, "expectation_failed");
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
    }

    try recordAndEmitTurnDone(allocator, &db, config.session, &events, turn_started_ms, "ok");
}

fn recordAndEmitTurnDone(
    allocator: std.mem.Allocator,
    db: *audit.AuditDb,
    session: []const u8,
    events: *ui_events.EventBus,
    turn_started_ms: i64,
    status: []const u8,
) !void {
    const elapsed_ms = ui_events.elapsedMillisSince(turn_started_ms);
    const body = try std.fmt.allocPrint(allocator, "status={s} elapsed_ms={}", .{ status, elapsed_ms });
    defer allocator.free(body);
    try db.recordEvent(session, "turn_done", body);
    try events.emit(.{ .turn_done = .{ .elapsed_ms = elapsed_ms } });
}

fn buildInitialModelContext(allocator: std.mem.Allocator, io: std.Io, prompt: []const u8, enable_tool_loop: bool) !?[]u8 {
    const include_persistent = modelContextEnabled();
    const include_collect_evidence_schema = enable_tool_loop and shouldOfferCollectEvidence(prompt);
    if (!include_persistent and !include_collect_evidence_schema) return null;

    var persistent = persistent_context.Loaded.init(allocator);
    defer persistent.deinit();
    if (include_persistent) persistent = try persistent_context.loadFromCwd(allocator, io);

    if (!include_collect_evidence_schema and persistent.memory.items.len == 0 and persistent.skills.items.len == 0) return null;

    return try model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .contracts = if (include_collect_evidence_schema) collectEvidenceToolSchema() else "",
        .memory = persistent.memory.items,
        .skills = persistent.skills.items,
        .next_action = if (include_collect_evidence_schema)
            "If file evidence is required, emit exactly one collect_evidence tool call with path. Otherwise answer directly."
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
    var maybe_call = tool_call.parseFirst(allocator, model_output) catch |err| {
        try db.recordEvent(config.session, "tool_parse_error", @errorName(err));
        return true;
    };
    if (maybe_call == null) return false;

    var tool_iterations: usize = 0;
    var repairs: usize = 0;
    var state = ToolLoopState.init(allocator);
    defer state.deinit();
    while (maybe_call) |call_value| {
        var call = call_value;
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
                maybe_call = next_call;
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
    if (!gate.isAllowed(call.name, &.{"collect_evidence"})) {
        try db.recordEvent(config.session, "tool_rejected", call.name);
        return .stopped;
    }
    if (!std.mem.eql(u8, call.name, "collect_evidence")) {
        try db.recordEvent(config.session, "tool_rejected", call.name);
        return .stopped;
    }

    const strategy = call.strategy orelse if (call.path == null) contracts.StrategyName.auto else contracts.StrategyName.path;
    const path = call.path;
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
            .contracts = collectEvidenceToolSchema(),
            .obligations = &.{
                "A collect_evidence call must include <parameter=path>relative/file</parameter>.",
                "Do not answer with prose until evidence is collected or you decide evidence is unnecessary.",
            },
            .next_action = "Emit one corrected collect_evidence tool call with path, or answer directly if no file evidence is needed.",
        });
        defer allocator.free(repair_context);
        try db.recordEvent(config.session, "model_context", repair_context);
        return try streamDeferredToolLoopTurn(allocator, config, prompt, repair_context, client, events, db, ui_ptr, aggregate_sink);
    }

    if (state.hasExecuted(call.*)) {
        if (state.duplicate_repairs >= max_duplicate_tool_repairs) {
            try db.recordEvent(config.session, "tool_loop_stop", "duplicate collect_evidence repeated after repair");
            return .stopped;
        }
        state.duplicate_repairs += 1;
        const duplicate_body = try std.fmt.allocPrint(allocator, "collect_evidence\t{s}", .{path orelse @tagName(strategy)});
        defer allocator.free(duplicate_body);
        try db.recordEvent(config.session, "tool_duplicate", duplicate_body);
        try events.emit(.{ .progress_update = "skipping duplicate collect_evidence; answering with existing evidence" });

        const duplicate_context = try renderCollectedEvidenceContext(
            allocator,
            prompt,
            state.evidence_texts.items,
            "The requested evidence was already collected in this turn. Answer now using the evidence above. Do not call tools again.",
        );
        defer allocator.free(duplicate_context);
        try db.recordEvent(config.session, "model_context", duplicate_context);
        return try streamDeferredToolLoopTurn(allocator, config, prompt, duplicate_context, client, events, db, ui_ptr, aggregate_sink);
    }

    if (tool_iterations.* >= max_tool_emergency_iterations or !state.hasBudgetForMoreEvidence()) {
        try db.recordEvent(config.session, "tool_loop_stop", "evidence budget exhausted");
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
        .task = prompt,
        .strategy = strategy,
        .start_line = call.start_line,
        .max_lines = call.max_lines,
        .budget_bytes = state.remainingBudget(),
    }) catch |err| {
        try db.recordEvent(config.session, "tool_error", @errorName(err));
        try events.emit(.{ .tool_result = .{ .name = "collect_evidence", .output = @errorName(err) } });
        return .stopped;
    };
    defer result.deinit(allocator);

    try db.recordEvent(config.session, "tool_event", result.tool_event_audit_text);
    try db.recordEvent(config.session, "evidence", result.evidence_text);
    try events.emit(.{ .tool_result = .{ .name = "collect_evidence", .output = result.evidence_text } });
    try state.rememberExecuted(call.*, result.evidence_text);
    state.model_budget_used += result.model_bytes;
    state.best_quality = @max(state.best_quality, result.quality_score);

    const follow_context = try renderCollectedEvidenceContext(
        allocator,
        prompt,
        state.evidence_texts.items,
        if (state.shouldAllowMoreEvidence())
            "Answer using the evidence above. If a different evidence range is strictly required and budget remains, emit one collect_evidence call. Do not request the same file/range again."
        else
            "Answer the current user request using the evidence above. Do not call tools again in this turn.",
    );
    defer allocator.free(follow_context);
    try db.recordEvent(config.session, "model_context", follow_context);

    return try streamDeferredToolLoopTurn(allocator, config, prompt, follow_context, client, events, db, ui_ptr, aggregate_sink);
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

    const next_call = tool_call.parseFirst(allocator, follow_sink.raw_visible.items) catch |err| {
        try db.recordEvent(config.session, "tool_parse_error", @errorName(err));
        return .stopped;
    };
    if (next_call) |call| return .{ .tool_call = call };

    try follow_sink.flushDeferredVisible();
    try aggregate_sink.visible.appendSlice(allocator, follow_sink.visible.items);
    aggregate_sink.visible_bytes += follow_sink.visible_bytes;
    return .final_answer;
}

const ToolCallKey = struct {
    path: []u8,
    strategy: contracts.StrategyName,
    start_line: usize,
    max_lines: usize,

    fn deinit(self: ToolCallKey, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }

    fn matches(self: ToolCallKey, call: tool_call.ToolCall) bool {
        const path = call.path orelse "<auto>";
        return std.mem.eql(u8, self.path, path) and
            self.strategy == (call.strategy orelse if (call.path == null) contracts.StrategyName.auto else contracts.StrategyName.path) and
            self.start_line == call.start_line and
            self.max_lines == call.max_lines;
    }
};

const ToolLoopState = struct {
    allocator: std.mem.Allocator,
    executed: std.ArrayList(ToolCallKey),
    evidence_texts: std.ArrayList([]u8),
    duplicate_repairs: usize = 0,
    model_budget_limit: usize = 18 * 1024,
    model_budget_used: usize = 0,
    best_quality: i32 = 0,

    fn init(allocator: std.mem.Allocator) ToolLoopState {
        return .{
            .allocator = allocator,
            .executed = std.ArrayList(ToolCallKey).empty,
            .evidence_texts = std.ArrayList([]u8).empty,
        };
    }

    fn deinit(self: *ToolLoopState) void {
        for (self.executed.items) |key| key.deinit(self.allocator);
        self.executed.deinit(self.allocator);
        for (self.evidence_texts.items) |text| self.allocator.free(text);
        self.evidence_texts.deinit(self.allocator);
    }

    fn hasExecuted(self: ToolLoopState, call: tool_call.ToolCall) bool {
        for (self.executed.items) |key| {
            if (key.matches(call)) return true;
        }
        return false;
    }

    fn rememberExecuted(self: *ToolLoopState, call: tool_call.ToolCall, evidence_text: []const u8) !void {
        const path = call.path orelse "<auto>";
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        const owned_evidence = try self.allocator.dupe(u8, evidence_text);
        errdefer self.allocator.free(owned_evidence);
        try self.executed.append(self.allocator, .{
            .path = owned_path,
            .strategy = call.strategy orelse if (call.path == null) contracts.StrategyName.auto else contracts.StrategyName.path,
            .start_line = call.start_line,
            .max_lines = call.max_lines,
        });
        try self.evidence_texts.append(self.allocator, owned_evidence);
    }

    fn hasBudgetForMoreEvidence(self: ToolLoopState) bool {
        return self.remainingBudget() >= 2200;
    }

    fn remainingBudget(self: ToolLoopState) usize {
        if (self.model_budget_used >= self.model_budget_limit) return 0;
        return self.model_budget_limit - self.model_budget_used;
    }

    fn shouldAllowMoreEvidence(self: ToolLoopState) bool {
        if (!self.hasBudgetForMoreEvidence()) return false;
        if (self.best_quality >= 82) return false;
        return true;
    }
};

fn renderCollectedEvidenceContext(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    evidence_texts: []const []u8,
    next_action: []const u8,
) ![]u8 {
    var evidence_blocks = try allocator.alloc(model_context.EvidenceBlock, evidence_texts.len);
    defer allocator.free(evidence_blocks);
    for (evidence_texts, 0..) |text, i| {
        evidence_blocks[i] = .{ .text = text };
    }
    return model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .evidence = evidence_blocks,
        .next_action = next_action,
    });
}

fn collectEvidenceToolSchema() []const u8 {
    return
        \\[TOOLS v1]
        \\collect_evidence(path?, strategy=auto|path|lexical|symbol|semantic|diagnostic|runtime|diff, start_line=1, max_lines=12)
        \\Use strategy=auto without path for ranked evidence. Use strategy=path only with path.
        \\Format with path:
        \\<tool_call>
        \\<function=collect_evidence>
        \\<parameter=path>relative/path</parameter>
        \\<parameter=strategy>path</parameter>
        \\<parameter=start_line>1</parameter>
        \\<parameter=max_lines>12</parameter>
        \\</function>
        \\</tool_call>
        \\Format ranked:
        \\<tool_call><function=collect_evidence><parameter=strategy>auto</parameter></function></tool_call>
    ;
}

fn shouldOfferCollectEvidence(prompt: []const u8) bool {
    const needles: []const []const u8 = &.{
        "arquivo",
        "file",
        "codigo",
        "código",
        "bug",
        "erro",
        "implemente",
        "refator",
        "analise",
        "analyze",
        "tool",
        "collect_evidence",
        ".zig",
        ".ts",
        ".js",
        ".md",
    };
    for (needles) |needle| {
        if (std.mem.indexOf(u8, prompt, needle) != null) return true;
    }
    return false;
}

fn modelContextEnabled() bool {
    const raw = c.getenv("PHENOM_MODEL_CONTEXT_V1") orelse return false;
    return modelContextValueEnabled(std.mem.span(raw));
}

fn modelContextValueEnabled(value: []const u8) bool {
    return std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true") or std.ascii.eqlIgnoreCase(value, "on");
}

fn toolLoopEnabled() bool {
    const raw = c.getenv("PHENOM_TOOL_LOOP_V1") orelse return false;
    return toolLoopValueEnabled(std.mem.span(raw));
}

fn toolLoopValueEnabled(value: []const u8) bool {
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
    _ = evidence_ranker;
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

test "tool loop env parser is opt in only" {
    try std.testing.expect(toolLoopValueEnabled("1"));
    try std.testing.expect(toolLoopValueEnabled("true"));
    try std.testing.expect(toolLoopValueEnabled("on"));
    try std.testing.expect(!toolLoopValueEnabled(""));
    try std.testing.expect(!toolLoopValueEnabled("0"));
    try std.testing.expect(!toolLoopValueEnabled("false"));
}

test "tool loop schema is compact and only offered for evidence-like prompts" {
    const schema = collectEvidenceToolSchema();
    try std.testing.expect(std.mem.indexOf(u8, schema, "collect_evidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "strategy=auto") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "symbol") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "apply_patch") == null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "grep_file") == null);
    try std.testing.expect(shouldOfferCollectEvidence("analise o arquivo README.md"));
    try std.testing.expect(shouldOfferCollectEvidence("corrija este bug em main.zig"));
    try std.testing.expect(!shouldOfferCollectEvidence("ola tudo bem"));
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
    try std.testing.expect(!state.hasExecuted(call));
    try state.rememberExecuted(call, "[EVIDENCE]\n- README.md L1-L12 hash=abc\n");
    try std.testing.expect(state.hasExecuted(call));
    try std.testing.expectEqual(@as(usize, 1), state.evidence_texts.items.len);
    try std.testing.expect(std.mem.indexOf(u8, state.evidence_texts.items[0], "README.md") != null);
}

test "duplicate evidence context keeps evidence and hides tool schema" {
    const evidence_text = try std.testing.allocator.dupe(u8, "[EVIDENCE]\n- README.md L1-L12 hash=abc\n");
    defer std.testing.allocator.free(evidence_text);
    const evidence_texts = [_][]u8{evidence_text};
    const rendered = try renderCollectedEvidenceContext(
        std.testing.allocator,
        "responda",
        &evidence_texts,
        "Answer now. Do not call tools again.",
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "[EVIDENCE]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "README.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[TOOLS v1]") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Do not call tools again") != null);
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
