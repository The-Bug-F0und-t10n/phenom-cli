const std = @import("std");

const c = @cImport({
    @cInclude("arpa/inet.h");
    @cInclude("ctype.h");
    @cInclude("fcntl.h");
    @cInclude("netinet/in.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("sys/socket.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
});

const Mode = enum {
    simple_greeting,
    git_evidence,
    agent_patch,
    phenom_md,
    web_rag,
    ambiguous_web,
    query_web,
    parse_error,
    think_only,
    rule_promotion,
    linear_web_workspace,
    required_tool_repair,
    memory_blocking,
};

const State = struct {
    mode: Mode,
    fd: c_int,
    port_file: []const u8,
    log_file: ?[]const u8,
    expect: []const u8 = "",
    port: u16 = 0,
    completions: usize = 0,
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer it.deinit();
    _ = it.next();
    const mode_arg = it.next() orelse return usage();
    const port_file = it.next() orelse return usage();
    const log_arg = it.next();
    const expect_arg = it.next();

    var state = State{
        .mode = parseMode(mode_arg) orelse return usage(),
        .fd = try listenLocal(),
        .port_file = port_file,
        .log_file = if (log_arg) |arg| if (std.mem.eql(u8, arg, "-")) null else arg else null,
        .expect = expect_arg orelse "",
    };
    defer _ = c.close(state.fd);

    state.port = try boundPort(state.fd);
    const port_text = try std.fmt.allocPrint(allocator, "{}", .{state.port});
    defer allocator.free(port_text);
    try writeFile(state.port_file, port_text);

    if (state.mode == .memory_blocking) return blockingServer(&state);
    while (state.completions < maxCompletions(state.mode)) {
        var addr: c.sockaddr_in = undefined;
        var addr_len: c.socklen_t = @sizeOf(c.sockaddr_in);
        const client = c.accept(state.fd, @ptrCast(&addr), &addr_len);
        if (client < 0) return error.AcceptFailed;
        handleClient(allocator, &state, client) catch {};
        _ = c.close(client);
    }
}

fn usage() error{InvalidArgs} {
    writeErr("usage: scripted_backend <mode> <port-file> [log-file|-] [expect]\n");
    return error.InvalidArgs;
}

fn writeErr(text: []const u8) void {
    _ = c.write(2, text.ptr, text.len);
}

fn parseMode(raw: []const u8) ?Mode {
    inline for (@typeInfo(Mode).@"enum".fields) |field| {
        if (std.mem.eql(u8, raw, field.name)) return @field(Mode, field.name);
    }
    return null;
}

fn listenLocal() !c_int {
    const fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.close(fd);
    var yes: c_int = 1;
    _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_REUSEADDR, &yes, @sizeOf(c_int));
    var addr: c.sockaddr_in = std.mem.zeroes(c.sockaddr_in);
    addr.sin_family = @intCast(c.AF_INET);
    addr.sin_port = c.htons(0);
    addr.sin_addr.s_addr = c.htonl(0x7f000001);
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr_in)) != 0) return error.BindFailed;
    if (c.listen(fd, 64) != 0) return error.ListenFailed;
    return fd;
}

fn boundPort(fd: c_int) !u16 {
    var addr: c.sockaddr_in = undefined;
    var len: c.socklen_t = @sizeOf(c.sockaddr_in);
    if (c.getsockname(fd, @ptrCast(&addr), &len) != 0) return error.SocketFailed;
    return c.ntohs(addr.sin_port);
}

fn maxCompletions(mode: Mode) usize {
    return switch (mode) {
        .simple_greeting => 2,
        .git_evidence => 3,
        .agent_patch => 4,
        .phenom_md => 2,
        .web_rag => 7,
        .ambiguous_web => 12,
        .query_web => 3,
        .parse_error => 2,
        .think_only => 2,
        .rule_promotion => 7,
        .linear_web_workspace => 10,
        .required_tool_repair => 4,
        .memory_blocking => 0,
    };
}

