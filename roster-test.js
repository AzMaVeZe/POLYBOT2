// Player roster: nickname profile, directory lookup by exact email/nickname,
// roster suggestions, linking at setup, anonymous players untouched.
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
  await page.goto('http://localhost:8000/index.html');

  // ---- A signs up and sets a nickname ----
  if (await page.isVisible('#cloud-open-btn')) await page.click('#cloud-open-btn');
  await page.fill('#cloud-email', 'ariel@test.com');
  await page.fill('#cloud-pass', 'secret123');
  await page.click('#cloud-signup-btn');
  await sleep(800);
  await page.click('#user-chip'); await sleep(150);
  await page.fill('#menu-nick', 'ace');
  await page.click('#menu-nick-save');
  await sleep(600);
  await page.click('#user-chip'); await sleep(150); // close menu
  console.log('A signed up and saved nickname "ace": OK');

  // ---- A runs a tournament; names accumulate into the roster ----
  await page.click('#new-tour-btn');
  for (let i = 0; i < 4; i++) await page.fill('#p' + i, ['Dana', 'Yossi', 'Noa', 'Omer'][i]);
  await page.click('#start-btn');
  await sleep(1800);
  await page.click('#game-home-btn');
  await page.click('#new-tour-btn');
  const options = await page.$$eval('#roster-list option', o => o.map(x => x.value));
  if (!['Dana', 'Yossi', 'Noa', 'Omer'].every(n => options.includes(n))) {
    throw new Error('roster datalist missing names: ' + options);
  }
  console.log('Roster accumulates played names (datalist suggestions): OK');
  await page.click('#setup-back-btn');

  // ---- A signs out: roster is wiped from the device ----
  await page.click('#user-chip'); await sleep(150);
  await page.click('#menu-logout'); await sleep(500);
  await page.click('#new-tour-btn');
  const emptyOpts = await page.$$eval('#roster-list option', o => o.length);
  if (emptyOpts !== 0) throw new Error('roster survived sign-out: ' + emptyOpts);
  await page.click('#setup-back-btn');
  console.log('Sign-out wipes the roster from the device: OK');

  // ---- B signs up on the same device ----
  if (await page.isVisible('#cloud-open-btn')) await page.click('#cloud-open-btn');
  await page.fill('#cloud-email', 'boaz@test.com');
  await page.fill('#cloud-pass', 'secret456');
  await page.click('#cloud-signup-btn');
  await sleep(800);
  await page.click('#new-tour-btn');

  // Directory lookup by nickname fills the first empty slot.
  await page.fill('#dir-q', 'ace');
  await page.click('#dir-btn');
  await sleep(600);
  const dirMsg = await page.textContent('#dir-result');
  if (!/ace/.test(dirMsg)) throw new Error('directory lookup by nickname failed: ' + dirMsg);
  const p0 = await page.inputValue('#p0');
  if (p0 !== 'ace') throw new Error('found player should fill slot 0, got: ' + p0);
  const badge0 = await page.textContent('#link-badge-0');
  if (!badge0.trim()) throw new Error('linked badge missing for directory-found player');
  console.log('Directory lookup by exact nickname → slot filled + linked badge: OK');

  // Typing an email links that registered player at start time.
  await page.fill('#p1', 'ariel@test.com'); // same person by email — should dedupe with roster...
  // use plain anonymous names for the rest
  await page.fill('#p2', 'Guest1');
  await page.fill('#p3', 'Guest2');
  // p1 duplicates p0 (both resolve to A) → expect uniqueness error
  await page.click('#start-btn');
  await sleep(600);
  const dupErr = await page.textContent('#setup-error');
  if (!dupErr.trim()) throw new Error('expected duplicate-player error when email resolves to an already-placed player');
  console.log('Email resolving to an already-placed player → duplicate error: OK');

  // Replace p1 with an anonymous name and start.
  await page.fill('#p1', 'Rami');
  await page.click('#start-btn');
  await sleep(1200);
  const tourInfo = await page.evaluate(() => {
    const tr = JSON.parse(localStorage.getItem('puddlezit-db-v2')).tournaments[0];
    return { players: tr.players, claims: tr.claims };
  });
  if (tourInfo.players[0] !== 'ace') throw new Error('linked player display name wrong: ' + tourInfo.players);
  const claimIdx = Object.values(tourInfo.claims);
  if (!claimIdx.includes(0)) throw new Error('claims missing linked player at slot 0: ' + JSON.stringify(tourInfo.claims));
  if (claimIdx.length !== 1) throw new Error('anonymous players must not have claims: ' + JSON.stringify(tourInfo.claims));
  if (tourInfo.players.some(n => n.includes('@'))) throw new Error('an email leaked into player names: ' + tourInfo.players);
  console.log('Start links registered player (claims) and keeps others anonymous, no emails: OK');

  // ---- Directory does NOT allow free-name search (privacy) ----
  await page.click('#game-home-btn');
  await page.click('#new-tour-btn');
  await page.fill('#dir-q', 'ariel'); // partial email / free text
  await page.click('#dir-btn');
  await sleep(500);
  const noHit = await page.textContent('#dir-result');
  if (/ace/.test(noHit)) throw new Error('free-text directory search should not match');
  console.log('Directory rejects free-text (exact email/nickname only): OK');

  await ctx.close();
  if (errors.length) throw new Error('page errors: ' + errors.join('; '));
  console.log('ALL ROSTER TESTS PASSED');
  await browser.close();
})().catch(e => { console.error('FAIL:', e.message); process.exit(1); });
