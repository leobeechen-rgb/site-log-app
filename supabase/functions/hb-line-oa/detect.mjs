// 判斷 LINE 訊息是不是「客人說已經付款了」，並盡量抓出金額。
// 寧可多抓（設計師可以按「忽略」），但排除明顯是在「問」怎麼付款的訊息。
const PAID = /(匯款|轉帳|匯出|轉出|匯過去|轉過去|匯好|轉好|匯了|轉了|已付|付清|付款了|已繳|繳清|入帳|查收|收款|款項|已經付|已支付|ATM)/i;
const ASKING = /(帳號|帳戶|戶名|怎麼|如何|哪裡|哪個|要匯|要轉|可以匯|可以轉|請問.*(匯|轉|付)|多少錢|報價)/;
const DONE = /(已|有|剛|先|好了|了|查收|入帳|確認|麻煩|附上|截圖)/;

export function isPaymentText(text) {
  const t = String(text || '').replace(/\s+/g, '');
  if (!t || t.length > 500 || !PAID.test(t)) return false;
  if (ASKING.test(t) && !/(已匯|已轉|已付|匯好|轉好|匯了|轉了|查收)/.test(t)) return false;
  return DONE.test(t);
}

export function parseAmount(text) {
  const t = String(text || '').replace(/[，]/g, ',').replace(/\s+/g, '');
  // 1萬8、1.8萬、18萬
  let m = t.match(/(\d+(?:\.\d+)?)萬(\d)?(?:千)?/);
  if (m) { const v = Math.round(parseFloat(m[1]) * 10000 + (m[2] ? Number(m[2]) * 1000 : 0)); if (v >= 100) return v; }
  const cands = [];
  // 金額旁有 $、NT、元、塊 或千分位逗號才算，避免抓到門牌、樓層、電話、日期
  const re = /(NT\$?|\$|新台幣)?(\d{1,3}(?:,\d{3})+|\d{3,8})(元|塊|整)?/gi;
  for (const x of t.matchAll(re)) {
    const raw = x[2], v = Number(raw.replace(/,/g, ''));
    const strong = !!(x[1] || x[3] || raw.includes(','));
    const before = t.slice(Math.max(0, x.index - 1), x.index), after = t.slice(x.index + x[0].length, x.index + x[0].length + 1);
    if (/[號樓F年月日點時分\-\/:：]/.test(after) || /[\-\/:]/.test(before)) continue;
    if (/^0/.test(raw) || v < 100) continue;
    if (!x[1] && /(碼|帳號|號碼|編號|單號|電話|手機)$/.test(t.slice(Math.max(0, x.index - 6), x.index))) continue;
    if (strong || (v >= 1000 && v <= 9999999)) cands.push({ v, strong });
  }
  const s = cands.find(c => c.strong) || cands[0];
  return s ? s.v : null;
}

// 客人回報施工問題（漏水、裂縫、壞掉…）。問句、閒聊、感謝不算。
const DEFECT = /(漏水|滲水|積水|壁癌|發霉|裂|破掉|破了|破損|壞了|壞掉|故障|掉漆|脫落|剝落|起泡|不亮|跳電|沒電|關不起來|關不上|關不緊|打不開|卡住|異音|有聲音|歪|傾斜|刮傷|刮痕|凹痕|凹陷|堵塞|不通|排不掉|鬆動|搖晃|鬆掉|縫隙|色差|髒污|沒有做|沒做好|不平|翹起|變形)/;
const NOT_DEFECT = /(謝謝|辛苦|好的|收到|OK|ok|沒問題|已修好|修好了|處理好了|沒事了)$/;
export function isDefectText(text) {
  const t = String(text || '').replace(/\s+/g, '');
  if (t.length < 4 || t.length > 500 || !DEFECT.test(t)) return false;
  if (NOT_DEFECT.test(t) && t.length < 12) return false;
  return true;
}
// 「綁定 案件名稱」
export function bindQuery(text) {
  const m = String(text || '').trim().match(/^(?:綁定|绑定)(?:案件)?[\s:：]*(.+)$/);
  return m ? m[1].trim() : null;
}

