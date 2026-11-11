-- 3 Nov 2026: tasks get a short title (text) plus optional notes, like Apple Reminders.
alter table public.tasks add column if not exists notes text;
