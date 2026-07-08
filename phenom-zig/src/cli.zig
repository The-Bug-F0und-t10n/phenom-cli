const std = @import("std");

pub const Backend = enum {
    ollama,
    llamacpp,
};

pub const ThinkingMode = enum {
    auto,
    on,
    off,
};

pub const Command = enum {
    chat,
    probe,
    snapshot,
    version,
    help,
};

pub const Config = struct {
    command: Command = .help,
    session: []const u8 = "default",
    prompt: []const u8 = "",
    prompt_provided: bool = false,
    host: []const u8 = "127.0.0.1:11434",
    model: []const u8 = "llama3.2",
    backend: Backend = .ollama,
    max_tokens: u16 = 512,
    thinking: ThinkingMode = .auto,
    no_color: bool = false,
    offline: bool = false,
    fail_on_model_error: bool = false,
    expect_contains: ?[]const u8 = null,
    show_expect_status: bool = false,
    demo_read_file: ?[]const u8 = null,
};

pub fn parseArgs(args: []const []const u8) !Config {
    return parseArgsWithBase(Config{}, args);
}

pub fn parseArgsWithBase(base: Config, args: []const []const u8) !Config {
    var cfg = base;
    if (args.len <= 1) return cfg;

    if (std.mem.eql(u8, args[1], "chat")) {
        cfg.command = .chat;
    } else if (std.mem.eql(u8, args[1], "probe")) {
        cfg.command = .probe;
    } else if (std.mem.eql(u8, args[1], "snapshot")) {
        cfg.command = .snapshot;
    } else if (std.mem.eql(u8, args[1], "version") or std.mem.eql(u8, args[1], "--version")) {
        cfg.command = .version;
        return cfg;
    } else {
        cfg.command = .help;
        return cfg;
    }

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--session")) {
            i += 1;
            if (i >= args.len) return error.MissingSession;
            cfg.session = args[i];
        } else if (std.mem.eql(u8, arg, "--prompt")) {
            i += 1;
            if (i >= args.len) return error.MissingPrompt;
            cfg.prompt = args[i];
            cfg.prompt_provided = true;
        } else if (std.mem.eql(u8, arg, "--host")) {
            i += 1;
            if (i >= args.len) return error.MissingHost;
            cfg.host = args[i];
        } else if (std.mem.eql(u8, arg, "--model")) {
            i += 1;
            if (i >= args.len) return error.MissingModel;
            cfg.model = args[i];
        } else if (std.mem.eql(u8, arg, "--backend")) {
            i += 1;
            if (i >= args.len) return error.MissingBackend;
            if (std.mem.eql(u8, args[i], "ollama")) cfg.backend = .ollama else if (std.mem.eql(u8, args[i], "llamacpp")) cfg.backend = .llamacpp else return error.UnknownBackend;
        } else if (std.mem.eql(u8, arg, "--max-tokens")) {
            i += 1;
            if (i >= args.len) return error.MissingMaxTokens;
            cfg.max_tokens = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--thinking")) {
            i += 1;
            if (i >= args.len) return error.MissingThinkingMode;
            if (std.mem.eql(u8, args[i], "auto")) {
                cfg.thinking = .auto;
            } else if (std.mem.eql(u8, args[i], "on")) {
                cfg.thinking = .on;
            } else if (std.mem.eql(u8, args[i], "off")) {
                cfg.thinking = .off;
            } else {
                return error.UnknownThinkingMode;
            }
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            cfg.no_color = true;
        } else if (std.mem.eql(u8, arg, "--offline")) {
            cfg.offline = true;
        } else if (std.mem.eql(u8, arg, "--fail-on-model-error")) {
            cfg.fail_on_model_error = true;
        } else if (std.mem.eql(u8, arg, "--expect-contains")) {
            i += 1;
            if (i >= args.len) return error.MissingExpectedText;
            cfg.expect_contains = args[i];
        } else if (std.mem.eql(u8, arg, "--show-expect-status")) {
            cfg.show_expect_status = true;
        } else if (std.mem.eql(u8, arg, "--demo-read-file")) {
            i += 1;
            if (i >= args.len) return error.MissingPath;
            cfg.demo_read_file = args[i];
        } else {
            return error.UnknownArgument;
        }
    }

    return cfg;
}

