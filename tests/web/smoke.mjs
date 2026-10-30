// site/index.html 冒煙測試：每組情境開一次頁面，確認沒有 JS error、今日行動卡文案符合情境、主要區塊都有渲染；
// 再用其中一組情境攔截請求，測三種失敗狀態（取不到檔案／資料格式不對／畫面程式錯誤）分開顯示。
// 用法：node smoke.mjs <base_url> <fixtures 目錄> <情境>...（<base_url>/<情境>/ 是 tests/lib/fixture.py site 產生的目錄）
// 設 SHOTS=<目錄> 時另存每組情境的桌機／手機截圖。
import { chromium } from 'playwright';
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';

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
async function open(url, vp, setup, opts = {}) {
  const page = await browser.newPage({ viewport: { width: vp.width, height: vp.height }, ...opts });
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
        work: { tiles: [...q('#work .wt')].map(e => e.innerText.replace(/\n/g, ' ')), empty: $('work').innerText },
        eff: document.querySelector('#cmds .eff')?.dataset.effort ?? null,
        lastCycles: [...q('#providers .last-cycle')].map(e => ({ tag: e.dataset.tag, text: e.textContent })),
        stab: (b => b && { max: +b.dataset.max, flaps: +b.dataset.flaps, tiles: b.querySelectorAll('.wt').length })(document.querySelector('#stability .stab')),
        stabLevel: document.querySelector('#stability .stab-verdict')?.dataset.level,
        tok: { tiles: q('#tokens .wt').length, text: $('tokens').innerText, days: q('#tokens-chart .tok-day').length, bars: q('#tokens-chart rect.tok-c, #tokens-chart rect.tok-x').length,
          models: [...q('#tokens-table tr[data-model]')].map(e => e.dataset.model), note: $('tokens-note').textContent },
        credit: [...q('#reserves .res-row[data-kind="credit"] .credit-burn')].map(e => ({ level: e.dataset.level, text: e.textContent, label: e.closest('.res-row').querySelector('.tag').textContent })),
        usage: [...q('#reserves .usage-row')].map(e => ({ p: e.dataset.p, head: e.querySelector('.res-head').textContent, level: e.querySelector('.credit-burn')?.dataset.level, text: e.querySelector('.credit-burn')?.textContent || '' })),
        ce: $('card-effect').hidden ? null : [...q('#card-effect li')].map(e => e.dataset.tag),
        peaks: [...q('#peaks .peak')].map(b => ({ p: b.dataset.p, rows: b.querySelectorAll('.heat .dl').length, cells: b.querySelectorAll('.heat .c').length,
          sev: [...b.querySelectorAll('.heat .c')].map(c => c.dataset.sev).filter(Boolean).length, note: b.querySelector('.peak-note')?.textContent || '' })),
      };
    });
    r.snapEffort = await page.evaluate(() => fetch('data/snapshot.json').then(x => x.json()).then(j => j.effort));
    const want = sc.expect.mode, providers = ['claude', 'codex'].filter(p => sc[p]).length;
    const usageN = (sc.reserves?.credits || []).filter(c => c.kind === 'usage').length;   // 使用量額度不上時間軸，另列
    const cards = sc.reserves?.cards || [], items = cards.length + (sc.reserves?.credits || []).length - usageN;
    const age = sc.snapshot_age || 0, stale = age > 90 * 60, degraded = age > 6 * 3600;
    if (sc.work === null || sc.tokens === null) errors.splice(0, errors.length, ...errors.filter(e => !/work\.json|tokens\.json|404 \(File not found\)|status of 404/.test(e)));   // 情境刻意沒有 work.json／tokens.json
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
    check(`${t}：卷區塊${items || usageN ? '並排' : '收成一行'}`, r.solo === !(items || usageN), String(r.solo));
    check(`${t}：趨勢圖標出週期重置`, r.resets >= 1, String(r.resets));
    // --- 第三批：工作量（work.json）、主控 effort、上週期結算 ---
    if (sc.work === null) check(`${t}：沒有 work.json → 工作量顯示「還沒接上」`, !r.work.tiles.length && r.work.empty.includes('還沒接上'), JSON.stringify(r.work));
    else {
      const W = { direct: { n: 12, ok: 11 }, dispatch: { n: 5, ok: 4 }, review: { verdicts: 1, memory: 3 }, ...(sc.work || {}) };
      const wantTiles = [W.direct.n ? `${W.direct.ok}/${W.direct.n}` : '近 7 天沒有', W.dispatch.n ? `${W.dispatch.ok}/${W.dispatch.n}` : '近 7 天沒有', '件',
        W.review ? `裁決 ${W.review.verdicts} · memory ${W.review.memory}` : '還沒接上'];
      check(`${t}：工作量 4 格 ${JSON.stringify(wantTiles)}`, r.work.tiles.length === 4 && wantTiles.every((x, i) => r.work.tiles[i].includes(x)), JSON.stringify(r.work.tiles));
    }
    if ('effort' in sc.expect) check(`${t}：snapshot.effort = ${sc.expect.effort}`, r.snapEffort === sc.expect.effort, String(r.snapEffort));
    const low = r.snapEffort === 'low';
    check(`${t}：主控 effort ${want.hub === 'opus' ? (low ? 'low' : '預設') : '不顯示（Sonnet）'}`,
      r.eff === (want.hub === 'opus' ? (low ? 'low' : 'default') : null) && low === r.todo.some(x => x.includes('effort low')) && low === r.reasons.some(x => x.startsWith('主控') && x.includes('effort low')),
      JSON.stringify({ eff: r.eff, snapEffort: r.snapEffort, todo: r.todo }));
    const lc = ['claude', 'codex'].filter(p => sc[p]);
    check(`${t}：上週期結算 ${lc.length} 行、合成歷史的上週期剩很多 → 浪費`, r.lastCycles.length === lc.length && r.lastCycles.every(x => x.tag === 'waste' && /^上週期 \d+\/\d+ 結束時剩 \d+%：浪費/.test(x.text)), JSON.stringify(r.lastCycles));
    check(`${t}：5h 尖峰熱圖 2 張、每列 24 格、有摘要`, r.peaks.length === 2 && r.peaks.every(x => !sc[x.p] ? true : x.rows >= 1 && x.cells === x.rows * 24 && x.sev > 0 && /5h (偏低多在 \d+–\d+ 時|沒有偏低)/.test(x.note)), JSON.stringify(r.peaks.map(({ sev, ...x }) => x)));
    if (sc.tokens === null) {
      errors.splice(0, errors.length, ...errors.filter(e => !/tokens\.json|404 \(File not found\)|status of 404/.test(e)));
      check(`${t}：沒有 tokens.json → Token 區塊顯示「還沒接上」`, r.tok.tiles === 0 && r.tok.text.includes('還沒接上'), JSON.stringify(r.tok));
    } else check(`${t}：Token 用量 3 格、14 天長條、4 個模型明細、沒有單價的模型有註明`, r.tok.tiles === 3 && r.tok.days === 14 && r.tok.bars >= 18 && r.tok.models.length === 4 && r.tok.note.includes('gpt-9-test') && r.tok.models[r.tok.models.length - 1] === 'gpt-9-test', JSON.stringify(r.tok));
    if (name === 'reserve-card') check(`${t}：點數 7 天從 US$30 用到 12.5 → 平均每天 US$2.50、比到期日早用完`, r.credit.length === 1 && r.credit[0].label.startsWith('雲端工作階段點數') && r.credit[0].level === 'warn' && /近 7 天平均每天 US\$2\.50，照這速度約 \d+\/\d+ 用完，比到期日早 2[56] 天/.test(r.credit[0].text), JSON.stringify(r.credit));
    if (name === 'reserve-card') check(`${t}：使用量額度另列（沒有到期日）：4 天從 US$40 扣到 31.66 → 扣了 US$8.34、有超出方案上限`,
      r.usage.length === 1 && r.usage[0].head.includes('沒有到期日') && r.usage[0].head.includes('剩 US$31.66') && r.usage[0].level === 'warn'
        && /近 4 天扣了 US\$8\.34（平均每天 US\$2\.0[89]）：有超出方案上限、在花已購買的額度，照這速度約 \d+\/\d+ 用完/.test(r.usage[0].text), JSON.stringify(r.usage));
    const deadCards = cards.filter(c => c.used_at || c.expires_in <= 0).length;
    check(`${t}：用卷效果${deadCards ? ` ${deadCards} 筆` : '不顯示（沒有已用或過期的卷）'}`, deadCards ? r.ce?.length === deadCards : r.ce === null, JSON.stringify(r.ce));
    check(`${t}：規則穩定度 3 格＋判讀（warn ⇔ 單日 ≥6 或來回 ≥3）`, r.stab && r.stab.tiles === 3 && r.stabLevel === (r.stab.max >= 6 || r.stab.flaps >= 3 ? 'warn' : 'ok'), JSON.stringify({ stab: r.stab, level: r.stabLevel }));
    if (SHOTS) await page.screenshot({ path: `${SHOTS}/${name}-${vp.tag}.png`, fullPage: true });
    await page.close();
  }
}