fn blockingServer(state: *State) !void {
    var addr: c.sockaddr_in = undefined;
    var addr_len: c.socklen_t = @sizeOf(c.sockaddr_in);
    const client = c.accept(state.fd, @ptrCast(&addr), &addr_len);
    if (client < 0) return error.AcceptFailed;
    defer _ = c.close(client);
    _ = c.sleep(60);
}

const Request = struct {
    method: []const u8,
    path: []const u8,
    body: []const u8,
};

fn handleClient(allocator: std.mem.Allocator, state: *State, client: c_int) !void {
    var buf: [256 * 1024]u8 = undefined;
    const req = try readRequest(client, &buf);
    if (std.mem.eql(u8, req.method, "GET") and std.mem.eql(u8, req.path, "/props")) {
        const body = if (state.mode == .rule_promotion)
            "{\"default_generation_settings\":{\"n_ctx\":65536}}"
        else if (state.mode == .git_evidence or state.mode == .agent_patch or state.mode == .think_only or state.mode == .required_tool_repair)
            "{\"n_ctx\":8192}"
        else
            "{\"n_ctx\":65536}";
        return send(client, "200 OK", "application/json", body);
    }
    if (std.mem.eql(u8, req.method, "POST") and std.mem.eql(u8, req.path, "/tokenize")) {
        if (state.mode == .think_only) return sendManyTokens(client, 2048);
        return send(client, "200 OK", "application/json", "{\"tokens\":[1,2,3,4,5,6,7,8]}");
    }
    if (std.mem.eql(u8, req.method, "GET") and std.mem.startsWith(u8, req.path, "/search")) {
        return handleSearch(client, state.mode, req.path);
    }
    if (std.mem.eql(u8, req.method, "GET") and state.mode == .web_rag and std.mem.eql(u8, req.path, "/doc.html")) {
        return send(client, "200 OK", "text/html", "<html><head><title>Phenom Web RAG</title></head><body><h1>Phenom Web RAG</h1><p>Contrato web_search fornece evidencia externa destilada para respostas e collect_evidence.</p></body></html>");
    }
    if (std.mem.eql(u8, req.method, "GET") and state.mode == .linear_web_workspace) {
        if (std.mem.eql(u8, req.path, "/doc-alpha.html")) return send(client, "200 OK", "text/html", "<html><head><title>Alpha RAG Doc</title></head><body><p>Alpha Web RAG evidence says PHENOM_WEB_ALPHA_FACT and explains distilled external retrieval.</p><p>Raw filler should not be persisted as HTML.</p></body></html>");
        if (std.mem.eql(u8, req.path, "/doc-beta.html")) return send(client, "200 OK", "text/html", "<html><head><title>Beta RAG Doc</title></head><body><p>Beta Web RAG evidence says PHENOM_WEB_BETA_FACT and complements local config comparison.</p></body></html>");
    }
    if (std.mem.eql(u8, req.method, "POST") and std.mem.eql(u8, req.path, "/v1/chat/completions")) {
        if (state.log_file) |path| try appendPromptLog(allocator, path, state.completions + 1, req.body);
        const text = try completionText(allocator, state, req.body);
        return sendSse(client, text);
    }
    try send(client, "404 Not Found", "text/plain", "not found");
}

fn readRequest(client: c_int, buf: []u8) !Request {
    var len: usize = 0;
    while (std.mem.indexOf(u8, buf[0..len], "\r\n\r\n") == null) {
        const n = c.recv(client, buf[len..].ptr, buf.len - len, 0);
        if (n <= 0) return error.RecvFailed;
        len += @intCast(n);
    }
    const split = std.mem.indexOf(u8, buf[0..len], "\r\n\r\n").?;
    const head = buf[0..split];
    var headers = std.mem.splitSequence(u8, head, "\r\n");
    const first = headers.next() orelse return error.BadRequest;
    var first_parts = std.mem.splitScalar(u8, first, ' ');
    const method = first_parts.next() orelse return error.BadRequest;
    const path = first_parts.next() orelse return error.BadRequest;
    var content_len: usize = 0;
    while (headers.next()) |line| {
        if (startsIgnoreCase(line, "content-length:")) {
            content_len = try std.fmt.parseInt(usize, std.mem.trim(u8, line["content-length:".len..], " \t"), 10);
        }
    }
    const body_start = split + 4;
    while (len - body_start < content_len) {
        const n = c.recv(client, buf[len..].ptr, buf.len - len, 0);
        if (n <= 0) return error.RecvFailed;
        len += @intCast(n);
    }
    return .{ .method = method, .path = path, .body = buf[body_start .. body_start + content_len] };
}

