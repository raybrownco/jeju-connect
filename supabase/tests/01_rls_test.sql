\set ON_ERROR_STOP on
\set QUIET on

grant usage on schema test to anon, authenticated;
grant execute on function test.assert(boolean, text) to anon, authenticated;

begin;

-- Fixed ids so assertions read clearly.
\set alice   '''aaaaaaaa-0000-4000-8000-000000000001'''
\set bob     '''bbbbbbbb-0000-4000-8000-000000000002'''
\set mod     '''cccccccc-0000-4000-8000-000000000003'''

-- ===========================================================================
\echo '== 1. handle_new_user() populates contributors from provider metadata'
-- ===========================================================================

insert into auth.users (id, email, raw_user_meta_data) values
  (:alice, 'alice@example.com', '{"full_name": "Alice Kim", "avatar_url": "https://cdn/a.jpg"}'),
  (:bob,   'bob@example.com',   '{"name": "Bob Park", "picture": "https://cdn/b.jpg"}'),
  -- Naver-shaped: Supabase flattens the nested "response" object, so the
  -- name arrives under "nickname" with the image under "profile_image".
  (:mod,   'mod@example.com',   '{"nickname": "Mina", "profile_image": "https://cdn/m.jpg"}');

do $$ begin
  perform test.assert(
    (select count(*) from public.contributors) = 3,
    'a contributors row is created for each auth user');
  perform test.assert(
    (select display_name from public.contributors where id = 'aaaaaaaa-0000-4000-8000-000000000001') = 'Alice Kim',
    'full_name is picked up (Facebook shape)');
  perform test.assert(
    (select display_name from public.contributors where id = 'bbbbbbbb-0000-4000-8000-000000000002') = 'Bob Park',
    'name is picked up (Kakao shape)');
  perform test.assert(
    (select display_name from public.contributors where id = 'cccccccc-0000-4000-8000-000000000003') = 'Mina',
    'nickname is picked up (Naver shape)');
  perform test.assert(
    (select avatar_url from public.contributors where id = 'cccccccc-0000-4000-8000-000000000003') = 'https://cdn/m.jpg',
    'profile_image is picked up (Naver shape)');
end $$;

-- A user with no usable metadata at all must still get a row.
insert into auth.users (id, email, raw_user_meta_data)
values ('dddddddd-0000-4000-8000-000000000004', 'ghost@example.com', '{}');

do $$ begin
  perform test.assert(
    (select display_name from public.contributors where id = 'dddddddd-0000-4000-8000-000000000004')
      = 'Jeju Connect member',
    'missing provider metadata falls back to a placeholder name');
end $$;

-- Promote one user to moderator as the service role (auth.uid() is null here).
update public.contributors set role = 'moderator' where id = :mod;

-- ===========================================================================
\echo '== 2. Inserts are forced to pending regardless of what the client sends'
-- ===========================================================================

select set_config('request.jwt.claims', json_build_object('sub', :alice)::text, false);
set role authenticated;

-- Alice tries to self-approve AND to attribute the row to Bob.
insert into public.places (name, category, latitude, longitude, content_status, submitted_by, moderator_notes)
values ('Hallim Park', 'outdoor', 33.3894, 126.2650, 'approved', :bob, 'looks great to me');

do $$ begin
  perform test.assert(
    (select content_status from public.places where name = 'Hallim Park') = 'pending',
    'client-supplied content_status=approved is overwritten to pending');
  perform test.assert(
    (select submitted_by from public.places where name = 'Hallim Park')
      = 'aaaaaaaa-0000-4000-8000-000000000001',
    'client-supplied submitted_by is overwritten with auth.uid()');
  perform test.assert(
    (select moderator_notes from public.places where name = 'Hallim Park') is null,
    'client-supplied moderator_notes is stripped');
  perform test.assert(
    (select reviewed_by from public.places where name = 'Hallim Park') is null,
    'reviewed_by starts null');
end $$;

-- ===========================================================================
\echo '== 3. Read visibility while pending'
-- ===========================================================================

do $$ begin
  perform test.assert(
    (select count(*) from public.places) = 1,
    'author can read back their own pending submission');
