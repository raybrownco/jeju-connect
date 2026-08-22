import { defineConfig } from 'astro/config';
import cloudflare from '@astrojs/cloudflare';
import react from '@astrojs/react';

export default defineConfig({
  output: 'server',
  adapter: cloudflare({
    platformProxy: {
      enabled: true,
    },
  }),
  integrations: [react()],
  vite: {
    ssr: {
      // Prevents "ws"/"require" errors from @supabase/ssr in Cloudflare Workers
      external: ['node:async_hooks'],
    },
  },
});
