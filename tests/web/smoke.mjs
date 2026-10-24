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
        rings: [...q('#budget .ring')].map(e => ({ sev: e.dataset.sev, label: e.getAttribute('aria-label') })),
        next: $('next').textContent, harness: vis('harness') ? $('harness').textContent : '',
        cmd: document.querySelector('#cmds .cmd')?.dataset.copy,
        chipText: [...q('#chips .chip')].map(e => e.textContent),
                solo: $('lower').classList.contains('solo'), resets: q('#chart .resets line.reset').length,
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
    for (const [i, p] of ['claude', 'codex'].entries()) {
      if (!sc[p] || sc[p].week_reset_in <= 86400) continue;
      const d = (100 - sc[p].week_used) / (sc[p].week_reset_in / 86400) - 100 / 7, cmp = Math.abs(d) <= 1 ? '約平均' : d > 0 ? '比平均寬' : '比平均緊';
      check(`${t}：${p} 今日預算標「${cmp}」（±1 個百分點內算約平均）`, r.budget[i]?.includes(cmp), r.budget[i]);
    }
    if (name === 'rich' && vp.tag === 'desktop') {   // 夾具沒有剛好落在平均的情況：把 Codex 週已用改成「剛好平均 +0.5」，重畫預算格
      const avg = await page.evaluate(() => {
        const w = snap.codex.week, days = (w.resets_at - nowS()) / 86400;
        w.used = 100 - (100 / 7 + 0.5) * days; renderBudget();
        return document.querySelector('#budget .budget-tile[data-p="codex"]').innerText.replace(/\n/g, ' ');
      });
      check(`${t}：差距 0.5 個百分點時標「約平均」`, avg.includes('約平均'), avg);
    }
    const WEEK = 7 * 86400;
    for (const p of ['claude', 'codex'].filter(p => sc[p])) {
      const b = r.burns.find(x => x.p === p), e = 100 * (1 - sc[p].week_reset_in / WEEK), want = sc[p].week_used / e * 100 > 100 ? 'empty' : 'left';
      check(`${t}：${p} 燃燒曲線（實線＋進度虛線＋推估「${want === 'empty' ? '見底' : '結束時剩'}」）`,
        b && b.svg && b.actual === 1 && b.pace === 1 && b.proj === want && (want === 'empty' ? /見底/ : /約剩 \d+%/).test(b.note), JSON.stringify(b));
    }
    check(`${t}：route 時間帶有色段＋圖例 5 項`, r.strip >= 1 && r.legendRoutes === 5, JSON.stringify({ strip: r.strip, legend: r.legendRoutes }));
    const sum = r.shares.reduce((a, b) => a + b, 0);
    check(`${t}：矩陣熱度占比合計 ≈100%、目前格 > 0`, Math.abs(sum - 100) <= 1.5 && r.onShare > 0, JSON.stringify({ sum, on: r.onShare }));
    const wantWhy = [r.reasons[0]?.startsWith('Claude'), r.reasons[1]?.startsWith('Codex'), r.reasons.some(x => x.includes(`M${want.mode}`)),
      want.override === '-' || r.reasons.some(x => x.startsWith('覆寫')), r.reasons.some(x => x.startsWith('主控') && x.includes(want.hub === 'opus' ? 'Opus' : 'Sonnet')),
      !r.reasons[0]?.startsWith('Claude') || r.reasons[0].includes(sc.snapshot_age > 0 && sc.claude?.updated_ago > 21600 ? '過期' : { rich: '充裕', ok: '正常', tight: '吃緊' }[want.claude === 'ok' && sc.reserves?.cards?.some(c => c.provider === 'claude' && !c.used_at) ? 'tight' : want.claude])];
    const hubWhy = r.reasons.find(x => x.startsWith('主控')) || '', cardLifted = /^Claude 吃緊.*重置卷/.test(r.reasons[0] || '');
    check(`${t}：主控說明${cardLifted ? '寫出「有卷先用卷不降級」' : '不誤報用卷'}`, cardLifted ? hubWhy.includes('先用卷') : !hubWhy.includes('先用卷'), JSON.stringify({ hubWhy, claude: r.reasons[0] }));
    if (name === 'reserve-card') check(`${t}：reserve-card 情境走到「Claude 吃緊＋有卷」`, cardLifted, r.reasons[0]);
    check(`${t}：「為什麼是這個模式」逐步說明（Claude／Codex／矩陣／覆寫／主控）`, r.reasons.length >= 4 && wantWhy.every(Boolean), JSON.stringify({ reasons: r.reasons, wantWhy }));
    // --- 第二批：現況圓環、下一個轉折、harness 提示、可複製指令、徽章／矩陣一致、卷區塊收合、週期重置標記 ---
    const sev5 = p => { const l = 100 - sc[p].five_used; return l < 10 ? 'crit' : l < 30 ? 'warn' : 'ok'; };
    const sev7 = p => ({ tight: 'crit', lean: 'warn', unknown: 'warn' })[want[p]] || 'ok';
    const wantRings = ['claude', 'codex'].flatMap(p => sc[p] ? [sev5(p), sev7(p)] : []);
    check(`${t}：現況圓環 ${wantRings.length} 個、顏色照嚴重度 ${JSON.stringify(wantRings)}`, r.rings.length === 4 && JSON.stringify(r.rings.map(x => x.sev).filter(x => x !== 'none')) === JSON.stringify(wantRings), JSON.stringify(r.rings));
    const five = ['claude', 'codex'].filter(p => sc[p]).map(sev5);
    const gate = want.override === 'both5h' || (want.claude === 'tight' && want.codex === 'tight') ? 'hold' : 'open';
    const wantLevel = degraded || gate === 'hold' || five.includes('crit') ? 'crit'
      : stale || wantRings.some(x => x !== 'ok') || want.card !== '-' || want.override.endsWith('5h-low') ? 'warn' : 'ok';
    check(`${t}：行動卡色條 ${wantLevel}`, r.level === wantLevel, JSON.stringify({ level: r.level, wantLevel }));
    check(`${t}：「下一個轉折」有時間與事件`, /^下一個轉折約 .+（.+後）｜.+/.test(r.next) && (!/^(claude|codex|both)5h$/.test(want.override) || r.next.includes('5h 恢復')), r.next);
    const wantHarness = (want.claude === 'tight' && want.hub === 'sonnet' || want.override === 'claude5h') && ['rich', 'ok'].includes(want.codex);
    check(`${t}：Harness 提示${wantHarness ? '有（Codex CLI）' : '無'}`, wantHarness ? r.harness.includes('Codex CLI') && r.harness.includes('規則尚未納入') : !r.harness, r.harness);
    check(`${t}：可複製指令 /model ${want.hub}`, r.cmd === `/model ${want.hub}`, r.cmd);
    check(`${t}：chip 標明 7d`, r.chipText.filter(x => x.includes('7d')).length === 2, JSON.stringify(r.chipText));
    check(`${t}：卷區塊${items ? '並排' : '收成一行'}`, r.solo === !items, String(r.solo));
    check(`${t}：趨勢圖標出週期重置`, r.resets >= 1, String(r.resets));
    if (SHOTS) await page.screenshot({ path: `${SHOTS}/${name}-${vp.tag}.png`, fullPage: true });
    await page.close();
  }
}

