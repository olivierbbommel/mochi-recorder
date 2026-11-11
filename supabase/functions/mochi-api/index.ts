// mochi-api: the apps' sync endpoint. Auth: a signed-in account ("Authorization: Bearer <access
// token>") whose email is MOCHI_OWNER_EMAIL, or (Macs set up before accounts) x-mochi-token equal
// to MOCHI_SYNC_TOKEN.
//   {action: "push", projects, meetings, tasks, events}  upserts; a task only wins when it is newer
//   {action: "pull", since}                               projects and tasks changed since `since`
//   Projects and tasks only win when newer; a project may carry a one-line note.
//   {action: "latest"}                                    the newest release and a 15 minute download link
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

async function allowed(req: Request): Promise<boolean> {
  const legacy = req.headers.get("x-mochi-token");
  if (legacy && legacy === Deno.env.get("MOCHI_SYNC_TOKEN")) return true;
  const jwt = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!jwt) return false;
  const { data, error } = await db.auth.getUser(jwt);
  const owner = (Deno.env.get("MOCHI_OWNER_EMAIL") ?? "").toLowerCase();
  return !error && !!owner && data.user?.email?.toLowerCase() === owner;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  if (!(await allowed(req))) return json({ error: "unauthorized" }, 401);
  const body = await req.json();

  if (body.action === "push") {
    if (body.projects?.length) {
      // Like tasks, a project only wins when its edit is newer (or equally new), so one device's
      // older copy never undoes a note or a rename made on another.
      const ids = body.projects.map((p: { id: string }) => p.id);
      const { data: existing } = await db.from("projects").select("id, updated_at").in("id", ids);
      const known = new Map((existing ?? []).map((p) => [p.id, Date.parse(p.updated_at)]));
      const newer = body.projects.filter((p: { id: string; updated_at: string }) =>
        !known.has(p.id) || Date.parse(p.updated_at) >= (known.get(p.id) ?? 0));
      if (newer.length) {
        const { error } = await db.from("projects").upsert(newer);
        if (error) return json({ error: error.message }, 500);
      }
    }
    if (body.meetings?.length) {
      // A deleted call stays deleted, and an older copy never overwrites a newer one.
      const ids = body.meetings.map((m: { id: string }) => m.id);
      const { data: existing } = await db.from("meetings").select("id, updated_at, deleted").in("id", ids);
      const known = new Map((existing ?? []).map((m) => [m.id, m]));
      const newer = body.meetings.filter((m: { id: string; updated_at: string }) => {
        const k = known.get(m.id);
        return !k || (!k.deleted && Date.parse(m.updated_at) >= Date.parse(k.updated_at));
      });
      if (newer.length) {
        const { error } = await db.from("meetings").upsert(newer);
        if (error) return json({ error: error.message }, 500);
      }
    }
    if (body.tasks?.length) {
      const ids = body.tasks.map((t: { id: string }) => t.id);
      const { data: existing } = await db.from("tasks").select("id, updated_at").in("id", ids);
      const known = new Map((existing ?? []).map((t) => [t.id, Date.parse(t.updated_at)]));
      const newer = body.tasks.filter((t: { id: string; updated_at: string }) =>
        !known.has(t.id) || Date.parse(t.updated_at) > (known.get(t.id) ?? 0));
      if (newer.length) {
        const { error } = await db.from("tasks").upsert(newer);
        if (error) return json({ error: error.message }, 500);
      }
    }
    if (body.events) {
      await db.from("calendar_events").delete().neq("id", "");
      if (body.events.length) {
        const { error } = await db.from("calendar_events").insert(body.events);
        if (error) return json({ error: error.message }, 500);
      }
    }
    return json({ ok: true, at: new Date().toISOString() });
  }

  if (body.action === "pull") {
    const since = body.since ?? "1970-01-01T00:00:00Z";
    const [tasks, projects, meetings, events] = await Promise.all([
      db.from("tasks").select("*").gt("updated_at", since),
      db.from("projects").select("*").gt("updated_at", since),
      db.from("meetings").select("*").gt("updated_at", since).order("updated_at").limit(50),
      // Upcoming meetings come from the Macs' calendars; the iPhone shows them.
      db.from("calendar_events").select("*").gte("ends_at", new Date().toISOString()).order("starts_at"),
    ]);
    const err = tasks.error ?? projects.error ?? meetings.error ?? events.error;
    if (err) return json({ error: err.message }, 500);
    // At most 50 meetings per pull; "at" then stops at the last one so the next pull continues.
    const full = (meetings.data ?? []).length === 50;
    const at = full ? meetings.data![49].updated_at : new Date().toISOString();
    return json({ tasks: tasks.data, projects: projects.data, meetings: meetings.data, events: events.data, at });
  }

  if (body.action === "latest") {
    const { data: file, error } = await db.storage.from("releases").download("mochi/latest.json");
    if (error || !file) return json({ release: null });
    const release = JSON.parse(await file.text());
    const { data: signed } = await db.storage.from("releases").createSignedUrl(release.path, 900);
    return json({ release: { ...release, url: signed?.signedUrl } });
  }

  return json({ error: "unknown action" }, 400);
});
