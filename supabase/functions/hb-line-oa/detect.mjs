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