end $$;

reset role;
select set_config('request.jwt.claims', json_build_object('sub', :bob)::text, false);
set role authenticated;

do $$ begin
  perform test.assert(
    (select count(*) from public.places) = 0,
    'a different signed-in user cannot see someone else pending submission');
end $$;

reset role;
select set_config('request.jwt.claims', '', false);
set role anon;

do $$ begin
  perform test.assert(
    (select count(*) from public.places) = 0,
    'anonymous readers cannot see pending content');
end $$;

-- ===========================================================================
\echo '== 4. Authors cannot approve their own content'
-- ===========================================================================

reset role;
select set_config('request.jwt.claims', json_build_object('sub', :alice)::text, false);
set role authenticated;

do $$
declare
  rows_hit integer;
begin
  update public.places set content_status = 'approved' where name = 'Hallim Park';
  get diagnostics rows_hit = row_count;
  perform test.assert(rows_hit = 0,
    'author self-approval updates zero rows (no matching UPDATE policy)');
exception when insufficient_privilege then
  perform test.assert(true, 'author self-approval is rejected outright');
end $$;

do $$ begin
  perform test.assert(
    (select content_status from public.places where name = 'Hallim Park') = 'pending',
    'content is still pending after the self-approval attempt');
end $$;

-- ===========================================================================
\echo '== 5. Moderators can approve, and the audit trail is stamped'
-- ===========================================================================

reset role;
select set_config('request.jwt.claims', json_build_object('sub', :mod)::text, false);
set role authenticated;

do $$ begin
  perform test.assert(
    (select count(*) from public.places) = 1,
    'moderator can see pending content in the review queue');
end $$;

update public.places
set content_status = 'approved', moderator_notes = 'verified location'
where name = 'Hallim Park';

do $$ begin
  perform test.assert(
    (select content_status from public.places where name = 'Hallim Park') = 'approved',
    'moderator approval succeeds');
  perform test.assert(
    (select reviewed_by from public.places where name = 'Hallim Park')
      = 'cccccccc-0000-4000-8000-000000000003',
    'reviewed_by is stamped with the approving moderator');
  perform test.assert(
    (select reviewed_at from public.places where name = 'Hallim Park') is not null,
    'reviewed_at is stamped automatically');
end $$;

-- ===========================================================================
\echo '== 6. Approved content becomes publicly visible'
-- ===========================================================================

reset role;
select set_config('request.jwt.claims', '', false);
set role anon;

do $$ begin
  perform test.assert(
    (select count(*) from public.places) = 1,
    'anonymous readers see approved content');
end $$;

-- ===========================================================================
\echo '== 7. Privilege escalation is blocked'
-- ===========================================================================

reset role;
select set_config('request.jwt.claims', json_build_object('sub', :alice)::text, false);
set role authenticated;

do $$ begin
  begin
    update public.contributors set role = 'admin' where id = 'aaaaaaaa-0000-4000-8000-000000000001';
    perform test.assert(false, 'self-promotion to admin should not have succeeded');
  exception when insufficient_privilege then
    perform test.assert(true, 'self-promotion is blocked by the column-level UPDATE grant');
  end;
end $$;

do $$ begin
  perform test.assert(
    (select role from public.contributors where id = 'aaaaaaaa-0000-4000-8000-000000000001') = 'contributor',
    'role is unchanged after the escalation attempt');
end $$;

-- A legitimate profile edit must still work.
update public.contributors set display_name = 'Alice K.' where id = :alice;

do $$ begin
  perform test.assert(
    (select display_name from public.contributors where id = 'aaaaaaaa-0000-4000-8000-000000000001') = 'Alice K.',
    'editing own display_name still works');
end $$;

-- ===========================================================================
\echo '== 8. Media ownership'
-- ===========================================================================

-- Alice uploads an unattached image: the normal mid-submission state.
insert into public.media (storage_path, uploaded_by, alt_text)
values ('aaaaaaaa-0000-4000-8000-000000000001/img1.jpg', :alice, 'front door');

