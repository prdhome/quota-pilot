// site/index.html 冒煙測試：每組情境開一次頁面，確認沒有 JS error、今日行動卡文案符合情境、主要區塊都有渲染；
// 再用其中一組情境攔截請求，測三種失敗狀態（取不到檔案／資料格式不對／畫面程式錯誤）分開顯示。
// 用法：node smoke.mjs <base_url> <fixtures 目錄> <情境>...（<base_url>/<情境>/ 是 tests/lib/fixture.py site 產生的目錄）
// 設 SHOTS=<目錄> 時另存每組情境的桌機／手機截圖。
import { chromium } from 'playwright';
import { readFileSync } from 'node:fs';

const [base, fixDir, ...names] = process.argv.slice(2);
const SHOTS = process.env.SHOTS;
let pass = 0, fail = 0;
const ok = m => { pass++; console.log(`  ✅ ${m}`); };
const ng = (m, why) => { fail++; console.log(`  ❌ ${m}${why ? `\n     ${why}` : ''}`); };
const check = (m, cond, why) => cond ? ok(m) : ng(m, why);
const VIEWPORTS = [{ width: 1200, height: 900, tag: 'desktop' }, { width: 375, height: 812, tag: 'mobile' }];

// Playwright 自帶的 Chromium 沒裝時（本機常見），退回系統安裝的 Google Chrome；PW_CHANNEL 可強制指定（例：chrome）。
async function launch() {
  if (process.env.PW_CHANNEL) return chromium.launch({ channel: process.env.PW_CHANNEL });
  try { return await chromium.launch(); }
  catch (e) {
    if (!/Executable doesn't exist/.test(e.message)) throw e;
    console.log('  ℹ️ 找不到 Playwright Chromium，改用系統 Chrome（channel: chrome）');
    return chromium.launch({ channel: 'chrome' });
  }
}
const browser = await launch();
async function open(url, vp, setup) {
  const page = await browser.newPage({ viewport: { width: vp.width, height: vp.height } });
  const errors = [];
  page.on('pageerror', e => errors.push('pageerror: ' + e.message));
  page.on('console', m => { if (m.type() === 'error') errors.push('console: ' + m.text()); });
  page.on('response', r => { if (r.status() >= 400) errors.push(`HTTP ${r.status()} ${r.url()}`); });
  if (setup) await setup(page);
  await page.goto(url, { waitUntil: 'networkidle' });
  await page.waitForFunction(() => document.body.dataset.state, null, { timeout: 5000 }).catch(() => {});
  return { page, errors };
}

for (const name of names) {
  const sc = JSON.parse(readFileSync(`${fixDir}/${name}.json`, 'utf8'));
  for (const vp of VIEWPORTS) {
    const t = `${name}/${vp.tag}`;
    const { page, errors } = await open(`${base}/${name}/`, vp);
    const r = await page.evaluate(() => {
      const q = s => document.querySelectorAll(s), $ = id => document.getElementById(id);
      const vis = id => !$(id).hidden && $(id).offsetParent !== null;
      return {
        state: document.body.dataset.state,
        statusVisible: vis('status'),
        action: $('action').innerText,
        headline: $('headline').textContent,
        todo: [...q('#todo li')].map(e => e.textContent),
        level: $('action').dataset.level,
        fresh: $('fresh').className + ' ' + $('fresh').textContent,
        whyFresh: vis('why-fresh'), degrade: vis('degrade') && $('degrade').textContent,
        actionTop: $('action').getBoundingClientRect().top,
        mode: $('mode-n').textContent,
        stamp: $('stamp').className,
        chips: q('#chips .chip').length,
        provCards: q('#providers > .card').length,
        meters: q('#providers [role=meter]').length,
        cells: q('#matrix .cell').length,
        on: [...q('#matrix .cell.on')].map(e => e.querySelector('b').textContent),
        resRows: q('#reserves .res-row').length, resUsed: q('#reserves .res-row.used').length,
        resEmpty: q('#reserves .empty').length, today: q('#reserves .tl-axis .today').length,
        lanesWithNow: q('#reserves .lane .now').length,
        paths: q('#chart svg path').length,
        tableRows: q('#table tr').length,
        hscroll: document.documentElement.scrollWidth > document.documentElement.clientWidth,
        budget: [...q('#budget .budget-tile')].map(e => e.innerText.replace(/\n/g, ' ')),
        burns: [...q('#providers .burn-box')].map(b => { const n = b.parentElement.querySelector('.burn-note');
          return { p: b.dataset.p, svg: !!b.querySelector('svg'), actual: b.querySelectorAll('path.actual').length, pace: b.querySelectorAll('line.pace').length, proj: n.dataset.proj, note: n.textContent }; }),
        strip: q('#chart .strip rect').length, legendRoutes: q('#route-legend > span').length,
        shares: [...q('#matrix .cell')].map(e => +e.dataset.share || 0), onShare: +(document.querySelector('#matrix .cell.on')?.dataset.share || 0),
        reasons: [...q('#reasons li')].map(e => e.textContent),
      };
    });
    const want = sc.expect.mode, providers = ['claude', 'codex'].filter(p => sc[p]).length;
    const cards = sc.reserves?.cards || [], items = cards.length + (sc.reserves?.credits || []).length;
    const age = sc.snapshot_age || 0, stale = age > 90 * 60, degraded = age > 6 * 3600;
    check(`${t}：無 JS error／載入失敗`, errors.length === 0 && r.state === 'ok' && !r.statusVisible, errors.join(' | ') || `state=${r.state}`);
    check(`${t}：行動卡在最上方、有標題與 1–3 句建議`, r.actionTop < 200 && r.headline.length > 4 && r.todo.length >= 1 && r.todo.length <= 3, JSON.stringify({ top: r.actionTop, headline: r.headline, todo: r.todo }));
    const miss = (sc.expect.action || []).filter(s => !r.action.includes(s));
    check(`${t}：行動卡文案含 ${JSON.stringify(sc.expect.action || [])}`, sc.expect.action && miss.length === 0, `缺 ${JSON.stringify(miss)}；行動卡：${r.action.replace(/\n/g, ' / ')}`);
    check(`${t}：用卷文案不鼓勵週額度還多時就用卷`, !r.todo.some(s => s.includes('重置卷') && s.includes('過半')), JSON.stringify(r.todo));
    if (want.override !== '-') check(`${t}：5h 覆寫文案`, r.todo.some(s => s.includes('5h') && s.includes('恢復')), JSON.stringify(r.todo));
    if (want.card !== '-') check(`${t}：用卷建議含到期日與剩幾天`, r.todo.some(s => s.includes('重置卷') && /\d+\/\d+ 到期/.test(s) && /剩 \d+ (天|小時)/.test(s)), JSON.stringify(r.todo));
    check(`${t}：新鮮度「x 前更新」${stale ? '標過期＋原因' : ''}`, /前更新/.test(r.fresh) && stale === r.fresh.includes('stale') && stale === r.whyFresh && stale === r.stamp.includes('stale'), JSON.stringify({ fresh: r.fresh, whyFresh: r.whyFresh, stamp: r.stamp }));
    check(`${t}：降級提示${degraded ? '有' : '無'}`, degraded ? r.degrade === '數據過期，建議僅供參考' && r.level === 'crit' : !r.degrade, JSON.stringify({ degrade: r.degrade, level: r.level }));
    check(`${t}：模式 M${want.mode}＋4 個 chip`, r.mode === 'M' + want.mode && r.chips === 4, JSON.stringify({ mode: r.mode, chips: r.chips }));
    check(`${t}：額度條 ${providers * 2} 條`, r.provCards === 2 && r.meters === providers * 2, JSON.stringify({ provCards: r.provCards, meters: r.meters }));
    check(`${t}：矩陣 12 格、亮 M${want.mode}`, r.cells === 12 && r.on.length === 1 && r.on[0] === 'M' + want.mode, JSON.stringify({ cells: r.cells, on: r.on }));
    const usedCards = cards.filter(c => c.used_at).length;
    check(`${t}：時間軸 ${items} 條 lane（已用 ${usedCards}）＋今天標記`,
      items ? r.resRows === items && r.resUsed === usedCards && r.today === 1 && r.lanesWithNow === items : r.resRows === 0 && r.resEmpty === 1,
      JSON.stringify({ resRows: r.resRows, resUsed: r.resUsed, today: r.today, lanes: r.lanesWithNow, resEmpty: r.resEmpty }));
    check(`${t}：趨勢圖 ${providers} 條線＋表格`, r.paths === providers && r.tableRows > 1, JSON.stringify({ paths: r.paths, tableRows: r.tableRows }));
    check(`${t}：無水平捲動`, !r.hscroll);
    // --- 第一批視覺化：今日預算、燃燒曲線、route 時間帶、矩陣熱度、白話判斷 ---
    check(`${t}：今日預算 2 格、各有每日 % 或「今天用完」`, r.budget.length === 2 && ['claude', 'codex'].every((p, i) => !sc[p] || /% \/ 天|今天用完/.test(r.budget[i])), JSON.stringify(r.budget));
    const WEEK = 7 * 86400;
    for (const p of ['claude', 'codex'].filter(p => sc[p])) {
      const b = r.burns.find(x => x.p === p), e = 100 * (1 - sc[p].week_reset_in / WEEK), want = sc[p].week_used / e * 100 > 100 ? 'empty' : 'left';
      check(`${t}：${p} 燃燒曲線（實線＋進度虛線＋推估「${want === 'empty' ? '見底' : '結束時剩'}」）`,
        b && b.svg && b.actual === 1 && b.pace === 1 && b.proj === want && (want === 'empty' ? /見底/ : /約剩 \d+%/).test(b.note), JSON.stringify(b));
    }
    check(`${t}：route 時間帶有色段＋圖例 6 項`, r.strip >= 1 && r.legendRoutes === 6, JSON.stringify({ strip: r.strip, legend: r.legendRoutes }));
    const sum = r.shares.reduce((a, b) => a + b, 0);
    check(`${t}：矩陣熱度占比合計 ≈100%、目前格 > 0`, Math.abs(sum - 100) <= 1.5 && r.onShare > 0, JSON.stringify({ sum, on: r.onShare }));
    const wantWhy = [r.reasons[0]?.startsWith('Claude'), r.reasons[1]?.startsWith('Codex'), r.reasons.some(x => x.includes(`M${want.mode}`)),
      want.override === '-' || r.reasons.some(x => x.startsWith('覆寫')), r.reasons.some(x => x.startsWith('主控') && x.includes(want.hub === 'opus' ? 'Opus' : 'Sonnet')),
      !r.reasons[0]?.startsWith('Claude') || r.reasons[0].includes(sc.snapshot_age > 0 && sc.claude?.updated_ago > 21600 ? '過期' : { rich: '充裕', ok: '正常', tight: '吃緊' }[want.claude === 'ok' && sc.reserves?.cards?.some(c => c.provider === 'claude' && !c.used_at) ? 'tight' : want.claude])];
    check(`${t}：「為什麼是這個模式」逐步說明（Claude／Codex／矩陣／覆寫／主控）`, r.reasons.length >= 4 && wantWhy.every(Boolean), JSON.stringify({ reasons: r.reasons, wantWhy }));
    if (SHOTS) await page.screenshot({ path: `${SHOTS}/${name}-${vp.tag}.png`, fullPage: true });
    await page.close();
  }
}

// --- 三種失敗狀態分開顯示（用第一組情境，攔截請求製造失敗）---
const errCase = async (label, setup, wantState, wantTitle, extra) => {
  const { page, errors } = await open(`${base}/${names[0]}/index.html`, VIEWPORTS[0], setup);
  const r = await page.evaluate(() => ({ state: document.body.dataset.state, status: document.getElementById('status').hidden ? '' : document.getElementById('status').innerText }));
  check(`錯誤狀態 ${label} → 「${wantTitle}」`, r.state === wantState && r.status.includes(wantTitle) && (wantTitle === '讀不到資料' || !r.status.includes('讀不到資料')), JSON.stringify(r));
  if (extra) extra(errors);
  await page.close();
};
await errCase('render 拋錯', page => page.route('**/index.html', async rt => {
  const res = await rt.fetch(); const html = await res.text();
  const hook = 'function render() {\n  if (!snap) return;';
  if (!html.includes(hook)) throw new Error('smoke.mjs 找不到 render() 注入點，請更新 hook');
  await rt.fulfill({ response: res, body: html.replace(hook, hook + "\n  throw new Error('injected render bug');") });
}), 'render', '畫面錯誤',
  errors => check('錯誤狀態 render 拋錯 → console.error 有記錄', errors.some(e => e.startsWith('console:') && e.includes('injected render bug')), errors.join(' | ')));
await errCase('snapshot.json 404', page => page.route('**/data/snapshot.json', rt => rt.fulfill({ status: 404, body: 'not found' })), 'fetch', '讀不到資料');
await errCase('snapshot.json 不是 JSON', page => page.route('**/data/snapshot.json', rt => rt.fulfill({ status: 200, contentType: 'application/json', body: '{"generated_at": 17' })), 'format', '資料格式不對');
await errCase('snapshot.json 缺 mode', page => page.route('**/data/snapshot.json', rt => rt.fulfill({ status: 200, contentType: 'application/json', body: '{"generated_at": 1792000000}' })), 'format', '資料格式不對');

await browser.close();
console.log(`pass=${pass} fail=${fail}`);
process.exit(fail ? 1 : 0);
