const std = @import("std");

const audit = @import("audit.zig");
const apply_patch_tool = @import("apply_patch_tool.zig");
const cli = @import("cli.zig");
const code_graph = @import("code_graph.zig");
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
const strategy_registry = @import("strategy_registry.zig");
const system_prompt = @import("system_prompt.zig");
const tool_call = @import("tool_call.zig");
const tool_envelope = @import("tool_envelope.zig");
const tool_event = @import("tool_event.zig");
const tool_loop = @import("tool_loop.zig");
const tools = @import("tools.zig");
const tui = @import("tui.zig");
const ui_events = @import("ui_events.zig");
const web_rag = @import("web_rag.zig");
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
        .graph => try runGraph(allocator, init.io),
        .snapshot => try runSnapshot(),
    }
}

fn runGraph(allocator: std.mem.Allocator, io: std.Io) !void {
    const path = "graph.html";
    try code_graph.writeHtml(allocator, io, path);
    try (fd_writer.FdWriter{ .fd = 1 }).print("wrote {s}\n", .{path});
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

fn recordBackendConfig(allocator: std.mem.Allocator, db: *audit.AuditDb, config: cli.Config, client: *http.LocalModelClient) !void {
    const endpoint = blk: {
        break :blk client.endpointSummary(allocator) catch |err| {
            break :blk try std.fmt.allocPrint(allocator, "unresolved host={s} endpoint_error={s}", .{ config.host, @errorName(err) });
        };
    };
    defer allocator.free(endpoint);
    const body = try std.fmt.allocPrint(allocator, "backend={s} endpoint={s} model={s} thinking={s}", .{ backendName(config.backend), endpoint, config.model, @tagName(config.thinking) });
    defer allocator.free(body);
    try db.recordEvent(config.session, "model_backend", body);

    const metadata = client.probeMetadata(allocator, config.system_prompt orelse system_prompt.default_system_prompt);
    defer metadata.deinit(allocator);
    client.rememberMetadata(metadata);
    const schema_tokens = try optionalUsizeText(allocator, metadata.schema_baseline_tokens);
    defer allocator.free(schema_tokens);
    const context_window = try optionalUsizeText(allocator, metadata.context_window);
    defer allocator.free(context_window);
    const metadata_body = try std.fmt.allocPrint(
        allocator,
        "source={s} tokenizer={s} schema_baseline_tokens={s} context_window={s} detail={s}",
        .{
            metadata.source,
            metadata.tokenizer,
            schema_tokens,
            context_window,
            metadata.detail,
        },
    );
    defer allocator.free(metadata_body);
    try db.recordEvent(config.session, "backend_metadata", metadata_body);
}

fn optionalUsizeText(allocator: std.mem.Allocator, value: ?usize) ![]const u8 {
    return if (value) |actual| try std.fmt.allocPrint(allocator, "{}", .{actual}) else try allocator.dupe(u8, "unknown");
}

fn auditClassForBackendFailure(kind: http.BackendFailureKind) audit.ErrorClass {
    return switch (kind) {
        .connect,
        .http_status,
        .stream_read,
        .stream_write,
        => .infrastructure,

        .protocol_parse,
        .model_empty,
        .model_think_only,
        => .model_protocol,

        .stream_cancelled => .infrastructure,
        .unknown => .model_protocol,
    };
}

fn recordModelStreamFailure(
    db: *audit.AuditDb,
    session: []const u8,
    source: []const u8,
    err_name: []const u8,
    kind: http.BackendFailureKind,
    detail: ?[]const u8,
) !void {
    const body = if (detail) |value|
        try std.fmt.allocPrint(db.allocator, "kind={s} error={s} {s}", .{ @tagName(kind), err_name, value })
    else
        try std.fmt.allocPrint(db.allocator, "kind={s} error={s}", .{ @tagName(kind), err_name });
    defer db.allocator.free(body);
    try db.recordTurnError(session, auditClassForBackendFailure(kind), source, body);
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

fn isCreateCustomPromptCommand(input: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, input, " \t\r\n"), "/create_custom_prompt");
}

fn runCreateCustomPromptCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: cli.Config,
    events: *ui_events.EventBus,
    db: *audit.AuditDb,
    ui_ptr: ?*tui.TerminalUi(fd_writer.FdWriter),
) ![]u8 {
    if (config.offline) {
        try db.recordTurnError(config.session, .infrastructure, "create_custom_prompt", "live model required");
        return allocator.dupe(u8, "Nao foi possivel criar Phenom.md: /create_custom_prompt requer um modelo ativo.");
    }

    if (ui_ptr) |active_ui| try active_ui.showStatus("Collecting project overview");
    try db.recordEvent(config.session, "tool_start", "collect_evidence\tstage=overview create_custom_prompt");
    try events.emit(.{ .tool_start = .{ .name = "collect_evidence", .detail = "overview" } });
    const project = collect_evidence.execute(allocator, io, .{
        .task = "create Phenom.md custom project prompt",
        .strategy = .auto,
        .budget_bytes = 7000,
    }) catch |err| {
        try db.recordTurnError(config.session, .tool_runtime, "collect_evidence", @errorName(err));
        return std.fmt.allocPrint(allocator, "Nao foi possivel criar Phenom.md: coleta de contexto falhou com {s}.", .{@errorName(err)});
    };
    defer project.deinit(allocator);
    try db.recordEvent(config.session, "tool_event", project.tool_event_audit_text);
    try db.recordEvent(config.session, "evidence", project.evidence_text);
    try events.emit(.{ .tool_result = .{ .name = "collect_evidence", .output = project.evidence_text } });

    var persistent = persistent_context.Loaded.init(allocator);
    defer persistent.deinit();
    persistent = persistent_context.loadFromCwd(allocator, io) catch persistent_context.Loaded.init(allocator);

    const generator_prompt = try renderCreateCustomPromptPrompt(allocator, project.evidence_text, persistent.memory.items, persistent.skills.items, config.system_prompt);
    defer allocator.free(generator_prompt);

    if (ui_ptr) |active_ui| try active_ui.showStatus("Generating Phenom.md");
    var client = http.LocalModelClient{
        .allocator = allocator,
        .host = config.host,
        .backend = config.backend,
        .model = config.model,
        .thinking = .off,
    };
    defer client.deinit();
    var sink = InternalCaptureSink{
        .allocator = allocator,
        .filter = reasoning_filter.ReasoningFilter.init(allocator, false),
        .visible = std.ArrayList(u8).empty,
        .thinking = std.ArrayList(u8).empty,
    };
    defer sink.deinit();
    client.streamInference(.{
        .user_prompt = generator_prompt,
        .system_prompt = system_prompt.default_system_prompt,
        .max_tokens = @min(config.max_tokens, 1800),
    }, &sink) catch |err| {
        try db.recordTurnError(config.session, .infrastructure, "create_custom_prompt", @errorName(err));
        return std.fmt.allocPrint(allocator, "Nao foi possivel criar Phenom.md: modelo falhou com {s}.", .{@errorName(err)});
    };
    try sink.flush();

    const custom_prompt = try normalizeGeneratedPhenomPrompt(allocator, sink.visible.items);
    defer allocator.free(custom_prompt);
    try model_context.assertNoRawContextLeak(custom_prompt);
    try writeFileAtomic(io, "Phenom.md", "Phenom.md.tmp", custom_prompt);
    const audit_body = try std.fmt.allocPrint(allocator, "path=Phenom.md bytes={} evidence_bytes={}", .{ custom_prompt.len, project.evidence_text.len });
    defer allocator.free(audit_body);
    try db.recordEvent(config.session, "custom_prompt_created", audit_body);
    return std.fmt.allocPrint(allocator, "Phenom.md criado/atualizado com prompt customizado do projeto ({} bytes).", .{custom_prompt.len});
}

fn renderCreateCustomPromptPrompt(
    allocator: std.mem.Allocator,
    project_evidence: []const u8,
    memory: []const []const u8,
    skills: []const []const u8,
    existing_prompt: ?[]const u8,
) ![]u8 {
    var memory_text = std.ArrayList(u8).empty;
    defer memory_text.deinit(allocator);
    try appendList(&memory_text, allocator, memory);
    var skills_text = std.ArrayList(u8).empty;
    defer skills_text.deinit(allocator);
    try appendList(&skills_text, allocator, skills);
    return std.fmt.allocPrint(allocator,
        \\[CREATE_PHENOM_MD]
        \\Create or refresh the project's Phenom.md custom prompt.
        \\Return only Markdown content for Phenom.md. No XML, no tool calls, no fenced wrapper.
        \\Keep durable project facts: purpose, architecture, contracts, absolute business rules, safety rules, persistent model behavior rules.
        \\Exclude transient task status, raw logs, long code dumps, secrets, volatile implementation guesses, and anything not grounded below.
        \\Use concise sections and imperative rules. Maximum 2400 bytes.
        \\
        \\[EXISTING_PHENOM_MD]
        \\{s}
        \\
        \\[PROJECT_EVIDENCE]
        \\{s}
        \\
        \\[MEMORY_MD]
        \\{s}
        \\
        \\[SKILLS_MD]
        \\{s}
        \\
    , .{
        existing_prompt orelse "",
        project_evidence[0..@min(project_evidence.len, 7000)],
        memory_text.items,
        skills_text.items,
    });
}

fn appendList(out: *std.ArrayList(u8), allocator: std.mem.Allocator, items: []const []const u8) !void {
    if (items.len == 0) {
        try out.appendSlice(allocator, "none");
        return;
    }
    for (items) |item| {
        try out.appendSlice(allocator, item);
        if (!std.mem.endsWith(u8, item, "\n")) try out.append(allocator, '\n');
    }
}

fn normalizeGeneratedPhenomPrompt(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.indexOf(u8, trimmed, "<tool_call>") != null) return error.InvalidGeneratedPrompt;
    if (std.mem.startsWith(u8, trimmed, "```")) {
        const first_newline = std.mem.indexOfScalar(u8, trimmed, '\n') orelse return error.InvalidGeneratedPrompt;
        trimmed = std.mem.trim(u8, trimmed[first_newline + 1 ..], " \t\r\n");
        if (std.mem.endsWith(u8, trimmed, "```")) trimmed = std.mem.trim(u8, trimmed[0 .. trimmed.len - 3], " \t\r\n");
    }
    if (trimmed.len == 0) return error.InvalidGeneratedPrompt;
    return allocator.dupe(u8, trimmed[0..@min(trimmed.len, 12 * 1024)]);
}

fn writeFileAtomic(io: std.Io, path: []const u8, tmp_path: []const u8, data: []const u8) !void {
    const dir = std.Io.Dir.cwd();
    try dir.writeFile(io, .{ .sub_path = tmp_path, .data = data });
    try dir.rename(tmp_path, dir, path, io);
}

fn runChatTurnWithUi(allocator: std.mem.Allocator, io: std.Io, config: cli.Config, stdout: fd_writer.FdWriter, prompt: []const u8, ui: anytype) !void {
    var effective_config = config;
    const turn_project_prompt = if (config.system_prompt == null) try config_file.loadProjectPromptIfPresent(allocator) else null;
    defer if (turn_project_prompt) |value| allocator.free(value);
    if (turn_project_prompt) |value| {
        if (std.mem.trim(u8, value, " \t\r\n").len > 0) effective_config.system_prompt = value;
    }

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
    }
    const turn_started_ms = ui_events.monotonicMillis();
    try db.recordEvent(config.session, "turn_start", prompt);
    try recordSessionCheckpointForTurn(allocator, &db, config.session, prompt);
    try db.recordTurnPhase(config.session, .intent, "turn_start");
    try events.emit(.{ .user_message = prompt });

    if (isCreateCustomPromptCommand(prompt)) {
        const visible = try runCreateCustomPromptCommand(allocator, io, effective_config, &events, &db, ui_ptr);
        defer allocator.free(visible);
        try events.emit(.{ .message_chunk = visible });
        try recordAndEmitTurnDone(allocator, &db, config.session, &events, turn_started_ms, "ok", prompt, visible);
        return;
    }

    try events.emit(.{ .think_start = "Thinking" });

    if (config.demo_read_file) |path| {
        const allowed = gate.isAllowed("read_file_range", &.{"read_file_range"});
        if (!allowed) return error.ToolDenied;
        if (ui_ptr) |active_ui| try active_ui.showStatus("Reading");
        try db.recordTurnPhase(config.session, .evidence, "demo_read_file");
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
            .thinking = config.thinking,
        };
        defer client.deinit();
        try recordBackendConfig(allocator, &db, effective_config, &client);
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
            shouldUseSessionContext(config),
        );
        defer if (model_context_text) |text| allocator.free(text);
        if (model_context_text) |text| try db.recordEvent(config.session, "model_context", text);
        var dialogue_events = if (shouldUseSessionContext(config))
            try db.loadRecentSessionEvents(allocator, config.session, 240)
        else
            std.ArrayList(audit.AuditEvent).empty;
        defer audit.freeAuditEvents(allocator, &dialogue_events);
        var dialogue_messages = try buildRecentChatMessages(allocator, dialogue_events.items, prompt);
        defer freeChatMessages(allocator, &dialogue_messages);

        const inference_input = http.InferenceInput{
            .user_prompt = prompt,
            .system_prompt = effective_config.system_prompt,
            .model_context = model_context_text,
            .dialogue = dialogue_messages.items,
            .max_tokens = config.max_tokens,
        };
        if (model_context_text) |text| {
            const context_usage = recordModelContextBudget(allocator, &db, config.session, text, &client, inference_input) catch |err| {
                const message = if (err == error.ModelContextBudgetExceeded)
                    "context limit exceeded before model call"
                else
                    @errorName(err);
                if (ui_ptr) |active_ui| try active_ui.showStatus(message);
                try events.emit(.{ .progress_update = message });
                try db.recordEvent(config.session, "model_error", @errorName(err));
                try db.recordTurnError(config.session, .model_protocol, "model_context", @errorName(err));
                try recordAndEmitTurnDone(allocator, &db, config.session, &events, turn_started_ms, "model_context_error", prompt, sink.visible.items);
                if (config.fail_on_model_error) return err;
                return;
            };
            try showModelContextUsage(context_usage, &events, ui_ptr);
        }
        streamInferenceWithUiCancel(&client, inference_input, ui_ptr, &sink) catch |err| {
            if (err == error.Cancelled) {
                try events.emit(.{ .inference_cancel = "cancelled by user" });
                try db.recordEvent(config.session, "inference_cancel", "cancelled by user");
                try sink.flush();
                try recordAndEmitTurnDone(allocator, &db, config.session, &events, turn_started_ms, "cancelled", prompt, sink.visible.items);
                return;
            }
            const endpoint = client.endpointSummary(allocator) catch "unknown-endpoint";
            defer if (!std.mem.eql(u8, endpoint, "unknown-endpoint")) allocator.free(endpoint);
            const failure_detail = try client.httpFailureDetail(allocator);
            defer if (failure_detail) |detail| allocator.free(detail);
            const failure_kind = http.classifyStreamFailure(err, client.last_http_status);
            const message = if (failure_detail) |detail|
                try std.fmt.allocPrint(
                    allocator,
                    "model connection failed: {s} endpoint={s} {s}",
                    .{ @errorName(err), endpoint, detail },
                )
            else
                try std.fmt.allocPrint(
                    allocator,
                    "model connection failed: {s} endpoint={s}",
                    .{ @errorName(err), endpoint },
                );
            defer allocator.free(message);
            try events.emit(.{ .progress_update = message });
            try db.recordEvent(config.session, "model_error", @errorName(err));
            try recordModelStreamFailure(&db, config.session, "streamInference", @errorName(err), failure_kind, failure_detail);
            try recordAndEmitTurnDone(allocator, &db, config.session, &events, turn_started_ms, "model_error", prompt, sink.visible.items);
            if (config.fail_on_model_error) return err;
            return;
        };
        try sink.flush();
        var repaired_think_only_before_tool_loop = false;
        if (enable_tool_loop and sink.hasNoVisibleText() and sink.thinking_bytes > 0) {
            sink.raw_visible.clearRetainingCapacity();
            repaired_think_only_before_tool_loop = try repairThinkOnlyFinalAnswer(allocator, effective_config, prompt, &client, &events, &db, ui_ptr, &sink);
        }
        if (enable_tool_loop and !repaired_think_only_before_tool_loop) {
            const handled_by_tool_loop = runToolLoopIterations(allocator, io, effective_config, prompt, sink.raw_model.items, sink.raw_visible.items, model_context_text, &client, &events, &db, ui_ptr, &sink) catch |err| blk: {
                if (err == error.Cancelled) {
                    try events.emit(.{ .inference_cancel = "cancelled by user" });
                    try db.recordEvent(config.session, "inference_cancel", "cancelled by user");
                    try sink.flush();
                    try recordAndEmitTurnDone(allocator, &db, config.session, &events, turn_started_ms, "cancelled", prompt, sink.visible.items);
                    return;
                }
                const message = try std.fmt.allocPrint(allocator, "tool loop failed: {s}", .{@errorName(err)});
                defer allocator.free(message);
                try events.emit(.{ .progress_update = message });
                try db.recordEvent(config.session, "tool_loop_error", @errorName(err));
                try db.recordTurnError(config.session, .tool_runtime, "tool_loop", @errorName(err));
                if (config.fail_on_model_error) return err;
                break :blk true;
            };
            if (!handled_by_tool_loop) try sink.flushDeferredVisible();
        }
        if (sink.hasNoVisibleText() and sink.thinking_bytes > 0) {
            sink.raw_visible.clearRetainingCapacity();
            if (try repairThinkOnlyFinalAnswer(allocator, effective_config, prompt, &client, &events, &db, ui_ptr, &sink)) {
                try sink.flushDeferredVisible();
            }
        }
        if (sink.visible_bytes == 0 and sink.raw_visible.items.len > 0 and std.mem.trim(u8, sink.raw_visible.items, " \t\r\n").len > 0) {
            try sink.flushDeferredVisible();
        }
        if (sink.visible_bytes == 0) {
            try emitEmptyVisibleAnswer(&sink);
        }
        for (0..config.expect_contains_count) |expect_idx| {
            const expected = config.expect_contains_all[expect_idx] orelse continue;
            if (std.mem.indexOf(u8, sink.visible.items, expected) == null) {
                const message = try std.fmt.allocPrint(
                    allocator,
                    "fail expected visible text missing: {s}",
                    .{expected},
                );
                defer allocator.free(message);
                try events.emit(.{ .progress_update = message });
                try db.recordEvent(config.session, "expectation_failed", expected);
                try db.recordTurnError(config.session, .validation_failed, "expect_contains", expected);
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
        if (sink.completion_stop_reason != .unknown) {
            const message = try std.fmt.allocPrint(allocator, "server_stop reason={s}", .{@tagName(sink.completion_stop_reason)});
            defer allocator.free(message);
            try db.recordEvent(config.session, "model_stop", message);
        }
        const final_status = "ok";
        try recordAndEmitTurnDone(allocator, &db, config.session, &events, turn_started_ms, final_status, prompt, sink.visible.items);
    }
}

fn shouldUseSessionContext(config: cli.Config) bool {
    return !config.prompt_provided or config.session_provided;
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
    try db.recordTurnPhase(session, .final, status);
    try db.recordEvent(session, "turn_done", body);
    try recordSessionFocusForTurn(allocator, db, session, prompt, visible, quality.quality, quality.flags);
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
    var has_turn_error = false;
    for (turn_events.items) |event| {
        if (std.mem.eql(u8, event.kind, "session_context")) used_session_context = true;
        if (std.mem.eql(u8, event.kind, "evidence")) used_evidence = true;
        if (std.mem.eql(u8, event.kind, "tool_start") and std.mem.startsWith(u8, event.body, "search_session")) used_session_context = true;
        if (std.mem.eql(u8, event.kind, "tool_start") and std.mem.startsWith(u8, event.body, "collect_evidence")) used_evidence = true;
        if (std.mem.eql(u8, event.kind, "persistent_promotion")) used_persistent_context = true;
        if (std.mem.eql(u8, event.kind, "persistent_context")) used_persistent_context = true;
        if (std.mem.eql(u8, event.kind, "tool_start") and std.mem.startsWith(u8, event.body, "promote_context")) used_persistent_context = true;
        if (std.mem.eql(u8, event.kind, "model_context") and std.mem.indexOf(u8, event.body, "mode: session_recall") != null) session_recall_contract = true;
        if (std.mem.eql(u8, event.kind, "turn_error")) has_turn_error = true;
    }
    const ok_status = std.mem.eql(u8, status, "ok");
    const contract_missing_context = session_recall_contract and !used_session_context;
    const context_tool_missing = false;
    const low_confidence = !ok_status or !answered or contract_missing_context or has_turn_error;
    const effective_low_confidence = low_confidence or context_tool_missing;
    const quality: []const u8 = if (!ok_status or !answered)
        "failed"
    else if (effective_low_confidence)
        "uncertain"
    else
        "confirmed";
    const flags = try std.fmt.allocPrint(
        allocator,
        "answered={} used_session_context={} used_evidence={} used_persistent_context={} refusal=false contradicted_context=false contract_missing_context={} context_tool_missing={} turn_error={} low_confidence={}",
        .{ answered, used_session_context, used_evidence, used_persistent_context, contract_missing_context, context_tool_missing, has_turn_error, effective_low_confidence },
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
    visible: []const u8,
    quality: []const u8,
    flags: []const u8,
) !void {
    const topic = try compactOperationalText(allocator, prompt, 360);
    defer allocator.free(topic);
    if (topic.len == 0) return;
    const facts = try buildConversationMemoryFacts(allocator, prompt, visible);
    defer allocator.free(facts);
    try db.recordSessionFocus(
        session,
        topic,
        "turn_memory",
        facts,
        quality,
        flags,
    );
}

fn recordSessionCheckpointForTurn(
    allocator: std.mem.Allocator,
    db: *audit.AuditDb,
    session: []const u8,
    prompt: []const u8,
) !void {
    const topic = try compactOperationalText(allocator, prompt, 360);
    defer allocator.free(topic);
    if (topic.len == 0) return;
    const facts = try buildTurnCheckpointFacts(allocator, prompt);
    defer allocator.free(facts);
    try db.recordEvent(session, "turn_checkpoint", facts);
    try db.recordSessionFocus(
        session,
        topic,
        "turn_checkpoint",
        facts,
        "in_progress",
        "answered=false in_progress=true low_confidence=false",
    );
}

fn buildTurnCheckpointFacts(allocator: std.mem.Allocator, prompt: []const u8) ![]u8 {
    const task = try compactOperationalText(allocator, prompt, 480);
    defer allocator.free(task);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "source=turn_checkpoint_v1\n");
    try appendMemoryLine(allocator, &out, "active_task", task);
    try out.appendSlice(allocator, "status: in_progress\n");
    try appendMemoryLine(allocator, &out, "retrieval_text", task);
    try out.appendSlice(allocator, "detail_available: turn_start event\n");
    return try out.toOwnedSlice(allocator);
}

fn buildConversationMemoryFacts(allocator: std.mem.Allocator, prompt: []const u8, visible: []const u8) ![]u8 {
    const user_goal = try compactOperationalText(allocator, prompt, 520);
    defer allocator.free(user_goal);
    const answer = try compactOperationalText(allocator, visible, 720);
    defer allocator.free(answer);
    const retrieval_text = try renderMemoryRetrievalText(allocator, prompt, visible);
    defer allocator.free(retrieval_text);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "source=turn_memory_v1\n");
    try appendMemoryLine(allocator, &out, "user_goal", user_goal);
    try appendMemoryLine(allocator, &out, "assistant_answered", answer);
    try appendMemoryLine(allocator, &out, "retrieval_text", retrieval_text);
    try out.appendSlice(allocator, "detail_available: assistant_delta event\n");
    return out.toOwnedSlice(allocator);
}

fn appendMemoryLine(allocator: std.mem.Allocator, out: *std.ArrayList(u8), key: []const u8, value: []const u8) !void {
    if (value.len == 0) return;
    try out.appendSlice(allocator, key);
    try out.appendSlice(allocator, ": ");
    try out.appendSlice(allocator, value);
    try out.append(allocator, '\n');
}

