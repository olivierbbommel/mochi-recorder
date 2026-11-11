-- Mochi cloud copy: text only (no audio). Written by the Mac app through the mochi-api function
-- and read or written by Claude through the mochi-mcp function. Both use service_role, so every
-- table is server-only: RLS on, no policies, no anon or authenticated grants.

create table public.projects (
  id text primary key,
  name text not null,
  color text not null default 'blue',
  sort int not null default 0,
  updated_at timestamptz not null default now()
);

create table public.meetings (
  id text primary key,                 -- the call id, 2026-11-01_112125
  title text not null,
  started_at timestamptz not null,
  duration_s double precision not null default 0,
  app_name text,
  project_id text references public.projects(id) on delete set null,
  event_id text,
  status text not null default 'ready',
  them_name text,
  mic_only boolean not null default false,
  transcript jsonb not null default '[]',   -- [{speaker, start, end, text, language}]
  transcript_text text not null default '', -- the Copy Transcript format, for search and reading
  summary jsonb,                            -- {text, topics, actionItems, provider, writtenAt}
  notes text not null default '',
  updated_at timestamptz not null default now()
);
create index meetings_started_at on public.meetings (started_at desc);
create index meetings_search on public.meetings using gin (to_tsvector('simple', title || ' ' || transcript_text));

create table public.tasks (
  id uuid primary key,
  text text not null,
  status text not null default 'todo' check (status in ('todo', 'in-progress', 'blocked', 'done')),
  meeting_id text references public.meetings(id) on delete set null,
  project_id text references public.projects(id) on delete set null,
  due date,
  blocked_reason text,
  created_at timestamptz not null default now(),
  done_at timestamptz,
  updated_at timestamptz not null default now(),
  deleted boolean not null default false,   -- a delete syncs as a tombstone
  source text not null default 'mochi'      -- 'mochi' or 'claude'
);
create index tasks_updated_at on public.tasks (updated_at);

create table public.calendar_events (
  id text primary key,
  title text not null,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  app_name text,
  attendees jsonb not null default '[]',
  calendar text,
  synced_at timestamptz not null default now()
);

-- Data API grants (required for new tables since Oct 30 2026): server-only.
grant select, insert, update, delete on public.projects, public.meetings, public.tasks, public.calendar_events to service_role;

alter table public.projects enable row level security;
alter table public.meetings enable row level security;
alter table public.tasks enable row level security;
alter table public.calendar_events enable row level security;
