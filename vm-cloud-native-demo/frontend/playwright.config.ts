import { defineConfig, devices } from '@playwright/test';

/**
 * Point the suite at a cluster Route with PLAYWRIGHT_BASE_URL, or at a local
 * `node server.js` for fast iteration. The stack spec also accepts
 * EXPECTED_WEB_RUNTIME / EXPECTED_API_RUNTIME so the same test verifies the VM
 * baseline and the container cutover.
 */
export default defineConfig({
  testDir: './e2e',
  timeout: 45_000,
  expect: { timeout: 10_000 },
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: [['list'], ['html', { open: 'never', outputFolder: 'playwright-report' }]],
  use: {
    baseURL: process.env.PLAYWRIGHT_BASE_URL || 'http://127.0.0.1:8080',
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    viewport: { width: 1440, height: 1000 },
  },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
});