// --- 5h 尖峰熱圖：注入 UTC 歷史，Claude 每天 14–16 時 5h 用到 95%（見底）、其他時段 10%；Codex 一直 10% ---
{
  const now = Math.floor(Date.now() / 1000), D = 86400, rows = [];
  for (let t = now - 9 * D; t <= now; t += 1800) {
    const h = new Date(t * 1000).getUTCHours();
    rows.push({ t, mode: 1, ct: 'rich', xt: 'rich', hub: 'opus', override: '-', card: '-', c5: h >= 14 && h <= 16 ? 95 : 10, x5: 10, c7: 30, cs: 10, x7: 30, xs: 10 });
  }
  const body = rows.map(r => JSON.stringify(r)).join('\n') + '\n';
  for (const vp of VIEWPORTS) {
    const { page, errors } = await open(`${base}/${names[0]}/`, vp, page => page.route('**/data/history.jsonl', rt => rt.fulfill({ status: 200, contentType: 'text/plain', body })), { timezoneId: 'UTC' });
    const r = await page.evaluate(() => [...document.querySelectorAll('#peaks .peak')].map(b => { const n = b.querySelector('.peak-note');
      return { p: b.dataset.p, hit: n.dataset.hit, note: n.textContent, crit: b.querySelectorAll('.c[data-sev="crit"]').length, warn: b.querySelectorAll('.c[data-sev="warn"]').length,
        hscroll: document.documentElement.scrollWidth > document.documentElement.clientWidth }; }));
    const m = r[0]?.note.match(/(\d+) 天裡有 (\d+) 天（其中 (\d+) 天見底）/);
    check(`5h 尖峰/${vp.tag}：Claude 摘要指出 14–17 時、每天都見底；Codex 沒有偏低；無水平捲動`,
      errors.length === 0 && r[0]?.hit === '14-17' && m && m[2] === m[3] && +m[2] >= 9 && +m[2] <= +m[1] && r[0].warn === 0 && r[0].crit >= 27
        && r[1]?.hit === '' && r[1].note.includes('沒有偏低') && !r[0].hscroll, JSON.stringify({ errors, r }));
    if (SHOTS) await page.locator('#peaks').screenshot({ path: `${SHOTS}/peaks-${vp.tag}.png` });
    await page.close();
  }
}

