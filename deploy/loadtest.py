#!/usr/bin/env python3
"""Нагрузочная проверка FamCoin.

Создаёт N тестовых пользователей с историей операций и проигрывает три
сценария: «утренний наплыв» (все открывают приложение), «активный день»
(траты и обновления вперемешку) и «шторм входов» (bcrypt нагружает базу
параллельно с обычными запросами). В конце печатает задержки и ошибки.

Запускать ТОЛЬКО на локальном стенде или стейджинге — тест создаёт аккаунты
(в конце удаляет). Против чужого адреса не пойдёт без --allow-remote.

  python3 deploy/loadtest.py --base http://localhost:8080 --users 1000
"""
import argparse
import http.client
import json
import random
import statistics
import sys
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import date, timedelta
from urllib.parse import urlparse

CATEGORIES = ['food', 'cafe', 'taxi', 'shop', 'home', 'health', 'fun']
_local = threading.local()
_lock = threading.Lock()
samples = {}   # операция -> [мс]
errors = {}    # (операция, статус) -> число


def conn(base):
    u = urlparse(base)
    c = getattr(_local, 'c', None)
    if c is None:
        c = _local.c = (http.client.HTTPSConnection if u.scheme == 'https' else http.client.HTTPConnection)(u.netloc, timeout=120)
    return c


def call(base, name, method, path, body=None, token=None):
    headers = {'content-type': 'application/json'}
    if token:
        headers['authorization'] = 'Bearer ' + token
    payload = None if body is None else json.dumps(body)
    t0 = time.perf_counter()
    status, data = 0, {}
    for attempt in (1, 2):
        try:
            c = conn(base)
            c.request(method, path, body=payload, headers=headers)
            r = c.getresponse()
            raw = r.read()
            status = r.status
            data = json.loads(raw) if raw else {}
            break
        except Exception:
            _local.c = None            # оборванное соединение — откроем заново
            status = 0
            if attempt == 2:
                break
    ms = (time.perf_counter() - t0) * 1000
    with _lock:
        samples.setdefault(name, []).append(ms)
        if status not in (200, 201):
            errors[(name, status)] = errors.get((name, status), 0) + 1
    return status, data


def day(offset):
    return (date.today() - timedelta(days=offset)).isoformat()


def history(uid, n, salt=''):
    """n трат за последние ~90 дней и пара доходов."""
    cmds = [{'type': 'income', 'id': f'i{salt}-{uid}-{k}', 'date': day(k * 30 + 2), 'account': 'cash', 'source': 'salary', 'amount': '50000000'} for k in range(3)]
    for k in range(n):
        cmds.append({'type': 'expense', 'id': f'e{salt}-{uid}-{k}', 'date': day(random.randint(0, 89)), 'account': 'cash',
                     'splits': {random.choice(CATEGORIES): str(random.randint(5, 400) * 1000)}})
    return cmds


def seed_user(base, i, run, hist):
    email = f'load-{run}-{i}@example.com'
    st, r = call(base, 'register', 'POST', '/auth/register', {'email': email, 'password': 'Load-test-12345', 'locale': 'ru'})
    if st != 201:
        return None
    tok = r['token']
    def cmd(c):
        return call(base, 'command', 'POST', '/command', {'commandId': uuid.uuid4().hex, **c}, tok)
    cmd({'type': 'addMoneyAccount', 'accountId': 'cash'})
    cmd({'type': 'opening', 'id': 'op', 'date': day(95), 'account': 'cash', 'amount': '20000000'})
    cmds = history(i, hist)
    for k in range(0, len(cmds), 200):
        cmd({'type': 'batch', 'commands': cmds[k:k + 200]})
    return {'i': i, 'email': email, 'token': tok}


