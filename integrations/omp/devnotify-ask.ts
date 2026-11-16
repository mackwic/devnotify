// devnotify for Oh My Pi: the agent's `ask` also shows as a devnotify card, and the first answer wins,
// in the terminal or on the card. The tool shadows the built-in `ask` (same description and schema,
// read from it at session start) and runs the native one through `ctx.invokeTool`: answering in the
// terminal removes the card, answering on the card closes the terminal prompt.
//
// omp versions differ: `ask` takes an HTML form (`html`) or a list of questions (`questions`); both
// work. One choice gets a button per option; every card takes a free reply (a choice's "Other"
// answer, a text field's text, or, when there are several questions, a note handed to the model as
// is). Without devnotify, only the native prompt.
//
// Installed by `make omp` from the devnotify repository into ~/.omp/agent/extensions.

import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { basename } from "node:path";

const DEVNOTIFY = process.env.DEVNOTIFY ?? `${homedir()}/.local/bin/devnotify`;
const MAX_BUTTONS = 5;

enum FieldKind {
	Choice = "choice",
	Many = "many",
	Text = "text",
	Hidden = "hidden",
}

interface Option {
	value: string;
	label: string;
}

interface Field {
	name: string;
	kind: FieldKind;
	options: Option[];
	value?: string;
}

interface CardAnswer {
	action?: number;
	label?: string;
	reply?: string;
}

interface ToolResult {
	content: { type: "text"; text: string }[];
	details?: unknown;
}

// The slice of omp's extension API this file uses (omp publishes its types under another package name).
interface ToolContext {
	hasUI: boolean;
	cwd?: string;
	invokeTool(params: Record<string, unknown>, options?: { signal?: AbortSignal; onUpdate?: unknown }): Promise<ToolResult>;
}

interface Question {
	id: string;
	question: string;
	header?: string;
	options: { label: string; description?: string }[];
	multi?: boolean;
}

interface NativeTool {
	name: string;
	label?: string;
	description?: string;
	parameters?: unknown;
}

interface ExtensionApi {
	setLabel(label: string): void;
	on(event: "session_start", handler: () => void): void;
	getAllTools?(): NativeTool[];
	getSessionName?(): string | undefined;
	registerTool(tool: {
		name: string;
		label: string;
		description: string;
		parameters: unknown;
		concurrency: "exclusive";
		execute(id: string, params: Record<string, unknown>, signal: AbortSignal | undefined, onUpdate: unknown, ctx: ToolContext): Promise<ToolResult>;
	}): void;
}

const attr = (tag: string, name: string): string | undefined =>
	tag.match(new RegExp(`\\b${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s>]+))`, "i"))?.slice(1).find(v => v !== undefined);

/** Readable text of an HTML fragment: one line per block, entities decoded. */
const text = (html: string): string =>
	html
		.replace(/<(script|style)\b[\s\S]*?<\/\1>/gi, "")
		.replace(/<(br|\/p|\/li|\/h\d|\/legend|\/tr|\/pre)\b[^>]*>/gi, "\n")
		.replace(/<[^>]+>/g, "")
		.replace(/&nbsp;/g, " ").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, "&")
		.split("\n").map(l => l.replace(/\s+/g, " ").trim()).filter(Boolean).join("\n");