// --- Token 估算金額：注入已知 token 數，對照官方單價算出的金額（Opus 5.5 各 1M → 4+20+0.2+5+8＝37.2；gpt-6.1-sol 各 1M → 2+10+0.1＝12.1；帶日期與 [1m] 的名稱也要對到單價）---
{
  const d = (() => { const x = new Date(); return `${x.getFullYear()}-${String(x.getMonth() + 1).padStart(2, '0')}-${String(x.getDate()).padStart(2, '0')}`; })(), M = 1e6;
  const body = JSON.stringify({ generated_at: Math.floor(Date.now() / 1000), days: 14, skipped: { claude_lines: 0, codex_lines: 2, codex_no_model: 0 }, rows: [
    { d, p: 'claude', m: 'claude-opus-5-5', n: 1, s: 1, in: M, out: M, cr: M, cw5: M, cw1h: M },
    { d, p: 'codex', m: 'gpt-6.1-sol', n: 1, s: 1, in: M / 2, out: M, cr: M, cw5: 0, cw1h: 0 },
    { d, p: 'codex', m: 'gpt-6.1-sol-2026-09-01', n: 1, s: 1, in: M / 2, out: 0, cr: 0, cw5: 0, cw1h: 0 },
    { d, p: 'claude', m: 'claude-haiku-5-5[1m]', n: 1, s: 1, in: 0, out: 0, cr: 0, cw5: 0, cw1h: 0 },
    { d, p: 'codex', m: 'mystery-model', n: 3, s: 1, in: M, out: M, cr: 0, cw5: 0, cw1h: 0 }] });
  for (const vp of VIEWPORTS) {
    const { page, errors } = await open(`${base}/${names[0]}/`, vp, page => page.route('**/data/tokens.json', rt => rt.fulfill({ status: 200, contentType: 'application/json', body })));
    const r = await page.evaluate(() => ({ week: document.querySelector('#tokens .wt[data-k="week"]').innerText.replace(/\n/g, ' '), today: document.querySelector('#tokens .wt[data-k="today"]').innerText.replace(/\n/g, ' '),
      rows: [...document.querySelectorAll('#tokens-table tr[data-model]')].map(e => [...e.cells].map(c => c.textContent).join('|')), note: document.getElementById('tokens-note').textContent,
      hscroll: document.documentElement.scrollWidth > document.documentElement.clientWidth }));
    check(`Token 估算/${vp.tag}：近 7 天 US$49.30（Claude US$37.20 · Codex US$12.10）、今天 US$49.30`, r.week.includes('US$49.30') && r.week.includes('Claude US$37.20') && r.week.includes('Codex US$12.10') && r.today.includes('US$49.30'), JSON.stringify(r));
    check(`Token 估算/${vp.tag}：帶日期／[1m] 的名稱對到單價、未知模型標「沒有單價」、略過計數有寫出、無水平捲動`,
      errors.length === 0 && r.rows.some(x => x.startsWith('gpt-6.1-sol-2026-09-01') && x.endsWith('US$1.00')) && r.rows.some(x => x.startsWith('claude-haiku-5-5[1m]') && x.endsWith('US$0.00'))
        && r.rows.some(x => x.startsWith('mystery-model') && x.endsWith('沒有單價')) && r.note.includes('mystery-model') && r.note.includes('codex_lines 2') && !r.hscroll, JSON.stringify({ errors, r }));
    if (SHOTS) await page.locator('#tokens-card').screenshot({ path: `${SHOTS}/tokens-${vp.tag}.png` });
    await page.close();
  }
}