def seed_heavy(base, i, run, total):
    email = f'load-{run}-heavy{i}@example.com'
    st, r = call(base, 'register', 'POST', '/auth/register', {'email': email, 'password': 'Load-test-12345', 'locale': 'ru'})
    tok = r['token']
    def cmd(c):
        return call(base, 'command', 'POST', '/command', {'commandId': uuid.uuid4().hex, **c}, tok)
    cmd({'type': 'addMoneyAccount', 'accountId': 'cash'})
    cmd({'type': 'opening', 'id': 'op', 'date': day(800), 'account': 'cash', 'amount': '900000000'})
    cmds = [{'type': 'expense', 'id': f'h{i}-{k}', 'date': day(random.randint(0, 720)), 'account': 'cash',
             'splits': {random.choice(CATEGORIES): str(random.randint(5, 400) * 1000)}} for k in range(total)]
    for k in range(0, len(cmds), 200):
        cmd({'type': 'batch', 'commands': cmds[k:k + 200]})
    return {'i': f'heavy{i}', 'email': email, 'token': tok}


def pool(workers, fn, items):
    with ThreadPoolExecutor(max_workers=workers) as ex:
        return list(ex.map(fn, items))


def report(title, names, wall=None):
    print(f'\n== {title}' + (f'  ({wall:.1f} с)' if wall else ''))
    print(f'{"операция":<16}{"запросов":>9}{"ошибок":>8}{"p50":>8}{"p95":>8}{"p99":>8}{"макс":>8}   мс')
    for n in names:
        v = sorted(samples.get(n, []))
        if not v:
            continue
        err = sum(c for (k, _), c in errors.items() if k == n)
        q = lambda p: v[min(len(v) - 1, int(len(v) * p))]
        print(f'{n:<16}{len(v):>9}{err:>8}{q(0.5):>8.0f}{q(0.95):>8.0f}{q(0.99):>8.0f}{v[-1]:>8.0f}')


# Пороги для --check (мс, p95). Мягкие: рассчитаны на слабую машину CI, ловят
# только провалы вроде «пачка входов замораживает всё приложение».
LIMITS = {'state': 1500, 'command': 1500, 'state (фон)': 4000}
problems = []


def verify(names, expected_errors=()):
    for n in names:
        v = sorted(samples.get(n, []))
        if not v:
            continue
        bad = sum(c for (k, st), c in errors.items() if k == n and st not in expected_errors)
        if bad:
            problems.append(f'{n}: неожиданных ошибок {bad}')
        p95 = v[min(len(v) - 1, int(len(v) * 0.95))]
        if n in LIMITS and p95 > LIMITS[n]:
            problems.append(f'{n}: p95 {p95:.0f} мс при пороге {LIMITS[n]} мс')


