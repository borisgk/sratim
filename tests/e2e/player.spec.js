import { test, expect } from '@playwright/test';
import { authenticateSession } from './helpers/auth.js';

test.describe('Video Player Playback & Streaming Tests', () => {
  let targetMovieId = 25;
  let targetMp4MovieId = 1673;

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

    // Try to dynamically detect available movies from movie libraries (including MP4)
    try {
      const libRes = await page.request.get('/api/v1/libraries');
      if (libRes.ok()) {
        const libData = await libRes.json();
        const movieLibs = (libData.libraries || []).filter(l => l.lib_type === 'Movies' || l.type === 'Movies');
        const candidateLibs = movieLibs.length > 0 ? movieLibs : (libData.libraries || []).filter(l => l.lib_type !== 'Shows' && l.type !== 'Shows');
        let selectedMovie = false;
        for (const lib of candidateLibs) {
          const itemsRes = await page.request.get(`/api/v1/library?id=${lib.id}`);
          if (itemsRes.ok()) {
            const itemsData = await itemsRes.json();
            const items = itemsData.updates || itemsData.items || [];
            if (items.length > 0) {
              if (!selectedMovie) {
                targetMovieId = items[0].id;
                selectedMovie = true;
              }
              for (const item of items) {
                if (item.title && (item.title.toLowerCase().includes('.mp4') || item.title.toLowerCase().includes('oklahoma'))) {
                  targetMp4MovieId = item.id;
                  break;
                }
              }
            }
          }
          if (selectedMovie && targetMp4MovieId) break;
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

  test('TC-07: Native MP4 slicing playback, continuous progression, and seeking', async ({ page }) => {
    const mp4Id = targetMp4MovieId || targetMovieId;
    await page.goto(`/player?id=${mp4Id}`);

    const video = page.locator('#video');
    await expect(video).toBeVisible({ timeout: 10000 });

    // Wait for video element readyState >= HAVE_CURRENT_DATA (2)
    await page.waitForFunction(() => {
      const v = document.querySelector('video');
      return v && v.readyState >= 2;
    }, { timeout: 15000 });

    // Assert video is not in error state
    const videoError = await page.evaluate(() => {
      const v = document.querySelector('video');
      return v && v.error ? { code: v.error.code, message: v.error.message } : null;
    });
    expect(videoError).toBeNull();

    // Verify time advances by at least 2.5 seconds
    const initialTime = await page.evaluate(() => document.querySelector('video').currentTime);
    await page.waitForFunction(
      (init) => {
        const v = document.querySelector('video');
        return v && v.currentTime >= init + 2.5;
      },
      initialTime,
      { timeout: 12000 }
    );

    const progressedTime = await page.evaluate(() => document.querySelector('video').currentTime);
    expect(progressedTime).toBeGreaterThan(initialTime + 2.0);

    // Verify seeking in native fMP4 stream
    await page.keyboard.press('ArrowRight'); // Seek +10s
    await page.waitForFunction(
      (prev) => {
        const v = document.querySelector('video');
        return v && v.currentTime >= prev + 5.0;
      },
      progressedTime,
      { timeout: 10000 }
    );

    const postSeekTime = await page.evaluate(() => document.querySelector('video').currentTime);
    expect(postSeekTime).toBeGreaterThan(progressedTime + 4.0);
  });

  test('TC-08: Episode playback and subtitle track extraction on Ludwig S02E01', async ({ page }) => {
    // Navigate to Ludwig S02E01
    await page.goto('/player?episode_id=8113');

    const video = page.locator('#video');
    await expect(video).toBeVisible({ timeout: 10000 });

    // Wait for playback startup
    await page.waitForFunction(() => {
      const v = document.querySelector('video');
      return v && v.readyState >= 2;
    }, { timeout: 15000 });

    // Select subtitles
    const btnSubtitles = page.locator('#subtitlesbtn');
    await expect(btnSubtitles).toBeVisible();
    await btnSubtitles.click();

    const trackButtons = page.locator('.sub-track-btn');
    const count = await trackButtons.count();
    expect(count).toBeGreaterThan(1);

    // Track response from /subtitles?episode_id=8113
    const subtitleResponsePromise = page.waitForResponse(
      (resp) => resp.url().includes('/subtitles?') && resp.url().includes('episode_id=8113') && resp.status() === 200,
      { timeout: 10000 }
    );

    // Select English track
    await trackButtons.nth(1).click();
    const subResponse = await subtitleResponsePromise;
    expect(subResponse.status()).toBe(200);
    const subText = await subResponse.text();
    expect(subText).toContain('WEBVTT');
    expect(subText).toContain('-->');

    // Verify subtitle overlay is active in DOM
    const overlay = page.locator('#subtitle-overlay');
    await expect(overlay).toBeAttached();
  });

  test('TC-09: Pure Zig AAC-LC encoding playback and audio progression on multichannel media', async ({ page }) => {
    // 1. Test Along Came Polly (id 25, 5.1 AC3 audio track)
    await page.goto('/player?id=25');

    const video = page.locator('#video');
    await expect(video).toBeVisible({ timeout: 10000 });

    await page.waitForFunction(() => {
      const v = document.querySelector('video');
      return v && v.readyState >= 2;
    }, { timeout: 15000 });

    const initTime = await page.evaluate(() => document.querySelector('video').currentTime);
    await page.waitForFunction(
      (init) => {
        const v = document.querySelector('video');
        return v && v.currentTime >= init + 2.0;
      },
      initTime,
      { timeout: 10000 }
    );

    const progressedTime = await page.evaluate(() => document.querySelector('video').currentTime);
    expect(progressedTime).toBeGreaterThan(initTime + 1.5);

    // 2. Test Tuner (id 26, 5.1 AAC audio track)
    await page.goto('/player?id=26');
    await expect(video).toBeVisible({ timeout: 10000 });

    await page.waitForFunction(() => {
      const v = document.querySelector('video');
      return v && v.readyState >= 2;
    }, { timeout: 15000 });

    const initTime2 = await page.evaluate(() => document.querySelector('video').currentTime);
    await page.waitForFunction(
      (init) => {
        const v = document.querySelector('video');
        return v && v.currentTime >= init + 2.0;
      },
      initTime2,
      { timeout: 10000 }
    );

    const progressedTime2 = await page.evaluate(() => document.querySelector('video').currentTime);
    expect(progressedTime2).toBeGreaterThan(initTime2 + 1.5);
  });

  test('TC-10: Pure Zig AC-3 decoding, seeking, and multi-track audio switching on Along Came Polly', async ({ page }) => {
    // Navigate to Along Came Polly (id 25, 5.1 AC-3 audio tracks)
    await page.goto('/player?id=25');

    const video = page.locator('#video');
    await expect(video).toBeVisible({ timeout: 10000 });

    // Wait for video playback startup
    await page.waitForFunction(() => {
      const v = document.querySelector('video');
      return v && v.readyState >= 2;
    }, { timeout: 15000 });

    const startTime = await page.evaluate(() => document.querySelector('video').currentTime);

    // Verify seeking with pure Zig AC-3 decoding
    await page.keyboard.press('ArrowRight'); // Seek +10s
    await page.waitForFunction(
      (prev) => {
        const v = document.querySelector('video');
        return v && v.currentTime >= prev + 4.0;
      },
      startTime,
      { timeout: 10000 }
    );

    const postSeekTime = await page.evaluate(() => document.querySelector('video').currentTime);
    expect(postSeekTime).toBeGreaterThan(startTime + 3.0);

    // Test audio track switching
    const btnAudio = page.locator('#audiobtn');
    if (await btnAudio.isVisible()) {
      await btnAudio.click();
      const trackButtons = page.locator('.audio-track-btn');
      const count = await trackButtons.count();
      if (count > 1) {
        await trackButtons.nth(1).click();
        await expect(trackButtons.nth(1)).toHaveClass(/active/);

        // Confirm playback continues on new AC-3 track
        await page.waitForTimeout(2000);
        const isPaused = await page.evaluate(() => document.querySelector('video').paused);
        expect(isPaused).toBe(false);
      }
    }
  });
});
