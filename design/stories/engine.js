// Детерминированная анимация для покадрового рендера: window.seek(t) ставит
// все CSS-анимации и счётчики на момент t (секунды). В браузере без рендера
// (просмотр) — ?play воспроизводит в реальном времени.
(function () {
  const ease = (x) => (x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2);
  const fmt = (n) => Math.round(n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, '\u00a0');

  // Строки со словами: data-in (появление), data-out (уход), data-stagger.
  function splitWords() {
    document.querySelectorAll('[data-words]').forEach((el) => {
      const t0 = parseFloat(el.dataset.in || '0');
      const st = parseFloat(el.dataset.stagger || '0.09');
      // Делим только по обычным пробелам: неразрывный (&nbsp;) держит «1 590 ₸» одним словом.
      const words = el.textContent.trim().split(/[ \t\n]+/);
      const accent = (el.dataset.accent || '').split('|').filter(Boolean);
      el.textContent = '';
      words.forEach((w, i) => {
        const s = document.createElement('span');
        s.className = 'w' + (accent.includes(w.replace(/[.,!?…]/g, '')) ? ' accent' : '');
        s.textContent = w;
        s.style.animationDelay = (t0 + i * st) + 's';
        el.appendChild(s);
        if (i < words.length - 1) el.appendChild(document.createTextNode(' '));
      });
      if (el.dataset.out) {
        el.style.animation = 'lineOut .7s cubic-bezier(.4,0,.2,1) forwards';
        el.style.animationDelay = el.dataset.out + 's';
      }
    });
    // Блоки целиком: data-show="in,out"
    document.querySelectorAll('[data-show]').forEach((el) => {
      const [a, b] = el.dataset.show.split(',').map(parseFloat);
      const anims = [`${el.dataset.anim || 'blockIn'} .9s cubic-bezier(.2,.7,.2,1) ${a}s both`];
      if (!isNaN(b)) anims.push(`blockOut .7s cubic-bezier(.4,0,.2,1) ${b}s forwards`);
      el.style.animation = anims.join(', ');
    });
  }

  // Счётчики: data-keys="t:value,t:value,…", кусочно с плавным переходом.
  function counters(t) {
    document.querySelectorAll('[data-keys]').forEach((el) => {
      const keys = el.dataset.keys.split(',').map((p) => p.split(':').map(parseFloat));
      let v = keys[0][1];
      for (let i = 0; i < keys.length - 1; i++) {
        const [ta, va] = keys[i], [tb, vb] = keys[i + 1];
        if (t >= tb) v = vb;
        else if (t > ta) { v = va + (vb - va) * ease((t - ta) / (tb - ta)); break; }
      }
      el.textContent = (el.dataset.sign && v > 0 ? '+' : '') + fmt(v);
    });
  }

  let ready = false;
  function init() {
    if (ready) return;
    splitWords();
    document.body.getBoundingClientRect();
    ready = true;
  }

  window.seek = function (t) {
    init();
    document.getAnimations().forEach((a) => { a.pause(); a.currentTime = t * 1000; });
    counters(t);
  };

  window.addEventListener('load', () => {
    init();
    if (location.search.includes('play')) {
      const start = performance.now();
      const tick = () => { window.seek((performance.now() - start) / 1000); requestAnimationFrame(tick); };
      tick();
    } else {
      window.seek(parseFloat(new URLSearchParams(location.search).get('t') || '0'));
    }
  });
})();
