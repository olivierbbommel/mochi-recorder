// mochi-mcp: a remote MCP server (Streamable HTTP, stateless JSON responses) so Claude can read
// the owner's meetings and transcripts and manage their tasks.
// Auth: header "x-api-key: <MOCHI_MCP_TOKEN>" (claude.ai: custom connector, No sign-in, request
// header x-api-key; claude.ai keeps "authorization" for its own OAuth). "Authorization: Bearer" works
// too. Anything else gets a 401 and no data.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

type Args = Record<string, unknown>;
const str = (v: unknown) => (typeof v === "string" && v.trim() !== "" ? v.trim() : undefined);
const num = (v: unknown, d: number) => (typeof v === "number" && v > 0 ? Math.min(v, 100) : d);
const STATUSES = ["todo", "in-progress", "blocked", "done"];

async function projectId(name: unknown): Promise<string | null | undefined> {
  const n = str(name);
  if (!n) return undefined;
  const { data } = await db.from("projects").select("id, name");
  const hit = (data ?? []).find((p) => p.name.toLowerCase() === n.toLowerCase() || p.id === n);
  if (!hit) throw new Error(`No project called "${n}". Use list_projects to see them.`);
  return hit.id;
}

function summaryMarkdown(s: any): string {
  if (!s) return "";
  const out = [s.text ?? ""];
  for (const t of s.topics ?? []) out.push("", `#### ${t.title}`, t.lead, ...t.points.map((p: string) => `* ${p}`));
  if ((s.actionItems ?? []).length) {
    out.push("", "### Action Items");
    for (const o of s.actionItems) out.push("", `#### ${o.name}`, ...o.items.map((i: string) => `* ${i}`));
  }
  return out.join("\n");
}

const tools = [
  {
    name: "list_upcoming_meetings",
    description: "The owner's upcoming calls from their Mac calendar (meetings with a Zoom, Meet, FaceTime or Teams link).",
    inputSchema: { type: "object", properties: { days: { type: "number", description: "How many days ahead, default 7" } } },
    run: async (a: Args) => {
      const until = new Date(Date.now() + num(a.days, 7) * 86_400_000).toISOString();
      const { data, error } = await db.from("calendar_events").select("*")
        .gte("ends_at", new Date().toISOString()).lte("starts_at", until).order("starts_at");
      if (error) throw error;
      return data;
    },
  },
  {
    name: "list_meetings",
    description: "Recorded meetings, newest first, with title, date, duration, project and the one-line summary.",
    inputSchema: {
      type: "object",
      properties: {
        project: { type: "string", description: "Project name, e.g. Work" },
        since: { type: "string", description: "ISO date, only meetings after it" },
        limit: { type: "number", description: "Default 20" },
      },
    },
    run: async (a: Args) => {
      let q = db.from("meetings").select("id, title, started_at, duration_s, app_name, project_id, summary").eq("deleted", false).order("started_at", { ascending: false }).limit(num(a.limit, 20));
      const p = await projectId(a.project);
      if (p) q = q.eq("project_id", p);
      if (str(a.since)) q = q.gte("started_at", str(a.since)!);
      const { data, error } = await q;
      if (error) throw error;
      return data.map((m) => ({ ...m, minutes: Math.round(m.duration_s / 60), summary: m.summary?.text ?? null, duration_s: undefined }));
    },
  },
  {
    name: "get_transcript",
    description: "The full transcript of one meeting (Me = the owner), plus its summary and notes.",
    inputSchema: { type: "object", required: ["meeting_id"], properties: { meeting_id: { type: "string" } } },
    run: async (a: Args) => {
      const { data, error } = await db.from("meetings").select("id, title, started_at, transcript_text, summary, notes").eq("deleted", false).eq("id", str(a.meeting_id)).single();
      if (error) throw new Error("No meeting with that id. Use list_meetings or search_transcripts.");
      return { id: data.id, title: data.title, started_at: data.started_at, summary: summaryMarkdown(data.summary), notes: data.notes, transcript: data.transcript_text };
    },
  },
  {
    name: "search_transcripts",
    description: "Find meetings whose title or transcript mention the words. Returns ids to use with get_transcript.",
    inputSchema: { type: "object", required: ["query"], properties: { query: { type: "string" }, limit: { type: "number" } } },
    run: async (a: Args) => {
      const words = (str(a.query) ?? "").split(/\s+/).filter(Boolean).join(" & ");
      const { data, error } = await db.from("meetings").select("id, title, started_at, summary").eq("deleted", false)
        .textSearch("transcript_text", words, { config: "simple" }).order("started_at", { ascending: false }).limit(num(a.limit, 10));
      if (error) throw error;
      return data.map((m) => ({ id: m.id, title: m.title, started_at: m.started_at, summary: m.summary?.text ?? null }));
    },
  },
  {
    name: "list_projects",
    description: "The owner's projects (tags for meetings and tasks).",
    inputSchema: { type: "object", properties: {} },
    run: async () => {
      const { data, error } = await db.from("projects").select("id, name, note").order("sort");
      if (error) throw error;
      return data;
    },
  },
  {
    name: "list_tasks",
    description: "The owner's tasks in Mochi. Status is todo, in-progress, blocked or done; open tasks by default.",
    inputSchema: {
      type: "object",
      properties: {
        status: { type: "string", enum: [...STATUSES, "open", "all"], description: "Default open (everything but done)" },
        project: { type: "string" },
      },
    },
    run: async (a: Args) => {
      let q = db.from("tasks").select("id, text, notes, status, due, blocked_reason, project_id, meeting_id, created_at").eq("deleted", false).order("due", { nullsFirst: false });
      const s = str(a.status) ?? "open";
      if (s === "open") q = q.neq("status", "done");
      else if (s !== "all") q = q.eq("status", s);
      const p = await projectId(a.project);
      if (p) q = q.eq("project_id", p);
      const { data, error } = await q;
      if (error) throw error;
      return data;
    },
  },
  {
    name: "create_task",
    description: "Add a task to the owner's Mochi task list. It appears in the Mochi app on their Mac.",
    inputSchema: {
      type: "object",
      required: ["text"],
      properties: {
        text: { type: "string", description: "A short title, a verb first, at most about 8 words, e.g. 'Send Dana the episode-three stills'" },
        notes: { type: "string", description: "Optional detail under the title: context, links, steps" },
        due: { type: "string", description: "YYYY-MM-DD" },
        project: { type: "string", description: "Project name" },
        meeting_id: { type: "string" },
        status: { type: "string", enum: STATUSES },
      },
    },
    run: async (a: Args) => {
      const text = str(a.text);
      if (!text) throw new Error("text is required");
      const row = {
        id: crypto.randomUUID(), text, notes: str(a.notes) ?? null, status: STATUSES.includes(str(a.status) ?? "") ? str(a.status) : "todo",
        due: str(a.due) ?? null, project_id: (await projectId(a.project)) ?? null, meeting_id: str(a.meeting_id) ?? null,
        source: "claude", updated_at: new Date().toISOString(),
      };
      const { data, error } = await db.from("tasks").insert(row).select().single();
      if (error) throw error;
      return data;
    },
  },
  {
    name: "update_task",
    description: "Change a task: its title (text), notes, status (todo, in-progress, blocked, done), due date, blocked reason or project.",
    inputSchema: {
      type: "object",
      required: ["id"],
      properties: {
        id: { type: "string" },
        text: { type: "string" },
        notes: { type: "string", description: "Replaces the notes; empty to clear" },
        status: { type: "string", enum: STATUSES },
        due: { type: "string", description: "YYYY-MM-DD, or empty to clear" },
        blocked_reason: { type: "string" },
        project: { type: "string" },
      },
    },
    run: async (a: Args) => {
      const patch: Record<string, unknown> = { updated_at: new Date().toISOString() };
      if (str(a.text)) patch.text = str(a.text);
      if (str(a.status)) {
        if (!STATUSES.includes(str(a.status)!)) throw new Error("status must be todo, in-progress, blocked or done");
        patch.status = str(a.status);
        patch.done_at = str(a.status) === "done" ? new Date().toISOString() : null;
      }
      if (typeof a.notes === "string") patch.notes = str(a.notes) ?? null;
      if (typeof a.due === "string") patch.due = str(a.due) ?? null;
      if (typeof a.blocked_reason === "string") patch.blocked_reason = str(a.blocked_reason) ?? null;
      const p = await projectId(a.project);
      if (p !== undefined) patch.project_id = p;
      const { data, error } = await db.from("tasks").update(patch).eq("id", str(a.id)).select().single();
      if (error) throw new Error("No task with that id. Use list_tasks.");
      return data;
    },
  },
];