fn renderMemoryRetrievalText(allocator: std.mem.Allocator, prompt: []const u8, visible: []const u8) ![]u8 {
    var joined = std.ArrayList(u8).empty;
    defer joined.deinit(allocator);
    try joined.appendSlice(allocator, prompt);
    if (visible.len > 0) {
        try joined.append(allocator, ' ');
        try joined.appendSlice(allocator, visible);
    }
    return compactOperationalText(allocator, joined.items, 520);
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
    include_session_context: bool,
) !?[]u8 {
    const include_persistent = modelContextEnabled();
    if (!include_persistent and !enable_tool_loop) return null;

    var persistent = persistent_context.Loaded.init(allocator);
    defer persistent.deinit();
    if (include_persistent) persistent = try persistent_context.loadFromCwd(allocator, io);

    if (!enable_tool_loop and persistent.memory.items.len == 0 and persistent.skills.items.len == 0) return null;

    var session_events = if (include_session_context)
        try db.loadRecentSessionEvents(allocator, session, 240)
    else
        std.ArrayList(audit.AuditEvent).empty;
    defer audit.freeAuditEvents(allocator, &session_events);

    const focus_text = if (include_session_context)
        try loadMergedSessionFocus(allocator, db, session, prompt, session_events.items)
    else
        null;
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
        .next_action_v1 = if (enable_tool_loop) .{
            .kind = .collect_context,
            .text = "First choose route. If you cannot identify a requested name/entity from grounded context, emit set_operational_contract(contract=search_web, query=exact requested name/entity). Never answer no-records/fictional/similar first.",
        } else .{
            .kind = .answer_directly,
            .text = "Apply persistent MEMORY/SKILLS only if relevant; answer the current user request directly.",
        },
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
    const stored_focus_text = try session_context.renderSessionFocusForPrompt(allocator, focus_rows.items, prompt);
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
const max_required_tool_protocol_repairs = 2;
const max_pathless_collect_budget: usize = 6 * 1024;
const max_web_evidence_budget: usize = 8192;
const max_model_context_send_bytes: usize = 24 * 1024;
const weak_evidence_quality_score: i32 = 64;
const required_tool_missing_answer = "[MODEL_FINALIZATION_BLOCKED] operational work was not completed; no final answer accepted.";
const required_work_missing_answer = "[MODEL_FINALIZATION_BLOCKED] required operational work was not completed; no final answer accepted.";

fn emitEmptyVisibleAnswer(sink: *StreamSink) !void {
    if (sink.ui) |active_ui| try active_ui.showStatus("no visible final answer; see diagnostic");
    const kind = http.classifyModelOutput(sink.completion_stop_reason, sink.visible_bytes, sink.thinking_bytes);
    const message = try renderEmptyVisibleAnswerMessage(sink.allocator, sink);
    defer sink.allocator.free(message);
    try sink.emitVisibleText(message);
    try sink.db.recordEvent(sink.session, "empty_visible_answer", message);
    if (kind) |value| try sink.db.recordTurnError(sink.session, auditClassForBackendFailure(value), "model_output", @tagName(value));
}

fn renderEmptyVisibleAnswerMessage(allocator: std.mem.Allocator, sink: *const StreamSink) ![]u8 {
    if (sink.completion_stop_reason == .length) {
        return std.fmt.allocPrint(
            allocator,
            "[MODEL_STOP] server_stop=length before visible final answer; hidden_reasoning_bytes={} raw_model_bytes={}",
            .{ sink.thinking_bytes, sink.raw_model.items.len },
        );
    }
    if (sink.thinking_bytes > 0) {
        return std.fmt.allocPrint(
            allocator,
            "[MODEL_EMPTY_ANSWER] no visible final answer; hidden_reasoning_bytes={} raw_model_bytes={} stop_reason={s}",
            .{ sink.thinking_bytes, sink.raw_model.items.len, @tagName(sink.completion_stop_reason) },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "[MODEL_EMPTY_ANSWER] no visible final answer; raw_model_bytes={} stop_reason={s}",
        .{ sink.raw_model.items.len, @tagName(sink.completion_stop_reason) },
    );
}

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
    visible_output: []const u8,
    initial_context: ?[]const u8,
    client: *http.LocalModelClient,
    events: *ui_events.EventBus,
    db: *audit.AuditDb,
    ui_ptr: ?*tui.TerminalUi(fd_writer.FdWriter),
    first_sink: *StreamSink,
) !bool {
    var state = ToolLoopState.init(allocator);
    defer state.deinit();
    _ = model_output;
    var maybe_envelope = tool_envelope.parseFirst(allocator, visible_output, state.active_contract) catch |err| {
        try db.recordEvent(config.session, "tool_envelope_error", @errorName(err));
        try db.recordTurnError(config.session, .model_protocol, "tool_envelope", @errorName(err));
        return true;
    };
    const has_visible_output = std.mem.trim(u8, visible_output, " \t\r\n").len > 0;
    if (maybe_envelope == null and has_visible_output and outputCitesMissingSessionEvidence(visible_output, initial_context)) {
        first_sink.discardDeferredVisible();
        try db.recordEvent(config.session, "tool_repair", "answer cited missing evidence");
        const repair_context = try renderMissingCitationRepairContext(allocator, prompt);
        defer allocator.free(repair_context);
        try db.recordEvent(config.session, "model_context", repair_context);
        const next = try streamDeferredRequiredToolLoopTurn(
            allocator,
            config,
            prompt,
            repair_context,
            "Your previous answer cited E#/S#, but no matching evidence block exists. Output exactly one collect_evidence or search_session tool_call now. No prose.",
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
    if (maybe_envelope == null and has_visible_output and shouldRepairPersistentContextClaim(visible_output, initial_context, &state)) {
        first_sink.discardDeferredVisible();
        try db.recordEvent(config.session, "answer_repair", "persistent context claim without retrieval");
        const repair_context = try renderPersistentContextClaimRepairContext(allocator, prompt, state.active_contract);
        defer allocator.free(repair_context);
        try db.recordEvent(config.session, "model_context", repair_context);
        const next = try streamDeferredRequiredToolLoopTurn(
            allocator,
            config,
            prompt,
            repair_context,
            "Your previous answer made a MEMORY/SKILLS claim without retrieved persistent context. Output exactly one set_operational_contract tool_call with contract=memory and concrete terms from USER_TASK. No prose.",
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
            if (envelope.rejection_reason == .parse_error) {
                try db.recordEvent(config.session, "tool_parse_error", envelope.auditText());
                first_sink.discardDeferredVisible();
                const repair_context = try renderMalformedToolCallRepairContext(allocator, prompt, state.active_contract);
                defer allocator.free(repair_context);
                try db.recordEvent(config.session, "model_context", repair_context);
                const next = try streamDeferredToolLoopTurn(allocator, config, prompt, repair_context, client, events, db, ui_ptr, first_sink, &state);
                switch (next) {
                    .final_answer => return true,
                    .stopped => return true,
                    .tool_call => |next_call| {
                        maybe_envelope = try tool_envelope.ToolCallEnvelope.fromAcceptedCall(allocator, state.active_contract, next_call);
                        continue;
                    },
                }
            }
            const body = try std.fmt.allocPrint(allocator, "{s}\t{s}", .{ envelope.raw_name, envelope.auditText() });
            defer allocator.free(body);
            try db.recordEvent(config.session, "tool_rejected", body);
            try db.recordTurnError(config.session, .tool_contract, "tool_envelope", body);
            if (state.active_contract.name == .workflow and envelope.rejection_reason == .tool_not_advertised) {
                first_sink.discardDeferredVisible();
                const repair_context = try renderInitialRejectedToolContext(allocator, prompt, envelope.raw_name);
                defer allocator.free(repair_context);
                try db.recordEvent(config.session, "model_context", repair_context);
                const next = try streamDeferredToolLoopTurn(allocator, config, prompt, repair_context, client, events, db, ui_ptr, first_sink, &state);
                switch (next) {
                    .final_answer => return true,
                    .stopped => return true,
                    .tool_call => |next_call| {
                        maybe_envelope = try tool_envelope.ToolCallEnvelope.fromAcceptedCall(allocator, state.active_contract, next_call);
                        continue;
                    },
                }
            }
            try emitRejectedToolAnswer(allocator, first_sink, envelope.raw_name, envelope.auditText());
            return true;
        }

        var call = envelope.takeCall() orelse {
            try db.recordEvent(config.session, "tool_rejected", "accepted envelope without call");
            try db.recordTurnError(config.session, .model_protocol, "tool_envelope", "accepted envelope without call");
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
    _ = context;
    return false;
}

fn initialContextRequiresSessionSearch(context: ?[]const u8) bool {
    _ = context;
    return false;
}

fn syntheticInitialSessionSearchCall(allocator: std.mem.Allocator, prompt: []const u8, initial_context: []const u8) !tool_call.ToolCall {
    const terms = try syntheticSessionSearchTerms(allocator, prompt, initial_context);
    errdefer allocator.free(terms);
    return .{
        .name = try allocator.dupe(u8, "search_session"),
        .intent = try allocator.dupe(u8, "recover requested prior-session fact"),
        .terms = terms,
        .scope = try allocator.dupe(u8, "current"),
    };
}

fn syntheticSessionSearchTerms(allocator: std.mem.Allocator, prompt: []const u8, initial_context: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try appendBoundedSearchText(allocator, &out, prompt, 240);
    if (contextSection(initial_context, "[SESSION_FOCUS]")) |focus| {
        try appendFocusSearchAnchors(allocator, &out, focus, prompt, 160);
    }
    return out.toOwnedSlice(allocator);
}

fn appendBoundedSearchText(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8, max_bytes: usize) !void {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n\"'`()[]{}<>:;,!?/\\|+=*&^%$#@~");
    while (it.next()) |raw| {
        if (out.items.len >= max_bytes) break;
        const token = std.mem.trim(u8, raw, ".-_");
        if (token.len < 2) continue;
        if (out.items.len > 0) try out.append(allocator, ' ');
        const remaining = max_bytes - out.items.len;
        if (token.len > remaining) break;
        try out.appendSlice(allocator, token);
    }
}

fn appendFocusSearchAnchors(allocator: std.mem.Allocator, out: *std.ArrayList(u8), focus: []const u8, prompt: []const u8, max_bytes: usize) !void {
    _ = prompt;
    const start_len = out.items.len;
    var lines = std.mem.splitScalar(u8, focus, '\n');
    while (lines.next()) |line| {
        if (out.items.len - start_len >= max_bytes) break;
        const value = focusLineValue(line) orelse continue;
        var it = std.mem.tokenizeAny(u8, value, " \t\r\n\"'`()[]{}<>:;,!?/\\|+=*&^%$#@~");
        while (it.next()) |raw| {
            if (out.items.len - start_len >= max_bytes) break;
            const token = std.mem.trim(u8, raw, ".-_");
            if (token.len < 2) continue;
            if (out.items.len > 0) try out.append(allocator, ' ');
            const remaining = max_bytes - (out.items.len - start_len);
            if (token.len > remaining) break;
            try out.appendSlice(allocator, token);
        }
    }
}

fn focusLineValue(line: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, line, "topic:")) |idx| return std.mem.trim(u8, line[idx + "topic:".len ..], " \t");
    if (std.mem.indexOf(u8, line, "useful_facts:")) |idx| return std.mem.trim(u8, line[idx + "useful_facts:".len ..], " \t");
    return null;
}

fn contextSection(context: []const u8, section: []const u8) ?[]const u8 {
    var marker_buffer: [64]u8 = undefined;
    const marker = std.fmt.bufPrint(&marker_buffer, "\n{s}\n", .{section}) catch return null;
    const start = std.mem.indexOf(u8, context, marker) orelse return null;
    const body_start = start + marker.len;
    if (std.mem.indexOf(u8, context[body_start..], "\n[")) |end| return context[body_start .. body_start + end];
    return context[body_start..];
}

fn outputCitesMissingContextEvidence(output: []const u8, context: ?[]const u8) bool {
    return outputCitesMissingWorkspaceEvidence(output, context) or outputCitesMissingSessionEvidence(output, context);
}

fn outputCitesMissingWorkspaceEvidence(output: []const u8, context: ?[]const u8) bool {
    return containsCitation(output, 'E') and !contextHasSection(context, "[EVIDENCE]");
}

fn outputNeedsWorkspaceEvidenceRepair(output: []const u8, context: ?[]const u8, allowed_tools: []const []const u8) bool {
    if (contextHasSection(context, "[EVIDENCE]")) return false;
    if (containsCitation(output, 'E')) return true;
    _ = allowed_tools;
    return outputClaimsEvidenceWithoutBlock(output);
}

fn outputContradictsRuntimeInspection(output: []const u8, context: []const u8) bool {
    if (std.mem.indexOf(u8, context, "[RUNTIME_INSPECTION]") == null) return false;
    if (std.mem.indexOf(u8, context, "[ANSWER_REPAIR]") != null) return false;
    if (!containsAsciiIgnoreCase(output, "runtime") and
        !containsAsciiIgnoreCase(output, "inspect_runtime") and
        !containsAsciiIgnoreCase(output, "browser") and
        !containsAsciiIgnoreCase(output, "navegador") and
        !containsAsciiIgnoreCase(output, "diagnost") and
        !containsAsciiIgnoreCase(output, "tempo de execução"))
    {
        return false;
    }
    if (containsAsciiIgnoreCase(output, "contrato") and
        (containsAsciiIgnoreCase(output, "nao requeria") or
            containsAsciiIgnoreCase(output, "não requeria") or
            containsAsciiIgnoreCase(output, "nao exigia") or
            containsAsciiIgnoreCase(output, "não exigia") or
            containsAsciiIgnoreCase(output, "not require")) and
        (containsAsciiIgnoreCase(output, "diagnost") or
            containsAsciiIgnoreCase(output, "browser") or
            containsAsciiIgnoreCase(output, "navegador") or
            containsAsciiIgnoreCase(output, "runtime")))
    {
        return true;
    }
    return containsAsciiIgnoreCase(output, "nao foi execut") or
        containsAsciiIgnoreCase(output, "não foi execut") or
        containsAsciiIgnoreCase(output, "nao foram execut") or
        containsAsciiIgnoreCase(output, "não foram execut") or
        containsAsciiIgnoreCase(output, "nao execut") or
        containsAsciiIgnoreCase(output, "não execut") or
        (containsAsciiIgnoreCase(output, "nenhuma") and containsAsciiIgnoreCase(output, "foi execut")) or
        (containsAsciiIgnoreCase(output, "nenhum") and containsAsciiIgnoreCase(output, "foi execut")) or
        (containsAsciiIgnoreCase(output, "nenhuma") and containsAsciiIgnoreCase(output, "foram execut")) or
        (containsAsciiIgnoreCase(output, "nenhum") and containsAsciiIgnoreCase(output, "foram execut")) or
        containsAsciiIgnoreCase(output, "not executed") or
        containsAsciiIgnoreCase(output, "was not executed");
}

fn outputDefersAvailableWorkspaceCollection(output: []const u8, context: ?[]const u8, allowed_tools: []const []const u8) bool {
    _ = output;
    _ = context;
    _ = allowed_tools;
    return false;
}

fn webEvidenceHasOnlyEmptyExcerpts(context: []const u8) bool {
    if (std.mem.indexOf(u8, context, "[WEB_EVIDENCE]") == null) return false;
    var saw_excerpt = false;
    var saw_nonempty_excerpt = false;
    var lines = std.mem.splitScalar(u8, context, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "excerpt=")) continue;
        saw_excerpt = true;
        if (std.mem.trim(u8, trimmed["excerpt=".len..], " \t\r\n").len > 0) {
            saw_nonempty_excerpt = true;
        }
    }
    return saw_excerpt and !saw_nonempty_excerpt;
}

fn unsupportedWebAnswerLiteral(output: []const u8, context: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, context, "[WEB_EVIDENCE]") == null) return null;
    var it = std.mem.tokenizeAny(u8, output, " \t\r\n");
    while (it.next()) |raw| {
        const token = std.mem.trim(u8, raw, ".,;:!?()[]{}<>\"'`*");
        if (!isEvidenceLiteral(token)) continue;
        if (containsAsciiIgnoreCase(context, token)) continue;
        if (token.len > 1 and (token[0] == 'v' or token[0] == 'V') and containsAsciiIgnoreCase(context, token[1..])) continue;
        return token;
    }
    return null;
}

fn isEvidenceLiteral(token: []const u8) bool {
    if (token.len < 4) return false;
    var digits: usize = 0;
    var all_digits = true;
    var has_structural_separator = false;
    for (token) |ch| {
        if (std.ascii.isDigit(ch)) {
            digits += 1;
            continue;
        }
        all_digits = false;
        if (ch == '.' or ch == '-' or ch == '/' or ch == ':' or ch == '_') has_structural_separator = true;
    }
    if (digits == 0) return false;
    if (all_digits and token.len == 4) return true;
    // ponytail: this enforces numeric/version/date literal support; upgrade to semantic entailment when a verifier model exists.
    return has_structural_separator;
}

fn outputClaimsEvidenceWithoutBlock(output: []const u8) bool {
    return std.mem.indexOf(u8, output, "[EVIDENCE]") != null or
        std.mem.indexOf(u8, output, "EVIDENCE:") != null or
        containsCitation(output, 'L');
}

fn outputMentionsAllowedTool(output: []const u8, allowed_tools: []const []const u8) bool {
    for (allowed_tools) |name| {
        if (std.mem.indexOf(u8, output, name) != null) return true;
    }
    return false;
}

fn toolAllowed(allowed_tools: []const []const u8, needle: []const u8) bool {
    for (allowed_tools) |name| {
        if (std.mem.eql(u8, name, needle)) return true;
    }
    return false;
}

fn outputCitesMissingSessionEvidence(output: []const u8, context: ?[]const u8) bool {
    return containsCitation(output, 'S') and !contextHasSection(context, "[SESSION_CONTEXT]");
}

fn outputClaimsPersistentContextWithoutRetrieval(output: []const u8, context: ?[]const u8) bool {
    const mentions_persistent_protocol = containsAsciiIgnoreCase(output, "MEMORY") or
        containsAsciiIgnoreCase(output, "SKILLS") or
        containsAsciiIgnoreCase(output, "memoria") or
        containsAsciiIgnoreCase(output, "memória") or
        containsAsciiIgnoreCase(output, "contexto persistente");
    if (!mentions_persistent_protocol) return false;
    if (contextHasSection(context, "[MEMORY]")) return false;
    if (contextHasSection(context, "[SKILLS]")) return false;
    if (contextHasSection(context, "[PERSISTENT_CONTEXT]")) return false;
    return true;
}

fn shouldRepairPersistentContextClaim(output: []const u8, context: ?[]const u8, state: ?*const ToolLoopState) bool {
    if (state) |loop_state| {
        if (loop_state.memory_promotions > 0) return false;
    }
    return outputClaimsPersistentContextWithoutRetrieval(output, context);
}

fn outputContradictsRetrievedSkills(output: []const u8, state: ?*const ToolLoopState) bool {
    const loop_state = state orelse return false;
    if (loop_state.active_contract.name != .memory) return false;
    if (loop_state.retrieved_skills.items.len == 0) return false;
    // ponytail: output-level protocol guard only; replace with semantic verifier if paraphrase tolerance becomes required.
    const denies_persistent_rule = (containsAsciiIgnoreCase(output, "I don't have") or
        containsAsciiIgnoreCase(output, "I do not have") or
        containsAsciiIgnoreCase(output, "nao tenho") or
        containsAsciiIgnoreCase(output, "não tenho") or
        containsAsciiIgnoreCase(output, "no specific") or
        containsAsciiIgnoreCase(output, "nenhuma regra") or
        containsAsciiIgnoreCase(output, "não há regra") or
        containsAsciiIgnoreCase(output, "nao ha regra") or
        containsAsciiIgnoreCase(output, "nao existe regra") or
        containsAsciiIgnoreCase(output, "não existe regra"));
    const asks_clarification = containsAsciiIgnoreCase(output, "could you clarify") or
        containsAsciiIgnoreCase(output, "please clarify") or
        containsAsciiIgnoreCase(output, "poderia esclarecer") or
        containsAsciiIgnoreCase(output, "preciso que esclare");
    const speaks_about_persistent_context = containsAsciiIgnoreCase(output, "rule") or
        containsAsciiIgnoreCase(output, "regra") or
        containsAsciiIgnoreCase(output, "memory") or
        containsAsciiIgnoreCase(output, "skills") or
        containsAsciiIgnoreCase(output, "memoria") or
        containsAsciiIgnoreCase(output, "memória") or
        containsAsciiIgnoreCase(output, "contexto persistente");
    return speaks_about_persistent_context and (denies_persistent_rule or asks_clarification);
}

fn firstMissingRetrievedSkillMarker(context: ?[]const u8, output: []const u8) ?[]const u8 {
    const text = context orelse return null;
    const skills = contextSection(text, "[SKILLS]") orelse return null;
    var it = std.mem.tokenizeAny(u8, skills, " \t\r\n`'\".,;:()[]{}<>");
    while (it.next()) |token| {
        const trimmed = std.mem.trim(u8, token, "-");
        if (!isSkillMarkerToken(trimmed)) continue;
        if (!containsAsciiIgnoreCase(output, trimmed)) return trimmed;
    }
    return null;
}

fn isSkillMarkerToken(token: []const u8) bool {
    if (token.len < 6) return false;
    if (std.mem.indexOfScalar(u8, token, '_') == null) return false;
    var has_digit = false;
    var has_upper = false;
    for (token) |ch| {
        if (std.ascii.isDigit(ch)) has_digit = true;
        if (std.ascii.isUpper(ch)) has_upper = true;
    }
    return has_digit and has_upper;
}

fn contextHasSection(context: ?[]const u8, section: []const u8) bool {
    const text = context orelse return false;
    var marker_buffer: [64]u8 = undefined;
    const marker = std.fmt.bufPrint(&marker_buffer, "\n{s}\n", .{section}) catch return false;
    return std.mem.indexOf(u8, text, marker) != null;
}

fn containsCitation(text: []const u8, prefix: u8) bool {
    for (text, 0..) |ch, idx| {
        if (ch != prefix) continue;
        if (idx > 0 and std.ascii.isAlphanumeric(text[idx - 1])) continue;
        const next = idx + 1;
        if (next < text.len and std.ascii.isDigit(text[next])) return true;
    }
    return false;
}