/** The form's named controls, in order: enough to turn a card answer into the form's data. */
function parseFields(form: string): Field[] {
	const fields: Field[] = [];
	const byName = new Map<string, Field>();
	const add = (name: string, kind: FieldKind): Field => {
		let f = byName.get(name);
		if (!f) {
			f = { name, kind, options: [] };
			byName.set(name, f);
			fields.push(f);
		} else if (kind === FieldKind.Many) {
			f.kind = FieldKind.Many;
		}
		return f;
	};
	// A control's label is the text of the <label> it sits in: the last one opened before it.
	const labels = [...form.matchAll(/<label\b[^>]*>([\s\S]*?)<\/label>/gi)].map(m => ({ start: m.index ?? 0, label: text(m[1]) }));
	for (const m of form.matchAll(/<(input|select|textarea)\b([^>]*)>([\s\S]*?<\/select>)?/gi)) {
		const name = attr(m[2], "name");
		if (!name || /\bdisabled\b/i.test(m[2])) continue;
		const tag = m[1].toLowerCase();
		if (tag === "select") {
			const f = add(name, /\bmultiple\b/i.test(m[2]) ? FieldKind.Many : FieldKind.Choice);
			for (const o of (m[3] ?? "").matchAll(/<option\b([^>]*)>([\s\S]*?)(?=<option\b|<\/select>)/gi)) {
				if (/\bdisabled\b/i.test(o[1])) continue;
				const label = text(o[2]);
				f.options.push({ value: attr(o[1], "value") ?? label, label });
			}
			continue;
		}
		const type = (attr(m[2], "type") ?? "text").toLowerCase();
		if (type === "radio" || type === "checkbox") {
			const f = add(name, type === "radio" ? FieldKind.Choice : FieldKind.Many);
			const value = attr(m[2], "value") ?? "on";
			const label = labels.filter(l => l.start <= (m.index ?? 0)).at(-1)?.label;
			f.options.push({ value, label: label || value });
		} else if (type === "hidden") {
			add(name, FieldKind.Hidden).value = attr(m[2], "value") ?? "";
		} else if (!["submit", "button", "reset", "image"].includes(type)) {
			add(name, FieldKind.Text);
		}
	}
	return fields;
}

type BuiltCard = { card: Record<string, unknown>; toResult(a: CardAnswer): ToolResult };

const card = (toolCallId: string, source: string, fields: Record<string, unknown>) => ({
	key: `omp:ask:${toolCallId}`,
	source,
	level: "warning",
	// The agent waits on the person: the card shows even under a Focus.
	urgent: true,
	title: "omp attend ta réponse",
	...fields,
});

const clip = (s: string) => (s.length > 280 ? `${s.slice(0, 277)}…` : s || undefined);

/** The card for a list of questions (older omp), and how to read its answer back as the tool's. */
function cardForQuestions(questions: Question[], toolCallId: string, source: string): BuiltCard | null {
	if (questions.length === 0) return null;
	const only = questions.length === 1 ? questions[0] : undefined;
	const buttons = only && !only.multi && only.options.length <= MAX_BUTTONS ? only.options : [];
	const listing = questions
		.map(q => [q.header ? `${q.header} : ${q.question}` : q.question, ...q.options.map(o => `• ${o.label}${o.description ? ` : ${o.description}` : ""}`)].join("\n"))
		.join("\n\n");
	const built = card(toolCallId, source, {
		body: clip(only ? only.question : `${questions.length} questions : ${questions.map(q => q.header ?? q.question).join(", ")}`),
		details: buttons.length === 0 || only?.options.some(o => o.description) || !only ? listing : undefined,
		detailsLabel: only ? "Les options" : "Les questions (plus simple dans le terminal)",
		actions: buttons.map(o => ({ label: o.label })),
		reply: { placeholder: only ? "Répondre…" : "Répondre en texte libre…", open: buttons.length === 0 },
	});
	const toResult = (a: CardAnswer): ToolResult => {
		const reply = a.reply?.trim() ?? "";
		const chosen = a.action === undefined ? undefined : buttons[a.action]?.label;
		const results = questions.map((q, i) => ({
			id: q.id,
			question: q.question,
			options: q.options.map(o => o.label),
			multi: q.multi ?? false,
			selectedOptions: i === 0 && chosen ? [chosen] : [],
			...(i === 0 && !chosen ? { customInput: reply } : {}),
		}));
		const text = only
			? `User answers:\n${only.question}: ${chosen ?? reply}`
			: `User answers (free text from a desktop notification instead of answering each question):\n${reply}`;
		return { content: [{ type: "text", text }], details: { results } };
	};
	return { card: built, toResult };
}

