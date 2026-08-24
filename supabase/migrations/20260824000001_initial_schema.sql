-- Jeju Connect — initial schema
-- Content types: places, events, articles. Shared: contributors, media.
-- Moderation state lives on every content table and is enforced by RLS
-- (see 20260824000002_rls_policies.sql).

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------

create type public.content_status as enum ('pending', 'approved', 'rejected');

create type public.contributor_role as enum ('contributor', 'moderator', 'admin');

create type public.place_category as enum (
  'restaurant',
  'cafe',
  'bar',
  'shop',
  'service',
  'outdoor',
  'accommodation',
  'healthcare',
  'education',
  'government',
  'other'
);

create type public.event_category as enum (
  'social',
  'music',
  'food',
  'outdoor',
  'sports',
  'arts',
  'language',
  'family',
  'market',
  'other'
);

-- ---------------------------------------------------------------------------
-- contributors
--
-- One row per authenticated user, keyed to auth.users. Created automatically
-- by the handle_new_user() trigger below, never inserted by clients.
-- ---------------------------------------------------------------------------

create table public.contributors (
  id           uuid primary key references auth.users (id) on delete cascade,
  display_name text not null,
  avatar_url   text,
  role         public.contributor_role not null default 'contributor',
  created_at   timestamptz not null default now()
);

comment on table public.contributors is
  'Public profile per authenticated user. Role changes are service-role only.';

-- Populate a contributor row whenever a new auth user appears.
-- Defensive about provider metadata shape: Facebook, Kakao and Naver each
-- nest the display name differently (Naver in particular returns its payload
-- under a "response" key, which Supabase flattens into raw_user_meta_data).
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.contributors (id, display_name, avatar_url)
  values (
    new.id,
    coalesce(
      nullif(new.raw_user_meta_data ->> 'full_name', ''),
      nullif(new.raw_user_meta_data ->> 'name', ''),
      nullif(new.raw_user_meta_data ->> 'nickname', ''),
      nullif(new.raw_user_meta_data ->> 'preferred_username', ''),
      'Jeju Connect member'
    ),
    nullif(
      coalesce(
        new.raw_user_meta_data ->> 'avatar_url',
        new.raw_user_meta_data ->> 'picture',
        new.raw_user_meta_data ->> 'profile_image'
      ),
      ''
    )
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- Shared moderation helpers
-- ---------------------------------------------------------------------------

-- SECURITY DEFINER so RLS policies on content tables can check the caller's
-- role without recursing into contributors' own RLS policies.
create or replace function public.is_moderator()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.contributors
    where id = auth.uid()
      and role in ('moderator', 'admin')
  );
$$;

-- Forces every client insert to land as 'pending' and attributes it to the
-- caller. Belt-and-braces with the RLS WITH CHECK clauses: the trigger
-- rewrites hostile input rather than rejecting it, RLS rejects anything the
-- trigger somehow missed. coalesce on submitted_by keeps service-role
-- seeding (where auth.uid() is null) working.
create or replace function public.force_pending_submission()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  new.content_status  := 'pending';
  new.reviewed_by     := null;
  new.reviewed_at     := null;
  new.moderator_notes := null;
  new.submitted_by    := coalesce(auth.uid(), new.submitted_by);
  new.created_at      := now();
  new.updated_at      := now();
  return new;
end;
$$;

-- Stamps the moderation audit trail whenever content_status actually changes.
create or replace function public.stamp_moderation_review()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.content_status is distinct from old.content_status then
    new.reviewed_by := coalesce(auth.uid(), new.reviewed_by);
    new.reviewed_at := now();
  end if;

  new.updated_at := now();
  return new;
end;
$$;

-- Blocks privilege escalation: a user may edit their own profile, but only
-- the service role may change a role.
create or replace function public.guard_contributor_role()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.role is distinct from old.role and auth.uid() is not null then
    raise exception 'contributor role may only be changed by the service role';
  end if;

  return new;
end;
$$;

create trigger contributors_guard_role
  before update on public.contributors
  for each row execute function public.guard_contributor_role();

-- ---------------------------------------------------------------------------
-- places
-- ---------------------------------------------------------------------------

