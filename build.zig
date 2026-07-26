const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.link_libc = true;
    exe_mod.linkSystemLibrary("sqlite3", .{});

    const exe = b.addExecutable(.{
        .name = "phenom",
        .root_module = exe_mod,
    });
    const install_artifact = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_artifact.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run phenom");
    run_step.dependOn(&run_cmd.step);

    const install_local_step = b.step("install-local", "Install phenom to ~/.local/bin and config to ~/.config/phenom.");
    const install_local_cmd = b.addSystemCommand(&.{
        "sh",
        "-c",
        "test -n \"$HOME\" && install -Dm755 \"$1\" \"$HOME/.local/bin/phenom\" && { test ! -f config.toml || sh tools/merge_config.sh config.toml \"$HOME/.config/phenom/config.toml\"; }",
        "sh",
    });
    install_local_cmd.addFileArg(exe.getEmittedBin());
    install_local_cmd.step.dependOn(&install_artifact.step);
    install_local_step.dependOn(&install_local_cmd.step);

    const real_backend = b.option([]const u8, "real-backend", "Real backend for smoke test: ollama or llamacpp") orelse "llamacpp";
    const real_host = b.option([]const u8, "real-host", "Real backend host:port for smoke test") orelse "127.0.0.1:11434";
    const real_model = b.option([]const u8, "real-model", "Real model name for smoke test") orelse "phenom:latest";
    const real_prompt = b.option([]const u8, "real-prompt", "Real prompt for smoke test") orelse "Complete: PHENOM_REAL_7319";
    const real_expect = b.option([]const u8, "real-expect", "Expected visible text for smoke test") orelse "PHENOM_REAL_7319";
    const real_session = b.option([]const u8, "real-session", "Session id for multi-turn real smoke test") orelse "real-session-smoke-294";
    const real_dialogue_session = b.option([]const u8, "real-dialogue-session", "Session id for dialogue continuity real smoke test") orelse "real-dialogue-smoke-301";
    const real_long_session = b.option([]const u8, "real-long-session", "Session id for long-session real smoke test") orelse "real-long-session-smoke-294";
    const real_patch_session = b.option([]const u8, "real-patch-session", "Session id for autonomous real patch smoke test") orelse "real-patch-smoke";

    const real_smoke_cmd = b.addRunArtifact(exe);
    real_smoke_cmd.step.dependOn(b.getInstallStep());
    real_smoke_cmd.addArgs(&.{
        "chat",
        "--backend",
        real_backend,
        "--host",
        real_host,
        "--model",
        real_model,
        "--prompt",
        real_prompt,
        "--max-tokens",
        "96",
        "--expect-contains",
        real_expect,
        "--show-expect-status",
        "--fail-on-model-error",
    });

    const real_smoke_step = b.step("real-smoke", "Opt-in real backend smoke test. Requires active HOST:PORT.");
    real_smoke_step.dependOn(&real_smoke_cmd.step);

    const real_session_seed_cmd = b.addRunArtifact(exe);
    real_session_seed_cmd.step.dependOn(b.getInstallStep());
    real_session_seed_cmd.addArgs(&.{
        "chat",
        "--backend",
        real_backend,
        "--host",
        real_host,
        "--model",
        real_model,
        "--session",
        real_session,
        "--prompt",
        "Nesta sessao, registre este acordo operacional: a palavra-codigo de validacao do contexto de sessao e AZUL-FTS-294. Responda exatamente: PHENOM_SESSION_SEED_294",
        "--max-tokens",
        "260",
        "--expect-contains",
        "PHENOM_SESSION_SEED_294",
        "--show-expect-status",
        "--fail-on-model-error",
        "--no-color",
    });

    const real_session_recall_cmd = b.addRunArtifact(exe);
    real_session_recall_cmd.step.dependOn(&real_session_seed_cmd.step);
    real_session_recall_cmd.addArgs(&.{
        "chat",
        "--backend",
        real_backend,
        "--host",
        real_host,
        "--model",
        real_model,
        "--session",
        real_session,
        "--prompt",
        "Qual foi a palavra-codigo de validacao do contexto de sessao que combinamos? Responda exatamente no formato: CODIGO=<valor> PHENOM_SESSION_RECALL_294",
        "--max-tokens",
        "420",
        "--expect-contains",
        "CODIGO=AZUL-FTS-294 PHENOM_SESSION_RECALL_294",
        "--show-expect-status",
        "--fail-on-model-error",
        "--no-color",
    });

    const real_session_smoke_step = b.step("real-session-smoke", "Opt-in two-turn session context smoke test. Requires active HOST:PORT.");
    real_session_smoke_step.dependOn(&real_session_recall_cmd.step);

    const real_dialogue_seed_cmd = b.addRunArtifact(exe);
    real_dialogue_seed_cmd.step.dependOn(b.getInstallStep());
    real_dialogue_seed_cmd.addArgs(&.{
        "chat",
        "--backend",
        real_backend,
        "--host",
        real_host,
        "--model",
        real_model,
        "--session",
        real_dialogue_session,
        "--prompt",
        "Me de um exemplo simples de uma funcao Python chamada calcular_media que calcula media de notas. Termine exatamente com PHENOM_DIALOGUE_SEED_302",
        "--max-tokens",
        "260",
        "--expect-contains",
        "PHENOM_DIALOGUE_SEED_302",
        "--show-expect-status",
        "--fail-on-model-error",
        "--no-color",
    });

    const real_dialogue_followup_cmd = b.addRunArtifact(exe);
    real_dialogue_followup_cmd.step.dependOn(&real_dialogue_seed_cmd.step);
    real_dialogue_followup_cmd.addArgs(&.{
        "chat",
        "--backend",
        real_backend,
        "--host",
        real_host,
        "--model",
        real_model,
        "--session",
        real_dialogue_session,
        "--prompt",
        "me de um exemplo mais robusto.",
        "--max-tokens",
        "700",
        "--expect-contains",
        "calcular_media",
        "--show-expect-status",
        "--fail-on-model-error",
        "--no-color",
    });

    const real_dialogue_smoke_step = b.step("real-dialogue-smoke", "Opt-in two-turn recent dialogue continuity smoke test. Requires active HOST:PORT.");
    real_dialogue_smoke_step.dependOn(&real_dialogue_followup_cmd.step);

    const long_turns = [_]struct {
        prompt: []const u8,
        expect: []const u8,
    }{
        .{
            .prompt = "Nesta sessao longa, registre este fato operacional antigo: a palavra-codigo longa e LONG-SESSION-294. Responda exatamente: PHENOM_LONG_SEED_294",
            .expect = "PHENOM_LONG_SEED_294",
        },
        .{
            .prompt = "Registre tambem que o fluxo correto de contexto usa evidencia destilada e nao raw output. Responda exatamente: PHENOM_LONG_FILLER_1",
            .expect = "PHENOM_LONG_FILLER_1",
        },
        .{
            .prompt = "Registre que SESSION_FOCUS e mapa operacional, nao evidencia citavel. Responda exatamente: PHENOM_LONG_FILLER_2",
            .expect = "PHENOM_LONG_FILLER_2",
        },
        .{
            .prompt = "Registre que fatos exatos antigos devem usar search_session quando necessario. Responda exatamente: PHENOM_LONG_FILLER_3",
            .expect = "PHENOM_LONG_FILLER_3",
        },
        .{
            .prompt = "Registre que MEMORY e SKILLS so recebem promocao explicita. Responda exatamente: PHENOM_LONG_FILLER_4",
            .expect = "PHENOM_LONG_FILLER_4",
        },
        .{
            .prompt = "Registre que patch seguro precisa de micro-contexto fresco. Responda exatamente: PHENOM_LONG_FILLER_5",
            .expect = "PHENOM_LONG_FILLER_5",
        },
    };
    var long_prev: *std.Build.Step = b.getInstallStep();
    for (long_turns) |turn| {
        const cmd = b.addRunArtifact(exe);
        cmd.step.dependOn(long_prev);
        cmd.addArgs(&.{
            "chat",
            "--backend",
            real_backend,
            "--host",
            real_host,
            "--model",
            real_model,
            "--session",
            real_long_session,
            "--prompt",
            turn.prompt,
            "--max-tokens",
            "320",
            "--expect-contains",
            turn.expect,
            "--show-expect-status",
            "--fail-on-model-error",
            "--no-color",
        });
        long_prev = &cmd.step;
    }

    const real_long_recall_cmd = b.addRunArtifact(exe);
    real_long_recall_cmd.step.dependOn(long_prev);
    real_long_recall_cmd.addArgs(&.{
        "chat",
        "--backend",
        real_backend,
        "--host",
        real_host,
        "--model",
        real_model,
        "--session",
        real_long_session,
        "--prompt",
        "Na sessao longa, qual foi a palavra-codigo antiga que combinamos? Responda exatamente no formato: CODIGO=<valor> PHENOM_LONG_RECALL_294",
        "--max-tokens",
        "900",
        "--expect-contains",
        "LONG-SESSION-294",
        "--show-expect-status",
        "--fail-on-model-error",
        "--no-color",
    });

    const real_long_session_smoke_step = b.step("real-long-session-smoke", "Opt-in long-session continuity smoke test. Requires active HOST:PORT.");
    real_long_session_smoke_step.dependOn(&real_long_recall_cmd.step);

    const real_alignment_session = b.option([]const u8, "real-alignment-session", "Session id for real alignment smoke") orelse "real-alignment-smoke-290";
    const real_alignment_prompt = b.option([]const u8, "real-alignment-prompt", "Prompt for real alignment smoke") orelse "Complete: PHENOM_REAL_ALIGNMENT_290";
    const real_alignment_expect = b.option([]const u8, "real-alignment-expect", "Expected visible text for real alignment smoke") orelse "PHENOM_REAL_ALIGNMENT_290";
    const real_alignment_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/check_real_alignment.sh",
    });
    real_alignment_cmd.step.dependOn(&install_artifact.step);
    real_alignment_cmd.addFileArg(exe.getEmittedBin());
    real_alignment_cmd.addArgs(&.{
        real_backend,
        real_host,
        real_model,
        real_alignment_session,
        real_alignment_prompt,
        real_alignment_expect,
    });

    const real_alignment_smoke_step = b.step("real-alignment-smoke", "Opt-in real backend smoke with SQLite audit validation.");
    real_alignment_smoke_step.dependOn(&real_alignment_cmd.step);

    const real_patch_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/check_real_patch.sh",
    });
    real_patch_cmd.step.dependOn(&install_artifact.step);
    real_patch_cmd.addFileArg(exe.getEmittedBin());
    real_patch_cmd.addArgs(&.{
        real_backend,
        real_host,
        real_model,
        real_patch_session,
    });

    const real_patch_smoke_step = b.step("real-patch-smoke", "Opt-in autonomous real model patch/validation smoke test. Requires active HOST:PORT.");
    real_patch_smoke_step.dependOn(&real_patch_cmd.step);

    const memory_persistence_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/check_memory_persistence.sh",
    });
    memory_persistence_cmd.step.dependOn(&install_artifact.step);
    memory_persistence_cmd.addFileArg(exe.getEmittedBin());

    const memory_persistence_step = b.step("memory-persistence-smoke", "Offline e2e SQLite smoke for completed and interrupted conversation memory.");
    memory_persistence_step.dependOn(&memory_persistence_cmd.step);

    const user_rule_promotion_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/check_user_rule_promotion_flow.sh",
    });
    user_rule_promotion_cmd.step.dependOn(&install_artifact.step);
    user_rule_promotion_cmd.addFileArg(exe.getEmittedBin());

    const user_rule_promotion_step = b.step("user-rule-promotion-flow-smoke", "Scripted-backend e2e smoke for model-driven SKILLS.md rule promotion and retrieval.");
    user_rule_promotion_step.dependOn(&user_rule_promotion_cmd.step);

    const agent_patch_flow_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/check_agent_patch_flow.sh",
    });
    agent_patch_flow_cmd.step.dependOn(&install_artifact.step);
    agent_patch_flow_cmd.addFileArg(exe.getEmittedBin());

    const agent_patch_flow_step = b.step("agent-patch-flow-smoke", "Offline e2e scripted-backend agent smoke for collect evidence and apply_patch.");
    agent_patch_flow_step.dependOn(&agent_patch_flow_cmd.step);

    const required_tool_repair_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/check_required_tool_repair_flow.sh",
    });
    required_tool_repair_cmd.step.dependOn(&install_artifact.step);
    required_tool_repair_cmd.addFileArg(exe.getEmittedBin());

    const required_tool_repair_step = b.step("required-tool-repair-smoke", "Offline e2e scripted-backend smoke for required tool repair finalization.");
    required_tool_repair_step.dependOn(&required_tool_repair_cmd.step);

    const think_only_finalization_cmd = b.addSystemCommand(&.{
        "sh",
        "tools/check_think_only_finalization.sh",
    });
    think_only_finalization_cmd.step.dependOn(&install_artifact.step);
    think_only_finalization_cmd.addFileArg(exe.getEmittedBin());

    const think_only_finalization_step = b.step("think-only-finalization-smoke", "Offline e2e scripted-backend smoke for visible finalization after think-only output.");
    think_only_finalization_step.dependOn(&think_only_finalization_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.link_libc = true;
    test_mod.linkSystemLibrary("sqlite3", .{});

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