pub fn printUsage(writer: anytype) !void {
    try writer.writeAll(
        \\phenom-zig
        \\  Produto Phenom em Zig + C para agente CLI/TUI, tool loop e contexto auditavel.
        \\
        \\commands:
        \\  chat [--prompt TEXT] [--session ID] [--offline]
        \\  chat --backend ollama|llamacpp --host HOST:PORT --model MODEL --prompt TEXT
        \\  probe --backend ollama|llamacpp --host HOST:PORT
        \\  snapshot
        \\  version
        \\
        \\options:
        \\  --no-color
        \\  --max-tokens N
        \\  --thinking auto|on|off
        \\  --fail-on-model-error
        \\  --expect-contains TEXT
        \\  --show-expect-status
        \\  --demo-read-file PATH
        \\
        \\config:
        \\  reads ./config.toml, then ~/.config/phenom/config.toml when local config is absent
        \\  flags override config values
        \\  keys: backend, host, port, server, model, thinking, max_tokens, no_color,
        \\        offline, fail_on_model_error, expect_contains, show_expect_status,
        \\        demo_read_file, session
        \\
    );
}

test "parse args preserves config defaults and lets flags override" {
    const base = Config{
        .host = "192.168.1.122:11434",
        .model = "phenom:latest",
        .backend = .llamacpp,
        .thinking = .on,
        .max_tokens = 128,
    };
    const args = &.{ "phenom", "chat", "--thinking", "off" };
    const cfg = try parseArgsWithBase(base, args);
    try std.testing.expectEqual(Command.chat, cfg.command);
    try std.testing.expectEqualStrings("192.168.1.122:11434", cfg.host);
    try std.testing.expectEqualStrings("phenom:latest", cfg.model);
    try std.testing.expectEqual(Backend.llamacpp, cfg.backend);
    try std.testing.expectEqual(ThinkingMode.off, cfg.thinking);
    try std.testing.expectEqual(@as(u16, 128), cfg.max_tokens);
}

test "parse probe args" {
    const args = &.{ "phenom", "probe", "--backend", "llamacpp", "--host", "192.168.1.122:11434" };
    const cfg = try parseArgs(args);
    try std.testing.expectEqual(Command.probe, cfg.command);
    try std.testing.expectEqual(Backend.llamacpp, cfg.backend);
    try std.testing.expectEqualStrings("192.168.1.122:11434", cfg.host);
}

test "parse chat args" {
    const args = &.{ "phenom", "chat", "--session", "s1", "--prompt", "ola", "--backend", "llamacpp", "--host", "127.0.0.1:8080", "--model", "local", "--max-tokens", "32", "--thinking", "on", "--no-color" };
    const cfg = try parseArgs(args);
    try std.testing.expectEqual(Command.chat, cfg.command);
    try std.testing.expect(std.mem.eql(u8, cfg.session, "s1"));
    try std.testing.expect(std.mem.eql(u8, cfg.prompt, "ola"));
    try std.testing.expect(cfg.prompt_provided);
    try std.testing.expectEqual(Backend.llamacpp, cfg.backend);
    try std.testing.expectEqual(@as(u16, 32), cfg.max_tokens);
    try std.testing.expectEqual(ThinkingMode.on, cfg.thinking);
    try std.testing.expect(cfg.no_color);
}

test "parse chat without prompt enables interactive mode" {
    const args = &.{ "phenom", "chat", "--offline" };
    const cfg = try parseArgs(args);
    try std.testing.expectEqual(Command.chat, cfg.command);
    try std.testing.expect(cfg.offline);
    try std.testing.expect(!cfg.prompt_provided);
    try std.testing.expectEqualStrings("", cfg.prompt);
}

test "parse expected visible output assertion" {
    const args = &.{ "phenom", "chat", "--prompt", "ola", "--expect-contains", "PHENOM_REAL_7319" };
    const cfg = try parseArgs(args);
    try std.testing.expectEqual(Command.chat, cfg.command);
    try std.testing.expectEqualStrings("PHENOM_REAL_7319", cfg.expect_contains.?);
}

test "parse visible expectation status flag" {
    const args = &.{ "phenom", "chat", "--prompt", "ola", "--expect-contains", "ok", "--show-expect-status" };
    const cfg = try parseArgs(args);
    try std.testing.expectEqualStrings("ok", cfg.expect_contains.?);
    try std.testing.expect(cfg.show_expect_status);
}
