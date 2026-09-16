-- Explore Philippines Map
-- Anonymous name + usage + presence tracking
-- Run this whole file in Supabase SQL Editor.

create extension if not exists pgcrypto;

create table if not exists public.pmm_users (
  id uuid primary key,
  name text not null check (char_length(trim(name)) between 2 and 80),
  first_seen timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  session_count integer not null default 0,
  quiz_started_count integer not null default 0,
  quiz_completed_count integer not null default 0,
  last_mode text,
  updated_at timestamptz not null default now()
);

create table if not exists public.pmm_user_events (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.pmm_users(id) on delete cascade,
  name text not null,
  session_id text not null,
  event_type text not null,
  mode text,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.pmm_presence (
  user_id uuid primary key references public.pmm_users(id) on delete cascade,
  name text not null,
  mode text,
  last_seen timestamptz not null default now()
);

create index if not exists pmm_users_last_seen_idx on public.pmm_users(last_seen desc);
create index if not exists pmm_events_user_created_idx on public.pmm_user_events(user_id, created_at desc);
create index if not exists pmm_presence_last_seen_idx on public.pmm_presence(last_seen desc);

-- Tables are intentionally not directly readable/writable from the public browser role.
-- The browser uses only the narrowly-scoped RPC functions below.
alter table public.pmm_users enable row level security;
alter table public.pmm_user_events enable row level security;
alter table public.pmm_presence enable row level security;

revoke all on public.pmm_users from anon, authenticated;
revoke all on public.pmm_user_events from anon, authenticated;
revoke all on public.pmm_presence from anon, authenticated;

create or replace function public.pmm_upsert_user(
  p_user_id uuid,
  p_name text,
  p_session_id text,
  p_mode text default null,
  p_new_session boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  clean_name text := left(regexp_replace(trim(coalesce(p_name,'')), '\s+', ' ', 'g'), 80);
  result public.pmm_users;
begin
  if p_user_id is null or char_length(clean_name) < 2 then
    raise exception 'Invalid user data';
  end if;

  insert into public.pmm_users(id, name, first_seen, last_seen, session_count, last_mode, updated_at)
  values(p_user_id, clean_name, now(), now(), case when p_new_session then 1 else 0 end, nullif(p_mode,''), now())
  on conflict (id) do update set
    name = excluded.name,
    last_seen = now(),
    last_mode = coalesce(excluded.last_mode, public.pmm_users.last_mode),
    session_count = public.pmm_users.session_count + case when p_new_session then 1 else 0 end,
    updated_at = now()
  returning * into result;

  return jsonb_build_object(
    'id', result.id,
    'name', result.name,
    'first_seen', result.first_seen,
    'last_seen', result.last_seen,
    'session_count', result.session_count
  );
end;
$$;

create or replace function public.pmm_heartbeat(
  p_user_id uuid,
  p_name text,
  p_mode text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  clean_name text := left(regexp_replace(trim(coalesce(p_name,'')), '\s+', ' ', 'g'), 80);
begin
  if p_user_id is null or char_length(clean_name) < 2 then
    return;
  end if;

  insert into public.pmm_users(id, name, first_seen, last_seen, session_count, last_mode, updated_at)
  values(p_user_id, clean_name, now(), now(), 0, nullif(p_mode,''), now())
  on conflict (id) do update set
    name = excluded.name,
    last_seen = now(),
    last_mode = coalesce(excluded.last_mode, public.pmm_users.last_mode),
    updated_at = now();

  insert into public.pmm_presence(user_id, name, mode, last_seen)
  values(p_user_id, clean_name, nullif(p_mode,''), now())
  on conflict (user_id) do update set
    name = excluded.name,
    mode = excluded.mode,
    last_seen = now();
end;
$$;

create or replace function public.pmm_record_event(
  p_user_id uuid,
  p_name text,
  p_session_id text,
  p_event_type text,
  p_mode text default null,
  p_payload jsonb default '{}'::jsonb
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  clean_name text := left(regexp_replace(trim(coalesce(p_name,'')), '\s+', ' ', 'g'), 80);
  clean_type text := left(trim(coalesce(p_event_type,'')), 60);
  new_id bigint;
begin
  if p_user_id is null or char_length(clean_name) < 2 or char_length(clean_type) < 1 then
    raise exception 'Invalid event data';
  end if;

  insert into public.pmm_users(id, name, first_seen, last_seen, session_count, last_mode, updated_at)
  values(p_user_id, clean_name, now(), now(), 0, nullif(p_mode,''), now())
  on conflict (id) do update set
    name = excluded.name,
    last_seen = now(),
    last_mode = coalesce(excluded.last_mode, public.pmm_users.last_mode),
    updated_at = now();

  insert into public.pmm_user_events(user_id, name, session_id, event_type, mode, payload)
  values(p_user_id, clean_name, left(coalesce(p_session_id,''),120), clean_type, nullif(left(coalesce(p_mode,''),60),''), coalesce(p_payload,'{}'::jsonb))
  returning id into new_id;

  if clean_type = 'quiz_started' then
    update public.pmm_users set quiz_started_count = quiz_started_count + 1, last_seen = now(), updated_at = now() where id = p_user_id;
  elsif clean_type = 'quiz_completed' then
    update public.pmm_users set quiz_completed_count = quiz_completed_count + 1, last_seen = now(), updated_at = now() where id = p_user_id;
  else
    update public.pmm_users set last_seen = now(), updated_at = now() where id = p_user_id;
  end if;

  return new_id;
end;
$$;

create or replace function public.pmm_online_count()
returns bigint
language sql
security definer
set search_path = public
as $$
  select count(*)::bigint
  from public.pmm_presence
  where last_seen >= now() - interval '90 seconds';
$$;

grant execute on function public.pmm_upsert_user(uuid,text,text,text,boolean) to anon, authenticated;
grant execute on function public.pmm_heartbeat(uuid,text,text) to anon, authenticated;
grant execute on function public.pmm_record_event(uuid,text,text,text,text,jsonb) to anon, authenticated;
grant execute on function public.pmm_online_count() to anon, authenticated;

-- Optional manual cleanup. Presence naturally becomes offline after 90 seconds;
-- this keeps old rows from accumulating forever.
create or replace function public.pmm_cleanup_presence()
returns integer
language sql
security definer
set search_path = public
as $$
  with deleted as (
    delete from public.pmm_presence
    where last_seen < now() - interval '1 day'
    returning 1
  )
  select count(*)::integer from deleted;
$$;

revoke all on function public.pmm_cleanup_presence() from anon, authenticated;

-- Owner/admin can inspect pmm_users, pmm_user_events and pmm_presence in Supabase Table Editor.
