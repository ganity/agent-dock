import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  server: {
    host: "0.0.0.0",
    allowedHosts: ["dock.lark.video"],
    proxy: {
      "/api": "http://127.0.0.1:4123",
      "/ws": {
        target: "ws://127.0.0.1:4123",
        ws: true,
      },
    },
  },
  test: {
    environment: "jsdom",
    setupFiles: "./src/test-setup.ts",
  },
});