// --- 點數消耗速度：沒有紀錄／加值後重算（到期會剩）／餘額沒減少／最後更新太久 ---
{
  const now = Math.floor(Date.now() / 1000), D = 86400, iso = t => new Date(t * 1000).toISOString();
  const snap = await (await fetch(`${base}/${names[0]}/data/snapshot.json`)).json();
  const cr = (p, left, expD, log) => ({ provider: p, usd_left: left, usd_total: 100, expires: iso(now + expD * D), log: log.map(([ago, v]) => [now - ago * D, v]) });
  snap.credits = [cr('claude', 50, 40, []), cr('codex', 96, 30, [[10, 50], [6, 40], [5, 100], [1, 96]]), cr('openai', 20, 50, [[3, 20], [1, 20]]), cr('gemini', 26, 60, [[9, 30], [5, 26]]),
    { ...cr('claude-usage', 31.66, 0, []), kind: 'usage', expires: null }, { ...cr('extra-usage', 20, 0, [[6, 20], [2, 20]]), kind: 'usage', expires: null }];
  const { page, errors } = await open(`${base}/${names[0]}/`, VIEWPORTS[1], page => page.route('**/data/snapshot.json', rt => rt.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(snap) })));
  const r = await page.evaluate(() => [...document.querySelectorAll('#reserves .res-row[data-kind="credit"]')].map(e => ({ label: e.querySelector('.tag').textContent, level: e.querySelector('.credit-burn')?.dataset.level, text: e.querySelector('.credit-burn')?.textContent || '' })));
  const by = Object.fromEntries(r.map(x => [x.label.match(/US\$(\d+)/)[1], x]));   // 沒寫 kind 的舊資料當雲端工作階段點數，照樣上時間軸
  check('點數速度：沒有紀錄 → 教怎麼用 quota-reserve.sh credit 記錄', by['50']?.level === 'none' && by['50'].text.includes('quota-reserve.sh credit claude'), JSON.stringify(by['50']));
  check('點數速度：加值前的紀錄不算 → 近 4 天每天 US$1.00、到期約剩 US$65.00', by['96']?.level === 'waste' && /近 4 天平均每天 US\$1\.00，照這速度到期時約剩 US\$6[45]\.\d\d/.test(by['96'].text), JSON.stringify(by['96']));
  check('點數速度：餘額沒減少', by['20']?.level === 'ok' && by['20'].text.includes('沒有減少'), JSON.stringify(by['20']));
  check('點數速度：最後更新 5 天前要註明', by['26']?.text.includes('最後一次更新是 5 天前') && errors.length === 0, JSON.stringify({ errors, x: by['26'] }));
  const u = await page.evaluate(() => Object.fromEntries([...document.querySelectorAll('#reserves .usage-row')].map(e => [e.dataset.p, e.querySelector('.credit-burn').textContent])));
  check('使用量額度：沒有紀錄 → 教怎麼記；沒有扣款 → 沒有超出方案上限', u['claude-usage']?.includes('quota-reserve.sh credit claude-usage') && u['extra-usage']?.includes('近 4 天沒有扣款（沒有超出方案上限）'), JSON.stringify(u));
  check('點數速度：沒寫 kind 的舊資料都當雲端工作階段點數', r.length === 4 && r.every(x => x.label.startsWith('雲端工作階段點數')), JSON.stringify(r.map(x => x.label)));
  await page.close();
}

