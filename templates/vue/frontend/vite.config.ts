import { defineConfig } from "vite";
import vue from "@vitejs/plugin-vue";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  plugins: [vue(), tailwindcss()],
  // plume dev loads plume.json's frontend.dev_url: keep them the same.
  server: { port: 5173, strictPort: true },
});