create table public.places (
  id             uuid primary key default gen_random_uuid(),
  name           text not null check (length(trim(name)) between 1 and 200),
  slug           text unique,
  category       public.place_category not null default 'other',
  description    text check (length(description) <= 5000),

  -- address_ko is deliberately separate: expats routinely need the Korean
  -- form to show a taxi driver or type into Kakao Map.
  address        text,
  address_ko     text,
  latitude       double precision not null check (latitude between -90 and 90),
  longitude      double precision not null check (longitude between -180 and 180),

  phone          text,
  website        text,
  hours          text,

  content_status  public.content_status not null default 'pending',
  submitted_by    uuid not null references public.contributors (id) on delete cascade,
  reviewed_by     uuid references public.contributors (id) on delete set null,
  reviewed_at     timestamptz,
  moderator_notes text,

  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create trigger places_force_pending
  before insert on public.places
  for each row execute function public.force_pending_submission();

create trigger places_stamp_review
  before update on public.places
  for each row execute function public.stamp_moderation_review();

-- Partial index: the public map view only ever reads approved rows.
create index places_approved_idx
  on public.places (created_at desc)
  where content_status = 'approved';

-- Bounding-box lookups for the map viewport.
create index places_approved_geo_idx
  on public.places (latitude, longitude)
  where content_status = 'approved';

create index places_moderation_queue_idx
  on public.places (created_at)
  where content_status = 'pending';

create index places_submitted_by_idx on public.places (submitted_by);

-- ---------------------------------------------------------------------------
-- events
-- ---------------------------------------------------------------------------

create table public.events (
  id           uuid primary key default gen_random_uuid(),
  title        text not null check (length(trim(title)) between 1 and 200),
  slug         text unique,
  category     public.event_category not null default 'other',
  description  text check (length(description) <= 5000),

  -- Location is optional: some community events are online-only.
  venue_name   text,
  address      text,
  address_ko   text,
  latitude     double precision check (latitude between -90 and 90),
  longitude    double precision check (longitude between -180 and 180),

  starts_at    timestamptz not null,
  ends_at      timestamptz,
  cost_krw     integer check (cost_krw >= 0),
  external_url text,

  content_status  public.content_status not null default 'pending',
  submitted_by    uuid not null references public.contributors (id) on delete cascade,
  reviewed_by     uuid references public.contributors (id) on delete set null,
  reviewed_at     timestamptz,
  moderator_notes text,

  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),

  constraint events_end_after_start check (ends_at is null or ends_at > starts_at),
  -- Either both coordinates or neither; a lone latitude is meaningless.
  constraint events_coords_paired check (
    (latitude is null) = (longitude is null)
  )
);

create trigger events_force_pending
  before insert on public.events
  for each row execute function public.force_pending_submission();

create trigger events_stamp_review
  before update on public.events
  for each row execute function public.stamp_moderation_review();

create index events_approved_upcoming_idx
  on public.events (starts_at)
  where content_status = 'approved';

create index events_moderation_queue_idx
  on public.events (created_at)
  where content_status = 'pending';

create index events_submitted_by_idx on public.events (submitted_by);

-- ---------------------------------------------------------------------------
-- articles
-- ---------------------------------------------------------------------------

create table public.articles (
  id            uuid primary key default gen_random_uuid(),
  title         text not null check (length(trim(title)) between 1 and 200),
  slug          text not null unique,
  excerpt       text check (length(excerpt) <= 500),
  body_markdown text not null check (length(trim(body_markdown)) > 0),
  tags          text[] not null default '{}',
  published_at  timestamptz,

  content_status  public.content_status not null default 'pending',
  submitted_by    uuid not null references public.contributors (id) on delete cascade,
  reviewed_by     uuid references public.contributors (id) on delete set null,
  reviewed_at     timestamptz,
  moderator_notes text,

  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create trigger articles_force_pending
  before insert on public.articles
  for each row execute function public.force_pending_submission();

create trigger articles_stamp_review
  before update on public.articles
  for each row execute function public.stamp_moderation_review();

create index articles_approved_idx
  on public.articles (coalesce(published_at, created_at) desc)
  where content_status = 'approved';

create index articles_moderation_queue_idx
  on public.articles (created_at)
  where content_status = 'pending';

create index articles_submitted_by_idx on public.articles (submitted_by);

create index articles_tags_idx on public.articles using gin (tags);

-- ---------------------------------------------------------------------------
-- media
--
-- Rows point at objects in the 'media' Storage bucket. A media row may attach
-- to at most one piece of content; all three FKs null means "uploaded but not
-- yet attached", which is the normal state mid-submission.
-- ---------------------------------------------------------------------------

create table public.media (
  id           uuid primary key default gen_random_uuid(),
  storage_path text not null unique,
  alt_text     text check (length(alt_text) <= 300),
  content_type text,
  width        integer check (width > 0),
  height       integer check (height > 0),
  byte_size    integer check (byte_size > 0),

  place_id     uuid references public.places (id) on delete cascade,
  event_id     uuid references public.events (id) on delete cascade,
  article_id   uuid references public.articles (id) on delete cascade,

  uploaded_by  uuid not null references public.contributors (id) on delete cascade,
  created_at   timestamptz not null default now(),

  constraint media_single_owner check (
    (place_id is not null)::int
    + (event_id is not null)::int
    + (article_id is not null)::int
    <= 1
  )
);

create index media_place_idx   on public.media (place_id)   where place_id is not null;
create index media_event_idx   on public.media (event_id)   where event_id is not null;
create index media_article_idx on public.media (article_id) where article_id is not null;
create index media_uploaded_by_idx on public.media (uploaded_by);

-- Orphan sweep target: media with no owner older than a day is abandoned
-- upload debris from forms that were never submitted.
create index media_orphans_idx
  on public.media (created_at)
  where place_id is null and event_id is null and article_id is null;