// --- 用卷效果：換掉 snapshot 的卷並注入歷史，涵蓋 時機好（建議後 5 小時才用）／偏早（沒建議就用）／過期沒用（期間有建議）／超出歷史 ---
{
  const now = Math.floor(Date.now() / 1000), D = 86400, H = 3600, iso = t => new Date(t * 1000).toISOString();
  const usedA = now - 2 * D, usedB = now - D, expC = now - D + 1800, rows = [];
  for (let t = now - 10 * D; t <= now; t += 1800) {
    const card = t >= usedA - 5 * H && t < usedA ? 'claude:use' : t >= expC - 6 * H && t <= expC ? 'claude:expiring' : '-';
    rows.push({ t, mode: 1, ct: 'rich', xt: 'rich', hub: 'opus', override: '-', card, c5: 10, x5: 10, cs: 0, xs: 0,
      c7: t < usedA - 6 * H ? 50 : t < usedA ? 94 : 3, x7: t < usedB ? 40 : 2 });
  }
  const snap = await (await fetch(`${base}/${names[0]}/data/snapshot.json`)).json();
  snap.cards = [{ provider: 'claude', expires: iso(now + 5 * D), used_at: iso(usedA) }, { provider: 'codex', expires: iso(now + 10 * D), used_at: iso(usedB) },
    { provider: 'claude', expires: iso(expC), used_at: null }, { provider: 'codex', expires: iso(now + 3 * D), used_at: iso(now - 20 * D) }];
  const body = rows.map(r => JSON.stringify(r)).join('\n') + '\n';
  const { page, errors } = await open(`${base}/${names[0]}/`, VIEWPORTS[1], async page => {
    await page.route('**/data/history.jsonl', rt => rt.fulfill({ status: 200, contentType: 'text/plain', body }));
    await page.route('**/data/snapshot.json', rt => rt.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(snap) }));
  });
  const r = await page.evaluate(() => ({ sum: document.querySelector('#card-effect .ce-sum')?.textContent || '',
    items: Object.fromEntries([...document.querySelectorAll('#card-effect li')].map(e => [e.dataset.tag, e.textContent])),
    hscroll: document.documentElement.scrollWidth > document.documentElement.clientWidth }));
  const it = r.items;
  check('用卷效果：時機好＝用時週剩 6%、回補 91%、建議後 5 小時才用', /用時週剩 6%，回補 91%/.test(it.good || '') && /建議出現後 5 小時才用/.test(it.good), JSON.stringify(it.good));
  check('用卷效果：偏早＝週剩 60% 就用、回補 38%、沒有建議', /用時週剩 60%，回補 38%/.test(it.early || '') && /週還剩 60% 就用/.test(it.early) && it.early.includes('沒有用卷建議'), JSON.stringify(it.early));
  check('用卷效果：過期沒用＝浪費一張、只算上次用卷後的 13 筆建議', /到期沒用：浪費一張/.test(it.wasted || '') && /到期前有 13 筆用卷建議/.test(it.wasted), JSON.stringify(it.wasted));
  check('用卷效果：超出歷史＝無法評估', /超出 14 天歷史/.test(it.old || ''), JSON.stringify(it.old));
  check('用卷效果：摘要計數＋無 JS error／水平捲動', errors.length === 0 && !r.hscroll && ['時機好 1', '偏早 1', '無法評估 1', '過期沒用 1 張'].every(x => r.sum.includes(x)), JSON.stringify({ errors, sum: r.sum }));
  if (SHOTS) await page.locator('#res-card').screenshot({ path: `${SHOTS}/card-effect-mobile.png` });
  await page.close();
}

