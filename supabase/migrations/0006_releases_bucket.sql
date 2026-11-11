-- The private bucket release.sh uploads builds to. mochi-api hands out 15 minute download links.
insert into storage.buckets (id, name, public)
values ('releases', 'releases', false)
on conflict (id) do nothing;
