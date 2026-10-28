// pi extension: the pi counterpart of the Claude Code / Codex hooks (linked by `agent-feedback setup --pi`).
// - Before each prompt: registers the session for the app's picker (session.sh update pi) and tells the agent
//   about open feedback items assigned to it (feedback-hint.sh).
// - Mailbox: the app drops items for a running session into ~/.claude/agent-feedback/queue/<session_id>/*.msg;
//   they are sent into the chat as a user message (right away if idle, otherwise as the next turn), prefixed with
//   /skill:feedback so pi puts the skill's instructions in front instead of relying on the model to load it.
// - On quit or session switch: removes the session from the picker (session.sh end).
// Only sessions with a chat (TUI or RPC) register; one-shot print/JSON runs (e.g. subagents) and runs started by
// agent-feedback itself (AGENT_FEEDBACK_RUN=1) don't register and don't read the mailbox.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { spawn, spawnSync } from "node:child_process";
import { type FSWatcher, mkdirSync, readdirSync, readFileSync, rmdirSync, unlinkSync, watch } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const HOME = join(homedir(), ".claude/agent-feedback");
const BIN = join(HOME, "bin");
const OWN_RUN = !!process.env.AGENT_FEEDBACK_RUN;
// The hooks would take a Claude project dir from a parent Claude session as the session's start directory.
const { CLAUDE_PROJECT_DIR: _, ...env } = process.env;

/** Runs a hook script with a JSON payload on stdin; returns stdout ("" if the hooks are not set up). */
function hook(script: string, args: string[], input: object): Promise<string> {
	return new Promise((resolve) => {
		const p = spawn(join(BIN, script), args, { env, stdio: ["pipe", "pipe", "ignore"], timeout: 5000 });
		let out = "";
		p.stdout.on("data", (d) => (out += d));
		p.on("error", () => resolve(""));
		p.on("close", () => resolve(out));
		p.stdin.on("error", () => {});
		p.stdin.end(JSON.stringify(input));
	});
}

export default function (pi: ExtensionAPI) {
	let watcher: FSWatcher | undefined;
	let sessionId = "";
	let registered = false;
	/** Messages we sent ourselves: they shouldn't replace the last prompt shown in the picker. */
	const delivered = new Set<string>();
	const ours = (prompt: string) => [...delivered].find((d) => prompt.includes(d));

	function drain(dir: string) {
		let names: string[] = [];
		try {
			names = readdirSync(dir).filter((n) => n.endsWith(".msg")).sort();
		} catch {
			return;
		}
		for (const name of names) {
			let text = "";
			try {
				text = readFileSync(join(dir, name), "utf8");
				unlinkSync(join(dir, name));
			} catch {
				continue;
			}
			if (!text.trim()) continue;
			delivered.add(text);
			pi.sendUserMessage(`/skill:feedback ${text}`, { deliverAs: "followUp", expandPromptTemplates: true });
		}
	}

	pi.on("session_start", (_event, ctx) => {
		sessionId = ctx.sessionManager.getSessionId();
		registered = !OWN_RUN && ctx.hasUI && !!sessionId;
		if (!registered) return;
		const dir = join(HOME, "queue", sessionId);
		try {
			mkdirSync(dir, { recursive: true });
			watcher = watch(dir, () => drain(dir));
		} catch {
			return;
		}
		drain(dir);
	});

	pi.on("before_agent_start", async (event, ctx) => {
		const id = ctx.sessionManager.getSessionId();
		const own = event.messageType === "user" ? ours(event.prompt) : undefined;
		if (own) delivered.delete(own);
		const prompt = event.messageType === "user" && !own ? event.prompt : "";
		if (registered) {
			await hook("session.sh", ["update", "pi"], {
				session_id: id,
				cwd: ctx.cwd,
				prompt,
				title: ctx.sessionManager.getSessionName() ?? "",
				pid: String(process.pid),
			});
		}
		const hint = (await hook("feedback-hint.sh", [], { session_id: id, cwd: ctx.cwd })).trim();
		if (hint) return { message: { customType: "agent-feedback", content: hint, display: false } };
	});

	pi.on("session_shutdown", (event) => {
		watcher?.close();
		watcher = undefined;
		// A reload keeps the session; quit and switching to another session end it here.
		if (!registered || event.reason === "reload") return;
		// A turn still finishing after this must not register the session again.
		registered = false;
		spawnSync(join(BIN, "session.sh"), ["end", "pi"], { env, input: JSON.stringify({ session_id: sessionId }), timeout: 5000 });
		try {
			rmdirSync(join(HOME, "queue", sessionId)); // only if empty
		} catch {}
	});
}
