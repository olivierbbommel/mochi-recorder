
-- 1 Nov 2026: which Mac recorded the call (calls sync between Macs, audio stays on the recording Mac).
alter table public.meetings add column if not exists device text;
