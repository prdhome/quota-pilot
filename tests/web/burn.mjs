// 用卷後燒速回歸；node tests/web/burn.mjs；SHOTS=<目錄> 另存三情境 × 桌機／手機截圖。
import assert from 'node:assert/strict';
import { readFileSync, mkdirSync } from 'node:fs';
import { chromium } from 'playwright';

const html = readFileSync(new URL('../../site/index.html', import.meta.url), 'utf8');
const NOW = 1792627200, WEEK = 604800, RESET = NOW + 127008, START = RESET - WEEK;
const card = (provider, t) => ({ provider, expires: new Date((NOW + WEEK) * 1000).toISOString(), used_at: t == null ? null : new Date(t * 1000).toISOString() });
const scenarios = [
  { name: 'no-card', age: null, used: 20, proj: 'left', text: '約剩 75%' },
  { name: 'card-30m', age: 1800, used: 0, proj: 'none', text: '用卷後資料不足' },
  { name: 'card-10h-20pct', age: 36000, used: 20, proj: 'left', text: '約剩 9%' },
];
let browser;
if (process.env.PW_CHANNEL) browser = await chromium.launch({ channel: process.env.PW_CHANNEL });
else {
  try { browser = await chromium.launch(); }
  catch (e) {
    if (!/Executable doesn't exist/.test(e.message)) throw e;
    browser = await chromium.launch({ channel: 'chrome' });
  }
}
if (process.env.SHOTS) mkdirSync(process.env.SHOTS, { recursive: true });
let pass = 0;
try {
  for (const sc of scenarios) for (const width of [1200, 375]) {
    const page = await browser.newPage({ viewport: { width, height: width === 375 ? 812 : 900 }, timezoneId: 'Asia/Taipei', colorScheme: 'light' });
    const errors = [];
    page.on('pageerror', e => errors.push(e.message));
    await page.clock.install({ time: NOW * 1000 });
    await page.clock.pauseAt(NOW * 1000);
    const side = { five: { used: 10, resets_at: NOW + 3600 }, week: { used: sc.used, resets_at: RESET }, surplus: 79 - sc.used };
    const snapshot = {
      generated_at: NOW, claude: side, codex: side,
      mode: { mode: '1', hub: 'opus', subagent: 'sonnet', route: 'delegate', claude: 'rich', codex: 'rich', override: '-', card: '-' },
      cards: sc.age == null ? [] : ['claude', 'codex'].map(p => card(p, NOW - sc.age)), credits: [], explain: [],
    };
    const history = [];
    for (let t = START; t < NOW; t += 1800) {
      const used = sc.age == null ? 20 * (t - START) / (NOW - START) : t < NOW - sc.age ? 80 * (t - START) / (NOW - sc.age - START) : sc.used * (t - NOW + sc.age) / sc.age;
      history.push({ t, c7: used, x7: used, cr: RESET, xr: RESET, cs: 100 * (t - START) / WEEK - used, xs: 100 * (t - START) / WEEK - used, mode: 1, ct: 'rich', xt: 'rich', override: '-' });
    }
    await page.route('http://quota.test/**', route => {
      const path = new URL(route.request().url()).pathname;
      return route.fulfill({ contentType: path.endsWith('.json') ? 'application/json' : path.endsWith('.jsonl') ? 'text/plain' : 'text/html', body: path.endsWith('snapshot.json') ? JSON.stringify(snapshot) : path.endsWith('history.jsonl') ? history.map(r => JSON.stringify(r)).join('\n') : html });
    });
    await page.goto('http://quota.test/');
    await page.waitForFunction(() => document.body.dataset.state === 'ok' && document.querySelector('.burn-svg'));
    const read = () => page.evaluate(() => ({
      overflow: document.documentElement.scrollWidth > innerWidth,
      burns: [...document.querySelectorAll('.burn-box')].map(box => {
        const svg = box.querySelector('svg'), note = box.parentElement.querySelector('.burn-note');
        return { p: box.dataset.p, note: note.textContent, proj: note.dataset.proj, pace: svg.querySelectorAll('line.pace').length, path: svg.querySelector('path.proj')?.getAttribute('d'), actual: svg.querySelector('path.actual')?.getAttribute('d'), width: box.clientWidth };
      }),
    }));
    const result = await read();
    assert.deepEqual(errors, []);
    assert.equal(result.overflow, false);
    for (const b of result.burns) {
      assert.equal(b.proj, sc.proj);
      assert.ok(b.note.includes(sc.text), b.note);
      assert.equal(b.pace, 1);
      if (sc.proj === 'none') assert.equal(b.path, undefined);
      else {
        const nums = b.path.match(/-?\d+(?:\.\d+)?/g).map(Number);
        const last = b.actual.match(/-?\d+(?:\.\d+)?/g).slice(-2).map(Number);
        assert.deepEqual(nums.slice(0, 2), last, '推估線從最後一個資料點開始');
        assert.equal(nums[2], b.width - 12, '剩餘分支終點為週期結束');
        const rate = sc.used / (sc.age ?? NOW - START), end = sc.used + rate * (RESET - NOW);
        assert.ok(Math.abs(nums[3] - (8 + 122 * (100 - end) / 100)) < 0.1, '推估終點用正確速率');
      }
    }
    if (process.env.SHOTS) {
      const prefix = `${process.env.SHOTS}/${sc.name}-${width}`;
      await page.screenshot({ path: `${prefix}-full.png`, fullPage: true });
      await page.locator('#providers').screenshot({ path: `${prefix}.png` });
    }
    console.log(`PASS ${sc.name}/${width}: ${result.burns.map(b => b.note).join(' / ')}; no overflow`);
    pass++;

    // 邊界與兩 provider 隔離；不依賴截圖來驗證速率。
    if (sc.name === 'no-card' && width === 1200) {
      const cases = [
        { name: 'latest-card-unsorted', cards: [card('claude', NOW - 36000), card('claude', NOW - 72000)], proj: 'left', text: '約剩 9%' },
        { name: 'other-provider', cards: [card('codex', NOW - 1800)], proj: 'left', text: '約剩 75%' },
        { name: 'previous-cycle', cards: [card('claude', START - 1)], proj: 'left', text: '約剩 75%' },
        { name: 'future-card', cards: [card('claude', NOW + 60)], proj: 'left', text: '約剩 75%' },
        { name: 'invalid-unused-card', cards: [{ provider: 'claude', used_at: 'invalid' }, card('claude', null)], proj: 'left', text: '約剩 75%' },
        { name: 'exactly-one-hour', cards: [card('claude', NOW - 3600)], proj: 'none', text: '用卷後資料不足' },
        { name: 'one-hour-plus-second', cards: [card('claude', NOW - 3601)], proj: 'empty', text: '見底' },
        { name: 'zero-usage', cards: [card('claude', NOW - 36000)], used: 0, proj: 'none', text: '用卷後資料不足' },
      ];
      for (const c of cases) {
        await page.evaluate(c => { snap.cards = c.cards; snap.claude.week.used = c.used ?? 20; drawBurns(); }, c);
        const b = (await read()).burns[0];
        assert.equal(b.proj, c.proj, c.name);
        assert.ok(b.note.includes(c.text), `${c.name}: ${b.note}`);
        if (c.proj === 'empty') {
          const nums = b.path.match(/-?\d+(?:\.\d+)?/g).map(Number);
          const emptyAt = NOW + 80 / (20 / 3601);
          assert.ok(Math.abs(nums[2] - (34 + (b.width - 46) * (emptyAt - START) / WEEK)) < 0.1);
          assert.equal(nums[3], 8, '見底分支終點為 100%');
        }
        console.log(`PASS ${c.name}`); pass++;
      }
      await page.evaluate(({ NOW, WEEK }) => {
        snap.cards = []; hist = []; snap.generated_at = NOW;
        snap.claude.week = { used: 1, resets_at: NOW + WEEK - 7200 }; drawBurns();
      }, { NOW, WEEK });
      assert.ok((await read()).burns[0].note.includes('週期剛開始'), '未用卷保留週初門檻');
      console.log('PASS no-card-early-cycle-regression'); pass++;
    }
    await page.close();
  }
  console.log(`pass=${pass} fail=0`);
} finally { await browser.close(); }