/** The card for an HTML form, and how to read its answer back as the form's data. */
function cardForForm(html: string, toolCallId: string, source: string): BuiltCard | null {
	const form = html.match(/<form\b[\s\S]*?<\/form>/i)?.[0] ?? html;
	const fields = parseFields(form);
	const asked = fields.filter(f => f.kind !== FieldKind.Hidden);
	if (asked.length === 0) return null;
	const only = asked.length === 1 ? asked[0] : undefined;
	const buttons = only?.kind === FieldKind.Choice && only.options.length <= MAX_BUTTONS ? only.options : [];
	const intro = text(form.replace(/<(label|select|textarea)\b[\s\S]*?<\/\1>/gi, "").replace(/<input\b[^>]*>/gi, ""));
	const built = card(toolCallId, source, {
		body: clip(intro),
		details: asked.length > 1 || buttons.length === 0 ? text(form) : undefined,
		detailsLabel: asked.length > 1 ? `Le formulaire (${asked.length} questions, plus simple dans le terminal)` : "La question complète",
		actions: buttons.map(o => ({ label: o.label })),
		reply: { placeholder: asked.length > 1 ? "Répondre en texte libre…" : "Répondre…", open: buttons.length === 0 },
	});

	const toResult = (a: CardAnswer): ToolResult => {
		const reply = a.reply?.trim() ?? "";
		if (!only) {
			return {
				content: [{ type: "text", text: `User answers (free text from a desktop notification instead of the form's fields):\n${reply}` }],
				details: { answers: [{ name: "reply", question: "Free reply", answer: reply }] },
			};
		}
		const data: Record<string, unknown> = {};
		for (const f of fields) if (f.kind === FieldKind.Hidden) data[f.name] = f.value;
		const button = a.action === undefined ? undefined : buttons[a.action];
		data[only.name] = button ? button.value : only.kind === FieldKind.Many ? [reply] : reply;
		return {
			content: [{ type: "text", text: `User answers:\n${JSON.stringify(data, null, 2)}` }],
			details: { answers: [{ name: only.name, question: intro.split("\n").at(-1) ?? only.name, answer: button?.label ?? reply }] },
		};
	};
	return { card: built, toResult };
}

/** Runs `devnotify ask`: resolves with the person's answer, or never when the card closes unanswered. */
function askCard(card: unknown): { answer: Promise<CardAnswer>; cancel: () => void } {
	const child = spawn(DEVNOTIFY, ["ask", JSON.stringify(card)], { stdio: ["ignore", "pipe", "ignore"] });
	const { promise, resolve } = Promise.withResolvers<CardAnswer>();
	let out = "";
	child.stdout.on("data", d => (out += d));
	child.on("close", () => {
		try {
			const a = JSON.parse(out) as CardAnswer;
			if (a.action !== undefined || a.reply !== undefined) resolve(a);
		} catch {
			// No devnotify, or the card closed unanswered: the terminal form stays the only answer.
		}
	});
	child.on("error", () => { });
	return { answer: promise, cancel: () => child.kill() };
}

export default function devnotifyAsk(pi: ExtensionApi) {
	pi.setLabel("devnotify ask");
	let registered = false;
	pi.on("session_start", () => {
		if (registered) return;
		const native = pi.getAllTools?.().find(t => t.name === "ask");
		if (!native?.description) return;
		registered = true;
		pi.registerTool({
			name: "ask",
			label: native.label ?? "Ask",
			description: native.description,
			// The native schema as is, so the model sees the same tool whatever this omp's `ask` takes.
			parameters: native.parameters,
			concurrency: "exclusive",
			async execute(toolCallId, params, signal, onUpdate, ctx) {
				const source = `omp · ${pi.getSessionName?.() || basename(ctx.cwd ?? "")}`;
				const built = !ctx.hasUI
					? null
					: typeof params.html === "string"
						? cardForForm(params.html, toolCallId, source)
						: Array.isArray(params.questions)
							? cardForQuestions(params.questions as Question[], toolCallId, source)
							: null;
				if (!built) return ctx.invokeTool(params);
				const form = new AbortController();
				const stop = () => form.abort();
				signal?.addEventListener("abort", stop);
				const remote = askCard(built.card);
				const local = ctx.invokeTool(params, { signal: form.signal, onUpdate }).then(
					result => ({ result }),
					(error: unknown) => ({ error }),
				);
				try {
					const first = await Promise.race([local, remote.answer.then(answer => ({ answer }))]);
					if ("answer" in first) {
						form.abort();
						await local;
						return built.toResult(first.answer);
					}
					remote.cancel();
					if ("error" in first) throw first.error;
					return first.result;
				} finally {
					signal?.removeEventListener("abort", stop);
				}
			},
		});
	});
}