fn startsIgnoreCase(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}

fn writeFile(path: []const u8, data: []const u8) !void {
    const z_path = try std.heap.page_allocator.dupeZ(u8, path);
    defer std.heap.page_allocator.free(z_path);
    const fd = c.open(z_path.ptr, c.O_CREAT | c.O_TRUNC | c.O_WRONLY, @as(c_uint, 0o644));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    try writeFdAll(fd, data);
}

fn appendPromptLog(allocator: std.mem.Allocator, path: []const u8, index: usize, body: []const u8) !void {
    const z_path = try allocator.dupeZ(u8, path);
    defer allocator.free(z_path);
    const fd = c.open(z_path.ptr, c.O_CREAT | c.O_APPEND | c.O_WRONLY, @as(c_uint, 0o644));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var header_buf: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "---REQUEST {}---\n", .{index});
    try writeFdAll(fd, header);
    try writeFdAll(fd, body);
    try writeFdAll(fd, "\n");
}

fn writeFdAll(fd: c_int, data: []const u8) !void {
    var offset: usize = 0;
    while (offset < data.len) {
        const n = c.write(fd, data[offset..].ptr, data.len - offset);
        if (n <= 0) return error.WriteFailed;
        offset += @intCast(n);
    }
}

fn completionText(allocator: std.mem.Allocator, state: *State, body: []const u8) ![]const u8 {
    if (state.mode == .web_rag and contains(body, "[WEB_QUERY_OPTIMIZATION]")) return "Phenom Web RAG contrato";
    if (state.mode == .linear_web_workspace and contains(body, "[WEB_QUERY_OPTIMIZATION]")) {
        return if (contains(body, "alpha") or contains(body, "Alpha")) "Alpha Web RAG PHENOM_WEB_ALPHA_FACT" else "Beta Web RAG PHENOM_WEB_BETA_FACT";
    }
    if (state.mode == .web_rag and contains(body, "[WEB_DISTILLATION_TASK]")) {
        return try std.fmt.allocPrint(allocator, "[WEB_EVIDENCE]\nsource=http_get raw_context_persisted=false distill=model_summary target=http://127.0.0.1:{}/doc.html\nstatus=200\nquery=Phenom Web RAG contrato\ntitle=Phenom Web RAG\nexcerpt=Phenom Web RAG fornece evidencia contratual externa destilada para respostas.", .{state.port});
    }
    if (state.mode == .linear_web_workspace and contains(body, "[WEB_DISTILLATION_TASK]")) {
        return if (contains(body, "PHENOM_WEB_ALPHA_FACT"))
            try std.fmt.allocPrint(allocator, "[WEB_EVIDENCE]\nsource=http_get raw_context_persisted=false distill=model_summary target=http://127.0.0.1:{}/doc-alpha.html\nstatus=200\nquery=Alpha Web RAG PHENOM_WEB_ALPHA_FACT\ntitle=Alpha RAG Doc\nexcerpt=Alpha Web RAG evidence says PHENOM_WEB_ALPHA_FACT and explains distilled external retrieval.", .{state.port})
        else
            try std.fmt.allocPrint(allocator, "[WEB_EVIDENCE]\nsource=http_get raw_context_persisted=false distill=model_summary target=http://127.0.0.1:{}/doc-beta.html\nstatus=200\nquery=Beta Web RAG PHENOM_WEB_BETA_FACT\ntitle=Beta RAG Doc\nexcerpt=Beta Web RAG evidence says PHENOM_WEB_BETA_FACT and complements local config comparison.", .{state.port});
    }
    const idx = state.completions;
    state.completions += 1;
    return switch (state.mode) {
        .simple_greeting => if (idx == 0) "O usuario apenas cumprimentou. Responder curto.\n</think>\n\n" else "Olá! Como posso ajudar?\nPHENOM_SIMPLE_GREETING_OK",
        .git_evidence => gitEvidence(idx, state.expect),
        .agent_patch => if (idx == 2) try agentPatchDynamic(allocator, body) else agentPatch(idx),
        .phenom_md => if (idx == 0) "I cannot create that file from the provided context." else "Phenom.md carregado no system prompt. PHENOM_MD_PROMPT_USED_OK",
        .web_rag => try webRag(allocator, idx, state.port),
        .ambiguous_web => ambiguousWeb(idx),
        .query_web => queryWeb(idx, state.expect),
        .parse_error => if (idx == 0) "vou usar uma ferramenta\n</think>\n<tool_call>\n<function=set_operational_contract>\n<parameter=contract>unknown_contract</parameter>\n</function>\n</tool_call>" else "resposta final\n</think>\nFormato corrigido. Resposta direta final. PHENOM_PARSE_ERROR_REPAIRED",
        .think_only => if (idx == 0) "<think>The user says there is no cmus history in .config. I need to explain cmus state files and avoid claiming a history file exists.</think>" else "Voce esta certo: cmus nao grava um historico de reproducao em ~/.config por padrao.\nCMUS_HISTORY_OK",
        .rule_promotion => rulePromotion(idx),
        .linear_web_workspace => try linearWebWorkspace(allocator, idx, state.port),
        .required_tool_repair => requiredToolRepair(idx),
        .memory_blocking => unreachable,
    };
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn gitEvidence(idx: usize, expect: []const u8) []const u8 {
    return switch (idx) {
        0 => "selecionar contrato para evidencia git\n</think>\n\n<tool_call><function=set_operational_contract><parameter=requiresInspection>true</parameter><parameter=requiresMutation>false</parameter><parameter=requiresRuntimeValidation>false</parameter><parameter=requiresBrowserDiagnostics>false</parameter><parameter=reason>investigar historico git via collect_evidence</parameter></function></tool_call>",
        1 => "coletar reflog sem trocar para busca textual\n</think>\n\n<tool_call><function=collect_evidence><parameter=strategyId>collect_git_reflog</parameter><parameter=intent>recover deleted commit touching collect_evidence</parameter><parameter=terms>collect_evidence web_distillation</parameter><parameter=budget_bytes>12000</parameter></function></tool_call>",
        else => if (expect.len > 0) "responder com evidencia git\n</think>\n\nE1 contem GIT_REFLOG e mostra o commit removido 'deleted commit touching collect_evidence web_distillation'. PHENOM_GIT_REFLOG_OK" else "",
    };
}

fn agentPatch(idx: usize) []const u8 {
    return switch (idx) {
        0 => "preciso selecionar contrato de mutacao\n</think>\n\n<tool_call><function=set_operational_contract><parameter=requiresInspection>true</parameter><parameter=requiresMutation>true</parameter><parameter=requiresRuntimeValidation>false</parameter><parameter=requiresBrowserDiagnostics>false</parameter><parameter=reason>editar arquivo com evidencia local</parameter></function></tool_call>",
        1 => "preciso ler o arquivo antes de editar\n</think>\n\n<tool_call><function=collect_evidence><parameter=intent>localizar funcao de soma quebrada</parameter><parameter=path>src/math.zig</parameter><parameter=strategy>path</parameter><parameter=start_line>1</parameter><parameter=max_lines>20</parameter></function></tool_call>",
        else => "patch aplicado, agora responder visivelmente\n</think>\n\nPatch aplicado em src/math.zig. PHENOM_AGENT_PATCH_OK",
    };
}

fn agentPatchDynamic(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    const start = std.mem.indexOf(u8, body, "ctx_") orelse return error.MissingContextId;
    var end = start;
    while (end < body.len and (std.ascii.isAlphanumeric(body[end]) or body[end] == '_')) : (end += 1) {}
    return std.fmt.allocPrint(allocator, "micro-contexto fresco encontrado\n</think>\n\n<tool_call><function=apply_patch><parameter=operation>edit</parameter><parameter=path>src/math.zig</parameter><parameter=contextId>{s}</parameter><parameter=search>return a - b;</parameter><parameter=replace>return a + b;</parameter></function></tool_call>", .{body[start..end]});
}

fn queryWeb(idx: usize, expect: []const u8) []const u8 {
    return switch (idx) {
        0 => "pergunta externa sem URL declara contrato rag web\n</think>\n\n<tool_call><function=set_operational_contract><parameter=contract>rag_web</parameter><parameter=strategyId>search_web_distilled</parameter><parameter=query>horario de brasilia agora fonte confiavel</parameter><parameter=budget_bytes>4096</parameter><parameter=reason>conhecimento externo nao atribuido ao contexto do modelo</parameter></function></tool_call>",
        1 => "horario de brasilia agora fonte confiavel",
        else => if (expect.len > 0) "responder com web rag\n</think>\n\nE1 mostra que a pergunta sem URL foi resolvida via Web RAG por query e retornou PHENOM_QUERY_WEB_FACT.\nPHENOM_QUERY_WEB_RAG_OK" else "",
    };
}

fn ambiguousWeb(idx: usize) []const u8 {
    const responses = [_][]const u8{
        "usar data autoritativa do sistema\n</think>\n\nHoje e 2026-08-01.\nPHENOM_TEMPORAL_DATE_OK",
        "usar dia autoritativo do sistema\n</think>\n\nHoje cai em Saturday.\nPHENOM_TEMPORAL_WEEKDAY_OK",
        "usuario ambiguo pediu fato externo atual; declaro ragweb com query propria\n</think>\n\n<tool_call><function=set_operational_contract><parameter=contract>rag_web</parameter><parameter=strategyId>search_web_distilled</parameter><parameter=query>horario de brasilia agora fonte oficial</parameter><parameter=budget_bytes>3072</parameter><parameter=reason>external fact from ambiguous user wording</parameter></function></tool_call>",
        "horario de brasilia agora fonte oficial",
        "resposta do primeiro turno usando evidencia web destilada\n</think>\n\nE1 confirma a atualizacao ambigua por Web RAG: PHENOM_WEB_AMBIG_BRASILIA_FACT. Vou manter este fio para as proximas perguntas.\nPHENOM_AMBIG_T1",
        "continuidade ambigua sem usuario dizer web; declaro ragweb para cotacao\n</think>\n\n<tool_call><function=set_operational_contract><parameter=contract>rag_web</parameter><parameter=strategyId>search_web_distilled</parameter><parameter=query>cotacao dolar real hoje fonte confiavel</parameter><parameter=budget_bytes>3072</parameter><parameter=reason>ambiguous follow-up needs current external evidence</parameter></function></tool_call>",
        "cotacao dolar real hoje fonte confiavel",
        "resposta do segundo turno preservando continuidade\n</think>\n\nE1 confirma a atualizacao da cotacao em continuidade: PHENOM_WEB_AMBIG_DOLAR_FACT. O contexto anterior continua sendo PHENOM_AMBIG_T1.\nPHENOM_AMBIG_T2",
        "usuario declarou ragweb explicitamente; contrato web continua model-driven\n</think>\n\n<tool_call><function=set_operational_contract><parameter=contract>search_web</parameter><parameter=strategyId>search_web_distilled</parameter><parameter=query>cotacao euro real hoje fonte confiavel</parameter><parameter=budget_bytes>3072</parameter><parameter=reason>user explicitly requested ragweb</parameter></function></tool_call>",
        "cotacao euro real hoje fonte confiavel",
        "resposta do terceiro turno declarativo\n</think>\n\nE1 confirma a busca declarativa por RAG Web: PHENOM_WEB_DECL_EURO_FACT. Mantive os pontos anteriores PHENOM_AMBIG_T1 e PHENOM_AMBIG_T2.\nPHENOM_DECL_T3",
        "resumo linear sem nova busca\n</think>\n\nResumo da sessao: primeiro o pedido ambiguo virou PHENOM_WEB_AMBIG_BRASILIA_FACT; depois a continuidade ambigua virou PHENOM_WEB_AMBIG_DOLAR_FACT; por fim o pedido declarativo com RAG Web virou PHENOM_WEB_DECL_EURO_FACT. A conversa manteve PHENOM_AMBIG_T1, PHENOM_AMBIG_T2 e PHENOM_DECL_T3.\nPHENOM_CONTINUITY_FINAL",
    };
    return responses[@min(idx, responses.len - 1)];
}

fn rulePromotion(idx: usize) []const u8 {
    const responses = [_][]const u8{
        "<think>o usuario definiu uma regra operacional duravel; devo persistir como skill interpretada</think>\n\n<tool_call><function=set_operational_contract><parameter=contract>memory</parameter><parameter=requiresMemoryPromotion>true</parameter><parameter=reason>persistir regra operacional duravel confirmada pelo usuario</parameter></function></tool_call>",
        "<think>contrato memory ativo; promover regra normalizada para skills</think>\n\n<tool_call><function=promote_context><parameter=target>skills</parameter><parameter=text>Nao commitar sem rodar testes</parameter></function></tool_call>",
        "<think>promocao concluida; responder curto</think>\n\nRegistrado em SKILLS.md: nao commitar sem rodar testes.",
        "<think>o usuario pergunta por regra local persistida; preciso consultar MEMORY/SKILLS</think>\n\n<tool_call><function=set_operational_contract><parameter=contract>memory</parameter><parameter=query>regra local antes de commitar testes</parameter><parameter=reason>recuperar regra operacional persistida</parameter></function></tool_call>",
        "<think>buscar regra persistida relevante</think>\n\n<tool_call><function=search_persistent_context><parameter=target>skills</parameter><parameter=terms>commitar testes regra operacional</parameter></function></tool_call>",
        "<think>ignorei a evidencia recuperada por engano</think>\n\nNao tenho nenhuma regra local persistida sobre isso.",
        "<think>SKILLS recuperou a regra; responder aplicando-a</think>\n\nA regra local e: nao commitar sem rodar testes. Antes de commitar, rode os testes relevantes.",
    };
    return responses[@min(idx, responses.len - 1)];
}

fn requiredToolRepair(idx: usize) []const u8 {
    const responses = [_][]const u8{
        "selecionar contrato de mutacao\n</think>\n\n<tool_call><function=set_operational_contract><parameter=requiresInspection>true</parameter><parameter=requiresMutation>true</parameter><parameter=requiresRuntimeValidation>false</parameter><parameter=requiresBrowserDiagnostics>false</parameter><parameter=reason>editar arquivo com evidencia local</parameter></function></tool_call>",
        "ler arquivo antes de editar\n</think>\n\n<tool_call><function=collect_evidence><parameter=intent>localizar funcao de soma quebrada</parameter><parameter=path>src/math.zig</parameter><parameter=strategy>path</parameter><parameter=start_line>1</parameter><parameter=max_lines>20</parameter></function></tool_call>",
        "vou aplicar o patch agora, mas esta resposta nao tem chamada de ferramenta\n</think>\n\nPreciso aplicar o patch.",
        "segunda tentativa ainda falha como um modelo real desalinhado\n</think>\n\nNao consigo chamar a ferramenta agora.",
    };
    return responses[@min(idx, responses.len - 1)];
}

fn webRag(allocator: std.mem.Allocator, idx: usize, port: u16) ![]const u8 {
    const target = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{}/doc.html", .{port});
    defer allocator.free(target);
    return switch (idx) {
        0 => allocator.dupe(u8, "selecionar contrato de evidencia externa\n</think>\n\n<tool_call><function=set_operational_contract><parameter=requiresInspection>true</parameter><parameter=requiresMutation>false</parameter><parameter=requiresRuntimeValidation>false</parameter><parameter=requiresBrowserDiagnostics>false</parameter><parameter=reason>coletar evidencia web explicita</parameter></function></tool_call>"),
        1 => std.fmt.allocPrint(allocator, "buscar pagina indicada\n</think>\n\n<tool_call><function=web_search><parameter=target>{s}</parameter><parameter=query>Phenom Web RAG contrato</parameter><parameter=budget_bytes>4096</parameter></function></tool_call>", .{target}),
        2 => std.fmt.allocPrint(allocator, "[WEB_EVIDENCE]\nsource=http_get raw_context_persisted=false distill=model_summary target={s}\nstatus=200\nquery=Phenom Web RAG contrato\ntitle=Phenom Web RAG\nexcerpt=Phenom Web RAG fornece evidencia contratual externa destilada para respostas.", .{target}),
        3 => allocator.dupe(u8, "E1 contem WEB_EVIDENCE da pagina explicitamente buscada e informa que Phenom Web RAG fornece evidencia contratual externa. PHENOM_WEB_RAG_OK"),
        4 => allocator.dupe(u8, "selecionar contrato de evidencia por collect_evidence\n</think>\n\n<tool_call><function=set_operational_contract><parameter=requiresInspection>true</parameter><parameter=requiresMutation>false</parameter><parameter=requiresRuntimeValidation>false</parameter><parameter=requiresBrowserDiagnostics>false</parameter><parameter=reason>coletar URL pelo collect_evidence</parameter></function></tool_call>"),
        5 => std.fmt.allocPrint(allocator, "coletar URL via collect_evidence\n</think>\n\n<tool_call><function=collect_evidence><parameter=httpSearch>true</parameter><parameter=target>{s}</parameter><parameter=query>Phenom Web RAG contrato</parameter><parameter=budget_bytes>4096</parameter></function></tool_call>", .{target}),
        else => allocator.dupe(u8, "E1 informa que Phenom Web RAG fornece evidencia externa destilada para respostas. PHENOM_COLLECT_WEB_OK"),
    };
}

fn linearWebWorkspace(allocator: std.mem.Allocator, idx: usize, port: u16) ![]const u8 {
    const responses = [_][]const u8{
        "saudacao e combinado de assunto\n</think>\n\nVamos manter uma conversa linear sobre RAG Web e evidencia local. Marcador inicial PHENOM_LINEAR_T1.",
        "",
        "responder alpha e manter continuidade\n</think>\n\nE1 registra PHENOM_WEB_ALPHA_FACT como evidencia web destilada. Continuo a partir de PHENOM_LINEAR_T1. PHENOM_LINEAR_T2.",
        "turno 3 precisa de workspace\n</think>\n\n<tool_call><function=set_operational_contract><parameter=contract>collect_evidence</parameter><parameter=reason>ler README local escolhido pelo modelo</parameter></function></tool_call>",
        "coletar README\n</think>\n\n<tool_call><function=collect_evidence><parameter=path>README.md</parameter><parameter=strategy>path</parameter><parameter=start_line>1</parameter><parameter=max_lines>8</parameter></function></tool_call>",
        "responder workspace e lembrar web\n</think>\n\nE1 contem PHENOM_LOCAL_README_FACT no README local. O fio continua com PHENOM_WEB_ALPHA_FACT e PHENOM_LINEAR_T2. PHENOM_LINEAR_T3.",
        "",
        "trocar para workspace config\n</think>\n\n<tool_call><function=set_operational_contract><parameter=contract>collect_evidence</parameter><parameter=reason>agora ler config local apos evidencia web beta</parameter></function></tool_call>",
        "coletar config local\n</think>\n\n<tool_call><function=collect_evidence><parameter=path>src/config.zig</parameter><parameter=strategy>path</parameter><parameter=start_line>1</parameter><parameter=max_lines>8</parameter></function></tool_call>",
        "final linear combinado\n</think>\n\nE1 registra PHENOM_LOCAL_CONFIG_FACT e a evidencia web anterior registra PHENOM_WEB_BETA_FACT. A conversa manteve PHENOM_LINEAR_T1, PHENOM_LINEAR_T2 e PHENOM_LINEAR_T3. PHENOM_LINEAR_FINAL.",
    };
    if (idx == 1) return std.fmt.allocPrint(allocator, "turno 2 precisa de web\n</think>\n\n<tool_call><function=set_operational_contract><parameter=contract>search_web</parameter><parameter=target>http://127.0.0.1:{}/doc-alpha.html</parameter><parameter=query>Alpha Web RAG PHENOM_WEB_ALPHA_FACT</parameter><parameter=budget_bytes>4096</parameter><parameter=reason>buscar evidencia web alpha escolhida pelo modelo</parameter></function></tool_call>", .{port});
    if (idx == 6) return std.fmt.allocPrint(allocator, "turno 4 mistura web beta e arquivo config\n</think>\n\n<tool_call><function=set_operational_contract><parameter=contract>search_web</parameter><parameter=target>http://127.0.0.1:{}/doc-beta.html</parameter><parameter=query>Beta Web RAG PHENOM_WEB_BETA_FACT</parameter><parameter=budget_bytes>4096</parameter><parameter=reason>comparar evidencia web beta com config local</parameter></function></tool_call>", .{port});
    return allocator.dupe(u8, responses[@min(idx, responses.len - 1)]);
}

fn handleSearch(client: c_int, mode: Mode, path: []const u8) !void {
    switch (mode) {
        .query_web => {
            if (!contains(path, "horario")) return send(client, "400 Bad Request", "text/plain", "bad query");
            return send(client, "200 OK", "text/html", "<html><head><title>Busca local Web RAG</title></head><body><p>A busca por query retornou PHENOM_QUERY_WEB_FACT para uma pergunta sem URL.</p></body></html>");
        },
        .ambiguous_web => {
            if (contains(path, "horario")) return send(client, "200 OK", "text/html", "<html><head><title>Busca horario Brasilia</title></head><body><p>Resultado atual sintetizado: PHENOM_WEB_AMBIG_BRASILIA_FACT.</p><p>HTML bruto nao deve entrar no contexto permanente.</p></body></html>");
            if (contains(path, "dolar")) return send(client, "200 OK", "text/html", "<html><head><title>Busca dolar real</title></head><body><p>Resultado atual sintetizado: PHENOM_WEB_AMBIG_DOLAR_FACT.</p></body></html>");
            if (contains(path, "euro")) return send(client, "200 OK", "text/html", "<html><head><title>Busca euro real</title></head><body><p>Resultado atual sintetizado: PHENOM_WEB_DECL_EURO_FACT.</p></body></html>");
            return send(client, "400 Bad Request", "text/plain", "bad query");
        },
        else => return send(client, "404 Not Found", "text/plain", "not found"),
    }
}

fn sendManyTokens(client: c_int, count: usize) !void {
    var buf: [16384]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.writeAll("{\"tokens\":[");
    for (0..count) |i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("123456");
    }
    try w.writeAll("]}");
    try send(client, "200 OK", "application/json", w.buffered());
}

fn sendSse(client: c_int, text: []const u8) !void {
    var body_buf: [32768]u8 = undefined;
    var w = std.Io.Writer.fixed(&body_buf);
    try w.writeAll("data: {\"content\":\"");
    try appendJson(&w, text);
    try w.writeAll("\",\"stop\":true}\n\n");
    try send(client, "200 OK", "text/event-stream", w.buffered());
}

fn appendJson(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |ch| switch (ch) {
        '\\' => try w.writeAll("\\\\"),
        '"' => try w.writeAll("\\\""),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => try w.writeByte(ch),
    };
}

fn send(client: c_int, status: []const u8, content_type: []const u8, body: []const u8) !void {
    var header_buf: [512]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nServer: phenom-zig-scripted-backend\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", .{ status, content_type, body.len });
    try sendAll(client, header);
    try sendAll(client, body);
}

fn sendAll(client: c_int, data: []const u8) !void {
    var offset: usize = 0;
    while (offset < data.len) {
        const n = c.send(client, data[offset..].ptr, data.len - offset, 0);
        if (n <= 0) return error.SendFailed;
        offset += @intCast(n);
    }
}