fn containsPathLikeToken(text: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n`'\"()[]{}<>:,;");
    while (it.next()) |token| {
        if (std.mem.indexOfScalar(u8, token, '/') == null) continue;
        if (std.mem.indexOfScalar(u8, token, '.') == null) continue;
        if (std.mem.startsWith(u8, token, "./") or !std.mem.startsWith(u8, token, "/")) return true;
    }
    return false;
}

fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn evidenceRepairTermsFromOutput(
    allocator: std.mem.Allocator,
    output: []const u8,
    prompt: []const u8,
    allowed_tools: []const []const u8,
) !?[]u8 {
    for (allowed_tools) |name| {
        if (std.mem.indexOf(u8, output, name) != null) {
            return try std.fmt.allocPrint(allocator, "{s} {s}", .{ name, prompt });
        }
    }
    return null;
}

fn renderInitialToolCallRepairContext(allocator: std.mem.Allocator, initial_context: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}\n[PROTOCOL_REPAIR]\nPrevious output was prose, but this turn requires one context tool call before prose. For broad workspace/project map, emit collect_evidence stage=overview strategy=auto with no terms. For focused collect_evidence/search_session, set intent+concrete terms. For code identity, emit collect_evidence stage=candidates before expanding a selected candidate.\n",
        .{initial_context},
    );
}

fn renderInitialRejectedToolContext(allocator: std.mem.Allocator, prompt: []const u8, raw_tool: []const u8) ![]u8 {
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

fn renderMalformedToolCallRepairContext(allocator: std.mem.Allocator, prompt: []const u8, active_contract: contracts.ActiveContract) ![]u8 {
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

fn emitMalformedToolCallAnswer(allocator: std.mem.Allocator, sink: *StreamSink) !void {
    const message = "A chamada de ferramenta veio malformada e nao foi executada. Reenvie a pergunta ou peça explicitamente a ferramenta/contrato desejado.";
    _ = allocator;
    try sink.emitVisibleText(message);
}

fn emitRejectedToolAnswer(allocator: std.mem.Allocator, sink: *StreamSink, raw_tool: []const u8, reason: []const u8) !void {
    const message = try std.fmt.allocPrint(
        allocator,
        "[MODEL_PROTOCOL_ERROR] tool `{s}` was rejected by the active contract: {s}",
        .{ raw_tool, reason },
    );
    defer allocator.free(message);
    try sink.emitVisibleText(message);
}

fn renderMissingCitationRepairContext(allocator: std.mem.Allocator, prompt: []const u8) ![]u8 {
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

fn renderPersistentContextClaimRepairContext(allocator: std.mem.Allocator, prompt: []const u8, active_contract: contracts.ActiveContract) ![]u8 {
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

fn renderRetrievedSkillsAnswerRepairContext(allocator: std.mem.Allocator, prompt: []const u8, state: *const ToolLoopState) ![]u8 {
    return model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .contracts = activeToolSchema(state),
        .skills = state.retrieved_skills.items,
        .obligations = &.{
            "The previous answer contradicted retrieved SKILLS.",
            "Retrieved SKILLS directly govern this memory-contract turn.",
            "Answer only from retrieved SKILLS. Do not ask clarification. Do not add generic advice.",
        },
        .grounding = groundingRules(),
        .next_action = "Emit the final answer now, applying the retrieved SKILLS exactly. No tool_call.",
    });
}

fn renderUnsupportedWorkspaceClaimRepairContext(allocator: std.mem.Allocator, prompt: []const u8) ![]u8 {
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

fn renderWorkspaceClaimRouterRepairContext(allocator: std.mem.Allocator, prompt: []const u8) ![]u8 {
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

fn renderCollectEvidenceSearchIntentRepairContext(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    context: *const working_context.WorkingContext,
) ![]u8 {
    return renderCollectedEvidenceContext(
        allocator,
        prompt,
        context,
        null,
        null,
        collectEvidenceSearchIntentRepairSchema(),
        "Emit exactly one visible collect_evidence tool_call with path, or with intent+terms and strategy=auto|lexical|symbol. Use workspace evidence above plus the current task to choose concrete code retrieval keys. No prose.",
    );
}

fn collectEvidenceSearchIntentRepairSchema() []const u8 {
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

fn collectEvidenceRepairContract() contracts.ActiveContract {
    return .{
        .name = .collect_evidence,
        .version = contracts.manifest_version,
        .allowed_tools = &.{"collect_evidence"},
    };
}

fn validationPathFromCollectOrPrompt(allocator: std.mem.Allocator, prompt: []const u8, call: *const tool_call.ToolCall) !?[]u8 {
    if (call.path) |path| return try allocator.dupe(u8, path);
    return try singleStructuredPathFromPrompt(allocator, prompt);
}

fn applyPatchOnlyRepairContract() contracts.ActiveContract {
    return .{
        .name = .mutate_file,
        .version = contracts.manifest_version,
        .allowed_tools = &.{"apply_patch"},
    };
}

fn applyPatchOnlyRepairSchema() []const u8 {
    return
    \\[TOOLS v1]
    \\apply_patch(operation=edit|create|delete|rename, path, destinationPath?, content?, contextId?, repeated search/replace?)
    \\Only apply_patch is active for this repair. Evidence and MICRO_CONTEXT are already present; do not call collect_evidence again.
    \\<tool_call><function=apply_patch><parameter=operation>edit</parameter><parameter=path>relative/path</parameter><parameter=contextId>ctx_...</parameter><parameter=search>exact old text</parameter><parameter=replace>exact new text</parameter></function></tool_call>
    ;
}

fn validateSyntaxOnlyRepairContract() contracts.ActiveContract {
    return .{
        .name = .validate_work,
        .version = contracts.manifest_version,
        .allowed_tools = &.{"validate_syntax"},
    };
}

fn validateSyntaxOnlyRepairSchema() []const u8 {
    return
    \\[TOOLS v1]
    \\validate_syntax(path)
    \\Only validate_syntax is active for this repair. Patch was already applied; do not call collect_evidence.
    \\<tool_call><function=validate_syntax><parameter=path>relative/path.zig</parameter></function></tool_call>
    ;
}

fn repairMutationRequiresPatch(
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
    try db.recordEvent(config.session, "tool_repair", "mutation requires apply_patch after evidence");
    try events.emit(.{ .progress_update = "mutation evidence is ready; repairing to apply_patch" });
    const repair_context = try renderCollectedEvidenceContextRequiringMutation(
        allocator,
        prompt,
        &state.context,
        applyPatchOnlyRepairSchema(),
        mutationPatchNextAction(),
    );
    defer allocator.free(repair_context);
    try db.recordEvent(config.session, "model_context", repair_context);
    return try streamDeferredRequiredToolLoopTurn(
        allocator,
        config,
        prompt,
        repair_context,
        "Evidence and MICRO_CONTEXT already exist. Output exactly one apply_patch tool_call now. No collect_evidence. No prose.",
        client,
        events,
        db,
        ui_ptr,
        aggregate_sink,
        applyPatchOnlyRepairContract(),
    );
}

fn repairValidationRequiresSyntax(
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
    _ = state;
    try db.recordEvent(config.session, "tool_repair", "validation requires validate_syntax after patch");
    try events.emit(.{ .progress_update = "patch applied; repairing to validate_syntax" });
    const repair_context = try model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .contracts = validateSyntaxOnlyRepairSchema(),
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
    defer allocator.free(repair_context);
    try db.recordEvent(config.session, "model_context", repair_context);
    return try streamDeferredRequiredToolLoopTurn(
        allocator,
        config,
        prompt,
        repair_context,
        "Patch was already applied. Output exactly one validate_syntax tool_call for the changed Zig file. No collect_evidence. No prose.",
        client,
        events,
        db,
        ui_ptr,
        aggregate_sink,
        validateSyntaxOnlyRepairContract(),
    );
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
        try db.recordTurnError(config.session, .tool_contract, "tool_gate", call.name);
        return .stopped;
    }
    try db.recordTurnPhase(config.session, phaseForTool(call.name), call.name);
    if (std.mem.eql(u8, call.name, "set_operational_contract")) {
        return try runSetOperationalContractStep(allocator, io, config, prompt, call, client, events, db, ui_ptr, aggregate_sink, state, tool_iterations);
    }
    if (std.mem.eql(u8, call.name, "search_session")) {
        return try runSearchSessionStep(allocator, config, prompt, call, client, events, db, ui_ptr, aggregate_sink, state, tool_iterations);
    }
    if (std.mem.eql(u8, call.name, "search_persistent_context")) {
        return try runSearchPersistentContextStep(allocator, io, config, prompt, call, client, events, db, ui_ptr, aggregate_sink, state, tool_iterations);
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
    if (std.mem.eql(u8, call.name, "web_search")) {
        return try runWebSearchStep(allocator, io, config, prompt, call, client, events, db, ui_ptr, aggregate_sink, state, tool_iterations);
    }
    if (std.mem.eql(u8, call.name, "promote_context")) {
        return try runPromoteContextStep(allocator, io, config, prompt, call, client, events, db, ui_ptr, aggregate_sink, state, tool_iterations);
    }
    if (!std.mem.eql(u8, call.name, "collect_evidence")) {
        try db.recordEvent(config.session, "tool_rejected", call.name);
        try db.recordTurnError(config.session, .tool_contract, "tool_dispatch", call.name);
        return .stopped;
    }
    if (stateNeedsValidationTool(state)) {
        const validation_path = try validationPathFromCollectOrPrompt(allocator, prompt, call);
        defer if (validation_path) |path| allocator.free(path);
        if (validation_path) |path| {
            try db.recordEvent(config.session, "tool_arg_repair", "collect_evidence -> validate_syntax after patch");
            var validation_call = tool_call.ToolCall{
                .name = try allocator.dupe(u8, "validate_syntax"),
                .path = try allocator.dupe(u8, path),
            };
            defer validation_call.deinit(allocator);
            return try runValidateSyntaxStep(allocator, config, prompt, &validation_call, client, events, db, ui_ptr, aggregate_sink, state, tool_iterations);
        }
        return try repairValidationRequiresSyntax(allocator, config, prompt, client, events, db, ui_ptr, aggregate_sink, state);
    }
    if (stateNeedsMutationTool(state)) {
        return try repairMutationRequiresPatch(allocator, config, prompt, client, events, db, ui_ptr, aggregate_sink, state);
    }

    if (isCollectEvidenceStage(call, "expand")) {
        return try runCollectEvidenceExpandStep(allocator, io, config, prompt, call, client, events, db, ui_ptr, aggregate_sink, state, tool_iterations);
    }
    if (isCollectEvidenceStage(call, "overview")) {
        return try runCollectEvidenceOverviewStep(allocator, io, config, prompt, call, client, events, db, ui_ptr, aggregate_sink, state, tool_iterations);
    }

    const call_source = collectEvidenceCallSource(call);
    const repaired_path = if (call.path == null and call_source != .git) try singleStructuredPathFromPrompt(allocator, prompt) else null;
    defer if (repaired_path) |owned| allocator.free(owned);
    if (repaired_path) |owned| {
        const body = try std.fmt.allocPrint(allocator, "collect_evidence path<-prompt_structured_path {s}", .{owned});
        defer allocator.free(body);
        try db.recordEvent(config.session, "tool_arg_repair", body);
    }

    const target_path = explicitHttpTargetFromCall(call);
    const path = call.path orelse repaired_path orelse target_path;
    if (target_path != null and call.http_search != true) {
        return try repairWebEvidenceIntentCall(allocator, config, prompt, client, events, db, ui_ptr, aggregate_sink, state, "collect_evidence target=http requires httpSearch=true");
    }
    if (target_path != null and !webEvidenceHasModelIntent(call)) {
        return try repairWebEvidenceIntentCall(allocator, config, prompt, client, events, db, ui_ptr, aggregate_sink, state, "collect_evidence httpSearch=true requires model-selected query/intent/terms");
    }
    const legacy_strategy = if (call_source == .git and call.strategy == null)
        contracts.StrategyName.history
    else if (call.path == null and repaired_path != null and (call.strategy == null or call.strategy.? == .auto))
        contracts.StrategyName.path
    else
        call.strategy orelse if (path == null) contracts.StrategyName.auto else contracts.StrategyName.path;
    const descriptor = strategy_registry.resolveCollectEvidence(.{
        .strategy_id = call.strategy_id,
        .source = call_source,
        .strategy = legacy_strategy,
        .path = path,
        .target = call.target,
        .http_search = call.http_search orelse false,
    }) catch |err| {
        try db.recordEvent(config.session, "tool_rejected", @errorName(err));
        try db.recordTurnError(config.session, .tool_contract, "collect_evidence:strategy", @errorName(err));
        return .stopped;
    };
    const effective_source = if (call.strategy_id != null) descriptor.source else call_source;
    const strategy = if (call.strategy_id != null) descriptor.strategy else legacy_strategy;
    if (path == null and (strategy == .path or strategy == .diagnostic)) {
        if (repairs.* >= max_tool_repairs) {
            try db.recordEvent(config.session, "tool_loop_stop", "collect_evidence missing path after repair; answer with collected evidence");
            const answer_context = try renderCollectedEvidenceContext(
                allocator,
                prompt,
                &state.context,
                null,
                null,
                context_profile.toolSchema(.code_evidence, .after_collect_evidence),
                "The previous collect_evidence call was still malformed. Answer now using only cited E# evidence already collected. Do not call tools again.",
            );
            defer allocator.free(answer_context);
            try db.recordEvent(config.session, "model_context", answer_context);
            return try streamDeferredToolLoopTurn(allocator, config, prompt, answer_context, client, events, db, ui_ptr, aggregate_sink, state);
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
            .next_action = "Emit one corrected collect_evidence tool call with path, or with intent+terms and strategy=auto|lexical|symbol. No prose.",
        });
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
            collectEvidenceRepairContract(),
        );
    }

    if (collectEvidenceHasSearchPlaceholder(call) and path == null and strategy != .path) {
        if (repairs.* >= max_tool_repairs) {
            try db.recordEvent(config.session, "tool_rejected", "collect_evidence missing intent/terms after repair");
            try db.recordTurnError(config.session, .tool_contract, "collect_evidence", "missing intent/terms after repair");
            return .stopped;
        }
        repairs.* += 1;
        try db.recordEvent(config.session, "tool_repair", "collect_evidence missing intent/terms");
        try events.emit(.{ .progress_update = "repairing tool call: collect_evidence requires search intent" });
        const repair_context = try renderCollectEvidenceSearchIntentRepairContext(
            allocator,
            prompt,
            &state.context,
        );
        defer allocator.free(repair_context);
        try db.recordEvent(config.session, "model_context", repair_context);
        const next = try streamDeferredRequiredToolLoopTurn(
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
            collectEvidenceRepairContract(),
        );
        switch (next) {
            .final_answer => return .final_answer,
            .tool_call => |next_call| return .{ .tool_call = next_call },
            .stopped => {
                var fallback_call = tool_call.ToolCall{
                    .name = try allocator.dupe(u8, "collect_evidence"),
                    .stage = try allocator.dupe(u8, "candidates"),
                    .strategy = strategy,
                };
                defer fallback_call.deinit(allocator);
                return try runCollectEvidenceCandidatesStep(allocator, io, config, prompt, &fallback_call, client, events, db, ui_ptr, aggregate_sink, state, tool_iterations, strategy);
            },
        }
    }

    if (path == null and effective_source != .git and !collectEvidenceHasSearchText(call)) {
        try db.recordEvent(config.session, "tool_arg_repair", "collect_evidence empty search -> candidates_from_task");
        return try runCollectEvidenceCandidatesStep(allocator, io, config, prompt, call, client, events, db, ui_ptr, aggregate_sink, state, tool_iterations, strategy);
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

        const duplicate_context = if (stateNeedsMutationTool(state))
            try renderCollectedEvidenceContextRequiringMutation(
                allocator,
                prompt,
                &state.context,
                activeToolSchema(state),
                mutationPatchNextAction(),
            )
        else
            try renderCollectedEvidenceContext(
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
        return try streamDeferredToolLoopTurn(allocator, config, prompt, duplicate_context, client, events, db, ui_ptr, aggregate_sink, state);
    }

    if (tool_iterations.* >= max_tool_emergency_iterations or !state.hasBudgetForMoreEvidence()) {
        try db.recordEvent(config.session, "tool_loop_stop", "evidence budget exhausted");
        try db.recordEvent(config.session, "working_context_budget", "evidence budget exhausted");
        return .stopped;
    }
    tool_iterations.* += 1;

    if (ui_ptr) |active_ui| try active_ui.showStatus("Reading");
    const tool_start = try renderCollectEvidenceAuditKey(allocator, effective_source, call.strategy_id, path, call.intent, call.terms, strategy);
    defer allocator.free(tool_start);
    try db.recordEvent(config.session, "tool_start", tool_start);
    try events.emit(.{ .tool_start = .{ .name = "collect_evidence", .detail = path orelse @tagName(strategy) } });

    const result = collect_evidence.execute(allocator, io, .{
        .path = path,
        .target = call.target,
        .http_search = call.http_search orelse false,
        .intent = call.intent,
        .need = call.need,
        .terms = call.terms,
        .target_files = call.target_files,
        .scope_root = call.scope_root,
        .task = prompt,
        .source = effective_source,
        .strategy_id = call.strategy_id,
        .strategy = strategy,
        .start_line = call.start_line,
        .max_lines = if (isCollectEvidenceStage(call, "minimum")) @min(call.max_lines, @as(usize, 8)) else call.max_lines,
        .budget_bytes = collectEvidenceBudgetForCall(call, path orelse call.target, state.remainingBudget()),
    }) catch |err| {
        try db.recordEvent(config.session, "tool_error", @errorName(err));
        try db.recordTurnError(config.session, .tool_runtime, "collect_evidence", @errorName(err));
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
        return try streamDeferredToolLoopTurn(allocator, config, prompt, follow_context, client, events, db, ui_ptr, aggregate_sink, state);
    };
    defer result.deinit(allocator);

    const model_evidence = if (call.http_search == true)
        try distillWebEvidenceForContext(allocator, config, prompt, explicitHttpTargetFromCall(call) orelse path orelse "<web>", call.terms orelse call.intent, result.evidence_text, client, db, &state.context)
    else
        try renderEvidenceAndMicroContext(allocator, result.evidence_text, result.micro_context_text);
    defer allocator.free(model_evidence);
    const model_context_id = if (call.http_search == true)
        try webEvidenceContextId(allocator, model_evidence)
    else
        try allocator.dupe(u8, result.context_id);
    defer allocator.free(model_context_id);
    try db.recordEvent(config.session, "tool_event", result.tool_event_audit_text);
    try db.recordEvent(config.session, "evidence", model_evidence);
    try events.emit(.{ .tool_result = .{ .name = "collect_evidence", .output = model_evidence } });
    try state.rememberExecutedArgs(path orelse call.target, call.terms, strategy, call.start_line, call.max_lines, model_context_id, model_evidence, model_evidence.len, result.quality_score);
    state.recordObservation();
    const working_add = try std.fmt.allocPrint(
        allocator,
        "path={s} terms_bytes={} strategy_id={s} strategy={s} compact={} model_bytes={} quality={}",
        .{ path orelse call.target orelse "<auto>", if (call.terms) |terms| terms.len else 0, call.strategy_id orelse "", @tagName(strategy), call.compact, model_evidence.len, result.quality_score },
    );
    defer allocator.free(working_add);
    try db.recordEvent(config.session, "working_context_add", working_add);
    if (call.compact) {
        state.context.compactAll();
        try db.recordEvent(config.session, "working_context_compact", "collect_evidence compact=true");
    }

    const require_mutation = stateNeedsMutationTool(state);
    const next_action =
        if (require_mutation)
            mutationPatchNextAction()
        else if (state.shouldAllowMoreEvidence() and result.quality_score < weak_evidence_quality_score)
            "The collected workspace evidence is weak or generic. Emit one refined collect_evidence call before answering: use stage=candidates for ambiguous source-code questions, choose concrete symbol/path/error terms from the evidence and task, and do not request the same terms again."
        else if (state.shouldAllowMoreEvidence())
            "Answer only if cited evidence directly covers the request. If the task is broad and evidence covers only a fragment, emit refined collect_evidence now; do not ask permission for obvious collection. Do not repeat same terms."
        else
            "Answer the current user request using only cited evidence above. Do not add capabilities, files, tools, architecture, or prior-session facts not present in evidence. If evidence is insufficient, say what is evidenced and what is not. Do not call tools again in this turn.";
    const require_refinement = (state.shouldAllowMoreEvidence() and result.quality_score < weak_evidence_quality_score) or state.shouldRequireExploratoryRefinement(call, path, strategy);
    if (require_refinement and path == null) state.forced_exploratory_refinements += 1;
    const follow_context = if (require_mutation)
        try renderCollectedEvidenceContextRequiringMutation(
            allocator,
            prompt,
            &state.context,
            activeToolSchema(state),
            next_action,
        )
    else if (require_refinement)
        try renderCollectedEvidenceContextRequiringCollection(
            allocator,
            prompt,
            &state.context,
            null,
            null,
            activeToolSchema(state),
            next_action,
        )
    else
        try renderCollectedEvidenceContext(
            allocator,
            prompt,
            &state.context,
            null,
            null,
            if (state.shouldAllowMoreEvidence()) activeToolSchema(state) else context_profile.toolSchema(.code_evidence, .after_collect_evidence),
            next_action,
        );
    defer allocator.free(follow_context);
    try db.recordEvent(config.session, "model_context", follow_context);

    return try streamDeferredToolLoopTurn(allocator, config, prompt, follow_context, client, events, db, ui_ptr, aggregate_sink, state);
}

fn phaseForTool(name: []const u8) audit.OperationalPhase {
    if (std.mem.eql(u8, name, "set_operational_contract")) return .contract;
    if (std.mem.eql(u8, name, "collect_evidence")) return .evidence;
    if (std.mem.eql(u8, name, "search_session")) return .evidence;
    if (std.mem.eql(u8, name, "search_persistent_context")) return .evidence;
    if (std.mem.eql(u8, name, "apply_patch")) return .mutation;
    if (std.mem.eql(u8, name, "promote_context")) return .mutation;
    if (std.mem.eql(u8, name, "validate_syntax")) return .validation;
    if (std.mem.eql(u8, name, "inspect_runtime")) return .validation;
    if (std.mem.eql(u8, name, "web_search")) return .evidence;
    return .evidence;
}

fn collectEvidenceHasSearchText(call: *const tool_call.ToolCall) bool {
    return hasNonEmptyText(call.intent) or hasNonEmptyText(call.terms) or hasNonEmptyText(call.need) or hasNonEmptyText(call.target_files) or hasNonEmptyText(call.scope_root);
}

fn collectEvidenceSourceIs(call: *const tool_call.ToolCall, source: contracts.SourceName) bool {
    return collectEvidenceCallSource(call) == source;
}

fn collectEvidenceCallSource(call: *const tool_call.ToolCall) contracts.SourceName {
    if (call.strategy_id) |strategy_id| {
        if (strategy_registry.byId(strategy_id)) |descriptor| return descriptor.source;
    }
    return call.source orelse .auto;
}

fn collectEvidenceHasSearchPlaceholder(call: *const tool_call.ToolCall) bool {
    if (call.intent) |value| if (isSchemaPlaceholderText(value)) return true;
    if (call.terms) |value| if (isSchemaPlaceholderText(value)) return true;
    if (call.need) |value| if (isSchemaPlaceholderText(value)) return true;
    if (call.target_files) |value| if (isSchemaPlaceholderText(value)) return true;
    if (call.scope_root) |value| if (isSchemaPlaceholderText(value)) return true;
    return false;
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
        try db.recordTurnError(config.session, .tool_runtime, "collect_evidence:candidates", @errorName(err));
        try events.emit(.{ .tool_result = .{ .name = "collect_evidence", .output = @errorName(err) } });
        return .stopped;
    };
    defer result.deinit(allocator);

    if (pathlessCandidatesAreDiffuse(result.candidates.items)) {
        try db.recordEvent(config.session, "tool_arg_repair", "diffuse candidates -> overview");
        return try runCollectEvidenceOverviewStep(allocator, io, config, prompt, call, client, events, db, ui_ptr, aggregate_sink, state, tool_iterations);
    }

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
        .next_action = "Output exactly one visible XML tool_call now: collect_evidence stage=expand selectedCandidate=<best visible C# for the task>. Do not answer in prose. Do not put the tool_call only in thinking.",
    });
    defer allocator.free(follow_context);
    try db.recordEvent(config.session, "model_context", follow_context);
    const next = try streamDeferredRequiredToolLoopTurn(
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
    switch (next) {
        .final_answer => return .final_answer,
        .tool_call => |next_call| return .{ .tool_call = next_call },
        .stopped => {
            if (state.context.entries.items.len > 0) {
                try db.recordEvent(config.session, "tool_loop_stop", "candidate selection missing; answer with existing evidence");
                const answer_context = try renderCollectedEvidenceContext(
                    allocator,
                    prompt,
                    &state.context,
                    null,
                    null,
                    context_profile.toolSchema(.code_evidence, .after_collect_evidence),
                    "Candidate selection failed, but E# evidence already exists. Answer now using only the existing cited E# evidence. Do not call tools again.",
                );
                defer allocator.free(answer_context);
                try db.recordEvent(config.session, "model_context", answer_context);
                return try streamDeferredToolLoopTurn(allocator, config, prompt, answer_context, client, events, db, ui_ptr, aggregate_sink, state);
            }
            const fallback_selected = selectedCandidateForProtocolFallback(state) orelse return .stopped;
            const fallback_candidate = state.findCandidate(fallback_selected) orelse return .stopped;
            const body = try std.fmt.allocPrint(allocator, "candidate selection missing -> collect range {s}", .{fallback_selected});
            defer allocator.free(body);
            try db.recordEvent(config.session, "tool_arg_repair", body);
            var fallback_call = tool_call.ToolCall{
                .name = try allocator.dupe(u8, "collect_evidence"),
                .path = try allocator.dupe(u8, fallback_candidate.path),
                .strategy = .path,
                .start_line = fallback_candidate.start_line,
                .max_lines = 48,
            };
            defer fallback_call.deinit(allocator);
            return try runCollectEvidenceRangeStep(allocator, io, config, prompt, fallback_call.path.?, fallback_call.start_line, fallback_call.max_lines, client, events, db, ui_ptr, aggregate_sink, state, tool_iterations);
        },
    }
}

fn pathlessCandidatesAreDiffuse(candidates: []const collect_evidence.CandidateItem) bool {
    if (candidates.len < 4) return false;
    var unique_paths: usize = 0;
    var dominant_path_count: usize = 0;
    for (candidates, 0..) |candidate, idx| {
        var first_for_path = true;
        for (candidates[0..idx]) |prior| {
            if (std.mem.eql(u8, prior.path, candidate.path)) {
                first_for_path = false;
                break;
            }
        }
        if (first_for_path) unique_paths += 1;
        var path_count: usize = 0;
        for (candidates) |other| {
            if (std.mem.eql(u8, other.path, candidate.path)) path_count += 1;
        }
        dominant_path_count = @max(dominant_path_count, path_count);
    }
    if (dominant_path_count * 2 >= candidates.len) return false;
    return unique_paths >= 4;
}

fn runCollectEvidenceOverviewStep(
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
    if (tool_iterations.* >= max_tool_emergency_iterations or !state.hasBudgetForMoreEvidence()) {
        try db.recordEvent(config.session, "tool_loop_stop", "overview budget exhausted");
        return .stopped;
    }
    tool_iterations.* += 1;

    if (ui_ptr) |active_ui| try active_ui.showStatus("Reading");
    const tool_start = try std.fmt.allocPrint(allocator, "collect_evidence\tstage=overview intent_bytes={}", .{if (call.intent) |value| value.len else 0});
    defer allocator.free(tool_start);
    try db.recordEvent(config.session, "tool_start", tool_start);
    try events.emit(.{ .tool_start = .{ .name = "collect_evidence", .detail = "overview" } });

    const result = collect_evidence.execute(allocator, io, .{
        .intent = call.intent,
        .need = call.need,
        .terms = call.terms,
        .target_files = call.target_files,
        .scope_root = call.scope_root,
        .task = prompt,
        .strategy = .auto,
        .budget_bytes = collectEvidenceExecutionBudget(null, state.remainingBudget()),
    }) catch |err| {
        try db.recordEvent(config.session, "tool_error", @errorName(err));
        try db.recordTurnError(config.session, .tool_runtime, "collect_evidence:overview", @errorName(err));
        try events.emit(.{ .tool_result = .{ .name = "collect_evidence", .output = @errorName(err) } });
        return .stopped;
    };
    defer result.deinit(allocator);

    const model_evidence = try renderEvidenceAndMicroContext(allocator, result.evidence_text, result.micro_context_text);
    defer allocator.free(model_evidence);
    try db.recordEvent(config.session, "tool_event", result.tool_event_audit_text);
    try db.recordEvent(config.session, "evidence", model_evidence);
    try events.emit(.{ .tool_result = .{ .name = "collect_evidence", .output = model_evidence } });
    try state.rememberExecutedArgs(null, null, .auto, call.start_line, call.max_lines, result.context_id, model_evidence, result.model_bytes, result.quality_score);
    state.recordObservation();

    const require_refinement = shouldRequireOverviewRefinement(state, result.quality_score);
    if (require_refinement) state.forced_exploratory_refinements += 1;
    const next_action = if (require_refinement)
        "The overview is only a workspace map. Emit one focused collect_evidence call using concrete terms from the user task and overview paths before answering. Do not ask clarification."
    else
        "Answer from the structural workspace overview evidence. If it does not cover the user's request, emit a focused collect_evidence call with concrete terms. Do not use C# candidates for this overview answer.";
    const follow_context = if (require_refinement)
        try renderCollectedEvidenceContextRequiringCollection(
            allocator,
            prompt,
            &state.context,
            null,
            null,
            activeToolSchema(state),
            next_action,
        )
    else
        try renderCollectedEvidenceContext(
            allocator,
            prompt,
            &state.context,
            null,
            null,
            if (state.shouldAllowMoreEvidence()) activeToolSchema(state) else context_profile.toolSchema(.code_evidence, .after_collect_evidence),
            next_action,
        );
    defer allocator.free(follow_context);
    try db.recordEvent(config.session, "model_context", follow_context);
    return try streamDeferredToolLoopTurn(allocator, config, prompt, follow_context, client, events, db, ui_ptr, aggregate_sink, state);
}

fn shouldRequireOverviewRefinement(state: *const ToolLoopState, quality_score: i32) bool {
    return state.shouldAllowMoreEvidence() and quality_score <= 0;
}

fn selectedCandidateForProtocolFallback(state: *const ToolLoopState) ?[]const u8 {
    for (state.candidates.items) |candidate| {
        if (std.mem.eql(u8, candidate.source, "local_symbol_ast")) return candidate.id;
    }
    for (state.candidates.items) |candidate| {
        if (std.mem.eql(u8, candidate.source, "symbol_ast")) return candidate.id;
    }
    if (state.candidates.items.len == 0) return null;
    return state.candidates.items[0].id;
}

fn runCollectEvidenceRangeStep(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: cli.Config,
    prompt: []const u8,
    path: []const u8,
    start_line: usize,
    max_lines: usize,
    client: *http.LocalModelClient,
    events: *ui_events.EventBus,
    db: *audit.AuditDb,
    ui_ptr: ?*tui.TerminalUi(fd_writer.FdWriter),
    aggregate_sink: *StreamSink,
    state: *ToolLoopState,
    tool_iterations: *usize,
) !ToolLoopNext {
    if (state.hasExecutedArgs(path, null, .path, start_line, max_lines)) {
        try db.recordEvent(config.session, "tool_loop_stop", "duplicate fallback candidate range");
        return .stopped;
    }
    if (tool_iterations.* >= max_tool_emergency_iterations or !state.hasBudgetForMoreEvidence()) {
        try db.recordEvent(config.session, "tool_loop_stop", "fallback candidate range budget exhausted");
        return .stopped;
    }
    tool_iterations.* += 1;

    if (ui_ptr) |active_ui| try active_ui.showStatus("Reading");
    const tool_start = try renderCollectEvidenceAuditKey(allocator, .file, null, path, null, null, .path);
    defer allocator.free(tool_start);
    try db.recordEvent(config.session, "tool_start", tool_start);
    try events.emit(.{ .tool_start = .{ .name = "collect_evidence", .detail = path } });

    const result = collect_evidence.execute(allocator, io, .{
        .path = path,
        .task = prompt,
        .strategy = .path,
        .start_line = start_line,
        .max_lines = max_lines,
        .budget_bytes = collectEvidenceExecutionBudget(path, state.remainingBudget()),
    }) catch |err| {
        try db.recordEvent(config.session, "tool_error", @errorName(err));
        try db.recordTurnError(config.session, .tool_runtime, "collect_evidence:range", @errorName(err));
        try events.emit(.{ .tool_result = .{ .name = "collect_evidence", .output = @errorName(err) } });
        return .stopped;
    };
    defer result.deinit(allocator);

    const model_evidence = try renderEvidenceAndMicroContext(allocator, result.evidence_text, result.micro_context_text);
    defer allocator.free(model_evidence);
    try db.recordEvent(config.session, "tool_event", result.tool_event_audit_text);
    try db.recordEvent(config.session, "evidence", model_evidence);
    try events.emit(.{ .tool_result = .{ .name = "collect_evidence", .output = model_evidence } });
    try state.rememberExecutedArgs(path, null, .path, start_line, max_lines, result.context_id, model_evidence, result.model_bytes, result.quality_score);
    state.recordObservation();

    const next_action = if (state.shouldAllowMoreEvidence() and result.quality_score < weak_evidence_quality_score)
        "The fallback candidate range evidence is weak or generic. Emit one refined collect_evidence call before answering."
    else
        "Answer only if cited E# directly covers the request. If the task is broad and this range covers only a fragment, emit refined collect_evidence now; do not ask permission.";
    const follow_context = if (state.shouldAllowMoreEvidence() and result.quality_score < weak_evidence_quality_score)
        try renderCollectedEvidenceContextRequiringCollection(
            allocator,
            prompt,
            &state.context,
            null,
            null,
            activeToolSchema(state),
            next_action,
        )
    else
        try renderCollectedEvidenceContext(
            allocator,
            prompt,
            &state.context,
            null,
            null,
            if (state.shouldAllowMoreEvidence()) activeToolSchema(state) else context_profile.toolSchema(.code_evidence, .after_collect_evidence),
            next_action,
        );
    defer allocator.free(follow_context);
    try db.recordEvent(config.session, "model_context", follow_context);
    return try streamDeferredToolLoopTurn(allocator, config, prompt, follow_context, client, events, db, ui_ptr, aggregate_sink, state);
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
        try db.recordTurnError(config.session, .tool_contract, "collect_evidence:expand", "unknown selectedCandidate");
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

    const max_lines = candidateExpansionLineLimit(call.max_lines, candidate.start_line, candidate.end_line);
    if (state.hasExecutedArgs(candidate.path, call.terms, .path, candidate.start_line, max_lines)) {
        try db.recordEvent(config.session, "tool_loop_stop", "duplicate candidate expansion");
        if (state.context.entries.items.len == 0) return .stopped;
        const answer_context = try renderCollectedEvidenceContext(
            allocator,
            prompt,
            &state.context,
            null,
            null,
            context_profile.toolSchema(.code_evidence, .after_collect_evidence),
            "The selected candidate was already expanded. Answer now using only the existing cited E# evidence. Do not call tools again.",
        );
        defer allocator.free(answer_context);
        try db.recordEvent(config.session, "model_context", answer_context);
        return try streamDeferredToolLoopTurn(allocator, config, prompt, answer_context, client, events, db, ui_ptr, aggregate_sink, state);
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
        try db.recordTurnError(config.session, .tool_runtime, "collect_evidence:expand", @errorName(err));
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
    state.recordObservation();

    const require_refinement = state.shouldAllowMoreEvidence() and result.quality_score < weak_evidence_quality_score;
    const next_action = if (require_refinement)
        expandedCandidateNextAction(true, true)
    else
        expandedCandidateNextAction(state.shouldAllowMoreEvidence(), false);
    const follow_context = if (require_refinement)
        try renderCollectedEvidenceContextRequiringCollection(
            allocator,
            prompt,
            &state.context,
            null,
            null,
            activeToolSchema(state),
            next_action,
        )
    else
        try renderCollectedEvidenceContext(
            allocator,
            prompt,
            &state.context,
            null,
            null,
            if (state.shouldAllowMoreEvidence()) activeToolSchema(state) else context_profile.toolSchema(.code_evidence, .after_collect_evidence),
            next_action,
        );
    defer allocator.free(follow_context);
    try db.recordEvent(config.session, "model_context", follow_context);
    return try streamDeferredToolLoopTurn(allocator, config, prompt, follow_context, client, events, db, ui_ptr, aggregate_sink, state);
}

fn expandedCandidateNextAction(allow_more_evidence: bool, weak_evidence: bool) []const u8 {
    if (allow_more_evidence and weak_evidence) {
        return "The expanded candidate evidence is weak or generic. Emit one more collect_evidence call with a different selectedCandidate or refined intent+terms before answering.";
    }
    if (allow_more_evidence) {
        return "Answer only if cited E# directly covers the request. If the task is broad and this candidate covers only a fragment, emit one more collect_evidence call; do not ask permission. If naming a called/related function whose declaration is not in E#, collect it first.";
    }
    return "Answer using only cited E# evidence from the expanded candidate. If evidence is insufficient, say what is evidenced and what is not. Do not call tools again.";
}

fn candidateExpansionLineLimit(requested_max_lines: usize, candidate_start_line: usize, candidate_end_line: usize) usize {
    const candidate_lines = candidate_end_line - candidate_start_line + 1;
    const requested_lines = if (requested_max_lines == 12) @as(usize, 32) else requested_max_lines;
    return @min(requested_lines, candidate_lines);
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

fn renderOperationalContractNextAction(
    allocator: std.mem.Allocator,
    selected: contracts.ContractName,
    call: *const tool_call.ToolCall,
) ![]u8 {
    if (selected == .search_web) {
        const query = declaredWebQuery(call) orelse "";
        return std.fmt.allocPrint(
            allocator,
            "Emit web_search with the declared query/target. query={s} target={s} budget_bytes={}",
            .{ query, call.target orelse "", call.budget_bytes orelse max_web_evidence_budget },
        );
    }
    if (selected == .collect_evidence) {
        return allocator.dupe(u8, "Proceed inside the active contract. Call collect_evidence with model-chosen strategyId/source/strategy and intent/terms/path.");
    }
    if (selected == .mutate_file) {
        return allocator.dupe(u8, "Proceed inside the active contract. Collect evidence first when needed, then include contextId in apply_patch.");
    }
    if (selected == .validate_work) {
        return allocator.dupe(u8, "Proceed inside the active contract. Call validate_syntax for the changed or requested Zig file.");
    }
    if (selected == .memory) {
        const terms = call.terms orelse call.intent orelse call.reason orelse "";
        if (call.requires_memory_promotion == true) {
            return allocator.dupe(u8, "Proceed inside the active memory contract. Promote the user-confirmed durable rule/preference/operational constraint with promote_context target=skills and concise interpreted text. Do not search first unless applying an existing rule is needed.");
        }
        return std.fmt.allocPrint(allocator, "Proceed inside the active memory contract. Search MEMORY/SKILLS with search_persistent_context target=both terms={s} before applying existing persistent context. If the current user turn establishes a new durable rule/preference, promote_context target=skills with concise interpreted text instead of searching.", .{terms});
    }
    return allocator.dupe(u8, "Proceed inside the active contract. Call only advertised tools, or answer if no more tool-backed context is needed.");
}

fn runSetOperationalContractStep(
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
    if (tool_iterations.* >= max_tool_emergency_iterations) {
        try db.recordEvent(config.session, "tool_loop_stop", "contract budget exhausted");
        return .stopped;
    }
    tool_iterations.* += 1;

    if (call.contract == null and (call.requires_inspection == null or
        call.requires_mutation == null or
        call.requires_runtime_validation == null or
        call.requires_browser_diagnostics == null))
    {
        try db.recordEvent(config.session, "tool_repair", "set_operational_contract missing required booleans");
        try db.recordTurnError(config.session, .tool_contract, "set_operational_contract", "missing required booleans");
        const repair_context = try model_context.renderModelTurnContext(allocator, .{
            .task = prompt,
            .contracts = activeToolSchema(state),
            .obligations = &.{
                "set_operational_contract requires requiresInspection, requiresMutation, requiresRuntimeValidation, and requiresBrowserDiagnostics.",
            },
            .next_action = "Emit one corrected set_operational_contract call with all required boolean fields, or answer directly if no operational contract is needed.",
        });
        defer allocator.free(repair_context);
        try db.recordEvent(config.session, "model_context", repair_context);
        return try streamDeferredToolLoopTurn(allocator, config, prompt, repair_context, client, events, db, ui_ptr, aggregate_sink, state);
    }

    const effective_requires_mutation = call.requires_mutation orelse false;
    const request = contracts.OperationalContractRequest{
        .requested_contract = call.contract,
        .requires_inspection = (call.requires_inspection orelse false) or effective_requires_mutation,
        .requires_mutation = effective_requires_mutation,
        .requires_runtime_validation = call.requires_runtime_validation orelse false,
        .requires_browser_diagnostics = call.requires_browser_diagnostics orelse false,
        .requires_memory_promotion = call.requires_memory_promotion orelse false,
    };
    const selected_name = contracts.selectOperationalContract(request);
    if (state.contract_selected and selected_name == state.active_contract.name) {
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
                "Use set_operational_contract only to switch to a different contract after evidence changes the operational strategy.",
            },
            .grounding = groundingRules(),
            .next_action = "Continue inside the existing contract. Call an advertised evidence/session/tool if needed, otherwise answer the user now.",
        });
        defer allocator.free(duplicate_context);
        try db.recordEvent(config.session, "model_context", duplicate_context);
        return try streamDeferredToolLoopTurn(allocator, config, prompt, duplicate_context, client, events, db, ui_ptr, aggregate_sink, state);
    }
    const selected = contracts.activeContract(selected_name) orelse return error.MissingContract;
    const switched_contract = state.contract_selected;
    state.selectContract(selected, request);

    const allowed = try renderAllowedTools(allocator, selected.allowed_tools);
    defer allocator.free(allowed);
    const declared_web_query = declaredWebQuery(call);
    const audit_body = try std.fmt.allocPrint(
        allocator,
        "contract={s} requestedContract={s} strategyId={s} query_bytes={} target={s} budget_bytes={} requiresInspection={} requiresMutation={} requiresRuntimeValidation={} requiresBrowserDiagnostics={} allowed_tools={s} reason={s}",
        .{
            @tagName(selected.name),
            if (call.contract) |contract| @tagName(contract) else "",
            call.strategy_id orelse "",
            if (declared_web_query) |query| query.len else 0,
            call.target orelse "",
            call.budget_bytes orelse 0,
            request.requires_inspection,
            request.requires_mutation,
            request.requires_runtime_validation,
            request.requires_browser_diagnostics,
            allowed,
            call.reason orelse "",
        },
    );
    defer allocator.free(audit_body);
    try db.recordEvent(config.session, if (switched_contract) "contract_switched" else "contract_selected", audit_body);
    try events.emit(.{ .tool_start = .{ .name = "set_operational_contract", .detail = @tagName(selected.name) } });
    try events.emit(.{ .tool_result = .{ .name = "set_operational_contract", .output = audit_body } });

    if (selected.name == .search_web and webEvidenceHasModelIntent(call)) {
        try db.recordEvent(config.session, "contract_executor", "contract=search_web executor=web_search source=set_operational_contract");
        var web_call = tool_call.ToolCall{
            .name = try allocator.dupe(u8, "web_search"),
            .target = if (call.target) |target| try allocator.dupe(u8, target) else null,
            .terms = if (declared_web_query) |query| try allocator.dupe(u8, query) else null,
            .intent = if (call.intent) |intent| try allocator.dupe(u8, intent) else null,
            .budget_bytes = call.budget_bytes,
            .strategy_id = if (call.strategy_id) |strategy_id| try allocator.dupe(u8, strategy_id) else null,
        };
        defer web_call.deinit(allocator);
        return try runWebSearchStep(allocator, io, config, prompt, &web_call, client, events, db, ui_ptr, aggregate_sink, state, tool_iterations);
    }

    const next_action_text = try renderOperationalContractNextAction(allocator, selected.name, call);
    defer allocator.free(next_action_text);
    const follow_context = try model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .contracts = activeToolSchema(state),
        .obligations = &.{
            "The operational contract is now active for this turn.",
            "Only advertised tools may be called. The controller rejects tools outside the selected contract.",
        },
        .grounding = groundingRules(),
        .next_action = if (selected.name == .answer_only)
            "Answer directly now. No tools are active for this no-op contract."
        else
            next_action_text,
    });
    defer allocator.free(follow_context);
    try db.recordEvent(config.session, "model_context", follow_context);
    return try streamDeferredToolLoopTurn(allocator, config, prompt, follow_context, client, events, db, ui_ptr, aggregate_sink, state);
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
        try db.recordTurnError(config.session, .tool_runtime, "apply_patch", @errorName(err));
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
        return try streamDeferredToolLoopTurn(allocator, config, prompt, repair_context, client, events, db, ui_ptr, aggregate_sink, state);
    };
    defer result.deinit(allocator);

    try db.recordEvent(config.session, "tool_event", result.audit_text);
    try db.recordEvent(config.session, "patch_result", result.text);
    try events.emit(.{ .tool_result = .{ .name = "apply_patch", .output = result.text } });
    state.recordMutation();

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
    return try streamDeferredToolLoopTurn(allocator, config, prompt, follow_context, client, events, db, ui_ptr, aggregate_sink, state);
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
    return try streamDeferredToolLoopTurn(allocator, config, prompt, repair_context, client, events, db, ui_ptr, aggregate_sink, state);
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
        try db.recordTurnError(config.session, .validation_failed, "validate_syntax", @errorName(err));
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
    state.recordRuntimeValidation();

    const validation_block = [_]model_context.EvidenceBlock{.{ .text = evidence_text }};
    const follow_context = try model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .evidence = &validation_block,
        .grounding = groundingRules(),
        .next_action = "Answer with the patch and validation result. Cite validation evidence if it reports errors.",
    });
    defer allocator.free(follow_context);
    try db.recordEvent(config.session, "model_context", follow_context);
    return try streamDeferredToolLoopTurn(allocator, config, prompt, follow_context, client, events, db, ui_ptr, aggregate_sink, state);
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
    return try streamDeferredToolLoopTurn(allocator, config, prompt, repair_context, client, events, db, ui_ptr, aggregate_sink, state);
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
    if (tool_iterations.* >= max_tool_emergency_iterations) return .stopped;
    tool_iterations.* += 1;
    const owned_target = try runtimeInspectionTarget(allocator, config.host, call.target orelse call.path);
    defer allocator.free(owned_target);
    if (ui_ptr) |active_ui| try active_ui.showStatus("Inspecting");
    const tool_start = try std.fmt.allocPrint(allocator, "inspect_runtime target={s}", .{owned_target});
    defer allocator.free(tool_start);
    try db.recordEvent(config.session, "tool_start", tool_start);
    try events.emit(.{ .tool_start = .{ .name = "inspect_runtime", .detail = owned_target } });

    const inspected = http.inspectHttpGet(allocator, owned_target);
    defer inspected.deinit(allocator);
    const result = try renderRuntimeInspection(allocator, inspected);
    defer allocator.free(result);
    try db.recordEvent(config.session, "tool_event", result);
    try db.recordEvent(config.session, "runtime_inspection", result);
    try events.emit(.{ .tool_result = .{ .name = "inspect_runtime", .output = result } });
    state.recordBrowserDiagnostics();
    const follow_context = try model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .evidence = &.{.{ .text = result }},
        .obligations = &.{"Runtime inspection is bounded HTTP status/body evidence. Do not claim DOM/browser automation ran."},
        .grounding = groundingRules(),
        .next_action = "Answer using the HTTP runtime inspection evidence. State browser DOM automation was not executed.",
    });
    defer allocator.free(follow_context);
    try db.recordEvent(config.session, "model_context", follow_context);
    return try streamDeferredToolLoopTurn(allocator, config, prompt, follow_context, client, events, db, ui_ptr, aggregate_sink, state);
}

fn runtimeInspectionTarget(allocator: std.mem.Allocator, backend_host: []const u8, requested: ?[]const u8) ![]u8 {
    const raw = std.mem.trim(u8, requested orelse backend_host, " \t\r\n");
    if (std.mem.startsWith(u8, raw, "http://") or std.mem.startsWith(u8, raw, "https://")) return allocator.dupe(u8, raw);
    if (std.mem.startsWith(u8, raw, "/")) return std.fmt.allocPrint(allocator, "http://{s}{s}", .{ backend_host, raw });
    return std.fmt.allocPrint(allocator, "http://{s}", .{raw});
}

fn renderRuntimeInspection(allocator: std.mem.Allocator, result: http.RuntimeHttpResult) ![]u8 {
    const status = try optionalUsizeText(allocator, if (result.status) |value| @as(usize, @intCast(value)) else null);
    defer allocator.free(status);
    return std.fmt.allocPrint(
        allocator,
        "[RUNTIME_INSPECTION]\nsource=http_get raw_context_persisted=false target={s}\nstatus={s}\nserver={s}\nerror={s}\nbody_snippet={s}\n",
        .{
            result.target,
            status,
            result.server orelse "",
            result.error_name orelse "",
            result.body_snippet,
        },
    );
}

fn optimizeWebSearchQueryForFetch(
    allocator: std.mem.Allocator,
    config: cli.Config,
    prompt: []const u8,
    declared_query: ?[]const u8,
    client: *http.LocalModelClient,
    db: *audit.AuditDb,
) !?[]u8 {
    const query = std.mem.trim(u8, declared_query orelse "", " \t\r\n");
    if (query.len == 0) return null;
    const optimize_prompt = try renderWebQueryOptimizationPrompt(allocator, prompt, query);
    defer allocator.free(optimize_prompt);

    var sink = InternalCaptureSink{
        .allocator = allocator,
        .filter = reasoning_filter.ReasoningFilter.init(allocator, false),
        .visible = std.ArrayList(u8).empty,
        .thinking = std.ArrayList(u8).empty,
    };
    defer sink.deinit();

    client.streamInference(.{
        .user_prompt = optimize_prompt,
        .max_tokens = 384,
    }, &sink) catch |err| {
        try recordWebQueryOptimizationAudit(allocator, db, config.session, query, query, false, @errorName(err));
        return null;
    };
    try sink.flush();

    const optimized = try normalizeWebQueryOptimizationOutput(allocator, sink.visible.items);
    errdefer if (optimized) |value| allocator.free(value);
    if (optimized) |value| {
        if (!optimizedQueryKeepsDeclaredCoverage(query, value)) {
            allocator.free(value);
            try recordWebQueryOptimizationAudit(allocator, db, config.session, query, query, false, "lossy_query");
            return null;
        }
    }
    try recordWebQueryOptimizationAudit(allocator, db, config.session, query, optimized orelse query, optimized != null, "");
    return optimized;
}

fn renderWebQueryOptimizationPrompt(allocator: std.mem.Allocator, prompt: []const u8, declared_query: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\[WEB_QUERY_OPTIMIZATION]
        \\Return exactly one web search query. No prose, no XML, no markdown.
        \\Use USER_TASK and MODEL_DECLARED_QUERY to produce a narrow operational query.
        \\Preserve MODEL_DECLARED_QUERY coverage. Do not enrich it with facts, entities, roles, categories, locations, nationality, platform, biography, or accusations absent from USER_TASK or MODEL_DECLARED_QUERY.
        \\Do not invent URLs. Maximum 12 words.
        \\
        \\[USER_TASK]
        \\{s}
        \\
        \\[MODEL_DECLARED_QUERY]
        \\{s}
        \\
    , .{ prompt, declared_query });
}

fn normalizeWebQueryOptimizationOutput(allocator: std.mem.Allocator, generated: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, generated, " \t\r\n\"'");
    if (trimmed.len == 0) return null;
    if (std.mem.indexOf(u8, trimmed, "<tool_call>") != null) return null;
    if (std.mem.indexOf(u8, trimmed, "[WEB_") != null) return null;

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var lines = std.mem.tokenizeAny(u8, trimmed, "\r\n");
    const first_line = std.mem.trim(u8, lines.next() orelse trimmed, " \t\r\n\"'");
    const sentence_end = firstSentenceEnd(first_line) orelse first_line.len;
    const line = std.mem.trim(u8, first_line[0..sentence_end], " \t\r\n\"'");
    if (line.len == 0 or line.len > 180) return null;
    var words = std.mem.tokenizeAny(u8, line, " \t");
    var count: usize = 0;
    while (words.next()) |word| {
        if (count >= 12) break;
        if (out.items.len > 0) try out.append(allocator, ' ');
        try out.appendSlice(allocator, word);
        count += 1;
    }
    if (out.items.len == 0) return null;
    return try out.toOwnedSlice(allocator);
}

fn firstSentenceEnd(text: []const u8) ?usize {
    for (text, 0..) |ch, i| {
        if (ch == '.' or ch == '!' or ch == '?') return i;
    }
    return null;
}

fn optimizedQueryKeepsDeclaredCoverage(original_query: []const u8, optimized_query: []const u8) bool {
    var original_terms: usize = 0;
    var covered_terms: usize = 0;
    var it = std.mem.tokenizeAny(u8, original_query, " \t\r\n\"'`()[]{}<>:;,./\\|+-_*=");
    while (it.next()) |raw| {
        const term = std.mem.trim(u8, raw, " \t\r\n");
        if (term.len < 3) continue;
        original_terms += 1;
        if (containsIgnoreCaseAscii(optimized_query, term)) covered_terms += 1;
    }
    if (original_terms <= 1) return optimized_query.len >= original_query.len;
    return covered_terms * 2 >= original_terms;
}

