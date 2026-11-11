-- 3 Nov 2026: a one-line note per project (what it is about), so suggested tasks land in the right project.
alter table public.projects add column if not exists note text;