// 群組裡提到的約定：「週六下午 3 點去看現場」「明天 10:30 丈量」「10/18 進場」
// now 傳台灣時間的 Date（以 UTC 欄位表示台灣當地時間）。回傳 { date:'YYYY-MM-DD', time:'HH:MM'|'' } 或 null
const ACT = /(看現場|現場看|丈量|會勘|勘查|見面|碰面|討論|開會|過去|過來|來看|到現場|驗收|交屋|進場|施工|簽約|看圖|看樣|選材|挑材料|約|拜訪|到府|到工地|集合)/;
const WD = { 日: 0, 天: 0, 一: 1, 二: 2, 三: 3, 四: 4, 五: 5, 六: 6 };
const CN = { 零: 0, 〇: 0, 一: 1, 兩: 2, 二: 2, 三: 3, 四: 4, 五: 5, 六: 6, 七: 7, 八: 8, 九: 9, 十: 10 };
function cnNum(s) {
  if (/^\d+$/.test(s)) return Number(s);
  if (s === '十') return 10;
  if (s.startsWith('十')) return 10 + (CN[s[1]] ?? 0);
  if (s.endsWith('十')) return (CN[s[0]] ?? 0) * 10;
  if (s.includes('十')) return (CN[s[0]] ?? 0) * 10 + (CN[s[2]] ?? 0);
  return CN[s] ?? NaN;
}
const pad = n => String(n).padStart(2, '0');
const ymd = d => d.getUTCFullYear() + '-' + pad(d.getUTCMonth() + 1) + '-' + pad(d.getUTCDate());
export function parseAppt(text, now) {
  const t = String(text || '').replace(/\s+/g, '').replace(/：/g, ':');
  if (t.length < 4 || t.length > 300) return null;
  if (/(已匯|匯款|轉帳|謝謝|收到$)/.test(t) && t.length < 8) return null;
  const base = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
  const add = n => new Date(base.getTime() + n * 86400000);
  let d = null, m;
  if ((m = t.match(/大後天/))) d = add(3);
  else if ((m = t.match(/後天/))) d = add(2);
  else if ((m = t.match(/明天|明日/))) d = add(1);
  else if ((m = t.match(/今天|今日|今晚/))) d = add(0);
  else if ((m = t.match(/(下下|下個?|這個?|本)?(?:週|周|星期|禮拜|拜)([一二三四五六日天])/))) {
    const want = WD[m[2]], cur = base.getUTCDay();
    let diff = (want - cur + 7) % 7;
    const pre = m[1] || '';
    if (/^下下/.test(pre)) diff = ((want === 0 ? 7 : want) - (cur === 0 ? 7 : cur)) + 14;
    else if (/^下/.test(pre)) diff = ((want === 0 ? 7 : want) - (cur === 0 ? 7 : cur)) + 7;
    else if (diff === 0 && !/^(這|本)/.test(pre)) diff = 0;
    d = add(diff);
  } else if ((m = t.match(/(?<![\d.\/])(\d{1,2})[\/月](\d{1,2})(?:日|號)?(?![\d\/])/))) {
    const mo = Number(m[1]), da = Number(m[2]);
    if (mo >= 1 && mo <= 12 && da >= 1 && da <= 31) {
      let y = base.getUTCFullYear();
      let c = new Date(Date.UTC(y, mo - 1, da));
      if (c.getTime() < base.getTime() - 30 * 86400000) c = new Date(Date.UTC(y + 1, mo - 1, da));
      d = c;
    }
  } else if ((m = t.match(/(?<![\d月\/])(\d{1,2}|[一二三四五六七八九十]{1,3})(?:日|號)(?!碼)/))) {
    const da = cnNum(m[1]);
    if (da >= 1 && da <= 31) {
      let c = new Date(Date.UTC(base.getUTCFullYear(), base.getUTCMonth(), da));
      if (c.getTime() < base.getTime()) c = new Date(Date.UTC(base.getUTCFullYear(), base.getUTCMonth() + 1, da));
      d = c;
    }
  }
  if (!d) return null;
  // 時間
  let time = '', tm;
  if ((tm = t.match(/(?<!\d)([01]?\d|2[0-3]):([0-5]\d)(?!\d)/))) {
    let h = Number(tm[1]);
    if (h < 12 && /(下午|晚上|傍晚)/.test(t)) h += 12;
    time = pad(h) + ':' + tm[2];
  } else if ((tm = t.match(/(早上|上午|中午|下午|晚上|傍晚)?(\d{1,2}|[一二三四五六七八九十兩]{1,3})(?:點|時)(半|(\d{1,2}|[一二三四五六七八九十]{1,3})分?)?/))) {
    let h = cnNum(tm[2]);
    if (!isNaN(h) && h >= 0 && h <= 23) {
      const ap = tm[1] || '';
      if (/(下午|晚上|傍晚)/.test(ap) && h < 12) h += 12;
      else if (ap === '中午' && h < 6) h += 12;
      else if (!ap && h >= 1 && h <= 6) h += 12; // 「3點」多半是下午
      const mi = tm[3] === '半' ? 30 : tm[4] ? cnNum(tm[4]) : 0;
      if (!isNaN(mi) && mi < 60) time = pad(h) + ':' + pad(mi);
    }
  }
  // 要有時間或「做什麼」的字，才算約定（避免「明天下雨」這種）
  if (!time && !ACT.test(t)) return null;
  return { date: ymd(d), time };
}