// --- 7 天趨勢的文字避讓：重現「兩次重置相隔很近＋右緣重置＋兩條線尾數值接近（-7／-9）」，檢查標籤互不重疊、不出圖 ---
for (const vp of VIEWPORTS) {
  const now = Math.floor(Date.now() / 1000), D = 86400, rows = [];
  const cAt = now - 1.3 * D, xAt = [now - 1.1 * D, now - 0.05 * D];          // Claude 與 Codex 重置只差 ~5 小時；Codex 另一次貼近右緣
  for (let t = now - 7 * D; t <= now; t += 1800) {
    const xr = now + 6 * D + xAt.filter(a => t >= a).length * D;
    rows.push({ t, mode: 6, ct: 'ok', xt: 'ok', override: '-', card: '-', cs: t >= now - 0.5 * D ? -9 : 5, xs: t >= now - 0.5 * D ? -7 : 3,
      c5: 10, c7: 40, x5: 10, x7: 40, cr: now + 3 * D + (t >= cAt ? D : 0), xr });
  }
  const body = rows.map(r => JSON.stringify(r)).join('\n') + '\n';
  const { page, errors } = await open(`${base}/${names[0]}/`, vp, page => page.route('**/data/history.jsonl', rt => rt.fulfill({ status: 200, contentType: 'text/plain', body })));
  const r = await page.evaluate(() => {
    const svg = document.querySelector('#chart svg'), W = svg.getBoundingClientRect();
    const boxes = [...svg.querySelectorAll('text.reset-label, text.end-label')].map(e => { const b = e.getBoundingClientRect(); return { t: e.textContent, l: b.left - W.left, r: b.right - W.left, top: b.top, bot: b.bottom }; });
    const hit = [];
    for (let i = 0; i < boxes.length; i++) for (let j = i + 1; j < boxes.length; j++) {
      const a = boxes[i], b = boxes[j];
      if (a.l < b.r - 1 && b.l < a.r - 1 && a.top < b.bot - 1 && b.top < a.bot - 1) hit.push(`${a.t} × ${b.t}`);
    }
    const dates = [...svg.querySelectorAll('text.date')].map(e => e.getBoundingClientRect());
    const dateHit = dates.some((b, i) => i && b.left < dates[i - 1].right + 2);
    return { n: boxes.length, labels: boxes.map(b => b.t), hit, out: boxes.filter(b => b.l < -1 || b.r > W.width + 1).map(b => b.t), dates: dates.length, dateHit };
  });
  check(`趨勢文字避讓/${vp.tag}：3 個重置標籤＋2 個線尾標籤互不重疊、不出圖；日期不擠在一起`, errors.length === 0 && r.n === 5 && !r.hit.length && !r.out.length && r.dates >= 3 && !r.dateHit, JSON.stringify({ errors, ...r }));
  if (SHOTS) await page.locator('#chart').screenshot({ path: `${SHOTS}/trend-labels-${vp.tag}.png` });
  await page.close();
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
