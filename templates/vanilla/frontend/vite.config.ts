import { defineConfig } from "vite";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  plugins: [tailwindcss()],
  // plume dev loads plume.json's frontend.dev_url: keep them the same.
  server: { port: 5173, strictPort: true },
});