def reset_samples():
    with _lock:
        samples.clear()
        errors.clear()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--base', default='http://localhost:8080')
    ap.add_argument('--users', type=int, default=1000)
    ap.add_argument('--history', type=int, default=60, help='трат на пользователя')
    ap.add_argument('--heavy', type=int, default=5, help='«тяжёлых» пользователей')
    ap.add_argument('--heavy-tx', type=int, default=5000)
    ap.add_argument('--workers', type=int, default=100)
    ap.add_argument('--keep', action='store_true', help='не удалять тестовых пользователей')
    ap.add_argument('--allow-remote', action='store_true')
    ap.add_argument('--check', action='store_true', help='вернуть код 1, если есть неожиданные ошибки или медленные ответы')
    a = ap.parse_args()

    host = urlparse(a.base).hostname or ''
    if host not in ('localhost', '127.0.0.1', '::1') and not host.endswith('.localhost') and not a.allow_remote:
        sys.exit(f'{host}: не локальный адрес. Тест создаёт аккаунты — добавьте --allow-remote, если это стейджинг.')

    run = uuid.uuid4().hex[:6]
    users, heavy = [], []
    try:
        t0 = time.time()
        users = [u for u in pool(16, lambda i: seed_user(a.base, i, run, a.history), range(a.users)) if u]
        heavy = pool(4, lambda i: seed_heavy(a.base, i, run, a.heavy_tx), range(a.heavy))
        print(f'создано пользователей: {len(users)} + {len(heavy)} тяжёлых ({a.heavy_tx} операций), {time.time() - t0:.0f} с')
        report('заполнение', ['register', 'command'], time.time() - t0)

        # Размер ответа /state у тяжёлого пользователя
        c = conn(a.base)
        c.request('GET', '/state', headers={'authorization': 'Bearer ' + heavy[0]['token'], 'accept-encoding': 'identity'})
        raw = c.getresponse().read()
        print(f'\n/state тяжёлого пользователя ({a.heavy_tx} операций): {len(raw) / 1024 / 1024:.2f} МБ без сжатия')

        # 1. Утренний наплыв: все открывают приложение
        reset_samples()
        t0 = time.time()
        pool(a.workers, lambda u: call(a.base, 'state', 'GET', '/state', token=u['token']), users)
        report(f'утренний наплыв: {len(users)} открытий приложения, {a.workers} параллельно', ['state'], time.time() - t0)
        verify(['state'])

        # Тяжёлые пользователи параллельно с обычными
        reset_samples()
        t0 = time.time()
        pool(a.workers, lambda u: call(a.base, 'state-heavy' if str(u['i']).startswith('heavy') else 'state', 'GET', '/state', token=u['token']), users + heavy * 10)
        report('то же + тяжёлые пользователи (×10)', ['state', 'state-heavy'], time.time() - t0)

        # 2. Активный день: у каждого 3 траты и 2 обновления вперемешку
        reset_samples()
        def active(u):
            time.sleep(random.random() * 20)
            call(a.base, 'state', 'GET', '/state', token=u['token'])
            for k in range(3):
                call(a.base, 'command', 'POST', '/command', {
                    'commandId': uuid.uuid4().hex, 'type': 'expense', 'id': f'a-{uuid.uuid4().hex[:10]}', 'date': day(0),
                    'account': 'cash', 'splits': {random.choice(CATEGORIES): str(random.randint(5, 300) * 1000)}}, u['token'])
                time.sleep(random.random() * 3)
            call(a.base, 'state', 'GET', '/state', token=u['token'])
        t0 = time.time()
        pool(a.workers, active, users)
        report('активный день: 3 траты + 2 обновления на пользователя', ['state', 'command'], time.time() - t0)
        verify(['state', 'command'])

        # 3. Шторм входов: 100 входов (bcrypt) + обычные запросы
        reset_samples()
        stop = threading.Event()
        def bg():
            while not stop.is_set():
                u = random.choice(users)
                call(a.base, 'state (фон)', 'GET', '/state', token=u['token'])
        threads = [threading.Thread(target=bg) for _ in range(20)]
        [t.start() for t in threads]
        t0 = time.time()
        pool(50, lambda u: call(a.base, 'login', 'POST', '/auth/login', {'email': u['email'], 'password': 'Load-test-12345'}), random.sample(users, min(100, len(users))))
        wall = time.time() - t0
        stop.set()
        [t.join() for t in threads]
        report('шторм входов: 100 входов + 20 потоков обычных запросов', ['login', 'state (фон)'], wall)
        verify(['login', 'state (фон)'], expected_errors=(429, 503))

        # 4. Неверные пароли для несуществующих адресов (нагрузка от злоумышленника)
        reset_samples()
        t0 = time.time()
        pool(50, lambda i: call(a.base, 'login-чужой', 'POST', '/auth/login', {'email': f'nobody{i}@example.com', 'password': 'x' * 12}), range(200))
        report('200 входов по несуществующим адресам', ['login-чужой'], time.time() - t0)
        verify(['login-чужой'], expected_errors=(401, 429, 503))
    finally:
        if not a.keep:
            everyone = users + heavy
            pool(16, lambda u: call(a.base, 'cleanup', 'POST', '/auth/delete', {}, u['token']), everyone)
            print(f'\nтестовые пользователи удалены: {len(everyone)}')
    if a.check:
        print('\nПРОВЕРКА:', 'пройдена' if not problems else '; '.join(problems))
        sys.exit(1 if problems else 0)


if __name__ == '__main__':
    main()
