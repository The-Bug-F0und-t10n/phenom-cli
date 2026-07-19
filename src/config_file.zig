const std = @import("std");

const cli = @import("cli.zig");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
});

const max_config_bytes = 64 * 1024;

pub const LoadedConfig = struct {
    config: cli.Config = .{},
    text: ?[]u8 = null,
    owned_host: ?[]u8 = null,

    pub fn deinit(self: *LoadedConfig, allocator: std.mem.Allocator) void {
        if (self.owned_host) |host| allocator.free(host);
        if (self.text) |text| allocator.free(text);
        self.* = .{};
    }
};

pub fn load(allocator: std.mem.Allocator, args: []const []const u8) !LoadedConfig {
    var loaded = try loadFileDefaults(allocator);
    errdefer loaded.deinit(allocator);
    loaded.config = try cli.parseArgsWithBase(loaded.config, args);
    return loaded;
}

fn loadFileDefaults(allocator: std.mem.Allocator) !LoadedConfig {
    var loaded = LoadedConfig{};
    if (try readIfExists(allocator, "config.toml")) |text| {
        loaded.text = text;
        try parseTomlSubset(allocator, &loaded, text);
        return loaded;
    }
    const path = configHomePath(allocator) catch |err| switch (err) {
        error.HomeNotSet => return loaded,
        else => return err,
    };
    defer allocator.free(path);
    if (try readIfExists(allocator, path)) |text| {
        loaded.text = text;
        try parseTomlSubset(allocator, &loaded, text);
    }
    return loaded;
}

fn readIfExists(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const z_path = try allocator.dupeZ(u8, path);
    defer allocator.free(z_path);
    if (c.access(z_path.ptr, c.F_OK) != 0) return null;
    const file = c.fopen(z_path.ptr, "rb") orelse return error.ConfigReadFailed;
    defer _ = c.fclose(file);

    if (c.fseek(file, 0, c.SEEK_END) != 0) return error.ConfigReadFailed;
    const size_raw = c.ftell(file);
    if (size_raw < 0) return error.ConfigReadFailed;
    const size: usize = @intCast(size_raw);
    if (size > max_config_bytes) return error.StreamTooLong;
    if (c.fseek(file, 0, c.SEEK_SET) != 0) return error.ConfigReadFailed;

    const out = try allocator.alloc(u8, size);
    errdefer allocator.free(out);
    const read = c.fread(out.ptr, 1, size, file);
    if (read != size) return error.ConfigReadFailed;
    return out;
}

fn configHomePath(allocator: std.mem.Allocator) ![]u8 {
    const home_ptr = c.getenv("HOME") orelse return error.HomeNotSet;
    const home = std.mem.span(home_ptr);
    if (home.len == 0) return error.HomeNotSet;
    return std.fs.path.join(allocator, &.{ home, ".config", "phenom", "config.toml" });
}

fn parseTomlSubset(allocator: std.mem.Allocator, loaded: *LoadedConfig, text: []u8) !void {
    var host_part: ?[]const u8 = null;
    var server: ?[]const u8 = null;
    var port: ?u16 = null;

    var start: usize = 0;
    while (start <= text.len) {
        const rel_end = std.mem.indexOfScalar(u8, text[start..], '\n') orelse text.len - start;
        const raw = text[start .. start + rel_end];
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len > 0 and line[0] != '#') {
            if (!(line[0] == '[' and line[line.len - 1] == ']')) {
                const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidConfigLine;
                const key = std.mem.trim(u8, line[0..eq], " \t");
                const raw_value = stripInlineComment(std.mem.trim(u8, line[eq + 1 ..], " \t"));
                const value = try parseValue(raw_value);
                try applyKey(&loaded.config, key, value, &host_part, &server, &port);
            }
        }
        if (start + rel_end >= text.len) break;
        start += rel_end + 1;
    }

    if (host_part != null or port != null) {
        const host = host_part orelse "127.0.0.1";
        if (port) |p| {
            loaded.owned_host = try std.fmt.allocPrint(allocator, "{s}:{}", .{ stripPort(host), p });
            loaded.config.host = loaded.owned_host.?;
        } else {
            loaded.config.host = host;
        }
    } else if (server) |value| {
        loaded.config.host = value;
    }
}