fn containsIgnoreCaseAscii(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn recordWebQueryOptimizationAudit(
    allocator: std.mem.Allocator,
    db: *audit.AuditDb,
    session: []const u8,
    original_query: []const u8,
    final_query: []const u8,
    success: bool,
    err: []const u8,
) !void {
    const body = try std.fmt.allocPrint(
        allocator,
        "tool=web_search_query_optimizer success={} original_query_bytes={} final_query={s} error={s}",
        .{ success, original_query.len, final_query, err },
    );
    defer allocator.free(body);
    try db.recordEvent(session, "web_query_optimization", body);
}

fn runWebSearchStep(
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
    if (tool_iterations.* >= max_tool_emergency_iterations or !state.hasBudgetForMoreEvidence()) {
        try db.recordEvent(config.session, "tool_loop_stop", "web evidence budget exhausted");
        return .stopped;
    }
    tool_iterations.* += 1;
    if (!webEvidenceHasModelIntent(call)) return try repairWebEvidenceIntentCall(allocator, config, prompt, client, events, db, ui_ptr, aggregate_sink, state, "web_search requires model-selected query matching the user's external-evidence intent");
    const declared_query = declaredWebQuery(call);
    const explicit_target = explicitHttpTargetFromCall(call) orelse if (declared_query) |query_text| explicitHttpTargetFromText(query_text) else null;
    const stripped_query = if (explicit_target != null and explicitHttpTargetFromCall(call) == null and declared_query != null)
        try stripFirstHttpUrlFromText(allocator, declared_query.?)
    else
        null;
    defer if (stripped_query) |value| allocator.free(value);
    const fetch_query_input = if (stripped_query) |value| if (std.mem.trim(u8, value, " \t\r\n").len > 0) value else declared_query else declared_query;
    const optimized_query = try optimizeWebSearchQueryForFetch(allocator, config, prompt, fetch_query_input, client, db);
    defer if (optimized_query) |value| allocator.free(value);
    const query = optimized_query orelse fetch_query_input;
    const target = web_rag.resolveSearchTargetWithTemplate(allocator, explicit_target, query, config.web_search_url) catch |err| {
        const message = switch (err) {
            error.MissingWebSearchTarget => "web_search target is missing and web_search_url/PHENOM_WEB_SEARCH_URL is not configured",
            error.InvalidWebSearchTemplate => "web_search_url/PHENOM_WEB_SEARCH_URL must include {query}",
            error.MissingWebSearchQuery => "web_search requires query when target is omitted",
            error.InvalidWebTarget => "web_search target must be an explicit HTTP/HTTPS URL",
            else => @errorName(err),
        };
        if (err == error.MissingWebSearchTarget or err == error.InvalidWebSearchTemplate) {
            return try stopWebSearchConfigurationError(allocator, config, message, events, db, aggregate_sink);
        }
        return try repairWebEvidenceIntentCall(allocator, config, prompt, client, events, db, ui_ptr, aggregate_sink, state, message);
    };
    defer allocator.free(target);
    const budget = collectWebEvidenceBudget(call.budget_bytes, state.remainingBudget());
    const strategy = contracts.StrategyName.document_summary;
    if (state.hasExecutedWebTarget(target, strategy)) {
        try db.recordEvent(config.session, "tool_duplicate", "web_search");
        const duplicate_context = try renderCollectedEvidenceContext(
            allocator,
            prompt,
            &state.context,
            null,
            null,
            context_profile.toolSchema(.code_evidence, .after_collect_evidence),
            "The requested web evidence was already collected in this turn. Answer using cited E# evidence. Do not call web_search again for the same target.",
        );
        defer allocator.free(duplicate_context);
        try db.recordEvent(config.session, "model_context", duplicate_context);
        return try streamDeferredToolLoopTurn(allocator, config, prompt, duplicate_context, client, events, db, ui_ptr, aggregate_sink, state);
    }
    if (ui_ptr) |active_ui| try active_ui.showStatus("Reading web");
    const start = try std.fmt.allocPrint(allocator, "web_search\ttarget={s} query_bytes={} budget_bytes={}", .{
        target,
        if (declared_query) |value| value.len else 0,
        budget,
    });
    defer allocator.free(start);
    try db.recordEvent(config.session, "tool_start", start);
    try events.emit(.{ .tool_start = .{ .name = "web_search", .detail = target } });

    const result = web_rag.fetch(allocator, io, target, query, budget) catch |err| {
        try db.recordEvent(config.session, "tool_error", @errorName(err));
        try db.recordTurnError(config.session, .tool_runtime, "web_search", @errorName(err));
        try events.emit(.{ .tool_result = .{ .name = "web_search", .output = @errorName(err) } });
        const follow_context = try renderCollectedEvidenceContext(
            allocator,
            prompt,
            &state.context,
            null,
            null,
            activeToolSchema(state),
            "web_search failed. If a valid explicit HTTP URL is available, emit one corrected web_search call; otherwise answer with current evidence and state the limitation.",
        );
        defer allocator.free(follow_context);
        try db.recordEvent(config.session, "model_context", follow_context);
        return try streamDeferredToolLoopTurn(allocator, config, prompt, follow_context, client, events, db, ui_ptr, aggregate_sink, state);
    };
    defer result.deinit(allocator);

    const model_evidence = try distillWebEvidenceForContext(allocator, config, prompt, target, query, result.evidence_text, client, db, &state.context);
    defer allocator.free(model_evidence);
    const model_context_id = try webEvidenceContextId(allocator, model_evidence);
    defer allocator.free(model_context_id);
    try db.recordEvent(config.session, "tool_event", result.audit_text);
    try db.recordEvent(config.session, "evidence", model_evidence);
    try events.emit(.{ .tool_result = .{ .name = "web_search", .output = model_evidence } });
    try state.rememberExecutedArgs(target, declared_query, strategy, 1, 1, model_context_id, model_evidence, model_evidence.len, result.quality_score);
    state.recordObservation();
    const working_add = try std.fmt.allocPrint(
        allocator,
        "path={s} terms_bytes={} strategy={s} compact=false model_bytes={} quality={}",
        .{ target, if (declared_query) |value| value.len else 0, @tagName(strategy), model_evidence.len, result.quality_score },
    );
    defer allocator.free(working_add);
    try db.recordEvent(config.session, "working_context_add", working_add);

    const follow_context = try renderCollectedEvidenceContext(
        allocator,
        prompt,
        &state.context,
        null,
        null,
        if (state.shouldAllowMoreEvidence()) activeToolSchema(state) else context_profile.toolSchema(.code_evidence, .after_collect_evidence),
        "Answer using cited WEB_EVIDENCE only if it directly and exactly supports the requested entity/fact. If WEB_EVIDENCE excerpt is empty, state that the search returned no direct supporting evidence. Similar names, adjacent topics, partial matches, or 'looks related' are insufficient. If WEB_EVIDENCE does not contain the named fact needed for the answer, do not answer from general knowledge; emit one refined web_search only if the query keeps the exact requested entity/fact and does not add guessed roles/categories/attributes. Do not ask permission for another search inside the active contract. Do not claim browser automation or full-page crawling.",
    );
    defer allocator.free(follow_context);
    try db.recordEvent(config.session, "model_context", follow_context);
    return try streamDeferredToolLoopTurn(allocator, config, prompt, follow_context, client, events, db, ui_ptr, aggregate_sink, state);
}

fn stopWebSearchConfigurationError(
    allocator: std.mem.Allocator,
    config: cli.Config,
    message: []const u8,
    events: *ui_events.EventBus,
    db: *audit.AuditDb,
    aggregate_sink: *StreamSink,
) !ToolLoopNext {
    try db.recordEvent(config.session, "tool_loop_stop", message);
    try db.recordTurnError(config.session, .infrastructure, "web_search_config", message);
    try events.emit(.{ .tool_result = .{ .name = "web_search", .output = message } });
    const visible = try std.fmt.allocPrint(
        allocator,
        "Nao consegui executar a pesquisa web: {s}. Configure web_search_url no config.toml ou PHENOM_WEB_SEARCH_URL com um endpoint que contenha {{query}}, ou informe uma URL HTTP/HTTPS explicita.",
        .{message},
    );
    defer allocator.free(visible);
    try aggregate_sink.emitVisibleText(visible);
    return .stopped;
}

fn webEvidenceHasModelIntent(call: *const tool_call.ToolCall) bool {
    return declaredWebQuery(call) != null;
}

fn declaredWebQuery(call: *const tool_call.ToolCall) ?[]const u8 {
    if (call.terms) |terms| {
        const trimmed = std.mem.trim(u8, terms, " \t\r\n");
        if (trimmed.len > 0) return trimmed;
    }
    if (call.intent) |intent| {
        const trimmed = std.mem.trim(u8, intent, " \t\r\n");
        if (trimmed.len > 0) return trimmed;
    }
    return null;
}

fn explicitHttpTargetFromCall(call: *const tool_call.ToolCall) ?[]const u8 {
    if (call.target) |target| if (web_rag.isHttpTarget(target)) return target;
    if (call.path) |path| if (web_rag.isHttpTarget(path)) return path;
    return null;
}

fn explicitHttpTargetFromText(text: []const u8) ?[]const u8 {
    var cursor: usize = 0;
    while (cursor < text.len) {
        const http_idx = std.mem.indexOf(u8, text[cursor..], "http://");
        const https_idx = std.mem.indexOf(u8, text[cursor..], "https://");
        const rel = if (http_idx) |h|
            if (https_idx) |s| @min(h, s) else h
        else
            https_idx orelse return null;
        const start = cursor + rel;
        var end = start;
        while (end < text.len and !std.ascii.isWhitespace(text[end])) : (end += 1) {}
        const target = std.mem.trim(u8, text[start..end], ".,;:!?()[]{}<>\"'");
        if (web_rag.isHttpTarget(target)) return target;
        cursor = end;
    }
    return null;
}

fn stripFirstHttpUrlFromText(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const target = explicitHttpTargetFromText(text) orelse return allocator.dupe(u8, text);
    const start = @intFromPtr(target.ptr) - @intFromPtr(text.ptr);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, std.mem.trim(u8, text[0..start], " \t\r\n"));
    if (out.items.len > 0) try out.append(allocator, ' ');
    const after_start = start + target.len;
    if (after_start < text.len) try out.appendSlice(allocator, std.mem.trim(u8, text[after_start..], " \t\r\n"));
    return out.toOwnedSlice(allocator);
}

fn collectWebEvidenceBudget(requested: ?usize, remaining_budget: usize) usize {
    return @min(requested orelse max_web_evidence_budget, @min(remaining_budget, max_web_evidence_budget));
}

fn collectEvidenceBudgetForCall(call: *const tool_call.ToolCall, path: ?[]const u8, remaining_budget: usize) usize {
    const base = if (call.http_search == true)
        collectWebEvidenceBudget(call.budget_bytes, remaining_budget)
    else
        call.budget_bytes orelse collectEvidenceExecutionBudget(path, remaining_budget);
    if (call.strategy_id) |strategy_id| {
        if (strategy_registry.byId(strategy_id)) |descriptor| return @min(base, descriptor.max_budget_bytes);
    }
    return base;
}

fn repairWebEvidenceIntentCall(
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
        .obligations = &.{
            reason,
            "Web retrieval is never automatic. It only runs after an accepted model tool_call.",
            "web_search requires query. target is optional when web_search_url or PHENOM_WEB_SEARCH_URL is configured.",
            "Only include target when the user supplied an explicit HTTP/HTTPS URL or current E# evidence already contains one.",
            "The query/terms must express the user's external-evidence intent. Do not invent URLs.",
        },
        .grounding = groundingRules(),
        .next_action = "Emit one corrected web_search with model-selected query/terms only if the error is fixable without inventing a URL; otherwise answer from current evidence and state the observed web_search limitation.",
    });
    defer allocator.free(repair_context);
    try db.recordEvent(config.session, "model_context", repair_context);
    return try streamDeferredToolLoopTurn(allocator, config, prompt, repair_context, client, events, db, ui_ptr, aggregate_sink, state);
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
        try db.recordTurnError(config.session, .tool_runtime, "promote_context", @errorName(err));
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
        return try streamDeferredToolLoopTurn(allocator, config, prompt, repair_context, client, events, db, ui_ptr, aggregate_sink, state);
    };
    defer allocator.free(result);

    try db.recordEvent(config.session, "persistent_promotion", result);
    try events.emit(.{ .tool_result = .{ .name = "promote_context", .output = result } });
    state.recordMemoryPromotion();
    const follow_context = try model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .grounding = groundingRules(),
        .next_action = "Answer that the explicit persistent context promotion was recorded. Do not claim raw tool output was stored.",
    });
    defer allocator.free(follow_context);
    try db.recordEvent(config.session, "model_context", follow_context);
    return try streamDeferredToolLoopTurn(allocator, config, prompt, follow_context, client, events, db, ui_ptr, aggregate_sink, state);
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
    return try streamDeferredToolLoopTurn(allocator, config, prompt, repair_context, client, events, db, ui_ptr, aggregate_sink, state);
}

fn runSearchPersistentContextStep(
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

    const terms = call.terms orelse call.intent orelse call.need orelse return try repairSearchPersistentContextCall(allocator, config, prompt, client, events, db, ui_ptr, aggregate_sink, state, "search_persistent_context requires terms or intent.");
    const target = parsePersistentSearchTarget(call.target) orelse return try repairSearchPersistentContextCall(allocator, config, prompt, client, events, db, ui_ptr, aggregate_sink, state, "search_persistent_context target must be memory, skills, or both.");
    const budget_bytes = @min(call.budget_bytes orelse @as(usize, 2048), @as(usize, 8192));
    const max_entries: usize = 6;

    try db.recordEvent(config.session, "tool_start", "search_persistent_context");
    try events.emit(.{ .tool_start = .{ .name = "search_persistent_context", .detail = @tagName(target) } });
    var result = persistent_context.searchFromCwd(allocator, io, target, terms, max_entries) catch |err| {
        try db.recordEvent(config.session, "tool_error", @errorName(err));
        try db.recordTurnError(config.session, .tool_runtime, "search_persistent_context", @errorName(err));
        try events.emit(.{ .tool_result = .{ .name = "search_persistent_context", .output = @errorName(err) } });
        return try repairSearchPersistentContextCall(allocator, config, prompt, client, events, db, ui_ptr, aggregate_sink, state, "Persistent context search failed. Emit corrected terms or answer without persistent context.");
    };
    defer result.deinit();

    const rendered = try renderPersistentSearchResult(allocator, result.memory.items, result.skills.items, budget_bytes);
    defer allocator.free(rendered);
    try db.recordEvent(config.session, "persistent_context", rendered);
    try events.emit(.{ .tool_result = .{ .name = "search_persistent_context", .output = rendered } });
    state.recordObservation();
    state.recordPersistentContextSearch();
    try state.rememberRetrievedSkills(result.skills.items);

    const follow_context = try model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .contracts = activeToolSchema(state),
        .memory = result.memory.items,
        .skills = result.skills.items,
        .grounding = groundingRules(),
        .next_action = "Apply relevant retrieved SKILLS as response rules. If the user asks for a local rule/preference/protocol, answer only the directly retrieved MEMORY/SKILLS entry; do not add adjacent advice, generic best practices, or inferred extras. If no entry directly supports the request, say persistent context did not contain it. Do not promote anything unless the user explicitly confirmed a new durable fact/rule.",
    });
    defer allocator.free(follow_context);
    try db.recordEvent(config.session, "model_context", follow_context);
    return try streamDeferredToolLoopTurn(allocator, config, prompt, follow_context, client, events, db, ui_ptr, aggregate_sink, state);
}

fn parsePersistentSearchTarget(value: ?[]const u8) ?persistent_context.SearchTarget {
    const raw = value orelse return .both;
    if (std.ascii.eqlIgnoreCase(raw, "memory")) return .memory;
    if (std.ascii.eqlIgnoreCase(raw, "skills")) return .skills;
    if (std.ascii.eqlIgnoreCase(raw, "both")) return .both;
    return null;
}

fn renderPersistentSearchResult(allocator: std.mem.Allocator, memory: []const []const u8, skills: []const []const u8, budget_bytes: usize) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "[PERSISTENT_CONTEXT]\nsource=MEMORY/SKILLS raw_context_persisted=false\n");
    if (skills.len > 0) {
        try out.appendSlice(allocator, "\n[SKILLS]\n");
        try appendListWithinBudget(&out, allocator, skills, budget_bytes);
    }
    if (memory.len > 0) {
        try out.appendSlice(allocator, "\n[MEMORY]\n");
        try appendListWithinBudget(&out, allocator, memory, budget_bytes);
    }
    if (skills.len == 0 and memory.len == 0) try out.appendSlice(allocator, "status=no_matches\n");
    return out.toOwnedSlice(allocator);
}

fn appendListWithinBudget(out: *std.ArrayList(u8), allocator: std.mem.Allocator, entries: []const []const u8, budget_bytes: usize) !void {
    for (entries) |entry| {
        if (out.items.len >= budget_bytes) {
            try out.appendSlice(allocator, "- [TRUNCATED]\n");
            return;
        }
        const before = out.items.len;
        try out.appendSlice(allocator, "- ");
        const remaining = budget_bytes -| out.items.len;
        if (entry.len <= remaining) {
            try out.appendSlice(allocator, entry);
        } else {
            try out.appendSlice(allocator, entry[0..remaining]);
            try out.appendSlice(allocator, " [TRUNCATED]");
        }
        try out.append(allocator, '\n');
        if (out.items.len == before) return;
    }
}

