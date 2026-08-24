import { createServerClient, createBrowserClient, parseCookieHeader } from '@supabase/ssr';
import type { AstroCookies } from 'astro';
import type { Database } from './database.types';

/**
 * The slice of Astro's context we need. Both `Astro` in a page and the
 * `APIContext` passed to endpoints, middleware and actions satisfy this, so
 * the same factory works everywhere.
 */
export interface SupabaseContext {
  request: Request;
  cookies: AstroCookies;
  locals: App.Locals;
}

/**
 * Server-side Supabase client. Use this in Astro frontmatter, API routes,
 * actions and middleware.
 *
 * Credentials come from the Cloudflare Worker bindings on
 * `locals.runtime.env` — NOT `import.meta.env`, which is inlined at build time
 * and is not how Workers receive secrets.
 *
 * Reads incoming cookies straight off the request header (AstroCookies has no
 * getAll()) and writes outgoing ones through AstroCookies so Astro attaches
 * the Set-Cookie headers to the response.
 *
 * Usage:
 *   const supabase = createSupabaseServer(Astro);
 *   const { data } = await supabase.from('places').select('*');
 */
export function createSupabaseServer(context: SupabaseContext) {
  const env = context.locals.runtime.env;

  return createServerClient<Database>(env.SUPABASE_URL, env.SUPABASE_ANON_KEY, {
    cookies: {
      getAll() {
        return parseCookieHeader(context.request.headers.get('Cookie') ?? '').map(
          ({ name, value }) => ({ name, value: value ?? '' }),
        );
      },
      setAll(cookiesToSet) {
        for (const { name, value, options } of cookiesToSet) {
          context.cookies.set(name, value, options);
        }
      },
    },
  });
}

/**
 * Privileged client that bypasses RLS. Only for genuinely administrative work
 * that no user-scoped policy can express — never in a request path driven by
 * user input.
 *
 * The service role key must never reach the browser: keep this out of React
 * islands and out of any value passed as a component prop.
 */
export function createSupabaseAdmin(env: Env) {
  return createServerClient<Database>(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
    cookies: {
      getAll: () => [],
      setAll: () => {},
    },
  });
}

/**
 * Browser client for React islands.
 *
 * The URL and anon key are passed in as arguments because an island cannot
 * reach Worker bindings — the Astro component that renders it reads them from
 * `Astro.locals.runtime.env` and hands them down as props. Both values are
 * safe to expose; RLS is what protects the data.
 */
export function createSupabaseBrowser(supabaseUrl: string, supabaseAnonKey: string) {
  return createBrowserClient<Database>(supabaseUrl, supabaseAnonKey);
}