fn applyKey(
    cfg: *cli.Config,
    key: []const u8,
    value: []const u8,
    host_part: *?[]const u8,
    server: *?[]const u8,
    port: *?u16,
) !void {
    if (std.mem.eql(u8, key, "session")) {
        cfg.session = value;
    } else if (std.mem.eql(u8, key, "server")) {
        server.* = value;
    } else if (std.mem.eql(u8, key, "host")) {
        host_part.* = value;
    } else if (std.mem.eql(u8, key, "port")) {
        port.* = try std.fmt.parseInt(u16, value, 10);
    } else if (std.mem.eql(u8, key, "model")) {
        cfg.model = value;
    } else if (std.mem.eql(u8, key, "backend")) {
        cfg.backend = parseBackend(value) orelse return error.UnknownBackend;
    } else if (std.mem.eql(u8, key, "max_tokens")) {
        cfg.max_tokens = try std.fmt.parseInt(u16, value, 10);
    } else if (std.mem.eql(u8, key, "thinking")) {
        cfg.thinking = parseThinking(value) orelse return error.UnknownThinkingMode;
    } else if (std.mem.eql(u8, key, "no_color")) {
        cfg.no_color = try parseBool(value);
    } else if (std.mem.eql(u8, key, "offline")) {
        cfg.offline = try parseBool(value);
    } else if (std.mem.eql(u8, key, "fail_on_model_error")) {
        cfg.fail_on_model_error = try parseBool(value);
    } else if (std.mem.eql(u8, key, "expect_contains")) {
        cfg.expect_contains = value;
    } else if (std.mem.eql(u8, key, "show_expect_status")) {
        cfg.show_expect_status = try parseBool(value);
    } else if (std.mem.eql(u8, key, "demo_read_file")) {
        cfg.demo_read_file = value;
    } else {
        return error.UnknownConfigKey;
    }
}

fn stripInlineComment(value: []const u8) []const u8 {
    var in_quote = false;
    var quote: u8 = 0;
    for (value, 0..) |ch, i| {
        if ((ch == '"' or ch == '\'') and (i == 0 or value[i - 1] != '\\')) {
            if (!in_quote) {
                in_quote = true;
                quote = ch;
            } else if (quote == ch) {
                in_quote = false;
            }
        } else if (ch == '#' and !in_quote) {
            return std.mem.trim(u8, value[0..i], " \t");
        }
    }
    return std.mem.trim(u8, value, " \t");
}

fn parseValue(raw: []const u8) ![]const u8 {
    if (raw.len >= 2 and ((raw[0] == '"' and raw[raw.len - 1] == '"') or (raw[0] == '\'' and raw[raw.len - 1] == '\''))) {
        return raw[1 .. raw.len - 1];
    }
    if (raw.len == 0) return error.EmptyConfigValue;
    return raw;
}

fn parseBackend(value: []const u8) ?cli.Backend {
    if (std.mem.eql(u8, value, "ollama")) return .ollama;
    if (std.mem.eql(u8, value, "llamacpp")) return .llamacpp;
    return null;
}

fn parseThinking(value: []const u8) ?cli.ThinkingMode {
    if (std.mem.eql(u8, value, "auto")) return .auto;
    if (std.mem.eql(u8, value, "on")) return .on;
    if (std.mem.eql(u8, value, "off")) return .off;
    return null;
}

fn parseBool(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.InvalidBool;
}

fn stripPort(host: []const u8) []const u8 {
    if (std.mem.startsWith(u8, host, "http://")) {
        const without_scheme = host["http://".len..];
        if (std.mem.indexOfScalar(u8, without_scheme, ':')) |idx| return without_scheme[0..idx];
        return without_scheme;
    }
    if (std.mem.indexOfScalar(u8, host, ':')) |idx| return host[0..idx];
    return host;
}

test "config file applies host port and flags override" {
    var text =
        \\backend = "llamacpp"
        \\host = "192.168.1.122"
        \\port = 11434
        \\model = "phenom:latest"
        \\thinking = "on"
        \\max_tokens = 256
        \\no_color = true
    .*;
    var loaded = LoadedConfig{};
    defer loaded.deinit(std.testing.allocator);
    try parseTomlSubset(std.testing.allocator, &loaded, &text);
    const args = &.{ "phenom", "chat", "--thinking", "off" };
    const cfg = try cli.parseArgsWithBase(loaded.config, args);
    try std.testing.expectEqual(cli.Command.chat, cfg.command);
    try std.testing.expectEqual(cli.Backend.llamacpp, cfg.backend);
    try std.testing.expectEqualStrings("192.168.1.122:11434", cfg.host);
    try std.testing.expectEqualStrings("phenom:latest", cfg.model);
    try std.testing.expectEqual(cli.ThinkingMode.off, cfg.thinking);
    try std.testing.expectEqual(@as(u16, 256), cfg.max_tokens);
    try std.testing.expect(cfg.no_color);
}

test "config file accepts server alias" {
    var text =
        \\server = "http://127.0.0.1:8080"
        \\backend = "llamacpp"
    .*;
    var loaded = LoadedConfig{};
    defer loaded.deinit(std.testing.allocator);
    try parseTomlSubset(std.testing.allocator, &loaded, &text);
    try std.testing.expectEqualStrings("http://127.0.0.1:8080", loaded.config.host);
    try std.testing.expectEqual(cli.Backend.llamacpp, loaded.config.backend);
}