// --- 規則穩定度與 bin/analyze.py 一致：tests/fixtures/history 的假歷史平移到「現在」、只留最近 6.9 天，網頁與 analyze.py --json 各算一次（都用 UTC 日界）---
{
  const root = new URL('../..', import.meta.url).pathname, tmp = mkdtempSync(`${tmpdir()}/qp-stab-`);
  for (const [hn, wantLevel, pair] of [['flapping', 'warn', 'Claude 正常↔吃緊'], ['stable-rich', 'ok', null]]) {
    const src = readFileSync(`${root}tests/fixtures/history/${hn}.jsonl`, 'utf8').split('\n').filter(Boolean).map(l => JSON.parse(l));
    const now = Math.floor(Date.now() / 1000), shift = now - 60 - src[src.length - 1].t;
    const rows = src.map(r => ({ ...r, t: r.t + shift })).filter(r => r.t >= now - 6.9 * 86400);
    const body = rows.map(r => JSON.stringify(r)).join('\n') + '\n', f = `${tmp}/${hn}.jsonl`;
    writeFileSync(f, body);
    const a = JSON.parse(execFileSync('python3', ['-I', `${root}bin/analyze.py`, '--json', f], { env: { ...process.env, TZ: 'UTC' } }).toString()).switches;
    const { page, errors } = await open(`${base}/${names[0]}/`, VIEWPORTS[0], page => page.route('**/data/history.jsonl', rt => rt.fulfill({ status: 200, contentType: 'text/plain', body })), { timezoneId: 'UTC' });
    const r = await page.evaluate(() => { const b = document.querySelector('#stability .stab'), v = document.querySelector('#stability .stab-verdict');
      return { max: +b.dataset.max, flaps: +b.dataset.flaps, hub: +b.dataset.hub, level: v.dataset.level, text: v.textContent }; });
    check(`規則穩定度/${hn}：單日最多 ${a.max_per_day}、來回 ${a.flaps}、主控單日 ${a.hub_max_per_day}（同 analyze.py）→ ${wantLevel}`,
      errors.length === 0 && r.max === a.max_per_day && r.flaps === a.flaps && r.hub === a.hub_max_per_day && r.level === wantLevel && (!pair || r.text.includes(pair)),
      JSON.stringify({ errors, page: r, analyze: { max: a.max_per_day, flaps: a.flaps, hub: a.hub_max_per_day } }));
    if (SHOTS) await page.locator('#stability').screenshot({ path: `${SHOTS}/stability-${hn}.png` });
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

// --- 上週期結算：注入歷史，Claude 自然結束只剩 2%（見底，最後讀數離結束 8 小時）、Codex 提前重置（不算浪費）---
{
  const now = Math.floor(Date.now() / 1000), D = 86400, WEEK = 7 * D, E = now - D, X = now - 1.5 * D, due = now + 2 * D, rows = [];
  for (let t = now - 3 * D; t <= now; t += 1800) {
    const ce = t < E ? 100 - 100 * (E - t) / WEEK : 100 * (t - E) / WEEK, cu = t < E ? 98 : ce;
    const xe = t < X ? 100 - 100 * (due - t) / WEEK : 100 * (t - X) / WEEK, xu = t < X ? 50 : xe / 2;
    const skipC = t < E && t > E - 8 * 3600;
    rows.push({ t, mode: 6, ct: 'ok', xt: 'ok', override: '-', card: '-', c5: 10, x5: 10, x7: xu, xs: xe - xu, ...(skipC ? { c7: null, cs: null } : { c7: cu, cs: ce - cu }) });
  }
  const body = rows.map(r => JSON.stringify(r)).join('\n') + '\n';
  const { page, errors } = await open(`${base}/${names[0]}/`, VIEWPORTS[0], page => page.route('**/data/history.jsonl', rt => rt.fulfill({ status: 200, contentType: 'text/plain', body })));
  const lc = await page.evaluate(() => [...document.querySelectorAll('#providers .last-cycle')].map(e => ({ tag: e.dataset.tag, text: e.textContent })));
  check('上週期結算：自然結束剩 2% → 見底＋讀數間隔註記', errors.length === 0 && lc[0]?.tag === 'empty' && /剩 2%：見底/.test(lc[0].text) && /離結束 8 小時/.test(lc[0].text), JSON.stringify({ errors, lc }));
  check('上週期結算：提前重置 → 不算浪費', lc[1]?.tag === 'early' && lc[1].text.includes('提前重置'), JSON.stringify(lc));
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
