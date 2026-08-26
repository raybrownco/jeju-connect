import type { APIRoute } from 'astro';

export const prerender = false;

/**
 * Bridge endpoint for Supabase's Naver custom OAuth2 provider.
 *
 * Naver is not a native Supabase provider, so it's configured as a Custom
 * OAuth2 Provider (Dashboard: Authentication > Sign In / Providers > Custom
 * Providers), referenced client-side as `custom:naver`.
 *
 * Point that provider's "Userinfo URL" at THIS endpoint — not at Naver's real
 * one (https://openapi.naver.com/v1/nid/me) — because Supabase's custom OAuth2
 * parser does a flat top-level JSON lookup (verified against
 * supabase/auth's internal/api/provider/custom_oauth.go: both the raw claims
 * unmarshal and applyAttributeMapping's claimsMap[v] do direct top-level map
 * access, with no dotted-path/nested support). Naver wraps every profile
 * field one level down:
 *
 *   { "resultcode": "00", "message": "success",
 *     "response": { "id": "...", "email": "...", "name": "...", ... } }
 *
 * so pointing Supabase straight at Naver's endpoint silently produces a user
 * with no email and no name — attribute mapping can't fix this, since it only
 * renames flat keys, it doesn't unwrap nesting.
 *
 * Supabase calls the configured userinfo URL as `GET` with
 * `Authorization: Bearer <access_token>` (confirmed in
 * internal/api/provider/provider.go's makeRequest, via Go's
 * oauth2.Config.Client()). This endpoint forwards that same bearer token to
 * Naver, unwraps `response`, and re-shapes it into the flat fields Supabase's
 * Claims struct expects (sub, email, name, picture) so no attribute mapping
 * is needed on the Supabase side at all.
 */
export const GET: APIRoute = async ({ request }) => {
  const authHeader = request.headers.get('Authorization');
  if (!authHeader?.startsWith('Bearer ')) {
    return new Response(JSON.stringify({ error: 'missing bearer token' }), {
      status: 401,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  const naverResponse = await fetch('https://openapi.naver.com/v1/nid/me', {
    headers: { Authorization: authHeader },
  });

  if (!naverResponse.ok) {
    return new Response(JSON.stringify({ error: 'naver userinfo request failed' }), {
      status: 502,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  const naverBody = (await naverResponse.json()) as {
    resultcode?: string;
    response?: {
      id?: string;
      email?: string;
      name?: string;
      nickname?: string;
      profile_image?: string;
    };
  };

  const profile = naverBody.response;
  if (naverBody.resultcode !== '00' || !profile?.id) {
    return new Response(JSON.stringify({ error: 'naver userinfo response malformed' }), {
      status: 502,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  // Flat shape matching Supabase's Claims struct field names — no attribute
  // mapping needed on the Supabase custom provider config.
  return new Response(
    JSON.stringify({
      sub: profile.id,
      email: profile.email,
      // Naver's real name field is "name"; "nickname" is the display handle.
      // Fall back to nickname since name is only returned with an approved
      // "real name" scope grant, which most apps won't have.
      name: profile.name ?? profile.nickname,
      nickname: profile.nickname,
      picture: profile.profile_image,
    }),
    { status: 200, headers: { 'Content-Type': 'application/json' } },
  );
};