const reply = (id: unknown, result: unknown) =>
  new Response(JSON.stringify({ jsonrpc: "2.0", id, result }), { headers: { "content-type": "application/json" } });
const fail = (id: unknown, code: number, message: string) =>
  new Response(JSON.stringify({ jsonrpc: "2.0", id, error: { code, message } }), { headers: { "content-type": "application/json" } });

Deno.serve(async (req) => {
  const token = Deno.env.get("MOCHI_MCP_TOKEN");
  const given = (req.headers.get("x-api-key") ?? req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!token || given !== token) return new Response("Unauthorized", { status: 401 });
  if (req.method === "GET") return new Response("Method not allowed", { status: 405 });   // no server-sent stream
  if (req.method === "DELETE") return new Response(null, { status: 204 });
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  const msg = await req.json();
  if (Array.isArray(msg)) return fail(null, -32600, "Batches are not supported");
  if (msg.id === undefined || msg.id === null) return new Response(null, { status: 202 });   // a notification

  switch (msg.method) {
    case "initialize":
      return reply(msg.id, {
        protocolVersion: msg.params?.protocolVersion ?? "2025-06-18",
        capabilities: { tools: {} },
        serverInfo: { name: "mochi", version: "1.0.0" },
        instructions: "Mochi is the owner's meeting recorder. Use it to read their meeting transcripts and summaries, see upcoming calls, and read or update their task list. 'Me' in transcripts is the owner.",
      });
    case "ping":
      return reply(msg.id, {});
    case "tools/list":
      return reply(msg.id, { tools: tools.map(({ run: _run, ...t }) => t) });
    case "tools/call": {
      const tool = tools.find((t) => t.name === msg.params?.name);
      if (!tool) return fail(msg.id, -32602, `Unknown tool ${msg.params?.name}`);
      try {
        const out = await tool.run(msg.params?.arguments ?? {});
        return reply(msg.id, { content: [{ type: "text", text: JSON.stringify(out, null, 1) }] });
      } catch (e) {
        return reply(msg.id, { content: [{ type: "text", text: (e as Error).message ?? String(e) }], isError: true });
      }
    }
    default:
      return fail(msg.id, -32601, `Method not found: ${msg.method}`);
  }
});