fn repairSearchPersistentContextCall(
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
        .next_action = "Emit search_persistent_context(target=memory|skills|both,terms) with concrete model-selected terms, or answer without persistent context.",
    });
    defer allocator.free(repair_context);
    try db.recordEvent(config.session, "model_context", repair_context);
    return try streamDeferredToolLoopTurn(allocator, config, prompt, repair_context, client, events, db, ui_ptr, aggregate_sink, state);
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
        return try streamDeferredToolLoopTurn(allocator, config, prompt, repair_context, client, events, db, ui_ptr, aggregate_sink, state);
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
        return try streamDeferredToolLoopTurn(allocator, config, prompt, repair_context, client, events, db, ui_ptr, aggregate_sink, state);
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
            "The requested session search was already performed in this turn. First judge whether existing S# directly supports the requested claim. Answer only from supporting E#/S# evidence, or state what remains unknown.",
        );
        defer allocator.free(duplicate_context);
        try db.recordEvent(config.session, "model_context", duplicate_context);
        return try streamDeferredToolLoopTurn(allocator, config, prompt, duplicate_context, client, events, db, ui_ptr, aggregate_sink, state);
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
    state.recordObservation();

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
        "First judge SESSION_CONTEXT against the current task. Use S# only when it directly supports the requested prior-session fact; if S# is a failed recall, irrelevant, contradictory, or too vague, do not answer from it. Refine once with search_session using concrete keys from SESSION_FOCUS/current reasoning while budget remains, otherwise state what is not evidenced. Cite S# for session claims and E# for workspace claims.",
    );
    defer allocator.free(follow_context);
    try db.recordEvent(config.session, "model_context", follow_context);
    return try streamDeferredToolLoopTurn(allocator, config, prompt, follow_context, client, events, db, ui_ptr, aggregate_sink, state);
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
    source: contracts.SourceName,
    strategy_id: ?[]const u8,
    path: ?[]const u8,
    intent: ?[]const u8,
    terms: ?[]const u8,
    strategy: contracts.StrategyName,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "collect_evidence\tsource={s} strategy_id={s} path={s} strategy={s} intent_bytes={} terms_bytes={}", .{
        @tagName(source),
        strategy_id orelse "",
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
    client: *http.LocalModelClient,
    input: http.InferenceInput,
) !ModelContextUsage {
    try model_context.assertNoRawContextLeak(rendered);
    var buckets = model_context.measureRenderedContextBytes(rendered);
    buckets.system = (input.system_prompt orelse system_prompt.default_system_prompt).len;
    const used_tokens = client.countInputTokens(input);
    const limit_tokens = client.context_window;
    if (used_tokens) |used| {
        if (limit_tokens) |limit| {
            if (used > limit) return error.ModelContextBudgetExceeded;
        }
    } else if (limit_tokens == null and buckets.total_context > max_model_context_send_bytes) {
        return error.ModelContextBudgetExceeded;
    }
    const used_text = try optionalUsizeText(allocator, used_tokens);
    defer allocator.free(used_text);
    const limit_text = try optionalUsizeText(allocator, limit_tokens);
    defer allocator.free(limit_text);
    const percent_text = try optionalPercentText(allocator, used_tokens, limit_tokens);
    defer allocator.free(percent_text);
    const budget_source: []const u8 = if (used_tokens != null and limit_tokens != null)
        "backend_tokenizer"
    else if (limit_tokens != null)
        "backend_limit"
    else
        "unavailable";
    const body = try std.fmt.allocPrint(
        allocator,
        "pre_send=true tokenizer={s} token_estimate=false context_source={s} context_used_tokens={s} context_limit_tokens={s} context_used_percent={s} system_bytes={} header_bytes={} temporal_bytes={} contracts_bytes={} skills_bytes={} memory_bytes={} candidates_bytes={} evidence_bytes={} focus_bytes={} dialogue_bytes={} session_bytes={} obligations_bytes={} grounding_bytes={} next_action_bytes={} total_context_bytes={} fallback_context_limit_bytes={}",
        .{
            if (client.tokenizer_available) "backend" else "unavailable",
            budget_source,
            used_text,
            limit_text,
            percent_text,
            buckets.system,
            buckets.header,
            buckets.temporal,
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
    return .{
        .used_tokens = used_tokens,
        .limit_tokens = limit_tokens,
    };
}

const ModelContextUsage = struct {
    used_tokens: ?usize,
    limit_tokens: ?usize,
};

fn optionalPercentText(allocator: std.mem.Allocator, used_tokens: ?usize, limit_tokens: ?usize) ![]const u8 {
    const used = used_tokens orelse return allocator.dupe(u8, "unknown");
    const limit = limit_tokens orelse return allocator.dupe(u8, "unknown");
    if (limit == 0) return allocator.dupe(u8, "unknown");
    const pct = (@as(f64, @floatFromInt(used)) * 100.0) / @as(f64, @floatFromInt(limit));
    return std.fmt.allocPrint(allocator, "{d:.1}", .{pct});
}

fn showModelContextUsage(usage: ModelContextUsage, events: *ui_events.EventBus, ui_ptr: ?*tui.TerminalUi(fd_writer.FdWriter)) !void {
    const used = usage.used_tokens orelse return;
    const limit = usage.limit_tokens orelse return;
    try events.emit(.{ .context_update = .{ .used_tokens = used, .limit_tokens = limit } });
    if (ui_ptr) |active_ui| try active_ui.showContextUsage(used, limit);
}

fn streamInferenceWithUiCancel(
    client: *http.LocalModelClient,
    input: http.InferenceInput,
    ui_ptr: ?*tui.TerminalUi(fd_writer.FdWriter),
    sink: anytype,
) !void {
    var cancel = std.atomic.Value(bool).init(false);
    var cancelable_input = input;
    cancelable_input.cancel = &cancel;
    if (ui_ptr) |active_ui| {
        try active_ui.startInferenceCancelInput(&cancel);
        cancelable_input.cancel_fd = active_ui.inferenceCancelFd();
        defer active_ui.stopInferenceCancelInput();
    }
    return client.streamInference(cancelable_input, sink);
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
    state: *ToolLoopState,
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
        state.active_contract,
        state,
        required_work_missing_answer,
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
        null,
        required_tool_missing_answer,
    );
}

fn streamSearchPlanTurn(
    allocator: std.mem.Allocator,
    config: cli.Config,
    prompt: []const u8,
    client: *http.LocalModelClient,
    events: *ui_events.EventBus,
    db: *audit.AuditDb,
    ui_ptr: ?*tui.TerminalUi(fd_writer.FdWriter),
    aggregate_sink: *StreamSink,
    active_contract: contracts.ActiveContract,
) !ToolLoopNext {
    _ = aggregate_sink;
    const plan_context = try renderSearchPlanContext(allocator, prompt);
    defer allocator.free(plan_context);
    try db.recordEvent(config.session, "model_context", plan_context);

    var plan_sink = StreamSink{
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
    defer plan_sink.deinit();

    const plan_input = http.InferenceInput{ .user_prompt = prompt, .system_prompt = config.system_prompt, .model_context = plan_context, .max_tokens = config.max_tokens };
    const context_usage = recordModelContextBudget(allocator, db, config.session, plan_context, client, plan_input) catch |err| {
        try db.recordEvent(config.session, "model_error", @errorName(err));
        return .stopped;
    };
    try showModelContextUsage(context_usage, events, ui_ptr);
    streamInferenceWithUiCancel(client, plan_input, ui_ptr, &plan_sink) catch |err| {
        const detail = try client.httpFailureDetail(allocator);
        defer if (detail) |value| allocator.free(value);
        const kind = http.classifyStreamFailure(err, client.last_http_status);
        try db.recordEvent(config.session, "model_error", @errorName(err));
        try recordModelStreamFailure(db, config.session, "search_plan_stream", @errorName(err), kind, detail);
        return err;
    };
    try plan_sink.flush();

    if (try tool_envelope.parseFirst(allocator, plan_sink.raw_model.items, active_contract)) |envelope| {
        var owned = envelope;
        defer owned.deinit(allocator);
        const envelope_audit = try owned.renderAudit(allocator);
        defer allocator.free(envelope_audit);
        try db.recordEvent(config.session, "tool_envelope", envelope_audit);
        if (owned.state == .accepted) {
            if (owned.takeCall()) |call| return .{ .tool_call = call };
        }
    }

    const terms = try parseSearchPlanTerms(allocator, plan_sink.raw_visible.items);
    errdefer if (terms) |value| allocator.free(value);
    if (terms) |value| {
        try db.recordEvent(config.session, "search_plan", value);
        return .{ .tool_call = .{
            .name = try allocator.dupe(u8, "collect_evidence"),
            .intent = try allocator.dupe(u8, "model search plan"),
            .terms = value,
            .stage = try allocator.dupe(u8, "candidates"),
            .strategy = .symbol,
        } };
    }
    try db.recordEvent(config.session, "search_plan", "empty");
    return .stopped;
}

fn renderSearchPlanContext(allocator: std.mem.Allocator, prompt: []const u8) ![]u8 {
    return model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .contracts =
        \\[SEARCH_PLAN v1]
        \\Output either:
        \\1. a collect_evidence XML tool_call with stage=overview for project/workspace map; or stage=candidates, intent, terms, strategy for focused lookup; or
        \\2. one visible line: SEARCH_TERMS: <identifier/API/file/symbol words>
        ,
        .obligations = &.{
            "This is not the final answer.",
            "For broad project/workspace map, use collect_evidence stage=overview instead of inventing search terms.",
            "Translate focused source-code requests into concrete code retrieval terms.",
            "Include identifier-like variants of the core concept, such as likely noun/verb forms, type names, API nouns, and file stems.",
            "Do not say evidence is unavailable in this planning step.",
        },
        .grounding = groundingRules(),
        .next_action = "Return only a search plan. Prefer identifiers, API names, field names, file stems, and English code terms that may exist in source.",
    });
}

fn repairThinkOnlyFinalAnswer(
    allocator: std.mem.Allocator,
    config: cli.Config,
    prompt: []const u8,
    client: *http.LocalModelClient,
    events: *ui_events.EventBus,
    db: *audit.AuditDb,
    ui_ptr: ?*tui.TerminalUi(fd_writer.FdWriter),
    aggregate_sink: *StreamSink,
) !bool {
    try db.recordEvent(config.session, "answer_repair", "think-only generation produced no visible final answer");
    try events.emit(.{ .progress_update = "model produced thinking only; requesting visible final answer" });

    const hidden_draft = try compactOperationalText(allocator, aggregate_sink.raw_model.items, 4096);
    defer allocator.free(hidden_draft);
    const session_blocks = [_]model_context.SessionBlock{.{ .text = hidden_draft }};
    const repair_context = try model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .mode = "finalization_repair",
        .contracts =
        \\[TOOLS v1]
        \\No tool schema is active for this repair.
        ,
        .session = &session_blocks,
        .obligations = &.{
            "Previous generation ended inside hidden thinking and no visible final answer reached the user.",
            "SESSION_CONTEXT here is an internal draft, not evidence to cite.",
            "Do not emit <think>, </think>, tool calls, or protocol tags.",
            "Answer visibly and directly in the user's language.",
        },
        .grounding = groundingRules(),
        .next_action_v1 = .{
            .kind = .answer_directly,
            .text = "Produce the final visible answer now. No thinking block.",
        },
    });
    defer allocator.free(repair_context);
    try db.recordEvent(config.session, "model_context", repair_context);

    var repair_sink = StreamSink{
        .allocator = allocator,
        .events = events,
        .db = db,
        .session = config.session,
        .ui = ui_ptr,
        .filter = reasoning_filter.ReasoningFilter.init(allocator, false),
        .visible = std.ArrayList(u8).empty,
        .visible_bytes = 0,
        .thinking_bytes = 0,
        .defer_visible = true,
        .trim_visible_leading_whitespace = false,
    };
    defer repair_sink.deinit();

    const previous_thinking = client.thinking;
    client.thinking = .off;
    defer client.thinking = previous_thinking;

    const repair_input = http.InferenceInput{
        .user_prompt = prompt,
        .system_prompt = config.system_prompt,
        .model_context = repair_context,
        .max_tokens = config.max_tokens,
    };
    const context_usage = recordModelContextBudget(allocator, db, config.session, repair_context, client, repair_input) catch |err| {
        try db.recordEvent(config.session, "answer_repair_failed", @errorName(err));
        try db.recordTurnError(config.session, .model_protocol, "think_only_finalization", @errorName(err));
        return false;
    };
    try showModelContextUsage(context_usage, events, ui_ptr);
    streamInferenceWithUiCancel(client, repair_input, ui_ptr, &repair_sink) catch |err| {
        const detail = try client.httpFailureDetail(allocator);
        defer if (detail) |value| allocator.free(value);
        const kind = http.classifyStreamFailure(err, client.last_http_status);
        try db.recordEvent(config.session, "answer_repair_failed", @errorName(err));
        try recordModelStreamFailure(db, config.session, "think_only_finalization", @errorName(err), kind, detail);
        return err;
    };
    try repair_sink.flush();

    aggregate_sink.mergeGenerationStop(repair_sink);
    if (repair_sink.raw_visible.items.len == 0) {
        try db.recordEvent(config.session, "answer_repair_failed", "think-only finalization produced no visible answer");
        try db.recordTurnError(config.session, .model_protocol, "think_only_finalization", "repair produced no visible answer");
        return false;
    }
    try aggregate_sink.writeVisible(repair_sink.raw_visible.items);
    repair_sink.raw_visible.clearRetainingCapacity();
    try db.recordEvent(config.session, "answer_repair_done", "think-only finalization emitted visible answer");
    return true;
}

fn parseSearchPlanTerms(allocator: std.mem.Allocator, visible: []const u8) !?[]u8 {
    const marker = "SEARCH_TERMS:";
    const start = if (std.mem.indexOf(u8, visible, marker)) |idx| idx + marker.len else 0;
    const selected = std.mem.trim(u8, visible[start..], " \t\r\n`");
    if (selected.len == 0) return null;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var it = std.mem.tokenizeAny(u8, selected, " \t\r\n,;|[]{}()<>`'\"");
    while (it.next()) |token| {
        if (std.mem.indexOfScalar(u8, token, ':') != null and !std.mem.eql(u8, token, marker)) continue;
        if (out.items.len > 0) try out.append(allocator, ' ');
        const remaining = 512 -| out.items.len;
        if (remaining == 0) break;
        try out.appendSlice(allocator, token[0..@min(token.len, remaining)]);
    }
    if (out.items.len == 0) return null;
    return try out.toOwnedSlice(allocator);
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
    finalization_state: ?*ToolLoopState,
    required_tool_missing_visible: []const u8,
) !ToolLoopNext {
    if (ui_ptr) |active_ui| {
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
    const follow_input = http.InferenceInput{ .user_prompt = prompt, .system_prompt = config.system_prompt, .model_context = follow_context, .max_tokens = config.max_tokens };
    const context_usage = recordModelContextBudget(allocator, db, config.session, follow_context, client, follow_input) catch |err| {
        const message = if (err == error.ModelContextBudgetExceeded)
            "context limit exceeded before model call"
        else
            @errorName(err);
        if (ui_ptr) |active_ui| try active_ui.showStatus(message);
        try events.emit(.{ .progress_update = message });
        try db.recordEvent(config.session, "model_error", @errorName(err));
        return .stopped;
    };
    try showModelContextUsage(context_usage, events, ui_ptr);
    streamInferenceWithUiCancel(client, follow_input, ui_ptr, &follow_sink) catch |err| {
        const detail = try client.httpFailureDetail(allocator);
        defer if (detail) |value| allocator.free(value);
        const kind = http.classifyStreamFailure(err, client.last_http_status);
        try db.recordEvent(config.session, "model_error", @errorName(err));
        try recordModelStreamFailure(db, config.session, "tool_loop_stream", @errorName(err), kind, detail);
        return err;
    };
    try follow_sink.flush();

    var envelope = (tool_envelope.parseFirst(allocator, follow_sink.raw_visible.items, active_contract) catch |err| {
        try db.recordEvent(config.session, "tool_envelope_error", @errorName(err));
        try db.recordTurnError(config.session, .model_protocol, "tool_envelope", @errorName(err));
        return .stopped;
    }) orelse {
        if (required_tool_repair) |repair_message| {
            if (follow_sink.raw_visible.items.len > 0) {
                if (try visibleCandidateSelectionToToolCall(allocator, follow_sink.raw_visible.items, follow_context)) |call| {
                    follow_sink.discardDeferredVisible();
                    try db.recordEvent(config.session, "tool_repair", "visible candidate selection converted to expand call");
                    return .{ .tool_call = call };
                }
            }
            if (repair_message.len == 0) {
                try db.recordEvent(config.session, "tool_loop_stop", "required follow-up tool call missing after repair");
                try db.recordTurnError(config.session, .model_protocol, "required_tool_repair", "missing follow-up tool_call after repair");
                try aggregate_sink.emitVisibleText(required_tool_missing_visible);
                return .stopped;
            }
            follow_sink.discardDeferredVisible();
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
                finalization_state,
                required_tool_missing_visible,
            );
        }
        if (outputContradictsRuntimeInspection(follow_sink.raw_visible.items, follow_context)) {
            follow_sink.discardDeferredVisible();
            try db.recordEvent(config.session, "answer_repair", "runtime inspection contradiction");
            const repair_context = try std.fmt.allocPrint(
                allocator,
                "{s}\n[ANSWER_REPAIR]\nPrevious visible answer contradicted [RUNTIME_INSPECTION]. requiresBrowserDiagnostics=true was selected and satisfied by bounded HTTP GET. HTTP runtime inspection was executed. Only DOM/browser automation was not executed. Answer again from the runtime evidence.\n",
                .{follow_context},
            );
            defer allocator.free(repair_context);
            try db.recordEvent(config.session, "model_context", repair_context);
            return streamDeferredToolLoopTurnInternal(
                allocator,
                config,
                prompt,
                repair_context,
                null,
                client,
                events,
                db,
                ui_ptr,
                aggregate_sink,
                active_contract,
                finalization_state,
                required_tool_missing_visible,
            );
        }
        if (follow_sink.raw_visible.items.len > 0) {
            if (shouldRepairPersistentContextClaim(follow_sink.raw_visible.items, follow_context, finalization_state)) {
                follow_sink.discardDeferredVisible();
                try db.recordEvent(config.session, "answer_repair", "persistent context claim without retrieval");
                const repair_context = try renderPersistentContextClaimRepairContext(allocator, prompt, active_contract);
                defer allocator.free(repair_context);
                try db.recordEvent(config.session, "model_context", repair_context);
                const repair_message = if (active_contract.name == .memory)
                    "Output exactly one search_persistent_context tool_call with target=both and concrete terms from USER_TASK. No prose."
                else
                    "Output exactly one set_operational_contract tool_call with contract=memory and concrete terms from USER_TASK. No prose.";
                return streamDeferredToolLoopTurnInternal(
                    allocator,
                    config,
                    prompt,
                    repair_context,
                    repair_message,
                    client,
                    events,
                    db,
                    ui_ptr,
                    aggregate_sink,
                    active_contract,
                    finalization_state,
                    required_tool_missing_visible,
                );
            }
            if (outputContradictsRetrievedSkills(follow_sink.raw_visible.items, finalization_state)) {
                follow_sink.discardDeferredVisible();
                if (finalization_state) |state| {
                    if (state.retrieved_skill_answer_repairs >= max_tool_repairs) {
                        try db.recordEvent(config.session, "answer_repair_blocked", "retrieved skills contradiction");
                        try db.recordTurnError(config.session, .model_protocol, "persistent_context", "retrieved skills contradicted after repair");
                        try aggregate_sink.emitVisibleText("[MODEL_PROTOCOL_ERROR] final answer contradicted retrieved SKILLS.");
                        return .stopped;
                    }
                    state.retrieved_skill_answer_repairs += 1;
                    try db.recordEvent(config.session, "answer_repair", "retrieved skills contradiction");
                    const repair_context = try renderRetrievedSkillsAnswerRepairContext(allocator, prompt, state);
                    defer allocator.free(repair_context);
                    try db.recordEvent(config.session, "model_context", repair_context);
                    return streamDeferredToolLoopTurnInternal(
                        allocator,
                        config,
                        prompt,
                        repair_context,
                        null,
                        client,
                        events,
                        db,
                        ui_ptr,
                        aggregate_sink,
                        state.active_contract,
                        state,
                        required_tool_missing_visible,
                    );
                }
            }
            if (firstMissingRetrievedSkillMarker(follow_context, follow_sink.raw_visible.items)) |marker| {
                try db.recordEvent(config.session, "answer_repair", "retrieved skill marker inserted");
                aggregate_sink.mergeGenerationStop(follow_sink);
                const repaired_visible = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ marker, follow_sink.raw_visible.items });
                defer allocator.free(repaired_visible);
                try aggregate_sink.emitVisibleText(repaired_visible);
                follow_sink.raw_visible.clearRetainingCapacity();
                return .final_answer;
            }
            if (active_contract.name == .search_web and webEvidenceHasOnlyEmptyExcerpts(follow_context)) {
                follow_sink.discardDeferredVisible();
                try db.recordEvent(config.session, "answer_repair", "empty web evidence final answer blocked");
                try aggregate_sink.emitVisibleText("[WEB_EVIDENCE_EMPTY] web_search returned no direct supporting excerpt; no current factual answer is evidenced by collected WEB_EVIDENCE.");
                return .final_answer;
            }
            if (active_contract.name == .search_web) {
                if (unsupportedWebAnswerLiteral(follow_sink.raw_visible.items, follow_context)) |literal| {
                    follow_sink.discardDeferredVisible();
                    if (finalization_state) |state| {
                        if (state.finalization_repairs < max_tool_repairs) {
                            state.finalization_repairs += 1;
                            const repair_context = try std.fmt.allocPrint(
                                allocator,
                                "{s}\n[ANSWER_REPAIR]\nThe previous visible answer introduced `{s}`, but that literal is not present in WEB_EVIDENCE. Under search_web, numeric, date, and version facts must be copied from collected evidence. Emit one refined web_search with the exact user fact intent if more evidence is needed; otherwise state that collected WEB_EVIDENCE does not directly support the answer. No unsupported factual literals.\n",
                                .{ follow_context, literal },
                            );
                            defer allocator.free(repair_context);
                            try db.recordEvent(config.session, "answer_repair", "unsupported web literal");
                            try db.recordEvent(config.session, "model_context", repair_context);
                            return streamDeferredToolLoopTurnInternal(
                                allocator,
                                config,
                                prompt,
                                repair_context,
                                null,
                                client,
                                events,
                                db,
                                ui_ptr,
                                aggregate_sink,
                                active_contract,
                                finalization_state,
                                required_tool_missing_visible,
                            );
                        }
                    }
                    const visible = try std.fmt.allocPrint(
                        allocator,
                        "[WEB_EVIDENCE_UNSUPPORTED] final answer contained `{s}`, but collected WEB_EVIDENCE does not contain that literal.",
                        .{literal},
                    );
                    defer allocator.free(visible);
                    try db.recordEvent(config.session, "answer_repair", "unsupported web literal final answer blocked");
                    try aggregate_sink.emitVisibleText(visible);
                    return .final_answer;
                }
            }
            if (finalization_state) |state| {
                if (state.finalizationBlocker()) |blocker| {
                    follow_sink.discardDeferredVisible();
                    if (state.finalization_repairs >= max_tool_repairs) {
                        try db.recordEvent(config.session, "finalization_blocked", blocker);
                        try db.recordTurnError(config.session, .insufficient_evidence, "finalization", blocker);
                        try aggregate_sink.emitVisibleText(required_work_missing_answer);
                        return .stopped;
                    }
                    state.finalization_repairs += 1;
                    try db.recordEvent(config.session, "finalization_repair", blocker);
                    const repair_context = try renderFinalizationRepairContext(allocator, prompt, state, blocker);
                    defer allocator.free(repair_context);
                    try db.recordEvent(config.session, "model_context", repair_context);
                    return streamDeferredToolLoopTurnInternal(
                        allocator,
                        config,
                        prompt,
                        repair_context,
                        "The visible final answer is blocked by unmet operational state. Output exactly one allowed tool_call that satisfies the blocker. No prose.",
                        client,
                        events,
                        db,
                        ui_ptr,
                        aggregate_sink,
                        state.active_contract,
                        state,
                        required_work_missing_answer,
                    );
                }
            }
            aggregate_sink.mergeGenerationStop(follow_sink);
            try aggregate_sink.emitVisibleText(follow_sink.raw_visible.items);
            follow_sink.raw_visible.clearRetainingCapacity();
        }
        return .final_answer;
    };
    defer envelope.deinit(allocator);
    const envelope_audit = try envelope.renderAudit(allocator);
    defer allocator.free(envelope_audit);
    try db.recordEvent(config.session, "tool_envelope", envelope_audit);

    if (envelope.state == .rejected) {
        if (envelope.rejection_reason == .parse_error) {
            try db.recordEvent(config.session, "tool_parse_error", envelope.auditText());
            follow_sink.discardDeferredVisible();
            if (protocolRepairMarkerCount(follow_context) >= max_required_tool_protocol_repairs) {
                try db.recordTurnError(config.session, .model_protocol, "tool_envelope", "malformed tool_call after repair");
                if (required_tool_repair != null) {
                    try aggregate_sink.emitVisibleText(required_tool_missing_visible);
                } else {
                    try emitMalformedToolCallAnswer(allocator, aggregate_sink);
                }
                return .stopped;
            }
            const base_repair = try renderMalformedToolCallRepairContext(allocator, prompt, active_contract);
            defer allocator.free(base_repair);
            const repair_context = if (required_tool_repair) |repair_message|
                try std.fmt.allocPrint(
                    allocator,
                    "{s}\n[PROTOCOL_REPAIR]\n{s}\n{s}\n",
                    .{ follow_context, base_repair, repair_message },
                )
            else
                try std.fmt.allocPrint(
                    allocator,
                    "{s}\n[PROTOCOL_REPAIR]\n{s}\n",
                    .{ follow_context, base_repair },
                );
            defer allocator.free(repair_context);
            try db.recordEvent(config.session, "model_context", repair_context);
            return streamDeferredToolLoopTurnInternal(
                allocator,
                config,
                prompt,
                repair_context,
                required_tool_repair,
                client,
                events,
                db,
                ui_ptr,
                aggregate_sink,
                active_contract,
                finalization_state,
                required_tool_missing_visible,
            );
        }
        const body = try std.fmt.allocPrint(allocator, "{s}\t{s}", .{ envelope.raw_name, envelope.auditText() });
        defer allocator.free(body);
        try db.recordEvent(config.session, "tool_rejected", body);
        try db.recordTurnError(config.session, .tool_contract, "tool_envelope", body);
        if (required_tool_repair) |repair_message| {
            if (repair_message.len > 0 and
                envelope.rejection_reason == .tool_not_advertised and
                protocolRepairMarkerCount(follow_context) < max_required_tool_protocol_repairs)
            {
                const repair_context = try std.fmt.allocPrint(
                    allocator,
                    "{s}\n[PROTOCOL_REPAIR]\nThe previous tool `{s}` is not active in this repair. {s}\n",
                    .{ follow_context, envelope.raw_name, repair_message },
                );
                defer allocator.free(repair_context);
                try db.recordEvent(config.session, "model_context", repair_context);
                return streamDeferredToolLoopTurnInternal(
                    allocator,
                    config,
                    prompt,
                    repair_context,
                    repair_message,
                    client,
                    events,
                    db,
                    ui_ptr,
                    aggregate_sink,
                    active_contract,
                    finalization_state,
                    required_tool_missing_visible,
                );
            }
        }
        try emitRejectedToolAnswer(allocator, aggregate_sink, envelope.raw_name, envelope.auditText());
        return .stopped;
    }
    if (envelope.takeCall()) |call| return .{ .tool_call = call };
    try db.recordEvent(config.session, "tool_rejected", "accepted envelope without call");
    try db.recordTurnError(config.session, .model_protocol, "tool_envelope", "accepted envelope without call");
    return .stopped;
}

fn protocolRepairMarkerCount(text: []const u8) usize {
    const marker = "[PROTOCOL_REPAIR]";
    var count: usize = 0;
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, text, index, marker)) |found| {
        count += 1;
        index = found + marker.len;
    }
    return count;
}

fn renderFinalizationRepairContext(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    state: *const ToolLoopState,
    blocker: []const u8,
) ![]u8 {
    const operational_state = try std.fmt.allocPrint(
        allocator,
        "contract={s} observations={} mutations={} runtime_validations={} browser_diagnostics={} memory_promotions={} blocker={s}",
        .{
            @tagName(state.active_contract.name),
            state.observations,
            state.mutations,
            state.runtime_validations,
            state.browser_diagnostics,
            state.memory_promotions,
            blocker,
        },
    );
    defer allocator.free(operational_state);
    return model_context.renderModelTurnContext(allocator, .{
        .task = prompt,
        .contracts = activeToolSchema(state),
        .obligations = &.{
            operational_state,
            "The previous visible answer was not accepted because the selected operational contract is not satisfied.",
            "Choose the smallest allowed tool call that satisfies the blocker. Do not answer in prose before that tool result.",
        },
        .grounding = groundingRules(),
        .next_action = "Emit exactly one allowed tool_call now. No prose.",
    });
}

fn visibleCandidateSelectionToToolCall(allocator: std.mem.Allocator, visible: []const u8, follow_context: []const u8) !?tool_call.ToolCall {
    if (std.mem.indexOf(u8, follow_context, "[CANDIDATES_CONTEXT]") == null) return null;
    const selected = (try parseVisibleCandidateSelection(allocator, visible)) orelse return null;
    errdefer allocator.free(selected);
    return .{
        .name = try allocator.dupe(u8, "collect_evidence"),
        .stage = try allocator.dupe(u8, "expand"),
        .selected_candidate = selected,
        .max_lines = 32,
    };
}

fn parseVisibleCandidateSelection(allocator: std.mem.Allocator, visible: []const u8) !?[]u8 {
    const marker = "SELECTED_CANDIDATE:";
    const selected = if (std.mem.indexOf(u8, visible, marker)) |idx| visible[idx + marker.len ..] else visible;
    var it = std.mem.tokenizeAny(u8, selected, " \t\r\n`'\".,;:()[]{}<>/\\|");
    while (it.next()) |token| {
        if (!isCandidateId(token)) continue;
        return try allocator.dupe(u8, token);
    }
    return null;
}

