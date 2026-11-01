import { defineConfig } from "vite";
import { svelte } from "@sveltejs/vite-plugin-svelte";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  plugins: [svelte(), tailwindcss()],
  // plume dev loads plume.json's frontend.dev_url: keep them the same.
  server: { port: 5173, strictPort: true },
});