do $$ begin
  perform test.assert(
    (select count(*) from public.media) = 1,
    'author can insert unattached media');
end $$;

reset role;
select set_config('request.jwt.claims', json_build_object('sub', :bob)::text, false);
set role authenticated;

-- Bob tries to bolt an image onto Alice's approved place.
do $$ begin
  begin
    insert into public.media (storage_path, uploaded_by, place_id)
    values ('bbbbbbbb-0000-4000-8000-000000000002/evil.jpg',
            'bbbbbbbb-0000-4000-8000-000000000002',
            (select id from public.places where name = 'Hallim Park'));
    perform test.assert(false, 'attaching media to another user content should have failed');
  exception when insufficient_privilege then
    perform test.assert(true, 'cannot attach media to content submitted by someone else');
  end;
end $$;

-- Bob also cannot forge the uploader.
do $$ begin
  begin
    insert into public.media (storage_path, uploaded_by)
    values ('x/forged.jpg', 'aaaaaaaa-0000-4000-8000-000000000001');
    perform test.assert(false, 'forging uploaded_by should have failed');
  exception when insufficient_privilege then
    perform test.assert(true, 'cannot insert media attributed to another user');
  end;
end $$;

-- Unattached media stays private to its uploader.
do $$ begin
  perform test.assert(
    (select count(*) from public.media) = 0,
    'unattached media belonging to someone else is invisible');
end $$;

reset role;
select set_config('request.jwt.claims', '', false);
set role anon;

do $$ begin
  perform test.assert(
    (select count(*) from public.media) = 0,
    'anonymous readers cannot see unattached media');
end $$;

-- ===========================================================================
\echo '== 9. Storage object policies'
-- ===========================================================================

reset role;
select set_config('request.jwt.claims', json_build_object('sub', :alice)::text, false);
set role authenticated;

insert into storage.objects (bucket_id, name)
values ('media', 'aaaaaaaa-0000-4000-8000-000000000001/photo.jpg');

do $$ begin
  perform test.assert(true, 'user can upload into their own folder');
end $$;

do $$ begin
  begin
    insert into storage.objects (bucket_id, name)
    values ('media', 'bbbbbbbb-0000-4000-8000-000000000002/photo.jpg');
    perform test.assert(false, 'writing into another user folder should have failed');
  exception when insufficient_privilege then
    perform test.assert(true, 'user cannot upload into another user folder');
  end;
end $$;

-- ===========================================================================
\echo '== 10. Domain constraints'
-- ===========================================================================

reset role;
select set_config('request.jwt.claims', json_build_object('sub', :alice)::text, false);
set role authenticated;

do $$ begin
  begin
    insert into public.events (title, starts_at, ends_at, submitted_by)
    values ('Backwards', now(), now() - interval '1 hour', 'aaaaaaaa-0000-4000-8000-000000000001');
    perform test.assert(false, 'an event ending before it starts should have failed');
  exception when check_violation then
    perform test.assert(true, 'events_end_after_start rejects an inverted time range');
  end;
end $$;

do $$ begin
  begin
    insert into public.events (title, starts_at, latitude, submitted_by)
    values ('Half a pin', now(), 33.5, 'aaaaaaaa-0000-4000-8000-000000000001');
    perform test.assert(false, 'a lone latitude should have failed');
  exception when check_violation then
    perform test.assert(true, 'events_coords_paired rejects a latitude with no longitude');
  end;
end $$;

do $$ begin
  begin
    insert into public.media (storage_path, uploaded_by, place_id, article_id)
    values ('aaaaaaaa-0000-4000-8000-000000000001/two.jpg',
            'aaaaaaaa-0000-4000-8000-000000000001',
            (select id from public.places limit 1),
            gen_random_uuid());
    perform test.assert(false, 'media attached to two owners should have failed');
  exception when check_violation or foreign_key_violation then
    perform test.assert(true, 'media_single_owner rejects multiple owners');
  end;
end $$;

reset role;
select set_config('request.jwt.claims', '', false);

\echo ''
\echo '===================== ALL RLS ASSERTIONS PASSED ====================='

rollback;