fn isCandidateId(text: []const u8) bool {
    if (text.len < 2 or text.len > 8) return false;
    if (text[0] != 'C' and text[0] != 'c') return false;
    for (text[1..]) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

fn currentActiveContract() contracts.ActiveContract {
    return contracts.activeContract(.workflow).?;
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
    duplicate_repairs: usize = 0,
    contract_selected: bool = false,
    duplicate_contract_repairs: usize = 0,
    finalization_repairs: usize = 0,
    retrieved_skill_answer_repairs: usize = 0,
    forced_exploratory_refinements: usize = 0,

    fn init(allocator: std.mem.Allocator) ToolLoopState {
        return .{
            .context = working_context.WorkingContext.init(allocator),
            .session_searches = std.ArrayList([]u8).empty,
            .retrieved_skills = std.ArrayList([]u8).empty,
            .candidates = std.ArrayList(collect_evidence.CandidateItem).empty,
            .active_contract = currentActiveContract(),
        };
    }

    fn deinit(self: *ToolLoopState) void {
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

    fn hasExecutedWebTarget(self: ToolLoopState, target: []const u8, strategy: contracts.StrategyName) bool {
        for (self.context.entries.items) |entry| {
            if (entry.strategy == strategy and entry.start_line == 1 and entry.max_lines == 1 and std.mem.eql(u8, entry.path, target)) return true;
        }
        return false;
    }

    fn rememberExecutedArgs(self: *ToolLoopState, path: ?[]const u8, terms: ?[]const u8, strategy: contracts.StrategyName, start_line: usize, max_lines: usize, context_id: ?[]const u8, evidence_text: []const u8, model_bytes: usize, quality_score: i32) !void {
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

    fn selectContract(self: *ToolLoopState, selected: contracts.ActiveContract, request: contracts.OperationalContractRequest) void {
        self.active_contract = selected;
        self.contract_selected = true;
        self.requirements = request;
        self.finalization_repairs = 0;
        self.retrieved_skill_answer_repairs = 0;
        self.duplicate_contract_repairs = 0;
    }

    fn recordObservation(self: *ToolLoopState) void {
        self.observations += 1;
        self.finalization_repairs = 0;
    }

    fn recordMutation(self: *ToolLoopState) void {
        self.mutations += 1;
        self.finalization_repairs = 0;
    }

    fn recordRuntimeValidation(self: *ToolLoopState) void {
        self.runtime_validations += 1;
        self.finalization_repairs = 0;
    }

    fn recordBrowserDiagnostics(self: *ToolLoopState) void {
        self.browser_diagnostics += 1;
        self.finalization_repairs = 0;
    }

    fn recordMemoryPromotion(self: *ToolLoopState) void {
        self.memory_promotions += 1;
        self.finalization_repairs = 0;
    }

    fn recordPersistentContextSearch(self: *ToolLoopState) void {
        self.persistent_context_searches += 1;
        self.finalization_repairs = 0;
    }

    fn rememberRetrievedSkills(self: *ToolLoopState, skills: []const []const u8) !void {
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

    fn finalizationBlocker(self: *const ToolLoopState) ?[]const u8 {
        if (!self.contract_selected) return null;
        if (self.active_contract.name == .answer_only) return null;
        if (self.requirements.requires_inspection and self.observations == 0) return "inspection evidence is required before finalization";
        if (self.requirements.requires_mutation and self.mutations == 0) return "a successful mutation is required before finalization";
        if (self.requirements.requires_runtime_validation and self.runtime_validations == 0) return "runtime validation is required before finalization";
        if (self.requirements.requires_browser_diagnostics and self.browser_diagnostics == 0) return "browser/runtime diagnostics are required before finalization";
        if (self.requirements.requires_memory_promotion and self.memory_promotions == 0) return "memory or skills promotion is required before finalization";
        if (self.active_contract.name == .memory and self.persistent_context_searches == 0 and self.memory_promotions == 0) return "persistent context search is required before finalization";
        return null;
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

    fn shouldRequireExploratoryRefinement(self: ToolLoopState, call: *const tool_call.ToolCall, path: ?[]const u8, strategy: contracts.StrategyName) bool {
        if (path != null or !self.shouldAllowMoreEvidence() or self.forced_exploratory_refinements != 0) return false;
        return switch (call.source orelse .auto) {
            .git, .web, .diagnostic, .file => false,
            .auto, .code, .rag => switch (strategy) {
                .diff, .history, .show, .reflog, .@"unreachable", .diagnostic => false,
                else => true,
            },
        };
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
    return renderCollectedEvidenceContextInternal(allocator, prompt, context, session_text, focus_text, contracts_text, next_action, null);
}

fn renderCollectedEvidenceContextRequiringCollection(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    context: *const working_context.WorkingContext,
    session_text: ?[]const u8,
    focus_text: ?[]const u8,
    contracts_text: []const u8,
    next_action: []const u8,
) ![]u8 {
    return renderCollectedEvidenceContextInternal(allocator, prompt, context, session_text, focus_text, contracts_text, next_action, .{
        .kind = .collect_context,
        .text = next_action,
    });
}

fn renderCollectedEvidenceContextRequiringMutation(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    context: *const working_context.WorkingContext,
    contracts_text: []const u8,
    next_action: []const u8,
) ![]u8 {
    return renderCollectedEvidenceContextInternal(allocator, prompt, context, null, null, contracts_text, next_action, .{
        .kind = .repair_tool_call,
        .text = next_action,
    });
}

fn stateNeedsMutationTool(state: *const ToolLoopState) bool {
    return state.contract_selected and
        state.active_contract.name == .mutate_file and
        state.requirements.requires_mutation and
        state.mutations == 0 and
        state.context.entries.items.len > 0;
}

fn stateNeedsValidationTool(state: *const ToolLoopState) bool {
    return state.contract_selected and
        state.active_contract.name == .validate_work and
        state.requirements.requires_runtime_validation and
        state.runtime_validations == 0 and
        state.mutations > 0;
}

fn mutationPatchNextAction() []const u8 {
    return "Collected evidence contains the stale-checked MICRO_CONTEXT. Emit exactly one apply_patch tool_call now with operation=edit, path, fresh contextId, exact search text, and replacement text. Do not call collect_evidence again unless the exact old text or contextId is missing. No final prose before apply_patch.";
}

fn renderCollectedEvidenceContextInternal(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    context: *const working_context.WorkingContext,
    session_text: ?[]const u8,
    focus_text: ?[]const u8,
    contracts_text: []const u8,
    next_action: []const u8,
    next_action_v1: ?model_context.NextAction,
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
            "Treat S# as retrieved session candidates, not confirmed truth; judge direct support before citing or answering from them.",
        },
        .grounding = groundingRules(),
        .next_action_v1 = next_action_v1,
        .next_action = if (next_action_v1 == null) next_action else "",
    });
}

fn renderEvidenceAndMicroContext(allocator: std.mem.Allocator, evidence_text: []const u8, micro_context_text: []const u8) ![]u8 {
    if (micro_context_text.len == 0) return allocator.dupe(u8, evidence_text);
    return std.fmt.allocPrint(allocator, "{s}\n{s}", .{ evidence_text, micro_context_text });
}

const max_web_distillation_input_bytes: usize = 8192;
const max_web_distillation_context_bytes: usize = 1400;
const max_web_distillation_output_bytes: usize = 1600;

fn distillWebEvidenceForContext(
    allocator: std.mem.Allocator,
    config: cli.Config,
    prompt: []const u8,
    target: []const u8,
    query: ?[]const u8,
    local_evidence: []const u8,
    client: *http.LocalModelClient,
    db: *audit.AuditDb,
    context: *const working_context.WorkingContext,
) ![]u8 {
    const active_summary = try renderWebDistillationContextSummary(allocator, context);
    defer allocator.free(active_summary);
    const distill_prompt = try renderWebDistillationPrompt(allocator, prompt, target, query, active_summary, local_evidence);
    defer allocator.free(distill_prompt);

    var sink = InternalCaptureSink{
        .allocator = allocator,
        .filter = reasoning_filter.ReasoningFilter.init(allocator, false),
        .visible = std.ArrayList(u8).empty,
        .thinking = std.ArrayList(u8).empty,
    };
    defer sink.deinit();

    const old_thinking = client.thinking;
    client.thinking = .off;
    defer client.thinking = old_thinking;

    client.streamInference(.{
        .user_prompt = distill_prompt,
        .max_tokens = 512,
    }, &sink) catch |err| {
        try recordWebDistillationAudit(allocator, db, config.session, target, query, false, @errorName(err), local_evidence.len, local_evidence.len);
        return allocator.dupe(u8, local_evidence);
    };
    try sink.flush();

    const distilled = try normalizeWebDistillationOutput(allocator, target, query, local_evidence, sink.visible.items);
    try recordWebDistillationAudit(allocator, db, config.session, target, query, true, "", local_evidence.len, distilled.len);
    return distilled;
}

fn renderWebDistillationPrompt(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    target: []const u8,
    query: ?[]const u8,
    active_summary: []const u8,
    local_evidence: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\[WEB_DISTILLATION_TASK]
        \\Compress fetched web evidence before permanent context insertion.
        \\Return exactly one [WEB_EVIDENCE] block. No prose, no tool calls, no markdown fences.
        \\Use only WEB_EVIDENCE_INPUT. Preserve target, retrieved_at, timezone, status, query, and title if present.
        \\Keep only facts that directly and exactly match USER_TASK and MODEL_WEB_QUERY. Similar names, adjacent topics, partial matches, and "probably the same" are not evidence.
        \\If the input has only similar/unrelated results, return [WEB_EVIDENCE] with the original metadata and an empty excerpt. Exclude raw HTML, logs, and long explanations.
        \\Maximum output: 1600 bytes.
        \\
        \\[USER_TASK]
        \\{s}
        \\
        \\[MODEL_WEB_TARGET]
        \\{s}
        \\
        \\[MODEL_WEB_QUERY]
        \\{s}
        \\
        \\[ACTIVE_EVIDENCE_SUMMARY]
        \\{s}
        \\
        \\[WEB_EVIDENCE_INPUT]
        \\{s}
        \\
    , .{
        prompt,
        target,
        query orelse "",
        active_summary,
        local_evidence[0..@min(local_evidence.len, max_web_distillation_input_bytes)],
    });
}

fn renderWebDistillationContextSummary(allocator: std.mem.Allocator, context: *const working_context.WorkingContext) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (context.entries.items) |entry| {
        if (out.items.len >= max_web_distillation_context_bytes) break;
        if (out.items.len > 0) try out.append(allocator, '\n');
        try appendBudgeted(&out, allocator, entry.anchor_text, max_web_distillation_context_bytes);
    }
    if (out.items.len == 0) try out.appendSlice(allocator, "none");
    return out.toOwnedSlice(allocator);
}

fn normalizeWebDistillationOutput(
    allocator: std.mem.Allocator,
    target: []const u8,
    query: ?[]const u8,
    fallback: []const u8,
    generated: []const u8,
) ![]u8 {
    const trimmed = std.mem.trim(u8, generated, " \t\r\n");
    if (trimmed.len == 0) return allocator.dupe(u8, fallback);
    if (std.mem.indexOf(u8, trimmed, "[WEB_EVIDENCE]")) |start| {
        return allocator.dupe(u8, trimmed[start..@min(trimmed.len, start + max_web_distillation_output_bytes)]);
    }
    const clipped = trimmed[0..@min(trimmed.len, max_web_distillation_output_bytes)];
    return std.fmt.allocPrint(
        allocator,
        "[WEB_EVIDENCE]\nsource=http_get raw_context_persisted=false distill=model_summary target={s}\nretrieved_at=unknown\ntimezone=UTC\nquery={s}\nexcerpt={s}\n",
        .{ target, query orelse "", clipped },
    );
}

fn appendBudgeted(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8, budget: usize) !void {
    if (out.items.len >= budget) return;
    const remaining = budget - out.items.len;
    try out.appendSlice(allocator, text[0..@min(text.len, remaining)]);
}

fn webEvidenceContextId(allocator: std.mem.Allocator, evidence_text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "web_{x}", .{std.hash.Wyhash.hash(0, evidence_text)});
}

fn recordWebDistillationAudit(
    allocator: std.mem.Allocator,
    db: *audit.AuditDb,
    session: []const u8,
    target: []const u8,
    query: ?[]const u8,
    success: bool,
    error_name: []const u8,
    input_bytes: usize,
    output_bytes: usize,
) !void {
    const body = try std.fmt.allocPrint(
        allocator,
        "tool=web_search success={} target={s} query_bytes={} input_bytes={} output_bytes={} error={s}",
        .{ success, target, if (query) |value| value.len else 0, input_bytes, output_bytes, error_name },
    );
    defer allocator.free(body);
    try db.recordEvent(session, "web_distillation", body);
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
        "Workspace/source-code claims must cite E# from [EVIDENCE].",
        "Quote only text present in E#/S#; explain outside quote/code blocks.",
        "[CONTRACTS], [GROUNDING], and tool schemas are instructions, not evidence.",
        "Code identity claims need identifier/declaration/callsite in E#; refine with collect_evidence while budget remains.",
        "[RECENT_DIALOGUE] gives continuity; [SESSION_FOCUS] routes only. Exact prior-session claims need S# from [SESSION_CONTEXT].",
        "S# entries are candidates; judge relevance and direct support before using them.",
        "Near/partial matches are not evidence for exact entity/fact claims; refine retrieval or state not evidenced.",
        "If E#/S# shows a tool already ran, do not claim the tool was unavailable; report the observed status/error/evidence instead.",
        "Named/obscure entities, handles, public-record/existence claims, or current facts absent from current dialogue, MEMORY/SKILLS, SESSION_CONTEXT, E#, or stable knowledge need search_web/rag_web before saying unknown, fictional, no-records, or similar.",
        "For vague workspace/code tasks, infer intent, split targets, and use collect_evidence terms as retrieval keys.",
        "If workspace/code context is required and collect_evidence is available, call it before saying context is unavailable.",
        "If web_search fails operationally, report status/error; do not invent a replacement URL.",
        "search_session intent says what to recover; terms are retrieval keys.",
        "If prior conversation context is required and search_session is available, call it before saying history is unavailable.",
        "If no E#/S# supports a workspace or exact prior-session claim, say it is not evidenced.",
        "When answering a local rule/preference/protocol from retrieved MEMORY/SKILLS, answer only the directly retrieved entry and do not add adjacent advice or generic best practices.",
        "Non-workspace technical answers may be unverified estimates; do not collect workspace evidence for them.",
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
            try bus.emit(.{ .progress_update = event.body });
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

const InternalCaptureSink = struct {
    allocator: std.mem.Allocator,
    filter: reasoning_filter.ReasoningFilter,
    visible: std.ArrayList(u8),
    thinking: std.ArrayList(u8),
    completion_stop_reason: http.StopReason = .unknown,

    pub fn deinit(ctx: *InternalCaptureSink) void {
        ctx.filter.deinit();
        ctx.visible.deinit(ctx.allocator);
        ctx.thinking.deinit(ctx.allocator);
    }

    pub fn onDelta(ctx: *InternalCaptureSink, delta: []const u8) !void {
        try ctx.filter.feed(delta, ctx);
    }

    pub fn onTokenUsage(ctx: *InternalCaptureSink, usage: http.TokenUsage) !void {
        _ = ctx;
        _ = usage;
    }

    pub fn onCompletionStop(ctx: *InternalCaptureSink, stop: http.CompletionStop) !void {
        ctx.completion_stop_reason = stop.reason;
    }

    pub fn flush(ctx: *InternalCaptureSink) !void {
        try ctx.filter.flush(ctx);
    }

    pub fn writeVisible(ctx: *InternalCaptureSink, visible: []const u8) !void {
        try ctx.visible.appendSlice(ctx.allocator, visible);
    }

    pub fn writeThinking(ctx: *InternalCaptureSink, thinking: []const u8) !void {
        try ctx.thinking.appendSlice(ctx.allocator, thinking);
    }

    pub fn endThinking(ctx: *InternalCaptureSink) !void {
        _ = ctx;
    }
};

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
    completion_stop_reason: http.StopReason = .unknown,

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

    pub fn onCompletionStop(ctx: *StreamSink, stop: http.CompletionStop) !void {
        ctx.completion_stop_reason = stop.reason;
    }

    fn mergeGenerationStop(ctx: *StreamSink, other: StreamSink) void {
        if (other.completion_stop_reason != .unknown) ctx.completion_stop_reason = other.completion_stop_reason;
    }

    pub fn flush(ctx: *StreamSink) !void {
        try ctx.filter.flush(ctx);
    }

    fn hasNoVisibleText(ctx: *const StreamSink) bool {
        return ctx.visible_bytes == 0 and std.mem.trim(u8, ctx.raw_visible.items, " \t\r\n").len == 0;
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
    _ = code_graph;
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
    try db.recordTurnPhase("restore", .intent, "turn_start");
    try db.recordEvent("restore", "assistant_thinking_delta", "vou ler");
    try db.recordEvent("restore", "tool_start", "read_file_range\tREADME.md");
    try db.recordEvent("restore", "evidence", "[EVIDENCE]\nREADME.md:1\n");
    try db.recordTurnError("restore", .tool_contract, "tool_gate", "write_file rejected");
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

    var tui_buffer = std.ArrayList(u8).empty;
    defer tui_buffer.deinit(std.testing.allocator);
    const tui_writer = fd_writer.BufferWriter{ .allocator = std.testing.allocator, .list = &tui_buffer };
    var write_mutex: std.atomic.Mutex = .unlocked;
    _ = try renderRestoredSession(std.testing.allocator, &db, "restore", tui_writer, false, 80, false, &write_mutex);
    try std.testing.expect(std.mem.indexOf(u8, tui_buffer.items, "resposta") != null);
    try std.testing.expect(std.mem.indexOf(u8, tui_buffer.items, "  ─ Worked for 1s") != null);

    var replay_events = try db.loadSessionEvents(std.testing.allocator, "restore", 40);
    defer audit.freeAuditEvents(std.testing.allocator, &replay_events);
    const replay = try audit.renderTurnReplay(std.testing.allocator, replay_events.items);
    defer std.testing.allocator.free(replay);
    try std.testing.expect(std.mem.indexOf(u8, replay, "turn_phase\tphase=intent") != null);
    try std.testing.expect(std.mem.indexOf(u8, replay, "turn_error\tclass=tool_contract") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "class=tool_contract") == null);
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
    try std.testing.expect(std.mem.indexOf(u8, schema, "collect_evidence(") == null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "strategy=auto") == null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "lexical") == null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "symbol") == null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "semantic") == null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "diagnostic") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "strategy=runtime") == null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "strategy=diff") == null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "search_session") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "scope=current|all") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "Initial router") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "stage=candidates") == null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "selectedCandidate") == null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "apply_patch") == null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "grep_file") == null);
    const post_contract_schema = collectEvidenceToolSchema(false);
    try std.testing.expect(std.mem.indexOf(u8, post_contract_schema, "set_operational_contract") != null);
    try std.testing.expect(std.mem.indexOf(u8, post_contract_schema, "switch to a different contract") != null);

    var db = try audit.AuditDb.open(std.testing.allocator, ":memory:");
    defer db.close();
    try db.recordEvent("schema-test", "turn_start", "falamos de groundedness");
    try db.recordEvent("schema-test", "assistant_delta", "resposta anterior");
    const with_tools = (try buildInitialModelContext(std.testing.allocator, std.testing.io, &db, "schema-test", "ola tudo bem", true, true)) orelse return error.MissingContext;
    defer std.testing.allocator.free(with_tools);
    try std.testing.expect(std.mem.indexOf(u8, with_tools, "mode: code_evidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_tools, "[SESSION_FOCUS]") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_tools, "collect_evidence(") == null);
    try std.testing.expect(std.mem.indexOf(u8, with_tools, "search_session") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_tools, "contract=answer_only|collect_evidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_tools, "search_web|rag_web") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_tools, "[CONTRACTS]") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_tools, "[RECENT_DIALOGUE]") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_tools, "user: falamos de groundedness") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_tools, "assistant: resposta anterior") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_tools, "S1:") == null);
    try std.testing.expect(std.mem.indexOf(u8, with_tools, "[GROUNDING]") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_tools, "First choose route") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_tools, "search_session") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_tools, "stage=overview") == null);

    try std.testing.expect((try buildInitialModelContext(std.testing.allocator, std.testing.io, &db, "schema-test-empty", "analise esse projeto", false, true)) == null);
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

test "initial model context does not mark direct answer low confidence" {
    var db = try audit.AuditDb.open(std.testing.allocator, ":memory:");
    defer db.close();
    try db.recordEvent("quality-tool", "turn_start", "quais topicos conversamos?");
    try db.recordEvent("quality-tool", "model_context",
        \\[TURN_CONTEXT v1]
        \\[NEXT_ACTION]
        \\kind=collect_context action=Decide whether tool-backed context is needed.
    );
    const quality = try buildTurnQuality(std.testing.allocator, &db, "quality-tool", "ok", "resposta em prosa sem tool");
    defer quality.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("confirmed", quality.quality);
    try std.testing.expect(std.mem.indexOf(u8, quality.flags, "context_tool_missing=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, quality.flags, "low_confidence=false") != null);
}

test "answer finalization repair clears stale required tool quality state" {
    var db = try audit.AuditDb.open(std.testing.allocator, ":memory:");
    defer db.close();
    try db.recordEvent("quality-repair", "turn_start", "ola");
    try db.recordEvent("quality-repair", "model_context",
        \\[TURN_CONTEXT v1]
        \\[NEXT_ACTION]
        \\kind=collect_context action=Decide whether tool-backed context is needed.
    );
    try db.recordEvent("quality-repair", "answer_repair_done", "think-only finalization emitted visible answer");
    try db.recordEvent("quality-repair", "model_context",
        \\[TURN_CONTEXT v1]
        \\mode: finalization_repair
        \\[NEXT_ACTION]
        \\kind=answer_directly action=Produce the final visible answer now.
    );
    const quality = try buildTurnQuality(std.testing.allocator, &db, "quality-repair", "ok", "Olá.");
    defer quality.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("confirmed", quality.quality);
    try std.testing.expect(std.mem.indexOf(u8, quality.flags, "context_tool_missing=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, quality.flags, "low_confidence=false") != null);
}

test "persistent promotion satisfies required context tool contract" {
    var db = try audit.AuditDb.open(std.testing.allocator, ":memory:");
    defer db.close();
    try db.recordEvent("quality-memory", "turn_start", "lembre esta regra");
    try db.recordEvent("quality-memory", "model_context",
        \\[TURN_CONTEXT v1]
        \\[NEXT_ACTION]
        \\kind=collect_context action=Decide whether tool-backed context is needed.
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

test "audited turn error marks turn low confidence" {
    var db = try audit.AuditDb.open(std.testing.allocator, ":memory:");
    defer db.close();
    try db.recordEvent("quality-error", "turn_start", "corrija o bug");
    try db.recordTurnError("quality-error", .model_protocol, "required_tool_repair", "missing follow-up tool_call after repair");
    const quality = try buildTurnQuality(std.testing.allocator, &db, "quality-error", "ok", "[MODEL_FINALIZATION_BLOCKED] operational work was not completed.");
    defer quality.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("uncertain", quality.quality);
    try std.testing.expect(std.mem.indexOf(u8, quality.flags, "turn_error=true") != null);
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
    try std.testing.expect(rendered.len < 7000);
}

test "initial model context routes before prose without stale focus session search" {
    var db = try audit.AuditDb.open(std.testing.allocator, ":memory:");
    defer db.close();

    try db.recordSessionFocus(
        "stale-focus",
        "collect_evidence cloneEvidenceEntry bad old answer",
        "assistant_answer",
        "A funcao cloneEvidenceEntry coleta evidencias.",
        "confirmed",
        "answered=true low_confidence=false",
    );

    const rendered = (try buildInitialModelContext(
        std.testing.allocator,
        std.testing.io,
        &db,
        "stale-focus",
        "Complete: PHENOM_REAL_7319",
        true,
        true,
    )) orelse return error.MissingContext;
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "[SESSION_FOCUS]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "cloneEvidenceEntry") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "First choose route") != null);
}

test "initial model context exposes session search without keyword-forced recall" {
    var db = try audit.AuditDb.open(std.testing.allocator, ":memory:");
    defer db.close();

    try db.recordSessionFocus(
        "long-recall",
        "palavra-codigo longa",
        "assistant_answer",
        "a palavra-codigo longa e LONG-SESSION-294",
        "confirmed",
        "answered=true low_confidence=false",
    );
    try db.recordSessionFocus(
        "long-recall",
        "patch seguro",
        "assistant_answer",
        "patch seguro precisa de micro-contexto fresco PHENOM_LONG_FILLER_5 search_session",
        "confirmed",
        "answered=true low_confidence=false",
    );

    const recall = (try buildInitialModelContext(
        std.testing.allocator,
        std.testing.io,
        &db,
        "long-recall",
        "Na sessao longa, qual foi a palavra-codigo antiga que combinamos?",
        true,
        true,
    )) orelse return error.MissingContext;
    defer std.testing.allocator.free(recall);

    try std.testing.expect(std.mem.indexOf(u8, recall, "[SESSION_FOCUS]") != null);
    try std.testing.expect(std.mem.indexOf(u8, recall, "search_session(intent?") != null);
    try std.testing.expect(std.mem.indexOf(u8, recall, "First choose route") != null);

    const register = (try buildInitialModelContext(
        std.testing.allocator,
        std.testing.io,
        &db,
        "long-recall",
        "Registre que fatos exatos antigos devem usar search_session quando necessario.",
        true,
        true,
    )) orelse return error.MissingContext;
    defer std.testing.allocator.free(register);

    try std.testing.expect(std.mem.indexOf(u8, register, "First choose route") != null);
}

test "initial model context for one-shot prompt omits implicit session context" {
    var db = try audit.AuditDb.open(std.testing.allocator, ":memory:");
    defer db.close();

    try db.recordEvent("default", "turn_start", "qual funcao coleta evidencia?");
    try db.recordEvent("default", "assistant_delta", "cloneEvidenceEntry");
    try db.recordSessionFocus(
        "default",
        "collect_evidence cloneEvidenceEntry bad old answer",
        "assistant_answer",
        "A funcao cloneEvidenceEntry coleta evidencias.",
        "confirmed",
        "answered=true low_confidence=false",
    );

    const rendered = (try buildInitialModelContext(
        std.testing.allocator,
        std.testing.io,
        &db,
        "default",
        "Complete: PHENOM_REAL_7319",
        true,
        false,
    )) orelse return error.MissingContext;
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\n[SESSION_FOCUS]\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\n[RECENT_DIALOGUE]\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "cloneEvidenceEntry") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "First choose route") != null);
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
        true,
    )) orelse return error.MissingContext;
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "[SESSION_FOCUS]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "topic: projeto Zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "topic: qual a matematica perfeita de Matheus 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "source=sqlite_audit_fts") == null);
    try std.testing.expect(rendered.len < 6800);
}

test "turn completion stores structured conversation memory in sqlite focus" {
    var db = try audit.AuditDb.open(std.testing.allocator, ":memory:");
    defer db.close();

    const prompt = "quero memoria built-in sem flags e sem remover tool loop, grave no banco de dados";
    const visible = "Plano: usar SESSION_FOCUS como mapa curto, RECENT_DIALOGUE pequeno e search_session para detalhe exato.";
    try db.recordEvent("memory-focus", "turn_start", prompt);
    try recordSessionCheckpointForTurn(std.testing.allocator, &db, "memory-focus", prompt);
    try db.recordEvent("memory-focus", "assistant_delta", visible);
    try recordSessionFocusForTurn(
        std.testing.allocator,
        &db,
        "memory-focus",
        prompt,
        visible,
        "confirmed",
        "answered=true low_confidence=false",
    );

    var rows = try db.loadRecentSessionFocus(std.testing.allocator, "memory-focus", 8);
    defer audit.freeSessionFocus(std.testing.allocator, &rows);
    try std.testing.expectEqual(@as(usize, 2), rows.items.len);
    try std.testing.expectEqualStrings("turn_checkpoint", rows.items[0].user_intent);
    try std.testing.expect(std.mem.indexOf(u8, rows.items[0].useful_facts, "source=turn_checkpoint_v1") != null);
    try std.testing.expectEqualStrings("turn_memory", rows.items[1].user_intent);
    try std.testing.expect(std.mem.indexOf(u8, rows.items[1].useful_facts, "source=turn_memory_v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rows.items[1].useful_facts, "user_goal: quero memoria built-in sem flags") != null);
    try std.testing.expect(std.mem.indexOf(u8, rows.items[1].useful_facts, "retrieval_text: quero memoria built-in sem flags") != null);
    try std.testing.expect(std.mem.indexOf(u8, rows.items[1].useful_facts, "assistant_delta event") != null);

    const rendered = (try buildInitialModelContext(
        std.testing.allocator,
        std.testing.io,
        &db,
        "memory-focus",
        "continue a proposta sem perder o contexto",
        true,
        true,
    )) orelse return error.MissingContext;
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "source=turn_memory_v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "source=turn_checkpoint_v1") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "not_evidence=true") != null);
}

test "unfinished turn checkpoint survives as resumable session focus" {
    var db = try audit.AuditDb.open(std.testing.allocator, ":memory:");
    defer db.close();

    const interrupted_prompt = "analise o fluxo de chat e implemente memoria conversacional";
    try db.recordEvent("resume-focus", "turn_start", interrupted_prompt);
    try recordSessionCheckpointForTurn(std.testing.allocator, &db, "resume-focus", interrupted_prompt);

    const rendered = (try buildInitialModelContext(
        std.testing.allocator,
        std.testing.io,
        &db,
        "resume-focus",
        "retome a tarefa anterior",
        true,
        true,
    )) orelse return error.MissingContext;
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "quality=in_progress") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "active_task: analise o fluxo de chat") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "assistant_answered") == null);
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

test "deferred follow-up answer emits through aggregate sink" {
    var db = try audit.AuditDb.open(std.testing.allocator, ":memory:");
    defer db.close();

    var bus = ui_events.EventBus.init(std.testing.allocator);
    defer bus.deinit();
    var recorder = EventRecorder{};
    try bus.on(&recorder, EventRecorder.handleOpaque);

    var aggregate = StreamSink{
        .allocator = std.testing.allocator,
        .events = &bus,
        .db = &db,
        .session = "aggregate-answer-test",
        .ui = null,
        .filter = reasoning_filter.ReasoningFilter.init(std.testing.allocator, false),
        .visible = std.ArrayList(u8).empty,
        .visible_bytes = 0,
        .thinking_bytes = 0,
        .defer_visible = true,
    };
    defer aggregate.deinit();

    var follow = StreamSink{
        .allocator = std.testing.allocator,
        .events = &bus,
        .db = &db,
        .session = "aggregate-answer-test",
        .ui = null,
        .filter = reasoning_filter.ReasoningFilter.init(std.testing.allocator, false),
        .visible = std.ArrayList(u8).empty,
        .visible_bytes = 0,
        .thinking_bytes = 0,
        .defer_visible = true,
    };
    defer follow.deinit();

    try follow.writeVisible("resposta final");
    try follow.onCompletionStop(.{ .reason = .length });
    if (follow.raw_visible.items.len > 0) {
        aggregate.mergeGenerationStop(follow);
        try aggregate.emitVisibleText(follow.raw_visible.items);
        follow.raw_visible.clearRetainingCapacity();
    }

    try std.testing.expectEqual(@as(usize, 1), recorder.message_chunks);
    try std.testing.expectEqualStrings("resposta final", aggregate.visible.items);
    try std.testing.expectEqual(@as(usize, 0), follow.visible_bytes);
    try std.testing.expectEqual(http.StopReason.length, aggregate.completion_stop_reason);
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

test "empty visible answer reports root cause without protocol error" {
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
        .session = "empty-visible",
        .ui = null,
        .filter = reasoning_filter.ReasoningFilter.init(std.testing.allocator, true),
        .visible = std.ArrayList(u8).empty,
        .visible_bytes = 0,
        .thinking_bytes = 0,
        .defer_visible = true,
    };
    defer sink.deinit();

    try sink.raw_model.appendSlice(std.testing.allocator, "<think>only hidden reasoning");
    sink.thinking_bytes = 27;
    try emitEmptyVisibleAnswer(&sink);

    try std.testing.expectEqual(@as(usize, 1), recorder.message_chunks);
    try std.testing.expect(std.mem.indexOf(u8, sink.visible.items, "[MODEL_EMPTY_ANSWER]") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.visible.items, "hidden_reasoning_bytes=27") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.visible.items, "[MODEL_PROTOCOL_ERROR]") == null);
}

