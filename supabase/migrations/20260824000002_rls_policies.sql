-- Jeju Connect — Row Level Security
--
-- The moderation contract, enforced in the database rather than app code:
--   1. Anonymous and authenticated readers only ever see content_status = 'approved'.
--   2. Authenticated inserts always land as 'pending' — no client-side self-approval.
--   3. Only moderators may change content_status.
--   4. Authors may read back their own submissions (to see review outcomes),
--      but not edit or delete them.
--
-- service_role bypasses RLS entirely (it carries BYPASSRLS), so server-side
-- admin tooling and seeding are unaffected by any policy below.

-- ---------------------------------------------------------------------------
-- Helper functions for media ownership checks
--
-- SECURITY DEFINER so that a media policy can inspect a parent row without
-- being filtered by that parent table's own RLS policies.
-- ---------------------------------------------------------------------------

create or replace function public.content_is_approved(
  p_place uuid,
  p_event uuid,
  p_article uuid
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select case
    when p_place is not null then
      exists (select 1 from public.places   where id = p_place   and content_status = 'approved')
    when p_event is not null then
      exists (select 1 from public.events   where id = p_event   and content_status = 'approved')
    when p_article is not null then
      exists (select 1 from public.articles where id = p_article and content_status = 'approved')
    else false
  end;
$$;

-- True when the media row is unattached (normal mid-submission state) or is
-- attached to content the caller submitted. Prevents a user from bolting
-- their own images onto someone else's listing.
create or replace function public.owns_referenced_content(
  p_place uuid,
  p_event uuid,
  p_article uuid
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select case
    when p_place is not null then
      exists (select 1 from public.places   where id = p_place   and submitted_by = auth.uid())
    when p_event is not null then
      exists (select 1 from public.events   where id = p_event   and submitted_by = auth.uid())
    when p_article is not null then
      exists (select 1 from public.articles where id = p_article and submitted_by = auth.uid())
    else true
  end;
$$;

-- ---------------------------------------------------------------------------
-- contributors
-- ---------------------------------------------------------------------------

alter table public.contributors enable row level security;

-- Display names are public: they appear as attribution on approved content.
-- No email or provider identifier is stored on this table.
create policy contributors_select_public
  on public.contributors
  for select
  to anon, authenticated
  using (true);

create policy contributors_update_own
  on public.contributors
  for update
  to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- No insert policy: rows are created solely by the handle_new_user() trigger.
-- No delete policy: profile deletion cascades from auth.users.

-- ---------------------------------------------------------------------------
-- places
-- ---------------------------------------------------------------------------

alter table public.places enable row level security;

create policy places_select_approved
  on public.places
  for select
  to anon, authenticated
  using (content_status = 'approved');

create policy places_select_own
  on public.places
  for select
  to authenticated
  using (submitted_by = auth.uid());

create policy places_select_moderator
  on public.places
  for select
  to authenticated
  using (public.is_moderator());

create policy places_insert_authenticated
  on public.places
  for insert
  to authenticated
  with check (
    submitted_by = auth.uid()
    and content_status = 'pending'
    and reviewed_by is null
    and reviewed_at is null
    and moderator_notes is null
  );

create policy places_update_moderator
  on public.places
  for update
  to authenticated
  using (public.is_moderator())
  with check (public.is_moderator());

create policy places_delete_moderator
  on public.places
  for delete
  to authenticated
  using (public.is_moderator());

-- ---------------------------------------------------------------------------
-- events
-- ---------------------------------------------------------------------------

alter table public.events enable row level security;

create policy events_select_approved
  on public.events
  for select
  to anon, authenticated
  using (content_status = 'approved');

create policy events_select_own
  on public.events
  for select
  to authenticated
  using (submitted_by = auth.uid());

create policy events_select_moderator
  on public.events
  for select
  to authenticated
  using (public.is_moderator());

create policy events_insert_authenticated
  on public.events
  for insert
  to authenticated
  with check (
    submitted_by = auth.uid()
    and content_status = 'pending'
    and reviewed_by is null
    and reviewed_at is null
    and moderator_notes is null
  );

create policy events_update_moderator
  on public.events
  for update
  to authenticated
  using (public.is_moderator())
  with check (public.is_moderator());

create policy events_delete_moderator
  on public.events
  for delete
  to authenticated
  using (public.is_moderator());

-- ---------------------------------------------------------------------------
-- articles
-- ---------------------------------------------------------------------------

alter table public.articles enable row level security;

create policy articles_select_approved
  on public.articles
  for select
  to anon, authenticated
  using (content_status = 'approved');

create policy articles_select_own
  on public.articles
  for select
  to authenticated
  using (submitted_by = auth.uid());

create policy articles_select_moderator
  on public.articles
  for select
  to authenticated
  using (public.is_moderator());

create policy articles_insert_authenticated
  on public.articles
  for insert
  to authenticated
  with check (
    submitted_by = auth.uid()
    and content_status = 'pending'
    and reviewed_by is null
    and reviewed_at is null
    and moderator_notes is null
  );

create policy articles_update_moderator
  on public.articles
  for update
  to authenticated
  using (public.is_moderator())
  with check (public.is_moderator());

create policy articles_delete_moderator
  on public.articles
  for delete
  to authenticated
  using (public.is_moderator());

-- ---------------------------------------------------------------------------
-- media
-- ---------------------------------------------------------------------------

alter table public.media enable row level security;

-- Public readers only see images whose parent content is approved. Unattached
-- media is invisible to the public.
create policy media_select_approved
  on public.media
  for select
  to anon, authenticated
  using (public.content_is_approved(place_id, event_id, article_id));

create policy media_select_own
  on public.media
  for select
  to authenticated
  using (uploaded_by = auth.uid());

create policy media_select_moderator
  on public.media
  for select
  to authenticated
  using (public.is_moderator());

create policy media_insert_own
  on public.media
  for insert
  to authenticated
  with check (
    uploaded_by = auth.uid()
    and public.owns_referenced_content(place_id, event_id, article_id)
  );

-- Authors may attach their own uploads to their own content, and nothing else.
create policy media_update_own
  on public.media
  for update
  to authenticated
  using (uploaded_by = auth.uid())
  with check (
    uploaded_by = auth.uid()
    and public.owns_referenced_content(place_id, event_id, article_id)
  );

create policy media_delete_own
  on public.media
  for delete
  to authenticated
  using (uploaded_by = auth.uid());

create policy media_update_moderator
  on public.media
  for update
  to authenticated
  using (public.is_moderator())
  with check (public.is_moderator());

create policy media_delete_moderator
  on public.media
  for delete
  to authenticated
  using (public.is_moderator());

-- ---------------------------------------------------------------------------
-- Table privileges
--
-- RLS narrows what a role can touch, but only if the role holds the privilege
-- in the first place. These grants are stated explicitly rather than relying
-- on Supabase's default privileges, so the schema is reproducible anywhere.
--
-- Note the column-level UPDATE grant on contributors: Postgres refuses an
-- UPDATE touching `role` outright, which is a harder guarantee than a policy
-- predicate. guard_contributor_role() is the second line of defence.
-- ---------------------------------------------------------------------------

revoke all on public.contributors from anon, authenticated;
grant select on public.contributors to anon, authenticated;
grant update (display_name, avatar_url) on public.contributors to authenticated;

revoke all on public.places from anon, authenticated;
grant select on public.places to anon, authenticated;
grant insert, update, delete on public.places to authenticated;

revoke all on public.events from anon, authenticated;
grant select on public.events to anon, authenticated;
grant insert, update, delete on public.events to authenticated;

revoke all on public.articles from anon, authenticated;
grant select on public.articles to anon, authenticated;
grant insert, update, delete on public.articles to authenticated;

revoke all on public.media from anon, authenticated;
grant select on public.media to anon, authenticated;
grant insert, update, delete on public.media to authenticated;

-- Helper functions are called from within policies; anon needs execute for
-- the public read paths to evaluate.
grant execute on function public.is_moderator() to anon, authenticated;
grant execute on function public.content_is_approved(uuid, uuid, uuid) to anon, authenticated;
grant execute on function public.owns_referenced_content(uuid, uuid, uuid) to anon, authenticated;
