// site/index.html 冒煙測試：每組情境開一次頁面，確認沒有 JS error、主要區塊都有渲染。
// 用法：node smoke.mjs <base_url> <fixtures 目錄> <情境>...（<base_url>/<情境>/ 是 tests/lib/fixture.py site 產生的目錄）
import { chromium } from 'playwright';
import { readFileSync } from 'node:fs';

const [base, fixDir, ...names] = process.argv.slice(2);
let pass = 0, fail = 0;
const ok = m => { pass++; console.log(`  ✅ ${m}`); };
const ng = (m, why) => { fail++; console.log(`  ❌ ${m}${why ? `\n     ${why}` : ''}`); };
const check = (m, cond, why) => cond ? ok(m) : ng(m, why);

const browser = await chromium.launch();
for (const name of names) {
  const sc = JSON.parse(readFileSync(`${fixDir}/${name}.json`, 'utf8'));
  for (const vp of [{ width: 1200, height: 900, tag: 'desktop' }, { width: 390, height: 844, tag: 'mobile' }]) {
    const page = await browser.newPage({ viewport: { width: vp.width, height: vp.height } });
    const errors = [];
    page.on('pageerror', e => errors.push('pageerror: ' + e.message));
    page.on('console', m => { if (m.type() === 'error') errors.push('console: ' + m.text()); });
    page.on('response', r => { if (r.status() >= 400) errors.push(`HTTP ${r.status()} ${r.url()}`); });
    const t = `${name}/${vp.tag}`;
    await page.goto(`${base}/${name}/`, { waitUntil: 'networkidle' });
    await page.waitForFunction(() => document.getElementById('mode-n').textContent !== '–', null, { timeout: 5000 }).catch(() => {});
    const r = await page.evaluate(() => {
      const q = s => document.querySelectorAll(s);
      return {
        mode: document.getElementById('mode-n').textContent,
        route: document.getElementById('route').textContent,
        stamp: document.getElementById('stamp').className,
        stampText: document.getElementById('stamp').textContent,
        chips: q('#chips .chip').length,
        provCards: q('#providers > .card').length,
        meters: q('#providers [role=meter]').length,
        cells: q('#matrix .cell').length,
        on: [...q('#matrix .cell.on')].map(e => e.querySelector('b').textContent),
        resRows: q('#reserves .res-row').length,
        resEmpty: q('#reserves .empty').length,
        paths: q('#chart svg path').length,
        tableRows: q('#table tr').length,
        alerts: [...q('#alerts .alert')].map(e => e.className + ' ' + e.textContent),
        hscroll: document.documentElement.scrollWidth > document.documentElement.clientWidth,
      };
    });
    const want = sc.expect.mode, providers = ['claude', 'codex'].filter(p => sc[p]).length;
    const cards = (sc.reserves?.cards || []).length + (sc.reserves?.credits || []).length;
    // load() 用 try/catch 把 render 例外寫進 stamp（「讀不到資料：…」），不會觸發 pageerror，要另外檢查
    if (r.stampText.startsWith('讀不到資料')) errors.push('stamp: ' + r.stampText);
    check(`${t}：無 JS error／載入失敗`, errors.length === 0, errors.join(' | '));
    check(`${t}：模式卡 M${want.mode}`, r.mode === 'M' + want.mode && r.route !== '–' && r.chips === 4, JSON.stringify({ mode: r.mode, route: r.route, chips: r.chips }));
    check(`${t}：額度條 ${providers * 2} 條`, r.provCards === 2 && r.meters === providers * 2, JSON.stringify({ provCards: r.provCards, meters: r.meters }));
    check(`${t}：矩陣 12 格、亮 M${want.mode}`, r.cells === 12 && r.on.length === 1 && r.on[0] === 'M' + want.mode, JSON.stringify({ cells: r.cells, on: r.on }));
    check(`${t}：重置卷 ${cards} 列`, cards ? r.resRows === cards : r.resRows === 0 && r.resEmpty === 1, JSON.stringify({ resRows: r.resRows, resEmpty: r.resEmpty }));
    check(`${t}：趨勢圖 ${providers} 條線＋表格`, r.paths === providers && r.tableRows > 1, JSON.stringify({ paths: r.paths, tableRows: r.tableRows }));
    check(`${t}：無水平捲動`, !r.hscroll);
    const stale = (sc.snapshot_age || 0) > 5400;
    check(`${t}：過期警示${stale ? '有' : '無'}`, stale === r.stamp.includes('stale') && stale === r.alerts.some(a => a.includes('crit') && a.includes('未更新')), JSON.stringify({ stamp: r.stamp, alerts: r.alerts }));
    if (want.override !== '-') check(`${t}：覆寫提示`, r.alerts.some(a => a.includes('暫時覆寫')), JSON.stringify(r.alerts));
    if (want.card !== '-') check(`${t}：用卷提示`, r.alerts.some(a => a.includes('重置卷')), JSON.stringify(r.alerts));
    await page.close();
  }
}
await browser.close();
console.log(`pass=${pass} fail=${fail}`);
process.exit(fail ? 1 : 0);