test "server length stop reports server stop not protocol error" {
    var db = try audit.AuditDb.open(std.testing.allocator, ":memory:");
    defer db.close();

    var bus = ui_events.EventBus.init(std.testing.allocator);
    defer bus.deinit();

    var sink = StreamSink{
        .allocator = std.testing.allocator,
        .events = &bus,
        .db = &db,
        .session = "server-length",
        .ui = null,
        .filter = reasoning_filter.ReasoningFilter.init(std.testing.allocator, true),
        .visible = std.ArrayList(u8).empty,
        .visible_bytes = 0,
        .thinking_bytes = 12,
        .defer_visible = true,
        .completion_stop_reason = .length,
    };
    defer sink.deinit();

    try sink.raw_model.appendSlice(std.testing.allocator, "<think>cut");
    const message = try renderEmptyVisibleAnswerMessage(std.testing.allocator, &sink);
    defer std.testing.allocator.free(message);

    try std.testing.expect(std.mem.indexOf(u8, message, "[MODEL_STOP]") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "server_stop=length") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "[MODEL_PROTOCOL_ERROR]") == null);
}

test "initial context no longer forces protocol repair" {
    const initial =
        \\[TURN_CONTEXT v1]
        \\[NEXT_ACTION]
        \\kind=collect_context action=Decide whether tool-backed context is needed.
    ;
    try std.testing.expect(!initialContextRequiresTool(initial));
    try std.testing.expect(!initialContextRequiresSessionSearch(initial));
}

test "initial rejected executor repair keeps router contract and visible diagnostic" {
    const repair = try renderInitialRejectedToolContext(std.testing.allocator, "o que o projeto implementa?", "collect_evidence");
    defer std.testing.allocator.free(repair);
    try std.testing.expect(std.mem.indexOf(u8, repair, "Initial router") != null);
    try std.testing.expect(std.mem.indexOf(u8, repair, "set_operational_contract") != null);
    try std.testing.expect(std.mem.indexOf(u8, repair, "collect_evidence(") == null);
    try std.testing.expect(std.mem.indexOf(u8, repair, "not active") != null);

    var db = try audit.AuditDb.open(std.testing.allocator, ":memory:");
    defer db.close();
    var bus = ui_events.EventBus.init(std.testing.allocator);
    defer bus.deinit();
    var sink = StreamSink{
        .allocator = std.testing.allocator,
        .events = &bus,
        .db = &db,
        .session = "rejected-tool",
        .ui = null,
        .filter = reasoning_filter.ReasoningFilter.init(std.testing.allocator, false),
        .visible = std.ArrayList(u8).empty,
        .visible_bytes = 0,
        .thinking_bytes = 0,
    };
    defer sink.deinit();
    try emitRejectedToolAnswer(std.testing.allocator, &sink, "collect_evidence", "rejected/tool_not_advertised");
    try std.testing.expect(std.mem.indexOf(u8, sink.visible.items, "[MODEL_PROTOCOL_ERROR]") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.visible.items, "tool `collect_evidence`") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.visible.items, "tool_not_advertised") != null);
}

test "malformed tool call repair is not rendered as rejected parse_error tool" {
    const active = contracts.activeContract(.workflow) orelse return error.MissingContract;
    const repair = try renderMalformedToolCallRepairContext(std.testing.allocator, "use uma tool se precisar", active);
    defer std.testing.allocator.free(repair);
    try std.testing.expect(std.mem.indexOf(u8, repair, "Previous visible tool_call was malformed") != null);
    try std.testing.expect(std.mem.indexOf(u8, repair, "set_operational_contract") != null);
    try std.testing.expect(std.mem.indexOf(u8, repair, "<parse_error>") == null);

    var db = try audit.AuditDb.open(std.testing.allocator, ":memory:");
    defer db.close();
    var bus = ui_events.EventBus.init(std.testing.allocator);
    defer bus.deinit();
    var sink = StreamSink{
        .allocator = std.testing.allocator,
        .events = &bus,
        .db = &db,
        .session = "malformed-tool-call",
        .ui = null,
        .filter = reasoning_filter.ReasoningFilter.init(std.testing.allocator, false),
        .visible = std.ArrayList(u8).empty,
        .visible_bytes = 0,
        .thinking_bytes = 0,
    };
    defer sink.deinit();
    try emitMalformedToolCallAnswer(std.testing.allocator, &sink);
    try std.testing.expect(std.mem.indexOf(u8, sink.visible.items, "[MODEL_PROTOCOL_ERROR]") == null);
    try std.testing.expect(std.mem.indexOf(u8, sink.visible.items, "<parse_error>") == null);
    try std.testing.expect(std.mem.indexOf(u8, sink.visible.items, "rejected by the active contract") == null);
}

