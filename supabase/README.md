# Database

Schema and Row Level Security for Jeju Connect, as version-controlled SQL.

## Layout

```
supabase/
  migrations/
    20260824000001_initial_schema.sql   enums, tables, triggers, indexes
    20260824000002_rls_policies.sql     RLS + table/column grants
    20260824000003_storage.sql          media bucket + storage.objects policies
  tests/
    00_supabase_mock.sql                local stubs for auth/storage
    01_rls_test.sql                     assertions against the policies
    run.sh                              applies migrations to a scratch DB, asserts
```

## Applying to a Supabase project

With the Supabase CLI (preferred — it tracks which migrations have run):

```bash
supabase link --project-ref <your-project-ref>
supabase db push
```

Without the CLI, paste each file into the SQL editor **in filename order**.
They are not idempotent: run them once, on a fresh project.

## Running the tests

```bash
./supabase/tests/run.sh     # or: bun run test:db
```

This needs a local Postgres you can create databases in. It builds a scratch
database, stubs the Supabase-managed pieces (`auth.uid()`,
`storage.foldername()`, the `anon` / `authenticated` / `service_role` roles),
applies every migration, and asserts the moderation contract holds. The stubs
mirror Supabase's real definitions, but they are stubs — treat a pass as
"our policies are correct", not "this is verified against production".

## The moderation contract

Enforced in the database, not in app code, so a compromised or bypassed client
cannot get around it:

| Rule | Mechanism |
|---|---|
| Public reads only see approved content | `*_select_approved` policies: `USING (content_status = 'approved')` |
| Inserts always land as `pending` | `force_pending_submission()` BEFORE INSERT trigger rewrites the row; `*_insert_authenticated` WITH CHECK rejects anything that slipped past |
| Submissions are attributed to the real caller | Same trigger overwrites `submitted_by` with `auth.uid()` |
| Only moderators change status | `*_update_moderator` policies gated on `is_moderator()` |
| Review actions are audited | `stamp_moderation_review()` BEFORE UPDATE trigger sets `reviewed_by` / `reviewed_at` |
| Users cannot promote themselves | Column-level `GRANT UPDATE (display_name, avatar_url)` — Postgres refuses any UPDATE touching `role`; `guard_contributor_role()` is a second line of defence |

`service_role` carries `BYPASSRLS`, so server-side admin tooling is unaffected
by every policy above. **Never expose the service role key to the browser.**

## Roles

Everyone starts as `contributor`. Promotion is deliberately not possible
through the app — do it with the service role:

```sql
update public.contributors set role = 'moderator' where id = '<user-uuid>';
```

## Known sharp edges

- **Unauthorized updates fail silently.** RLS filters rows rather than raising,
  so a non-moderator's approval attempt updates 0 rows and returns success.
  Server code must check the affected row count, not just the absence of an error.
- **Authors can read `moderator_notes` on their own submissions.** RLS is
  row-level, and moderators are `authenticated` too, so a column grant can't
  separate them. If notes should stay internal, read them only through the
  service role in the moderation view.
- **The media bucket is public-read.** Approved images serve straight from the
  CDN with no signing round-trip; the cost is that a pending image is fetchable
  by anyone who knows its UUID path. See the note in the storage migration.
- **Types are hand-written.** Regenerate `src/lib/database.types.ts` with
  `supabase gen types typescript --linked > src/lib/database.types.ts` once the
  CLI is set up, so they can't drift from the schema.
