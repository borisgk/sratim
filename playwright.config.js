import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './tests/e2e',
  timeout: 30000,
  expect: {
    timeout: 10000,
  },
  fullyParallel: false,
  workers: 1,
  reporter: [
    ['list'],
    ['html', { outputFolder: 'tests/e2e-report', open: 'never' }]
  ],
  use: {
    baseURL: process.env.BASE_URL || 'http://127.0.0.1:8000',
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
    launchOptions: {
      args: [
        '--autoplay-policy=no-user-gesture-required',
        '--use-fake-ui-for-media-stream',
        '--disable-features=PreloadMediaEngagementData,MediaEngagementBypassAutoplayPolicies',
      ],
    },
  },
  projects: [
    {
      name: 'Google Chrome',
      use: {
        ...devices['Desktop Chrome'],
        channel: 'chrome', // Uses system Google Chrome with full hardware H.264/HEVC/AAC codecs
      },
    },
  ],
});
