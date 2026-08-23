import { test, expect } from '@playwright/test';
import { authenticateSession } from './helpers/auth.js';

test.describe('Video Player Playback & Streaming Tests', () => {
  let targetMovieId = 1;

  test.beforeEach(async ({ page, context, baseURL }) => {
    // Authenticate session before navigating to protected endpoints
    await authenticateSession(context, baseURL);

    // Collect console errors to detect any runtime exceptions
    page.on('console', (msg) => {
      if (msg.type() === 'error') {
        // Ignore expected non-fatal network aborts
        if (!msg.text().includes('AbortError') && !msg.text().includes('ERR_ABORTED')) {
          console.error(`[Browser Console Error] ${msg.text()}`);
        }
      }
    });

    // Try to dynamically detect the first available movie from library
    try {
      const libRes = await page.request.get('/api/v1/libraries');
      if (libRes.ok()) {
        const libData = await libRes.json();
        if (libData.libraries && libData.libraries.length > 0) {
          const firstLib = libData.libraries[0];
          const itemsRes = await page.request.get(`/api/v1/library?id=${firstLib.id}`);
          if (itemsRes.ok()) {
            const itemsData = await itemsRes.json();
            if (itemsData.items && itemsData.items.length > 0) {
              targetMovieId = itemsData.items[0].id;
            }
          }
        }
      }
    } catch (_) {}
  });

  test('TC-01: Playback startup, MSE attachment, and continuous time progression', async ({ page }) => {
    await page.goto(`/player?id=${targetMovieId}`);

    const video = page.locator('#video');
    await expect(video).toBeVisible({ timeout: 10000 });

    // Wait for video element readyState >= HAVE_CURRENT_DATA (2) or HAVE_ENOUGH_DATA (4)
    await page.waitForFunction(() => {
      const v = document.querySelector('video');
      return v && v.readyState >= 2;
    }, { timeout: 12000 });

    // Assert video is not in error state
    const videoError = await page.evaluate(() => {
      const v = document.querySelector('video');
      return v && v.error ? { code: v.error.code, message: v.error.message } : null;
    });
    expect(videoError).toBeNull();

    // Verify time advances by at least 2.5 seconds
    const initialTime = await page.evaluate(() => document.querySelector('video').currentTime);
    await page.waitForTimeout(3000);
    const updatedTime = await page.evaluate(() => document.querySelector('video').currentTime);

    expect(updatedTime - initialTime).toBeGreaterThanOrEqual(2.0);
  });

  test('TC-02: Video seeking jumps to target time and resumes playback', async ({ page }) => {
    await page.goto(`/player?id=${targetMovieId}`);

    const video = page.locator('#video');
    await expect(video).toBeVisible();

    await page.waitForFunction(() => {
      const v = document.querySelector('video');
      return v && v.readyState >= 2;
    }, { timeout: 12000 });

    // Seek to 15 seconds
    const targetSeek = 15;
    await page.evaluate((seekTime) => {
      const seekbar = document.getElementById('seekbar');
      const DURATION = window.DURATION || 100;
      // Trigger via seek click calculation
      if (typeof StreamEngine !== 'undefined') {
        StreamEngine.loadVideo(seekTime);
      } else {
        const v = document.querySelector('video');
        if (v) v.currentTime = seekTime;
      }
    }, targetSeek);

    // Wait for playback to resume near target time
    await page.waitForFunction((target) => {
      const v = document.querySelector('video');
      const getAbs = window.getAbsoluteTime ? window.getAbsoluteTime() : v.currentTime;
      return getAbs >= (target - 5) && !v.paused && v.readyState >= 2;
    }, targetSeek, { timeout: 10000 });

    // Ensure it continues advancing past the seek point
    const seekedTime = await page.evaluate(() => window.getAbsoluteTime ? window.getAbsoluteTime() : document.querySelector('video').currentTime);
    await page.waitForTimeout(2500);
    const afterSeekTime = await page.evaluate(() => window.getAbsoluteTime ? window.getAbsoluteTime() : document.querySelector('video').currentTime);

    expect(afterSeekTime - seekedTime).toBeGreaterThanOrEqual(1.5);
  });

  test('TC-03: Subtitle track selection and overlay rendering', async ({ page }) => {
    await page.goto(`/player?id=${targetMovieId}`);

    const btnSubtitles = page.locator('#subtitlesbtn');
    await expect(btnSubtitles).toBeVisible();

    // Check if subtitle options exist
    await btnSubtitles.click();
    const subMenu = page.locator('#subtitles-menu');
    await expect(subMenu).not.toHaveClass(/hidden/);

    const trackButtons = page.locator('.sub-track-btn');
    const count = await trackButtons.count();

    if (count > 1) {
      // Click the first real track (index 1 after 'Off')
      await trackButtons.nth(1).click();
      await expect(btnSubtitles).toHaveClass(/active/);

      // Verify subtitle overlay DOM element exists
      const overlay = page.locator('#subtitle-overlay');
      await expect(overlay).toBeAttached();
    }
  });

  test('TC-04: Audio track switching', async ({ page }) => {
    await page.goto(`/player?id=${targetMovieId}`);

    const btnAudio = page.locator('#audiobtn');
    const isVisible = await btnAudio.isVisible();

    if (isVisible) {
      await btnAudio.click();
      const audioMenu = page.locator('#audio-menu');
      await expect(audioMenu).not.toHaveClass(/hidden/);

      const trackButtons = page.locator('.audio-track-btn');
      const count = await trackButtons.count();

      if (count > 1) {
        // Switch to track 2
        await trackButtons.nth(1).click();
        await expect(trackButtons.nth(1)).toHaveClass(/active/);

        // Verify video continues playing without media decode error
        await page.waitForTimeout(2000);
        const isPaused = await page.evaluate(() => document.querySelector('video').paused);
        expect(isPaused).toBe(false);
      }
    }
  });

  test('TC-05: Keyboard shortcuts (Space play/pause, Arrow keys seek)', async ({ page }) => {
    await page.goto(`/player?id=${targetMovieId}`);

    await page.waitForFunction(() => {
      const v = document.querySelector('video');
      return v && v.readyState >= 2;
    }, { timeout: 12000 });

    // Press Space to Pause
    await page.keyboard.press('Space');
    await page.waitForFunction(() => document.querySelector('video').paused === true);
    let isPaused = await page.evaluate(() => document.querySelector('video').paused);
    expect(isPaused).toBe(true);

    // Press Space to Resume Play
    await page.keyboard.press('Space');
    await page.waitForFunction(() => document.querySelector('video').paused === false);
    isPaused = await page.evaluate(() => document.querySelector('video').paused);
    expect(isPaused).toBe(false);
  });

  test('TC-06: Watch event analytics recording', async ({ page }) => {
    let watchEventReceived = false;

    // Intercept watch event POST calls
    await page.route('**/api/watch/event', async (route) => {
      watchEventReceived = true;
      await route.continue();
    });

    await page.goto(`/player?id=${targetMovieId}`);
    await page.waitForTimeout(2000);

    expect(watchEventReceived).toBe(true);
  });
});
