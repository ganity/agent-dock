import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

const proxy = {
  "/api": "http://127.0.0.1:4123",
  "/ws": {
    target: "ws://127.0.0.1:4123",
    ws: true,
  },
};

export default defineConfig({
  plugins: [react()],
  server: {
    host: "0.0.0.0",
    allowedHosts: ["dock.lark.video"],
    proxy,
  },
  preview: {
    host: "0.0.0.0",
    port: 4950,
    strictPort: true,
    allowedHosts: ["dock.lark.video"],
    proxy,
  },
  test: {
    environment: "jsdom",
    setupFiles: "./src/test-setup.ts",
  },
});
