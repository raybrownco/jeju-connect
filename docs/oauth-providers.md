# OAuth provider setup

Facebook and Kakao are native Supabase providers — Naver is not and is registered as a
Custom OAuth2 Provider, referenced client-side as `custom:naver`. This doc is a
checklist for registering all three; it assumes a Supabase project already exists
(`supabase/README.md` covers the database side).

## Callback URL (all three providers)

Every provider's developer console needs the same Supabase-managed callback URL:

```
https://<your-project-ref>.supabase.co/auth/v1/callback
```

Find `<your-project-ref>` in the Supabase dashboard URL or as the subdomain of your
`SUPABASE_URL`. Use this exact URL — not your app's own domain — since Supabase's auth
server is what completes the OAuth exchange before handing your app a session.

## 1. Facebook (native provider)

1. [Facebook for Developers](https://developers.facebook.com/) → **My Apps** → **Create App** → type **Consumer**.
2. Add the **Facebook Login** product.
3. Facebook Login → Settings → **Valid OAuth Redirect URIs** → paste the callback URL above.
4. App Settings → Basic → copy the **App ID** and **App Secret**.
5. Supabase Dashboard → **Authentication → Sign In / Providers → Facebook** → toggle on,
   paste App ID and App Secret, save.
6. While the app is in **Development Mode**, only users listed as Facebook
   testers/developers on the app can log in — fine for our own testing, but you'll need
   to submit for App Review (requesting the `email` and `public_profile` permissions)
   before the public can use it.

**Bring back:** App ID, App Secret.

## 2. Kakao (native provider)

1. [Kakao Developers](https://developers.kakao.com/) → **My Application** → **Add an
   application**.
2. App Settings → **App Keys** → copy the **REST API key** (this becomes the client ID).
3. Product Settings → **Kakao Login** → General → set **State** to **ON**.
4. Product Settings → **Kakao Login** → **Redirect URI** → add the callback URL above.
5. Product Settings → **Kakao Login** → **Security** → activate **Client Secret**, copy
   the generated code.
6. Under **Consent Items**, enable `account_email` (email is not returned by default —
   without this, Supabase gets a Kakao user with no email address).
7. Supabase Dashboard → **Authentication → Sign In / Providers → Kakao** → toggle on,
   paste the REST API key as Client ID and the Kakao Client Secret code as Client
   Secret, save.
8. Like Facebook, a new Kakao app starts restricted to registered testers until you
   complete Kakao's business/app review for public launch.

**Bring back:** REST API key, Kakao Login Client Secret.

## 3. Naver (custom OAuth2 provider)

Naver isn't in Supabase's built-in provider list, and — this is the part worth reading
closely — you can't just point Supabase's generic custom-provider config at Naver's real
userinfo endpoint either.

### Why a bridge endpoint is required, not optional

Naver's userinfo endpoint (`https://openapi.naver.com/v1/nid/me`) nests every profile
field one level down:

```json
{ "resultcode": "00", "message": "success",
  "response": { "id": "...", "email": "...", "name": "...", "nickname": "...", "profile_image": "..." } }
```

Supabase's custom OAuth2 provider (`supabase/auth`'s `internal/api/provider/custom_oauth.go`)
parses the userinfo response with a flat top-level JSON lookup — confirmed directly in
its source: both the raw claims unmarshal and `applyAttributeMapping`'s
`claimsMap[v]` do a direct top-level map access, with no dotted-path or nested-object
support. Point Supabase straight at Naver's real endpoint and you get a signed-in user
with no email and no name — silently, no error — because `email` and `name` live at
`response.email` / `response.name`, not at the top level. The dashboard's attribute
mapping field can rename a flat key, it cannot unwrap nesting, so it can't fix this.

**The fix:** `src/pages/api/auth/naver-userinfo.ts` in this repo is a small bridge route
that Supabase calls *instead of* Naver's real endpoint. Supabase calls whatever userinfo
URL you configure as `GET` with `Authorization: Bearer <access_token>` (confirmed in
`provider.go`'s `makeRequest`, via Go's `oauth2.Config.Client()`). The bridge forwards
that same bearer token to Naver, unwraps `response`, and returns a flat body
(`sub`, `email`, `name`, `nickname`, `picture`) matching what Supabase's parser expects
— so no attribute mapping is needed on the Supabase side at all. It needs no secrets of
its own; it only relays whatever token it's handed.

Once deployed, this endpoint lives at:
```
https://<your-worker-domain>/api/auth/naver-userinfo
```
This is what you'll register as the **Userinfo URL** below — not Naver's own endpoint.

### Registering the Naver app

1. [Naver Developers](https://developers.naver.com/apps/#/register) → **Application
   Registration**.
2. Under **API Settings**, enable **네이버 로그인 (Naver Login)**.
3. Request these provided-information items (used to build the `response` payload
   above): **회원이름 (name)**, **이메일 주소 (email)**, **별명 (nickname)**,
   **프로필 사진 (profile image)**.
4. **Login Open API 서비스 환경** (service environment) → add:
   - **PC 웹** with your production/preview URL, or
   - **모바일 웹** if this needs to work in an in-app browser context (Kakao/Facebook
     in-app browsers can behave differently — test both if a launch channel matters).
5. **Callback URL** → the same Supabase callback URL from the top of this doc.
6. App Settings → copy **Client ID** and **Client Secret**.
7. Note: a new Naver app also starts in a restricted review state — check the current
   review requirement in the Naver Developers console before assuming public users can
   log in immediately.

**Bring back:** Client ID, Client Secret.

### Configuring `custom:naver` in Supabase

1. Supabase Dashboard → **Authentication → Sign In / Providers** → scroll to **Custom
   Providers** → **New Provider**.
2. Set:
   | Field | Value |
   |---|---|
   | Name | `naver` (this is what makes it `custom:naver` client-side) |
   | Type | OAuth2 (not OIDC — Naver has no discovery document) |
   | Client ID | from the Naver app |
   | Client Secret | from the Naver app |
   | Authorization URL | `https://nid.naver.com/oauth2.0/authorize` |
   | Token URL | `https://nid.naver.com/oauth2.0/token` |
   | Userinfo URL | `https://<your-worker-domain>/api/auth/naver-userinfo` **(the bridge — not Naver's own endpoint)** |
   | Scopes | leave empty — Naver doesn't use OAuth2 scopes; the requested-information items are configured on the Naver app itself (step 3 above) |
3. Save. The client calls it as:
   ```ts
   await supabase.auth.signInWithOAuth({ provider: 'custom:naver' });
   ```

### Verifying it actually works

Don't trust the dashboard save confirmation alone — the flat-parsing gotcha above fails
silently (a real signed-in user with a blank email), so confirm the round trip once
credentials are in place:

1. Sign in via `custom:naver` in a real browser.
2. In the Supabase dashboard, **Authentication → Users**, open the new user record.
3. Confirm `email` is populated and `raw_user_meta_data` contains `name`/`nickname` —
   not empty strings. If they're blank, the userinfo URL is probably still pointed at
   Naver's real endpoint instead of the bridge, or the bridge isn't deployed yet.
4. Check `public.contributors` (via the `handle_new_user()` trigger from
   `supabase/migrations/`) got a matching row with a real `display_name`, not the
   `'Jeju Connect member'` placeholder fallback.

## Summary — what to bring back

| Provider | Values needed |
|---|---|
| Facebook | App ID, App Secret |
| Kakao | REST API key, Kakao Login Client Secret |
| Naver | Client ID, Client Secret |

None of these are app secrets for *our* code — they're configured directly in the
Supabase dashboard, not in `.env` or `wrangler secret`. `.env` only needs
`SUPABASE_URL` / `SUPABASE_ANON_KEY` / `SUPABASE_SERVICE_ROLE_KEY`, already covered in
`.env.example`.
