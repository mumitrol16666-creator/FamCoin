/// Страница админки: один HTML, работает с /api/admin/* через fetch.
library;

const adminHtml = r'''<!DOCTYPE html>
<html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>FamCoin · админка</title>
<style>
:root{--bg:#F5F3EE;--card:#fff;--text:#1A1D21;--muted:#58645F;--primary:#1F5E4F;--line:#E3DFD6;--warn:#B7791F;--bad:#AA402C;--ok:#226A44}
@media(prefers-color-scheme:dark){:root{--bg:#12151A;--card:#1B2028;--text:#ECEEF1;--muted:#A8B3AD;--primary:#4FB39A;--line:#2C333E;--warn:#F0B955;--bad:#FF9789;--ok:#70D7A1}}
*{box-sizing:border-box}body{margin:0;font:14px/1.45 system-ui,sans-serif;background:var(--bg);color:var(--text)}
header{display:flex;align-items:center;gap:16px;padding:14px 20px;border-bottom:1px solid var(--line);background:var(--card)}
header h1{font-size:18px;margin:0}header nav button{background:none;border:0;color:var(--muted);font:inherit;padding:6px 10px;cursor:pointer;border-radius:8px}
header nav button.on{color:var(--primary);font-weight:600;background:var(--bg)}
main{max-width:1100px;margin:0 auto;padding:20px}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:16px;margin-bottom:14px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px}
.kpi b{display:block;font-size:24px}.kpi span{color:var(--muted);font-size:12px}
table{width:100%;border-collapse:collapse;font-size:13px}th,td{padding:8px 6px;text-align:left;border-bottom:1px solid var(--line);vertical-align:top}th{color:var(--muted);font-weight:600}
input{font:inherit;padding:9px 12px;border:1px solid var(--line);border-radius:10px;background:var(--bg);color:var(--text);width:100%}
button.b{font:inherit;padding:7px 12px;border:1px solid var(--line);border-radius:10px;background:var(--card);color:var(--text);cursor:pointer;margin:2px}
button.b.p{background:var(--primary);color:#fff;border-color:var(--primary)}button.b.d{color:var(--bad)}
.tag{display:inline-block;padding:1px 8px;border-radius:999px;font-size:11px;font-weight:700}.tag.pro{background:#E0A43A;color:#1A1D21}.tag.bad{background:var(--bad);color:#fff}.tag.ok{background:var(--ok);color:#fff}
.muted{color:var(--muted)}.bars{display:flex;gap:3px;align-items:flex-end;height:80px}.bars div{flex:1;background:var(--primary);border-radius:3px 3px 0 0;min-height:2px}
#login{max-width:360px;margin:80px auto}#toast{position:fixed;bottom:20px;left:50%;transform:translateX(-50%);background:var(--text);color:var(--bg);padding:10px 16px;border-radius:10px;display:none}
</style></head><body>
<header><h1>FamCoin · админка</h1><nav id="nav" hidden><button data-v="stats" class="on">Сводка</button><button data-v="users">Пользователи</button><button data-v="payments">Платежи</button><button data-v="audit">Журнал</button><button id="logout">Выйти</button></nav></header>
<main>
<div id="login" class="card"><h2>Вход</h2><p class="muted">Пароль администратора из .env на сервере.</p><input id="pw" type="password" placeholder="Пароль" autofocus><br><br><button class="b p" id="loginBtn">Войти</button><p id="loginErr" class="muted"></p></div>
<div id="stats" hidden></div>
<div id="users" hidden><div class="card"><input id="q" placeholder="Поиск по email"></div><div class="card" id="usersList"></div></div>
<div id="payments" hidden><div class="card" id="paymentsList"></div></div>
<div id="audit" hidden><div class="card" id="auditList"></div></div>
</main>
<div id="toast"></div>
<script>
const $=s=>document.querySelector(s);let token=sessionStorage.getItem('adm');
const api=async(p,o={})=>{const r=await fetch('/api/admin'+p,{...o,headers:{'content-type':'application/json','authorization':'Bearer '+token,...(o.headers||{})}});const d=await r.json().catch(()=>({}));if(r.status===401&&p!=='/login'){sessionStorage.removeItem('adm');location.reload()}if(!r.ok)throw new Error(d.error||r.status);return d};
const toast=t=>{const e=$('#toast');e.textContent=t;e.style.display='block';setTimeout(()=>e.style.display='none',3500)};
const fmt=d=>d?new Date(d).toLocaleString('ru-RU',{dateStyle:'short',timeStyle:'short'}):'—';
async function show(v){document.querySelectorAll('#nav button[data-v]').forEach(b=>b.classList.toggle('on',b.dataset.v===v));for(const s of['stats','users','payments','audit'])$('#'+s).hidden=s!==v;if(v==='stats')await stats();if(v==='users')await users();if(v==='payments')await payments();if(v==='audit')await audit()}
const fmtD=d=>d?new Date(d).toLocaleDateString('ru-RU'):'—';
async function payments(){const l=await api('/payments');$('#paymentsList').innerHTML=l.length?`<table><tr><th>Когда</th><th>Пользователь</th><th>Звёзд</th><th>Срок</th><th>Pro до</th><th>Статус</th><th></th></tr>${l.map(p=>`<tr><td>${fmt(p.createdAt)}</td><td>${p.email}</td><td>${p.stars} ⭐</td><td>${p.days} дн.</td><td>${fmtD(p.proUntil)}</td><td>${p.status==='refunded'?`<span class="tag bad">возврат ${fmtD(p.refundedAt)}</span>`:'<span class="tag ok">оплачен</span>'}</td><td>${p.status==='paid'?`<button class="b d" onclick="refund('${p.id}','${p.email}')">Вернуть звёзды</button>`:''}</td></tr>`).join('')}</table>`:'<p class="muted">Платежей пока не было</p>'}
async function refund(id,email){if(!confirm(`Вернуть звёзды пользователю ${email}? Срок Pro уменьшится на оплаченный период.`))return;try{await api(`/payments/${id}/refund`,{method:'POST',body:'{}'});toast('Возврат выполнен');payments()}catch(e){toast('Ошибка: '+e.message)}}
async function stats(){const s=await api('/stats');const max=Math.max(1,...s.byDay.map(d=>d.commands));$('#stats').innerHTML=`<div class="card grid">
${[['Пользователей',s.users],['Новых за неделю',s.newWeek],['Активных за сутки',s.activeDay],['Pro',s.pro],['Операций всего',s.transactions],['Команд за сутки',s.commandsDay],['Привязан Telegram',s.telegram],['Размер базы',s.dbSize]].map(([k,v])=>`<div class="kpi"><b>${v}</b><span>${k}</span></div>`).join('')}</div>
<div class="card"><b>Активность за 14 дней</b> <span class="muted">(команд в день; регистрации подписаны)</span><div class="bars" style="margin-top:10px">${s.byDay.map(d=>`<div title="${d.date}: команд ${d.commands}, регистраций ${d.signups}" style="height:${Math.round(d.commands/max*100)}%"></div>`).join('')}</div>
<div class="muted" style="display:flex;justify-content:space-between;font-size:11px"><span>${s.byDay[0].date}</span><span>${s.byDay.at(-1).date}</span></div></div>`}
async function users(){const q=$('#q').value;const list=await api('/users?q='+encodeURIComponent(q));$('#usersList').innerHTML=list.length?`<table><tr><th>Email</th><th>Тариф</th><th>Регистрация</th><th>Был</th><th>Операций</th><th>Статус</th><th></th></tr>${list.map(u=>`<tr>
<td>${u.email}<br><span class="muted">${u.locale} · ${u.onboarded?'анкета пройдена':'анкета не пройдена'}${u.telegram?' · TG':''}</span></td>
<td>${u.plan==='pro'?`<span class="tag pro">Pro</span><br><span class="muted">${u.proUntil?'до '+fmtD(u.proUntil):'бессрочно'}</span>`:'обычный'}</td><td>${fmt(u.createdAt)}</td><td>${fmt(u.lastSeenAt)}</td><td>${u.transactions}</td>
<td>${u.locked?'<span class="tag bad">заблокирован</span>':u.failedAttempts?`<span class="muted">ошибок: ${u.failedAttempts}</span>`:'<span class="tag ok">ок</span>'}</td>
<td><button class="b" onclick="act('${u.id}','plan',{plan:'${u.plan==='pro'?'free':'pro'}'})">${u.plan==='pro'?'Снять Pro':'Дать Pro'}</button>${u.locked||u.failedAttempts?`<button class="b" onclick="act('${u.id}','unlock')">Разблокировать</button>`:''}<button class="b" onclick="reset('${u.id}','${u.email}')">Сбросить пароль</button><button class="b d" onclick="del('${u.id}','${u.email}')">Удалить</button></td></tr>`).join('')}</table>`:'<p class="muted">Никого не найдено</p>'}
async function act(id,a,body){try{await api(`/users/${id}/${a}`,{method:'POST',body:JSON.stringify(body||{})});toast('Готово');users()}catch(e){toast('Ошибка: '+e.message)}}
async function reset(id,email){if(!confirm(`Сбросить пароль для ${email}? Все его сессии закроются.`))return;try{const d=await api(`/users/${id}/reset-password`,{method:'POST',body:'{}'});prompt('Временный пароль (показывается один раз):',d.password);users()}catch(e){toast('Ошибка: '+e.message)}}
async function del(id,email){if(prompt(`Удаление необратимо. Введите email для подтверждения:`)!==email)return;try{await api(`/users/${id}/delete`,{method:'POST',body:JSON.stringify({email})});toast('Удалён');users()}catch(e){toast('Ошибка: '+e.message)}}
async function audit(){const l=await api('/audit');$('#auditList').innerHTML=l.length?`<table><tr><th>Когда</th><th>Действие</th><th>Пользователь</th><th>Детали</th></tr>${l.map(a=>`<tr><td>${fmt(a.at)}</td><td>${a.action}</td><td>${a.email||a.target||'—'}</td><td class="muted">${JSON.stringify(a.details)}</td></tr>`).join('')}</table>`:'<p class="muted">Действий пока не было</p>'}
$('#loginBtn').onclick=async()=>{try{const d=await api('/login',{method:'POST',body:JSON.stringify({password:$('#pw').value}),headers:{authorization:''}});token=d.token;sessionStorage.setItem('adm',token);init()}catch(e){$('#loginErr').textContent=e.message==='invalid_credentials'?'Неверный пароль':'Ошибка: '+e.message}};
$('#pw').onkeydown=e=>{if(e.key==='Enter')$('#loginBtn').click()};
$('#logout').onclick=()=>{sessionStorage.removeItem('adm');location.reload()};
$('#q').oninput=()=>{clearTimeout(window._t);window._t=setTimeout(users,300)};
document.querySelectorAll('#nav button[data-v]').forEach(b=>b.onclick=()=>show(b.dataset.v));
function init(){$('#login').hidden=true;$('#nav').hidden=false;show('stats')}
if(token)init();
</script></body></html>''';
