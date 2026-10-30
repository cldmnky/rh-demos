import { readFileSync, readdirSync, statSync, unlinkSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { defineConfig, type Plugin } from 'vite';
import react from '@vitejs/plugin-react';

/**
 * PatternFly ships italic faces for the Red Hat fonts. This board never uses
 * italics, and the bundle travels through cloud-init userdata, which becomes a
 * Kubernetes Secret capped at 1 MiB. Dropping the faces saves ~117 KB and keeps
 * `npm run build` self-consistent, so dist/ is always exactly what ships.
 */
const dropItalicFaces = (): Plugin => ({
  name: 'rocket-ramen-drop-italic-faces',
  apply: 'build',
  closeBundle() {
    const assets = resolve(process.cwd(), 'dist/assets');
    const css = join(assets, 'index.css');
    const source = readFileSync(css, 'utf8');
    const blocks = source.match(/@font-face\{[^}]*\}/g) ?? [];
    const kept = blocks.filter((block) => !block.includes('Italic'));
    if (kept.length !== blocks.length) {
      writeFileSync(css, source.replace(/@font-face\{[^}]*\}/g, (block) => (block.includes('Italic') ? '' : block)));
    }
    let dropped = 0;
    for (const file of readdirSync(assets)) {
      if (file.endsWith('.woff2') && file.includes('Italic')) {
        dropped += statSync(join(assets, file)).size;
        unlinkSync(join(assets, file));
      }
    }
    if (dropped > 0) {
      console.log(`dropped ${blocks.length - kept.length} italic @font-face blocks (${dropped} bytes)`);
    }
  },
});

export default defineConfig({
  // Relative base so the same bundle works behind any Route path.
  base: './',
  plugins: [react(), dropItalicFaces()],
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    // Deterministic asset names: the built bundle is packed into a tarball that
    // cloud-init writes into the web VM, and the container image copies the same
    // files. No content hashes keeps the chart and the image reviewable.
    rollupOptions: {
      output: {
        entryFileNames: 'assets/app.js',
        chunkFileNames: 'assets/[name].js',
        assetFileNames: 'assets/[name][extname]',
      },
    },
  },
  // Dev Spaces and local E2E: the Go API runs next to Vite.
  server: {
    proxy: {
      '/api': { target: process.env.API_URL || 'http://127.0.0.1:8080', changeOrigin: true },
    },
  },
  preview: {
    proxy: {
      '/api': { target: process.env.API_URL || 'http://127.0.0.1:8080', changeOrigin: true },
    },
  },
});
