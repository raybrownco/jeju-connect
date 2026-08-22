import { createServerClient, createBrowserClient } from '@supabase/ssr';
import type { AstroCookies } from 'astro';

/**
 * Server-side Supabase client.
 *
 * Always use this in Astro page/layout frontmatter and API routes.
 * Reads credentials from Cloudflare Worker bindings (Astro.locals.runtime.env),
 * NOT from import.meta.env — those aren't available to Workers at runtime.
 *
 * Usage:
 *   const supabase = createSupabaseServer(Astro.locals.runtime.env, Astro.cookies);
 */
export function createSupabaseServer(env: Env, cookies: AstroCookies) {
  return createServerClient(env.SUPABASE_URL, env.SUPABASE_ANON_KEY, {
    cookies: {
      getAll() {
        return cookies.getAll();
      },
      setAll(cookiesToSet) {
        cookiesToSet.forEach(({ name, value, options }) => {
          cookies.set(name, value, options);
        });
      },
    },
  });
}

/**
 * Browser-side Supabase client for use inside React islands.
 *
 * The URL and anon key must be passed down from the Astro server component
 * as props — do NOT hard-code them in client code or read from window/env.
 *
 * Usage (Astro component):
 *   const { runtime } = Astro.locals;
 *   <MyIsland supabaseUrl={runtime.env.SUPABASE_URL} supabaseAnonKey={runtime.env.SUPABASE_ANON_KEY} />
 *
 * Usage (React island):
 *   const supabase = createSupabaseBrowser(props.supabaseUrl, props.supabaseAnonKey);
 */
export function createSupabaseBrowser(supabaseUrl: string, supabaseAnonKey: string) {
  return createBrowserClient(supabaseUrl, supabaseAnonKey);
}
