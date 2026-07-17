// Regression: one account's tournaments must NOT leak to a different account
// that signs in on the same device (shared-device cross-account bleed).
const { chromium } = require('playwright');
const sleep = ms => new Promise(r => setTimeout(r, ms));

(async () => {
  const browser = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });
  const ctx = await browser.newContext({ reducedMotion: 'reduce' });
  await ctx.addInitScript(() => {
    localStorage.setItem('padelzit-cloud-url', 'http://localhost:9021');
    localStorage.setItem('padelzit-cloud-key', 'k');
  });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', e => errors.push(e.message));
  const state = async () => (await (await fetch('http://localhost:9021/__state')).json());
  await page.goto('http://localhost:8000/index.html');

  // ---- User A signs up and creates a tournament ----
  await page.fill('#cloud-email', 'ariel@test.com');
  await page.fill('#cloud-pass', 'secret123');
  await page.click('#cloud-signup-btn');
  await sleep(500);
  await page.click('#new-tour-btn');
  for (let i = 0; i < 4; i++) await page.fill('#p' + i, ['Tsadok', 'Tamar', 'Lea', 'Ariel'][i]);
  await page.click('#start-btn');
  await page.fill('#scoreA', '20'); await page.click('#save-btn');
  await sleep(1500);
  await page.click('#game-home-btn');
  let cards = await page.$$eval('#tournament-list .tour-item', e => e.length);
  if (cards !== 1) throw new Error('A should have 1 tournament, got ' + cards);
  let s = await state();
  const aRows = s.rows.length;
  if (aRows !== 1) throw new Error('cloud should have 1 row for A, got ' + aRows);
  console.log('User A created a tournament (local + cloud): OK');

  // ---- A signs out on the shared device ----
  await page.click('#user-chip');
  await sleep(150);
  await page.click('#menu-logout');
  await sleep(400);
  // After logout the device must be clean.
  cards = await page.$$eval('#tournament-list .tour-item', e => e.length);
  if (cards !== 0) throw new Error('After A logout, device still shows ' + cards + ' tournaments (LEAK)');
  if (!(await page.isVisible('#guest-note'))) throw new Error('guest note should show after logout');
  console.log('Sign-out wipes local tournaments from the device: OK');

  // ---- User B (new account) signs up on the SAME device ----
  await page.fill('#cloud-email', 'friend@test.com');
  await page.fill('#cloud-pass', 'secret456');
  await page.click('#cloud-signup-btn');
  await sleep(1500);
  cards = await page.$$eval('#tournament-list .tour-item', e => e.length);
  if (cards !== 0) throw new Error('LEAK: new account B sees ' + cards + " of A's tournaments");
  console.log('New account B sees zero of A’s tournaments: OK');

  // ---- And nothing of A leaked up into B's cloud account ----
  s = await state();
  const bRows = s.rows.filter(r => r.user_id && r.user_id.indexOf('u_') === 0);
  // total rows should still be exactly 1 (A's), none owned by B
  if (s.rows.length !== 1) throw new Error("LEAK: cloud now has " + s.rows.length + " rows; A's data was pushed into B");
  console.log('No tournament pushed into B’s cloud account: OK');

  // ---- A logs back in → their data returns from the cloud ----
  await page.click('#user-chip'); await sleep(150); await page.click('#menu-logout'); await sleep(400);
  await page.fill('#cloud-email', 'ariel@test.com');
  await page.fill('#cloud-pass', 'secret123');
  await page.click('#cloud-login-btn');
  await sleep(1500);
  cards = await page.$$eval('#tournament-list .tour-item', e => e.length);
  if (cards !== 1) throw new Error('A re-login should restore 1 tournament, got ' + cards);
  console.log('User A re-login restores their tournament from cloud: OK');

  await ctx.close();
  if (errors.length) throw new Error('page errors: ' + errors.join('; '));
  console.log('ALL LEAK TESTS PASSED');
  await browser.close();
})().catch(e => { console.error('FAIL:', e.message); process.exit(1); });
