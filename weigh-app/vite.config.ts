import { defineConfig, loadEnv, type Plugin } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

// In production /api/orders is a Vercel function (api/orders.ts). Locally the
// same handler is mounted into the dev server so `npm run dev` works end to
// end without the Vercel CLI.
function apiDev(): Plugin {
  return {
    name: "api-dev",
    configureServer(server) {
      for (const name of ["orders", "login"]) {
        server.middlewares.use(`/api/${name}`, async (req, res) => {
          try {
            const mod = await server.ssrLoadModule(`/api/${name}.ts`);
            await mod.default(req, res);
          } catch (e) {
            res.statusCode = 500;
            res.setHeader("Content-Type", "application/json");
            res.end(JSON.stringify({ error: `Dev server error: ${(e as Error).message}`, code: "config" }));
          }
        });
      }
    },
  };
}

export default defineConfig(({ mode }) => {
  // Make non-VITE_ variables (FOODICS_TOKEN etc.) visible to the dev API.
  const env = loadEnv(mode, process.cwd(), "");
  for (const [k, v] of Object.entries(env)) {
    if (process.env[k] === undefined) process.env[k] = v;
  }
  return {
    plugins: [react(), tailwindcss(), apiDev()],
    server: { port: 5180 },
    // One bundle (~155 KB gzipped: React, router, supabase-js) loaded once per
    // device and cached; splitting it buys nothing for a single-screen app.
    build: { chunkSizeWarningLimit: 700 },
  };
});
