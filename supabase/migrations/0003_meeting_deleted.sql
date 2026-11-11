-- 1 Nov 2026: a deleted call syncs as a tombstone so every Mac removes it.
alter table public.meetings add column if not exists deleted boolean not null default false;
