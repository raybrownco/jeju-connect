-- Minimal local stand-in for the Supabase-managed pieces our migrations rely on.
-- Mirrors the real definitions of auth.uid(), storage.foldername() and the
-- anon/authenticated/service_role roles closely enough to exercise RLS.

create schema if not exists auth;
create schema if not exists storage;

do $$ begin
  create role anon nologin;
exception when duplicate_object then null; end $$;

do $$ begin
  create role authenticated nologin;
exception when duplicate_object then null; end $$;

do $$ begin
  create role service_role nologin bypassrls;
exception when duplicate_object then null; end $$;

grant usage on schema public, auth, storage to anon, authenticated, service_role;

create table auth.users (
  id                 uuid primary key default gen_random_uuid(),
  email              text,
  raw_user_meta_data jsonb not null default '{}'::jsonb,
  created_at         timestamptz not null default now()
);

-- Verbatim shape of Supabase's auth.uid().
create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid;
$$;

grant execute on function auth.uid() to anon, authenticated, service_role;

create table storage.buckets (
  id                 text primary key,
  name               text not null,
  public             boolean not null default false,
  file_size_limit    bigint,
  allowed_mime_types text[],
  created_at         timestamptz not null default now()
);

create table storage.objects (
  id         uuid primary key default gen_random_uuid(),
  bucket_id  text not null references storage.buckets (id),
  name       text not null,
  owner      uuid,
  created_at timestamptz not null default now()
);

alter table storage.objects enable row level security;

create or replace function storage.foldername(name text)
returns text[]
language plpgsql
as $$
declare
  _parts text[];
begin
  select string_to_array(name, '/') into _parts;
  return _parts[1 : array_length(_parts, 1) - 1];
end;
$$;

grant execute on function storage.foldername(text) to anon, authenticated, service_role;
grant select on storage.buckets to anon, authenticated;
grant select, insert, update, delete on storage.objects to authenticated;
grant select on storage.objects to anon;

-- Test helpers -------------------------------------------------------------

create schema if not exists test;

create or replace function test.assert(cond boolean, msg text)
returns void
language plpgsql
as $$
begin
  if not cond then
    raise exception 'FAIL: %', msg;
  end if;
  raise notice '  ok  %', msg;
end;
$$;

-- Impersonate a signed-in user the way PostgREST does.
create or replace function test.login(user_id uuid)
returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', user_id)::text, false);
  execute 'set local role authenticated';
end;
$$;

create or replace function test.logout()
returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claims', '', false);
  execute 'set local role anon';
end;
$$;