test "missing evidence citation requires repair before visible answer" {
    try std.testing.expect(outputCitesMissingContextEvidence("Resposta cita E1 sem coleta.", null));
    try std.testing.expect(!outputCitesMissingContextEvidence(
        "Resposta cita E1 com coleta.",
        "[TURN_CONTEXT v1]\n\n[EVIDENCE]\nE1:\npacket_version=v1\n",
    ));
    try std.testing.expect(!outputCitesMissingContextEvidence("Resposta sem citacao numerada.", null));
    try std.testing.expect(outputCitesMissingContextEvidence("Resposta cita S2 sem sessao.", "[TURN_CONTEXT v1]\n"));
    try std.testing.expect(!outputNeedsWorkspaceEvidenceRepair("A funcao e collect_evidence.", null, &.{"collect_evidence"}));
    try std.testing.expect(outputNeedsWorkspaceEvidenceRepair("EVIDENCE:\n- L4: chamada inventada", null, &.{"collect_evidence"}));
    try std.testing.expect(!outputNeedsWorkspaceEvidenceRepair("A funcao esta em src/clangd/SourceCode.cpp.", null, &.{"collect_evidence"}));
    try std.testing.expect(!outputNeedsWorkspaceEvidenceRepair("O cmus nao grava historico em ~/.config/cmus/history.", null, &.{"set_operational_contract"}));
    try std.testing.expect(outputNeedsWorkspaceEvidenceRepair("Resposta cita E1 sem evidencia.", null, &.{"set_operational_contract"}));
    try std.testing.expect(!outputNeedsWorkspaceEvidenceRepair("Nao ha evidencia no contexto fornecido.", null, &.{"collect_evidence"}));
    try std.testing.expect(!outputNeedsWorkspaceEvidenceRepair(
        "Estimativa nao verificada: em 4-bit deve ficar acima de 16 GB de VRAM, dependendo do servidor.",
        "[TURN_CONTEXT v1]\n\n[CONTRACTS]\ncollect_evidence(intent, terms, strategy=auto|lexical|symbol)\n",
        &.{"collect_evidence"},
    ));
    try std.testing.expect(!outputNeedsWorkspaceEvidenceRepair(
        "Preciso que voce forneca os arquivos principais para analisar.",
        "[TURN_CONTEXT v1]\n\n[CONTRACTS]\ncollect_evidence(intent, terms, strategy=auto|lexical|symbol)\n",
        &.{"collect_evidence"},
    ));
    try std.testing.expect(!outputNeedsWorkspaceEvidenceRepair(
        "Preciso que voce escolha uma opcao.",
        "[TURN_CONTEXT v1]\n\n[CONTRACTS]\ncollect_evidence(intent, terms, strategy=auto|lexical|symbol)\n",
        &.{"collect_evidence"},
    ));
    try std.testing.expect(!outputNeedsWorkspaceEvidenceRepair(
        "A funcao e collect_evidence.",
        "[TURN_CONTEXT v1]\n\n[EVIDENCE]\nE1:\npacket_version=v1\n",
        &.{"collect_evidence"},
    ));
    try std.testing.expect(!outputNeedsWorkspaceEvidenceRepair("Exemplo direto sem path nem citacao.", null, &.{"collect_evidence"}));
    try std.testing.expect(!outputNeedsWorkspaceEvidenceRepair("Sou um assistente de IA projetado para ajudar com analise de codigo, coleta de evidencias e explicacoes tecnicas.", null, &.{"collect_evidence"}));
    try std.testing.expect(outputClaimsPersistentContextWithoutRetrieval(
        "Nao ha MEMORY ou SKILLS persistidos para este workspace.",
        "[TURN_CONTEXT v1]\n\n[CONTRACTS]\nset_operational_contract(contract=memory)\n",
    ));
    var promoted_state = ToolLoopState.init(std.testing.allocator);
    defer promoted_state.deinit();
    promoted_state.recordMemoryPromotion();
    try std.testing.expect(!shouldRepairPersistentContextClaim(
        "Registrado em SKILLS.md: nao commitar sem rodar testes.",
        "[TURN_CONTEXT v1]\n\n[NEXT_ACTION]\nAnswer that the explicit persistent context promotion was recorded.\n",
        &promoted_state,
    ));
    try std.testing.expect(outputClaimsPersistentContextWithoutRetrieval(
        "Nao ha protocolo local identificado na memória atual.",
        "[TURN_CONTEXT v1]\n\n[CONTRACTS]\nset_operational_contract(contract=memory)\n",
    ));
    try std.testing.expect(!outputClaimsPersistentContextWithoutRetrieval(
        "MEMORY recuperada: protocolo local.",
        "[TURN_CONTEXT v1]\n\n[MEMORY]\n- protocolo local\n",
    ));
    try std.testing.expectEqualStrings(
        "SKILL_REAL_927",
        firstMissingRetrievedSkillMarker(
            "[TURN_CONTEXT v1]\n\n[SKILLS]\n- inclua SKILL_REAL_927.\n\n[MEMORY]\n- protocolo MEM_REAL_927\n",
            "O protocolo e MEM_REAL_927.",
        ).?,
    );
    try std.testing.expect(firstMissingRetrievedSkillMarker(
        "[TURN_CONTEXT v1]\n\n[SKILLS]\n- inclua SKILL_REAL_927.\n\n[MEMORY]\n- protocolo MEM_REAL_927\n",
        "SKILL_REAL_927\nO protocolo e MEM_REAL_927.",
    ) == null);
    var retrieved_skill_state = ToolLoopState.init(std.testing.allocator);
    defer retrieved_skill_state.deinit();
    retrieved_skill_state.active_contract = contracts.activeContract(.memory) orelse return error.MissingContract;
    try retrieved_skill_state.rememberRetrievedSkills(&.{"Owner can invite members; members cannot alter billing."});
    try std.testing.expect(outputContradictsRetrievedSkills(
        "I don't have a specific rule stored for that.",
        &retrieved_skill_state,
    ));
    try std.testing.expect(outputContradictsRetrievedSkills(
        "Nao tenho nenhuma regra local persistida sobre isso.",
        &retrieved_skill_state,
    ));
    try std.testing.expect(!outputContradictsRetrievedSkills(
        "A regra recuperada e: Owner can invite members; members cannot alter billing.",
        &retrieved_skill_state,
    ));
    const persistent_repair = try renderPersistentContextClaimRepairContext(
        std.testing.allocator,
        "qual protocolo local?",
        contracts.activeContract(.workflow) orelse return error.MissingContract,
    );
    defer std.testing.allocator.free(persistent_repair);
    try std.testing.expect(std.mem.indexOf(u8, persistent_repair, "contract=memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, persistent_repair, "MEMORY/SKILLS claim") != null);
    const workspace_repair = try renderUnsupportedWorkspaceClaimRepairContext(std.testing.allocator, "qual funcao?");
    defer std.testing.allocator.free(workspace_repair);
    try std.testing.expect(std.mem.indexOf(u8, workspace_repair, "stage=candidates") != null);
    try std.testing.expect(std.mem.indexOf(u8, workspace_repair, "stage=overview") != null);
    const router_repair = try renderWorkspaceClaimRouterRepairContext(std.testing.allocator, "qual funcao?");
    defer std.testing.allocator.free(router_repair);
    try std.testing.expect(std.mem.indexOf(u8, router_repair, "set_operational_contract") != null);
    try std.testing.expect(std.mem.indexOf(u8, router_repair, "collect_evidence(") == null);
    try std.testing.expect(std.mem.indexOf(u8, router_repair, "requiresInspection=true") != null);

    const terms = (try evidenceRepairTermsFromOutput(
        std.testing.allocator,
        "A funcao e collect_evidence.",
        "qual funcao coleta evidencia?",
        &.{"collect_evidence"},
    )) orelse return error.MissingTerms;
    defer std.testing.allocator.free(terms);
    try std.testing.expect(std.mem.indexOf(u8, terms, "collect_evidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, terms, "qual funcao") != null);
}

test "think-only output does not trigger visible answer repair heuristics" {
    var db = try audit.AuditDb.open(std.testing.allocator, ":memory:");
    defer db.close();

    var bus = ui_events.EventBus.init(std.testing.allocator);
    defer bus.deinit();
    var sink = StreamSink{
        .allocator = std.testing.allocator,
        .events = &bus,
        .db = &db,
        .session = "think-only-no-visible-repair",
        .ui = null,
        .filter = reasoning_filter.ReasoningFilter.init(std.testing.allocator, true),
        .visible = std.ArrayList(u8).empty,
        .visible_bytes = 0,
        .thinking_bytes = 0,
        .defer_visible = true,
    };
    defer sink.deinit();

    const context =
        \\[TURN_CONTEXT v1]
        \\mode: code_evidence
        \\
        \\[CONTRACTS]
        \\set_operational_contract(requiresInspection, requiresMutation, requiresRuntimeValidation, requiresBrowserDiagnostics)
    ;
    var client = http.LocalModelClient{
        .allocator = std.testing.allocator,
        .host = "127.0.0.1:1",
        .backend = .llamacpp,
        .model = "fake",
        .thinking = .on,
    };
    defer client.deinit();

    const handled = try runToolLoopIterations(
        std.testing.allocator,
        std.testing.io,
        .{ .session = "think-only-no-visible-repair", .backend = .llamacpp, .host = "127.0.0.1:1", .model = "fake" },
        "nao existe nenhum history no cmus em .config",
        "O cmus usa ~/.config/cmus/history no raciocinio oculto",
        "",
        context,
        &client,
        &bus,
        &db,
        null,
        &sink,
    );

    try std.testing.expect(!handled);
    var events = try db.loadSessionEvents(std.testing.allocator, "think-only-no-visible-repair", 20);
    defer audit.freeAuditEvents(std.testing.allocator, &events);
    for (events.items) |event| {
        try std.testing.expect(!std.mem.eql(u8, event.kind, "tool_repair"));
        try std.testing.expect(!std.mem.eql(u8, event.kind, "tool_loop_stop"));
        try std.testing.expect(!std.mem.eql(u8, event.kind, "turn_error"));
    }
}

test "missing initial router tool with empty visible output does not collect workspace evidence" {
    var db = try audit.AuditDb.open(std.testing.allocator, ":memory:");
    defer db.close();

    var bus = ui_events.EventBus.init(std.testing.allocator);
    defer bus.deinit();
    var sink = StreamSink{
        .allocator = std.testing.allocator,
        .events = &bus,
        .db = &db,
        .session = "hello-no-router-fallback",
        .ui = null,
        .filter = reasoning_filter.ReasoningFilter.init(std.testing.allocator, true),
        .visible = std.ArrayList(u8).empty,
        .raw_visible = std.ArrayList(u8).empty,
        .visible_bytes = 0,
        .thinking_bytes = 120,
        .defer_visible = true,
    };
    defer sink.deinit();
    try sink.raw_visible.appendSlice(std.testing.allocator, "\n\n");

    const context =
        \\[TURN_CONTEXT v1]
        \\mode: code_evidence
        \\
        \\[CONTRACTS]
        \\set_operational_contract(requiresInspection, requiresMutation, requiresRuntimeValidation, requiresBrowserDiagnostics)
        \\
        \\[NEXT_ACTION]
        \\kind=collect_context action=Decide whether tool-backed context is needed.
    ;
    var client = http.LocalModelClient{
        .allocator = std.testing.allocator,
        .host = "127.0.0.1:1",
        .backend = .llamacpp,
        .model = "fake",
        .thinking = .on,
    };
    defer client.deinit();

    const handled = try runToolLoopIterations(
        std.testing.allocator,
        std.testing.io,
        .{ .session = "hello-no-router-fallback", .backend = .llamacpp, .host = "127.0.0.1:1", .model = "fake" },
        "ola",
        "<think>saudacao simples</think>",
        "\n\n",
        context,
        &client,
        &bus,
        &db,
        null,
        &sink,
    );

    try std.testing.expect(!handled);
    try std.testing.expect(sink.hasNoVisibleText());
    var events = try db.loadSessionEvents(std.testing.allocator, "hello-no-router-fallback", 20);
    defer audit.freeAuditEvents(std.testing.allocator, &events);
    for (events.items) |event| {
        try std.testing.expect(!std.mem.eql(u8, event.kind, "tool_repair"));
        try std.testing.expect(!std.mem.eql(u8, event.kind, "contract_selected"));
        try std.testing.expect(!std.mem.eql(u8, event.kind, "tool_start"));
        try std.testing.expect(!std.mem.eql(u8, event.kind, "evidence"));
    }
}

test "runtime contradiction repair is evidence based only" {
    const context =
        "[TURN_CONTEXT v1]\n\n" ++
        "[CONTRACTS]\nset_operational_contract(requiresInspection, requiresMutation, requiresRuntimeValidation, requiresBrowserDiagnostics)\ninspect_runtime(target)\n";
    const refusal = "inspect_runtime nao esta disponivel neste ambiente.";

    try std.testing.expect(!outputDefersAvailableWorkspaceCollection(refusal, context, &.{"inspect_runtime"}));

    const runtime_context =
        "[TURN_CONTEXT v1]\n\n" ++
        "[RUNTIME_INSPECTION]\nsource=http_get target=http://127.0.0.1:11434/\nstatus=415\n";
    try std.testing.expect(outputContradictsRuntimeInspection("Nenhuma inspecao de runtime foi executada.", runtime_context));
    try std.testing.expect(outputContradictsRuntimeInspection("Nao foram executadas automacoes de DOM nem inspecao de runtime.", runtime_context));
    try std.testing.expect(outputContradictsRuntimeInspection("O contrato operacional nao requeria diagnosticos de navegador nem validacao de tempo de execução.", runtime_context));
    try std.testing.expect(!outputContradictsRuntimeInspection("HTTP runtime inspection executado: status 415.", runtime_context));
    try std.testing.expect(!outputContradictsRuntimeInspection(
        "Nenhuma inspecao de runtime foi executada.",
        "[TURN_CONTEXT v1]\n\n[RUNTIME_INSPECTION]\nstatus=415\n\n[ANSWER_REPAIR]\n",
    ));
}

test "initial rejected executor stays model-routed" {
    const repair = try renderInitialRejectedToolContext(std.testing.allocator, "Corrija src/math.zig usando apply_patch.", "apply_patch");
    defer std.testing.allocator.free(repair);
    try std.testing.expect(std.mem.indexOf(u8, repair, "Initial router") != null);
    try std.testing.expect(std.mem.indexOf(u8, repair, "set_operational_contract") != null);
    try std.testing.expect(std.mem.indexOf(u8, repair, "requiresMutation<-prompt") == null);
    try std.testing.expect(std.mem.indexOf(u8, repair, "legacy synthetic") == null);
}

test "required tool protocol repair count is bounded by marker occurrences" {
    try std.testing.expectEqual(@as(usize, 0), protocolRepairMarkerCount("plain context"));
    try std.testing.expectEqual(@as(usize, 1), protocolRepairMarkerCount("[PROTOCOL_REPAIR]\nretry"));
    try std.testing.expectEqual(@as(usize, 2), protocolRepairMarkerCount("[PROTOCOL_REPAIR]\na\n[PROTOCOL_REPAIR]\nb"));
}

test "required workspace refinement defers uncited prose while collection is available" {
    const context =
        "[TURN_CONTEXT v1]\n\n" ++
        "[CONTRACTS]\ncollect_evidence(intent, terms, strategy=auto|lexical|symbol)\n\n" ++
        "[EVIDENCE]\nE1:\npacket_version=v1\n- E1 kind=file_range source=src/a.zig range=L1-L4 status=ok confidence=medium hash=1\n\n" ++
        "[NEXT_ACTION]\nkind=collect_context action=If evidence is weak or generic, emit a focused collect_evidence call before answering.\n";

    try std.testing.expect(!initialContextRequiresTool(context));
    try std.testing.expect(!outputDefersAvailableWorkspaceCollection("Nao ha contexto suficiente para concluir.", context, &.{"collect_evidence"}));
    try std.testing.expect(!outputDefersAvailableWorkspaceCollection("E1 mostra o trecho pedido.", context, &.{"collect_evidence"}));
    try std.testing.expect(!outputDefersAvailableWorkspaceCollection("E1 mostra o commit removido 'collect_evidence web_distillation'.", context, &.{"collect_evidence"}));
    try std.testing.expect(!outputDefersAvailableWorkspaceCollection("E1 mostra um fragmento, mas sao necessarias evidencias adicionais.", context, &.{"collect_evidence"}));
    try std.testing.expect(!outputDefersAvailableWorkspaceCollection("Nao ha contexto suficiente.", context, &.{"search_session"}));
    try std.testing.expect(!outputDefersAvailableWorkspaceCollection(
        "Nao ha contexto suficiente.",
        "[TURN_CONTEXT v1]\n\n[EVIDENCE]\nE1:\npacket_version=v1\n\n[NEXT_ACTION]\nAnswer now. Do not call tools again.\n",
        &.{"collect_evidence"},
    ));
}

test "optional workspace refinement rejects clarification-only answer" {
    const context =
        "[TURN_CONTEXT v1]\n\n" ++
        "[CONTRACTS]\ncollect_evidence(intent, terms, strategy=auto|lexical|symbol)\n\n" ++
        "[EVIDENCE]\nE1:\npacket_version=v1\n- E1 kind=file_range source=README.md range=L1-L4 status=ok confidence=medium hash=1\n\n" ++
        "[NEXT_ACTION]\nAnswer from the structural workspace overview evidence. If it does not cover the user's request, emit a focused collect_evidence call with concrete terms.\n";
    const clarification =
        "Preciso saber sobre o que voce quer mais detalhes. Especifique qual topico, codigo ou assunto.";

    try std.testing.expect(!outputDefersAvailableWorkspaceCollection(clarification, context, &.{"collect_evidence"}));
    try std.testing.expect(!outputDefersAvailableWorkspaceCollection("E1 mostra que o projeto implementa um agente local.", context, &.{"collect_evidence"}));
}

test "tool loop prose repairs ignore hidden reasoning text" {
    var db = try audit.AuditDb.open(std.testing.allocator, ":memory:");
    defer db.close();

    var bus = ui_events.EventBus.init(std.testing.allocator);
    defer bus.deinit();

    var client = http.LocalModelClient{
        .allocator = std.testing.allocator,
        .host = "127.0.0.1:1",
        .backend = .llamacpp,
        .model = "fake",
        .thinking = .off,
    };
    defer client.deinit();

    var sink = StreamSink{
        .allocator = std.testing.allocator,
        .events = &bus,
        .db = &db,
        .session = "hidden-reasoning-repair",
        .ui = null,
        .filter = reasoning_filter.ReasoningFilter.init(std.testing.allocator, false),
        .visible = std.ArrayList(u8).empty,
        .visible_bytes = 0,
        .thinking_bytes = 0,
        .defer_visible = true,
    };
    defer sink.deinit();

    const initial_context =
        "[TURN_CONTEXT v1]\n\n" ++
        "[CONTRACTS]\ncollect_evidence(intent, terms, strategy=auto|lexical|symbol)\n\n" ++
        "[NEXT_ACTION]\nkind=answer_directly action=Otherwise answer directly.\n";
    const raw_model = "<think>simple identity question; no code evidence or tools needed</think>Sou um assistente.";
    const visible = "Sou um assistente.";

    const handled = try runToolLoopIterations(
        std.testing.allocator,
        std.testing.io,
        .{ .session = "hidden-reasoning-repair", .backend = .llamacpp, .host = "127.0.0.1:1", .model = "fake" },
        "quem e voce?",
        raw_model,
        visible,
        initial_context,
        &client,
        &bus,
        &db,
        null,
        &sink,
    );
    try std.testing.expect(!handled);
}

test "search plan terms can be parsed from visible model plan" {
    const terms = (try parseSearchPlanTerms(
        std.testing.allocator,
        "SEARCH_TERMS: readFileRange start_line max_lines FileRange lines",
    )) orelse return error.MissingTerms;
    defer std.testing.allocator.free(terms);

    try std.testing.expectEqualStrings("readFileRange start_line max_lines FileRange lines", terms);

    const context = try renderSearchPlanContext(std.testing.allocator, "qual parte le um pedaco de arquivo?");
    defer std.testing.allocator.free(context);
    try std.testing.expect(std.mem.indexOf(u8, context, "[SEARCH_PLAN v1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "SEARCH_TERMS:") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "stage=overview") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "identifier-like variants") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "file stems") != null);
}

test "model context budget audit records pre-send buckets without token estimates" {
    var db = try audit.AuditDb.open(std.testing.allocator, ":memory:");
    defer db.close();
    const rendered = try model_context.renderModelTurnContext(std.testing.allocator, .{
        .task = "corrigir",
        .contracts = "tools: collect_evidence",
        .evidence = &[_]model_context.EvidenceBlock{.{ .text = "packet_version=v1\n- E1 kind=file_range source=src/a.zig range=L1-L1 status=ok confidence=medium hash=1\nconst x = 1;" }},
        .next_action_v1 = .{ .kind = .collect_context, .text = "collect evidence" },
    });
    defer std.testing.allocator.free(rendered);

    var client = http.LocalModelClient{
        .allocator = std.testing.allocator,
        .host = "127.0.0.1:1",
        .backend = .llamacpp,
        .model = "fake",
    };
    defer client.deinit();
    _ = try recordModelContextBudget(std.testing.allocator, &db, "budget-audit", rendered, &client, .{
        .user_prompt = "corrigir",
        .model_context = rendered,
    });
    var events = try db.loadSessionEvents(std.testing.allocator, "budget-audit", 8);
    defer audit.freeAuditEvents(std.testing.allocator, &events);

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqualStrings("model_context_budget", events.items[0].kind);
    try std.testing.expect(std.mem.indexOf(u8, events.items[0].body, "pre_send=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, events.items[0].body, "tokenizer=unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, events.items[0].body, "token_estimate=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, events.items[0].body, "context_source=unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, events.items[0].body, "context_used_percent=unknown") != null);
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

    var client = http.LocalModelClient{
        .allocator = std.testing.allocator,
        .host = "127.0.0.1:1",
        .backend = .llamacpp,
        .model = "fake",
    };
    defer client.deinit();
    try std.testing.expectError(error.ModelContextBudgetExceeded, recordModelContextBudget(std.testing.allocator, &db, "budget-fail", large.items, &client, .{
        .user_prompt = "x",
        .model_context = large.items,
    }));
}

test "pathless collect evidence accepts model search text or task fallback" {
    const weak_xml =
        \\<tool_call>
        \\<function=collect_evidence>
        \\<parameter=strategy>auto</parameter>
        \\</function>
        \\</tool_call>
    ;
    const weak = (try tool_call.parseFirst(std.testing.allocator, weak_xml)) orelse return error.NoToolCall;
    defer weak.deinit(std.testing.allocator);
    try std.testing.expect(!collectEvidenceHasSearchText(&weak));
    try std.testing.expect(!collectEvidenceHasSearchPlaceholder(&weak));

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
    try std.testing.expect(collectEvidenceHasSearchText(&focused));
    try std.testing.expect(!collectEvidenceHasSearchPlaceholder(&focused));

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
    try std.testing.expect(collectEvidenceHasSearchText(&focused_v2));
    try std.testing.expect(!collectEvidenceHasSearchPlaceholder(&focused_v2));

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
    try std.testing.expect(collectEvidenceHasSearchText(&placeholder));
    try std.testing.expect(collectEvidenceHasSearchPlaceholder(&placeholder));

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
    try std.testing.expect(!collectEvidenceHasSearchPlaceholder(&path));

    const overview_xml =
        \\<tool_call>
        \\<function=collect_evidence>
        \\<parameter=strategy>auto</parameter>
        \\<parameter=stage>overview</parameter>
        \\</function>
        \\</tool_call>
    ;
    const overview = (try tool_call.parseFirst(std.testing.allocator, overview_xml)) orelse return error.NoToolCall;
    defer overview.deinit(std.testing.allocator);
    try std.testing.expect(!collectEvidenceHasSearchText(&overview));
    try std.testing.expect(isCollectEvidenceStage(&overview, "overview"));
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
    var state = ToolLoopState.init(std.testing.allocator);
    defer state.deinit();
    try state.rememberExecutedArgs(
        "src/render.zig",
        "markdown table renderer",
        .path,
        18,
        49,
        "ctx_render_table",
        "[EVIDENCE]\n- E1 kind=file_range source=src/render.zig range=L18-L49 status=ok confidence=medium hash=abc\npub fn AppendOnlyRenderer(comptime Writer: type) type {",
        180,
        72,
    );

    const repair = try renderCollectEvidenceSearchIntentRepairContext(
        std.testing.allocator,
        "qual e a funcao que renderiza o cli?",
        &state.context,
    );
    defer std.testing.allocator.free(repair);
    try std.testing.expect(std.mem.indexOf(u8, repair, "pathless collect_evidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, repair, "<parameter=intent>") != null);
    try std.testing.expect(std.mem.indexOf(u8, repair, "<parameter=terms>") != null);
    try std.testing.expect(std.mem.indexOf(u8, repair, "controller does not infer search terms") != null);
    try std.testing.expect(std.mem.indexOf(u8, repair, "[EVIDENCE]") != null);
    try std.testing.expect(std.mem.indexOf(u8, repair, "AppendOnlyRenderer") != null);
    try std.testing.expect(std.mem.indexOf(u8, repair, "Only collect_evidence is active for this repair") != null);
    try std.testing.expect(std.mem.indexOf(u8, repair, "search_session(intent") == null);

    const repair_contract = collectEvidenceRepairContract();
    try std.testing.expect(repair_contract.allows("collect_evidence"));
    try std.testing.expect(!repair_contract.allows("search_session"));
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

test "tool loop state treats duplicate working evidence as idempotent" {
    var state = ToolLoopState.init(std.testing.allocator);
    defer state.deinit();

    try state.rememberExecutedArgs("README.md", null, .path, 1, 12, "ctx_readme", "[EVIDENCE]\n- README.md L1-L12 hash=abc\n", 120, 72);
    try state.rememberExecutedArgs("README.md", null, .path, 1, 12, "ctx_readme_dup", "[EVIDENCE]\n- duplicate\n", 50, 1);

    try std.testing.expectEqual(@as(usize, 1), state.context.entries.items.len);
    try std.testing.expectEqualStrings("ctx_readme", state.context.entries.items[0].context_id);
    try std.testing.expect(std.mem.indexOf(u8, state.context.entries.items[0].evidence_text, "duplicate") == null);
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
    try std.testing.expect(std.mem.indexOf(u8, rendered, "not confirmed truth") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "judge direct support") != null);
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

fn testingCandidate(allocator: std.mem.Allocator, id: []const u8, path: []const u8, source: []const u8) !collect_evidence.CandidateItem {
    return .{
        .id = try allocator.dupe(u8, id),
        .path = try allocator.dupe(u8, path),
        .start_line = 1,
        .end_line = 12,
        .score = 100,
        .source = try allocator.dupe(u8, source),
        .signature = try allocator.dupe(u8, "pub fn sample() void"),
        .preview = try allocator.dupe(u8, "test"),
    };
}

test "diffuse pathless candidates are not treated as symbol identity" {
    var diffuse = [_]collect_evidence.CandidateItem{
        try testingCandidate(std.testing.allocator, "C1", "src/a.zig", "symbol_ast"),
        try testingCandidate(std.testing.allocator, "C2", "src/b.zig", "module_entrypoint"),
        try testingCandidate(std.testing.allocator, "C3", "src/c.zig", "fts_bm25"),
        try testingCandidate(std.testing.allocator, "C4", "src/d.zig", "prompt_path"),
    };
    defer {
        for (&diffuse) |candidate| candidate.deinit(std.testing.allocator);
    }

    var focused = [_]collect_evidence.CandidateItem{
        try testingCandidate(std.testing.allocator, "C1", "src/render.zig", "symbol_ast"),
        try testingCandidate(std.testing.allocator, "C2", "src/render.zig", "module_entrypoint"),
        try testingCandidate(std.testing.allocator, "C3", "src/render.zig", "fts_bm25"),
        try testingCandidate(std.testing.allocator, "C4", "src/other.zig", "symbol_ast"),
    };
    defer {
        for (&focused) |candidate| candidate.deinit(std.testing.allocator);
    }

    var local = [_]collect_evidence.CandidateItem{
        try testingCandidate(std.testing.allocator, "C1", "src/a.zig", "local_symbol_ast"),
        try testingCandidate(std.testing.allocator, "C2", "src/b.zig", "module_entrypoint"),
        try testingCandidate(std.testing.allocator, "C3", "src/c.zig", "fts_bm25"),
        try testingCandidate(std.testing.allocator, "C4", "src/d.zig", "prompt_path"),
    };
    defer {
        for (&local) |candidate| candidate.deinit(std.testing.allocator);
    }

    try std.testing.expect(pathlessCandidatesAreDiffuse(&diffuse));
    try std.testing.expect(!pathlessCandidatesAreDiffuse(&focused));
    try std.testing.expect(pathlessCandidatesAreDiffuse(&local));
}

test "candidate selection protocol fallback prefers structural candidate" {
    var state = ToolLoopState.init(std.testing.allocator);
    defer state.deinit();

    try state.candidates.append(std.testing.allocator, .{
        .id = try std.testing.allocator.dupe(u8, "C1"),
        .path = try std.testing.allocator.dupe(u8, "src/render.zig"),
        .start_line = 18,
        .end_line = 65,
        .score = 2150,
        .source = try std.testing.allocator.dupe(u8, "module_entrypoint"),
        .signature = try std.testing.allocator.dupe(u8, "pub fn AppendOnlyRenderer(comptime Writer: type) type {"),
        .preview = try std.testing.allocator.dupe(u8, "module_entrypoint"),
    });
    try state.candidates.append(std.testing.allocator, .{
        .id = try std.testing.allocator.dupe(u8, "C2"),
        .path = try std.testing.allocator.dupe(u8, "src/render.zig"),
        .start_line = 385,
        .end_line = 394,
        .score = 1662,
        .source = try std.testing.allocator.dupe(u8, "symbol_ast"),
        .signature = try std.testing.allocator.dupe(u8, "fn renderMarkdownPending(self: *Self, newline: bool) !void {"),
        .preview = try std.testing.allocator.dupe(u8, "symbol_ast"),
    });
    try std.testing.expectEqualStrings("C2", selectedCandidateForProtocolFallback(&state).?);

    for (state.candidates.items) |candidate| candidate.deinit(std.testing.allocator);
    state.candidates.clearRetainingCapacity();
    try state.candidates.append(std.testing.allocator, .{
        .id = try std.testing.allocator.dupe(u8, "C1"),
        .path = try std.testing.allocator.dupe(u8, "src/render.zig"),
        .start_line = 18,
        .end_line = 65,
        .score = 2150,
        .source = try std.testing.allocator.dupe(u8, "module_entrypoint"),
        .signature = try std.testing.allocator.dupe(u8, "pub fn AppendOnlyRenderer(comptime Writer: type) type {"),
        .preview = try std.testing.allocator.dupe(u8, "module_entrypoint"),
    });
    try std.testing.expectEqualStrings("C1", selectedCandidateForProtocolFallback(&state).?);
}

test "candidate expansion stays inside selected candidate range" {
    try std.testing.expectEqual(@as(usize, 15), candidateExpansionLineLimit(32, 77, 91));
    try std.testing.expectEqual(@as(usize, 8), candidateExpansionLineLimit(8, 77, 91));
    try std.testing.expect(std.mem.indexOf(u8, expandedCandidateNextAction(true, false), "called/related function whose declaration is not in E#") != null);
    try std.testing.expect(std.mem.indexOf(u8, expandedCandidateNextAction(true, false), "do not ask permission") != null);
    try std.testing.expect(std.mem.indexOf(u8, expandedCandidateNextAction(false, false), "Do not call tools again") != null);
}

test "visible candidate selection converts to expand tool call" {
    const selected = (try parseVisibleCandidateSelection(std.testing.allocator, "SELECTED_CANDIDATE: C4")) orelse return error.MissingCandidate;
    defer std.testing.allocator.free(selected);
    try std.testing.expectEqualStrings("C4", selected);
    const hidden_selected = (try parseVisibleCandidateSelection(std.testing.allocator, "<think>SELECTED_CANDIDATE: C5</think>")) orelse return error.MissingCandidate;
    defer std.testing.allocator.free(hidden_selected);
    try std.testing.expectEqualStrings("C5", hidden_selected);

    const call = (try visibleCandidateSelectionToToolCall(
        std.testing.allocator,
        "SELECTED_CANDIDATE: C4",
        "[TURN_CONTEXT v1]\n[CANDIDATES_CONTEXT]\n- C4 path=src/render.zig\n",
    )) orelse return error.MissingCandidate;
    defer call.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("collect_evidence", call.name);
    try std.testing.expectEqualStrings("expand", call.stage.?);
    try std.testing.expectEqualStrings("C4", call.selected_candidate.?);
    try std.testing.expectEqual(@as(usize, 32), call.max_lines);
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
    try state.rememberExecutedArgs("https://html.duckduckgo.com/html/?q=a", "short", .document_summary, 1, 1, "ctx_web", "[WEB_EVIDENCE]\nquery=short\n", 80, 30);
    try std.testing.expect(state.hasExecutedWebTarget("https://html.duckduckgo.com/html/?q=a", .document_summary));
    try std.testing.expect(!state.hasExecutedWebTarget("https://html.duckduckgo.com/html/?q=b", .document_summary));
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

test "collected evidence context can require a follow-up collection" {
    var state = ToolLoopState.init(std.testing.allocator);
    defer state.deinit();
    try state.rememberExecutedArgs(null, "render", .auto, 1, 12, "ctx_render", "[EVIDENCE]\n- src/render.zig L1-L12 hash=abc\n", 120, 40);

    const rendered = try renderCollectedEvidenceContextRequiringCollection(
        std.testing.allocator,
        "analise o projeto",
        &state.context,
        null,
        null,
        activeToolSchema(&state),
        "Emit one refined collect_evidence call before answering.",
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "kind=collect_context action=Emit one refined collect_evidence call before answering.") != null);
    try std.testing.expect(!initialContextRequiresTool(rendered));
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[MEMORY]") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[SKILLS]") == null);
}

test "explicit git evidence can finalize without required follow-up repair" {
    var state = ToolLoopState.init(std.testing.allocator);
    defer state.deinit();
    var auto_call = tool_call.ToolCall{ .name = try std.testing.allocator.dupe(u8, "collect_evidence") };
    defer auto_call.deinit(std.testing.allocator);
    try std.testing.expect(state.shouldRequireExploratoryRefinement(&auto_call, null, .auto));

    var git_call = tool_call.ToolCall{
        .name = try std.testing.allocator.dupe(u8, "collect_evidence"),
        .source = .git,
        .strategy = .reflog,
    };
    defer git_call.deinit(std.testing.allocator);
    try state.rememberExecutedArgs(null, "collect_evidence web_distillation", .reflog, 1, 12, "ctx_git", "[EVIDENCE]\n- E1 kind=git_reflog source=git\n", 240, 86);
    state.recordObservation();
    try std.testing.expect(!state.shouldRequireExploratoryRefinement(&git_call, null, .reflog));

    const rendered = try renderCollectedEvidenceContext(
        std.testing.allocator,
        "recupere commit removido",
        &state.context,
        null,
        null,
        activeToolSchema(&state),
        "Answer only if cited evidence directly covers the request.",
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "required_tool_calls") == null);
    try std.testing.expect(!initialContextRequiresTool(rendered));
}

test "overview evidence can answer broad workspace map without forced follow-up" {
    var state = ToolLoopState.init(std.testing.allocator);
    defer state.deinit();

    try std.testing.expect(shouldRequireOverviewRefinement(&state, 0));
    try std.testing.expect(!shouldRequireOverviewRefinement(&state, 48));
    try std.testing.expect(!shouldRequireOverviewRefinement(&state, weak_evidence_quality_score));
    state.forced_exploratory_refinements = 1;
    try std.testing.expect(!shouldRequireOverviewRefinement(&state, 48));
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
    try std.testing.expectEqual(contracts.ContractName.workflow, state.active_contract.name);
    try std.testing.expect(state.active_contract.allows("set_operational_contract"));
    try std.testing.expect(!state.active_contract.allows("collect_evidence"));
    try std.testing.expect(!state.active_contract.allows("web_search"));
    try std.testing.expect(!state.active_contract.allows("apply_patch"));
}

test "web evidence tools require model selected retrieval intent" {
    var missing_query = tool_call.ToolCall{
        .name = try std.testing.allocator.dupe(u8, "web_search"),
        .target = try std.testing.allocator.dupe(u8, "http://127.0.0.1/doc.html"),
    };
    defer missing_query.deinit(std.testing.allocator);
    try std.testing.expect(!webEvidenceHasModelIntent(&missing_query));

    var with_query = tool_call.ToolCall{
        .name = try std.testing.allocator.dupe(u8, "web_search"),
        .target = try std.testing.allocator.dupe(u8, "http://127.0.0.1/doc.html"),
        .terms = try std.testing.allocator.dupe(u8, "user requested web evidence about Phenom Web RAG"),
    };
    defer with_query.deinit(std.testing.allocator);
    try std.testing.expect(webEvidenceHasModelIntent(&with_query));

    var collect_with_intent = tool_call.ToolCall{
        .name = try std.testing.allocator.dupe(u8, "collect_evidence"),
        .target = try std.testing.allocator.dupe(u8, "http://127.0.0.1/doc.html"),
        .intent = try std.testing.allocator.dupe(u8, "summarize the explicit URL for the user"),
    };
    defer collect_with_intent.deinit(std.testing.allocator);
    try std.testing.expect(webEvidenceHasModelIntent(&collect_with_intent));
    try std.testing.expectEqualStrings("summarize the explicit URL for the user", declaredWebQuery(&collect_with_intent).?);
}

test "search web contract next action uses declared query from parser field" {
    var contract_call = tool_call.ToolCall{
        .name = try std.testing.allocator.dupe(u8, "set_operational_contract"),
        .contract = .search_web,
        .terms = try std.testing.allocator.dupe(u8, "Wesley Behemoth perfil biografia"),
        .target = try std.testing.allocator.dupe(u8, ""),
        .budget_bytes = 2048,
    };
    defer contract_call.deinit(std.testing.allocator);

    const rendered = try renderOperationalContractNextAction(std.testing.allocator, .search_web, &contract_call);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Wesley Behemoth perfil biografia") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "budget_bytes=2048") != null);
}

test "web search can derive explicit http target from declared query text" {
    const text = "https://ziglang.org/download/ stable version today";
    try std.testing.expectEqualStrings("https://ziglang.org/download/", explicitHttpTargetFromText(text).?);
    const stripped = try stripFirstHttpUrlFromText(std.testing.allocator, text);
    defer std.testing.allocator.free(stripped);
    try std.testing.expectEqualStrings("stable version today", stripped);
}

test "web query optimization output is one bounded query and rejects tool calls" {
    const query = (try normalizeWebQueryOptimizationOutput(std.testing.allocator, "criador kernel Linux Linus Torvalds fonte\nprosa extra")) orelse return error.MissingQuery;
    defer std.testing.allocator.free(query);
    try std.testing.expectEqualStrings("criador kernel Linux Linus Torvalds fonte", query);

    const long = (try normalizeWebQueryOptimizationOutput(std.testing.allocator, "um dois tres quatro cinco seis sete oito nove dez onze doze treze quatorze")) orelse return error.MissingQuery;
    defer std.testing.allocator.free(long);
    try std.testing.expectEqualStrings("um dois tres quatro cinco seis sete oito nove dez onze doze", long);

    const with_prose = (try normalizeWebQueryOptimizationOutput(std.testing.allocator, "Linus Torvalds criou o kernel Linux em 1991. Posso consultar fontes para confirmar.")) orelse return error.MissingQuery;
    defer std.testing.allocator.free(with_prose);
    try std.testing.expectEqualStrings("Linus Torvalds criou o kernel Linux em 1991", with_prose);

    const optimize_prompt = try renderWebQueryOptimizationPrompt(std.testing.allocator, "quem e Pessoa X?", "Pessoa X");
    defer std.testing.allocator.free(optimize_prompt);
    try std.testing.expect(std.mem.indexOf(u8, optimize_prompt, "Do not enrich it with facts") != null);

    try std.testing.expect(!optimizedQueryKeepsDeclaredCoverage("quem criou o kernel Linux", "quem"));
    try std.testing.expect(optimizedQueryKeepsDeclaredCoverage("quem criou o kernel Linux", "criador kernel Linux"));
    try std.testing.expect((try normalizeWebQueryOptimizationOutput(std.testing.allocator, "<tool_call><function=web_search></function></tool_call>")) == null);
}

test "built-in web search endpoint is available without env or config" {
    var saved_env: ?[:0]u8 = null;
    if (c.getenv("PHENOM_WEB_SEARCH_URL")) |value| {
        saved_env = try std.testing.allocator.dupeZ(u8, std.mem.span(value));
    }
    _ = c.unsetenv("PHENOM_WEB_SEARCH_URL");
    defer {
        if (saved_env) |value| {
            _ = c.setenv("PHENOM_WEB_SEARCH_URL", value.ptr, 1);
            std.testing.allocator.free(value);
        } else {
            _ = c.unsetenv("PHENOM_WEB_SEARCH_URL");
        }
    }

    const target = try web_rag.resolveSearchTargetWithTemplate(std.testing.allocator, null, "Wesley Beemot perfil", null);
    defer std.testing.allocator.free(target);
    try std.testing.expectEqualStrings("https://html.duckduckgo.com/html/?q=Wesley%20Beemot%20perfil", target);
}

test "web evidence budget is capped before model context insertion" {
    var call = tool_call.ToolCall{
        .name = try std.testing.allocator.dupe(u8, "collect_evidence"),
        .target = try std.testing.allocator.dupe(u8, "http://127.0.0.1/doc.html"),
        .http_search = true,
        .terms = try std.testing.allocator.dupe(u8, "horario de brasilia"),
        .budget_bytes = 32 * 1024,
    };
    defer call.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, max_web_evidence_budget), collectEvidenceBudgetForCall(&call, call.target, 64 * 1024));
    try std.testing.expectEqual(@as(usize, 512), collectWebEvidenceBudget(512, 64 * 1024));
    try std.testing.expectEqual(@as(usize, 128), collectWebEvidenceBudget(null, 128));

    var strategy_call = tool_call.ToolCall{
        .name = try std.testing.allocator.dupe(u8, "collect_evidence"),
        .strategy_id = try std.testing.allocator.dupe(u8, "collect_git_reflog"),
        .budget_bytes = 32 * 1024,
    };
    defer strategy_call.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 12000), collectEvidenceBudgetForCall(&strategy_call, null, 64 * 1024));
}

test "empty web evidence excerpt is detected structurally" {
    const empty =
        \\[EVIDENCE]
        \\E1:
        \\  [WEB_EVIDENCE]
        \\  status=200
        \\  query=latest zig
        \\  excerpt=
    ;
    const nonempty =
        \\[EVIDENCE]
        \\E1:
        \\  [WEB_EVIDENCE]
        \\  status=200
        \\  query=latest zig
        \\  excerpt=Zig 0.16.0
    ;
    try std.testing.expect(webEvidenceHasOnlyEmptyExcerpts(empty));
    try std.testing.expect(!webEvidenceHasOnlyEmptyExcerpts(nonempty));
    try std.testing.expect(!webEvidenceHasOnlyEmptyExcerpts("[EVIDENCE]\nexcerpt=\n"));
}

test "web final answer numeric literal must be present in web evidence" {
    const context =
        \\[EVIDENCE]
        \\E1:
        \\  [WEB_EVIDENCE]
        \\  query=latest zig
        \\  excerpt=Download the latest release of Zig from the official project page.
    ;
    try std.testing.expectEqualStrings("0.13.0", unsupportedWebAnswerLiteral("A versao mais recente e 0.13.0.", context).?);
    try std.testing.expect(unsupportedWebAnswerLiteral("Nao encontrei evidencia direta.", context) == null);
    try std.testing.expect(unsupportedWebAnswerLiteral("A versao evidenciada e 0.15.1.", "[WEB_EVIDENCE]\nexcerpt=Zig 0.15.1\n") == null);
}

test "plain URL in model prose does not synthesize web search" {
    var db = try audit.AuditDb.open(std.testing.allocator, ":memory:");
    defer db.close();
    var bus = ui_events.EventBus.init(std.testing.allocator);
    defer bus.deinit();
    var sink = StreamSink{
        .allocator = std.testing.allocator,
        .events = &bus,
        .db = &db,
        .session = "web-no-auto",
        .ui = null,
        .filter = reasoning_filter.ReasoningFilter.init(std.testing.allocator, true),
        .visible = std.ArrayList(u8).empty,
        .visible_bytes = 0,
        .thinking_bytes = 0,
        .defer_visible = true,
    };
    defer sink.deinit();
    var client = http.LocalModelClient{
        .allocator = std.testing.allocator,
        .host = "127.0.0.1:1",
        .backend = .llamacpp,
        .model = "fake",
        .thinking = .on,
    };
    defer client.deinit();

    const handled = try runToolLoopIterations(
        std.testing.allocator,
        std.testing.io,
        .{ .session = "web-no-auto", .backend = .llamacpp, .host = "127.0.0.1:1", .model = "fake" },
        "resuma http://127.0.0.1/doc.html se precisar",
        "Sem ferramenta chamada, nao coletei web automaticamente.",
        "Sem ferramenta chamada, nao coletei web automaticamente.",
        null,
        &client,
        &bus,
        &db,
        null,
        &sink,
    );
    try std.testing.expect(!handled);

    var events = try db.loadSessionEvents(std.testing.allocator, "web-no-auto", 20);
    defer audit.freeAuditEvents(std.testing.allocator, &events);
    for (events.items) |event| {
        try std.testing.expect(!std.mem.eql(u8, event.kind, "tool_start"));
        try std.testing.expect(std.mem.indexOf(u8, event.body, "web_search") == null);
    }
}

test "workflow starts without synthetic inspection fallback" {
    var state = ToolLoopState.init(std.testing.allocator);
    defer state.deinit();

    try std.testing.expectEqual(contracts.ContractName.workflow, state.active_contract.name);
    try std.testing.expect(!state.contract_selected);
    try std.testing.expect(state.active_contract.allows("set_operational_contract"));
    try std.testing.expect(!state.active_contract.allows("collect_evidence"));
    try std.testing.expect(!state.active_contract.allows("web_search"));
}

test "turn progress blocks finalization until selected contract is satisfied" {
    var state = ToolLoopState.init(std.testing.allocator);
    defer state.deinit();

    state.selectContract(contracts.activeContract(.answer_only).?, .{
        .requires_inspection = false,
        .requires_mutation = false,
        .requires_runtime_validation = false,
        .requires_browser_diagnostics = false,
        .requires_memory_promotion = false,
    });
    try std.testing.expect(state.finalizationBlocker() == null);

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

    state.selectContract(contracts.activeContract(.mutate_file).?, .{
        .requires_inspection = false,
        .requires_mutation = true,
        .requires_runtime_validation = false,
        .requires_browser_diagnostics = false,
        .requires_memory_promotion = false,
    });
    try std.testing.expectEqualStrings("a successful mutation is required before finalization", state.finalizationBlocker().?);
    state.recordMutation();
    try std.testing.expect(state.finalizationBlocker() == null);

    state.selectContract(contracts.activeContract(.validate_work).?, .{
        .requires_inspection = false,
        .requires_mutation = false,
        .requires_runtime_validation = true,
        .requires_browser_diagnostics = false,
        .requires_memory_promotion = false,
    });
    try std.testing.expectEqualStrings("runtime validation is required before finalization", state.finalizationBlocker().?);
    state.recordRuntimeValidation();
    try std.testing.expect(state.finalizationBlocker() == null);

    state.selectContract(contracts.activeContract(.memory).?, .{
        .requires_inspection = false,
        .requires_mutation = false,
        .requires_runtime_validation = false,
        .requires_browser_diagnostics = false,
        .requires_memory_promotion = false,
    });
    try std.testing.expectEqualStrings("persistent context search is required before finalization", state.finalizationBlocker().?);
    state.recordObservation();
    try std.testing.expectEqualStrings("persistent context search is required before finalization", state.finalizationBlocker().?);
    state.recordPersistentContextSearch();
    try std.testing.expect(state.finalizationBlocker() == null);
}

test "finalization repair context exposes only active contract tools" {
    var state = ToolLoopState.init(std.testing.allocator);
    defer state.deinit();
    state.selectContract(contracts.activeContract(.collect_evidence).?, .{
        .requires_inspection = true,
        .requires_mutation = false,
        .requires_runtime_validation = false,
        .requires_browser_diagnostics = false,
        .requires_memory_promotion = false,
    });

    const blocker = state.finalizationBlocker() orelse return error.MissingBlocker;
    const rendered = try renderFinalizationRepairContext(std.testing.allocator, "qual funcao coleta evidencia?", &state, blocker);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "[CONTRACTS]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "collect_evidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "set_operational_contract(") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "inspection evidence is required") != null);
    try std.testing.expect(std.mem.indexOf(u8, required_work_missing_answer, "[MODEL_PROTOCOL_ERROR]") == null);
    try std.testing.expect(std.mem.indexOf(u8, required_tool_missing_answer, "[MODEL_PROTOCOL_ERROR]") == null);
    try std.testing.expect(std.mem.indexOf(u8, required_tool_missing_answer, "required follow-up tool_call missing") == null);
}

test "allowed tools render compact audit list" {
    const active = contracts.activeContract(.mutate_file) orelse return error.MissingContract;
    const rendered = try renderAllowedTools(std.testing.allocator, active.allowed_tools);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("set_operational_contract,collect_evidence,search_session,apply_patch", rendered);
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

test "memory contract next action promotes durable user rule without forced search" {
    var contract_call = tool_call.ToolCall{
        .name = try std.testing.allocator.dupe(u8, "set_operational_contract"),
        .contract = .memory,
        .requires_memory_promotion = true,
        .reason = try std.testing.allocator.dupe(u8, "persist durable user rule"),
    };
    defer contract_call.deinit(std.testing.allocator);

    const rendered = try renderOperationalContractNextAction(std.testing.allocator, .memory, &contract_call);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "promote_context target=skills") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Do not search first") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Exact prior-session claims need S#") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "S# entries are candidates") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "direct support") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, rendered, "S# entries are candidates") != null);
}

test "grounding rules separate dialogue continuity from exact session evidence" {
    const rules = groundingRules();
    try std.testing.expect(hasGroundingRule(rules, "[RECENT_DIALOGUE]", "continuity"));
    try std.testing.expect(hasGroundingRule(rules, "[RECENT_DIALOGUE]", "S#"));
    try std.testing.expect(hasGroundingRule(rules, "collect_evidence", "retrieval keys"));
    try std.testing.expect(hasGroundingRule(rules, "search_session", "retrieval keys"));
    try std.testing.expect(hasGroundingRule(rules, "vague workspace/code tasks", "split targets"));
    try std.testing.expect(hasGroundingRule(rules, "history is unavailable", "search_session"));
    try std.testing.expect(hasGroundingRule(rules, "workspace/code context is required", "collect_evidence"));
    try std.testing.expect(hasGroundingRule(rules, "Named/obscure entities", "search_web/rag_web"));
    try std.testing.expect(hasGroundingRule(rules, "web_search fails operationally", "do not invent a replacement URL"));
    try std.testing.expect(hasGroundingRule(rules, "[CONTRACTS]", "not evidence"));
    try std.testing.expect(hasGroundingRule(rules, "S# entries", "candidates"));
    try std.testing.expect(hasGroundingRule(rules, "judge relevance", "direct support"));
    try std.testing.expect(hasGroundingRule(rules, "Near/partial matches", "not evidenced"));
    try std.testing.expect(hasGroundingRule(rules, "Quote only text present", "outside quote/code blocks"));
    try std.testing.expect(hasGroundingRule(rules, "retrieved MEMORY/SKILLS", "generic best practices"));
}

fn hasGroundingRule(rules: []const []const u8, a: []const u8, b: []const u8) bool {
    for (rules) |rule| {
        if (std.mem.indexOf(u8, rule, a) != null and std.mem.indexOf(u8, rule, b) != null) return true;
    }
    return false;
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
