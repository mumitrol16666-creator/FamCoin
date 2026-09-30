#!/usr/bin/env python3
"""Проверка устойчивости журнала при параллельных запросах и повторах.

Проверяет на живом API (локальном или стейджинге) то, на чём обычно ломается
учёт денег: двойное нажатие, повторная отправка после обрыва, одновременное
удаление одной операции, гонки правок профиля, некорректные суммы. Создаёт
временного пользователя и удаляет его. Код возврата 0 — всё выдержало.

  python3 deploy/concurrency_check.py [--base http://localhost:8080]
"""
import argparse
import json
import sys
import threading
import urllib.error
import urllib.request
import uuid
from urllib.parse import urlparse

D = '2026-09-30'
failed = []


def call(base, method, path, body=None, token=None):
    req = urllib.request.Request(base + path, method=method, data=None if body is None else json.dumps(body).encode(),
                                 headers={'content-type': 'application/json', **({'authorization': 'Bearer ' + token} if token else {})})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.loads(r.read() or b'{}')
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b'{}')


def par(n, fn):
    out = [None] * n
    def run(i):
        out[i] = fn(i)
    ts = [threading.Thread(target=run, args=(i,)) for i in range(n)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    return out


def check(name, ok, detail=''):
    print(('  ок    ' if ok else '  СБОЙ  ') + name + (f'  [{detail}]' if detail else ''))
    if not ok:
        failed.append(name)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--base', default='http://localhost:8080')
    a = ap.parse_args()
    base = a.base.rstrip('/')
    host = urlparse(base).hostname or ''
    if host not in ('localhost', '127.0.0.1', '::1'):
        sys.exit('Только для локального стенда: тест создаёт пользователя и пишет в базу.')

    st, r = call(base, 'POST', '/auth/register', {'email': f'check-{uuid.uuid4().hex[:8]}@example.com', 'password': 'Check-pass-12345', 'locale': 'ru'})
    tok = r['token']
    cmd = lambda c: call(base, 'POST', '/command', {'commandId': uuid.uuid4().hex, **c}, tok)

    def balance():
        s = call(base, 'GET', '/state', token=tok)[1]
        return sum(int(p['v']) for t in s['transactions'] for p in t['postings'] if p['a'] == 'cash'), s['revision']

    try:
        cmd({'type': 'addMoneyAccount', 'accountId': 'cash'})
        cmd({'type': 'opening', 'id': 'op1', 'date': D, 'account': 'cash', 'amount': '10000000'})
        b0, rev0 = balance()

        print('повторная отправка одной команды (двойное нажатие, обрыв связи)')
        same = {'commandId': 'dup-1', 'type': 'expense', 'id': 'e-dup', 'date': D, 'account': 'cash', 'splits': {'cafe': '100000'}}
        res = par(20, lambda i: call(base, 'POST', '/command', same, tok))
        applied = sum(1 for s, b in res if s == 200 and b.get('repeated') is False)
        repeated = sum(1 for s, b in res if s == 200 and b.get('repeated') is True)
        b1, rev1 = balance()
        check('20 одинаковых команд: применена ровно одна', applied == 1 and repeated == 19, f'применено {applied}, повторов {repeated}')
        check('баланс изменился один раз', b1 - b0 == -100000, f'{b1 - b0}')

        print('параллельные разные команды одного пользователя')
        res = par(30, lambda i: cmd({'type': 'expense', 'id': f'e-par-{i}', 'date': D, 'account': 'cash', 'splits': {'food': '10000'}}))
        b2, rev2 = balance()
        check('30 параллельных трат: все приняты', all(s == 200 for s, _ in res))
        check('ни одна не потеряна и не задвоена', b2 - b1 == -300000 and rev2 - rev1 == 30, f'баланс {b2 - b1}, ревизий +{rev2 - rev1}')

        print('одновременное удаление одной операции')
        res = par(2, lambda i: cmd({'type': 'reverse', 'txId': 'e-dup', 'id': f'rev-{i}', 'date': D}))
        codes = sorted(s for s, _ in res)
        b3, _ = balance()
        check('одно удаление принято, второе отклонено', codes == [200, 422], f'{codes}')
        check('баланс вернулся ровно один раз', b3 - b2 == 100000, f'{b3 - b2}')

        print('параллельные правки разных полей профиля')
        keys = {'firstName': 'Аня', 'lastName': 'Тест', 'birthDate': '1990-01-01', 'dailyLimit': '500000'}
        res = par(len(keys), lambda i: cmd({'type': 'updateProfile', 'profile': {list(keys)[i]: list(keys.values())[i]}}))
        prof = call(base, 'GET', '/state', token=tok)[1]['profile']
        check('все правки сохранились', all(s == 200 for s, _ in res) and all(prof.get(k) == v for k, v in keys.items()))

        print('некорректные данные не меняют баланс')
        s, _ = cmd({'type': 'expense', 'id': 'neg', 'date': D, 'account': 'cash', 'splits': {'cafe': '-500000'}})
        b4, _ = balance()
        check('расход с отрицательной суммой отклонён', s == 422 and b4 == b3, f'статус {s}')
        s, _ = cmd({'type': 'expense', 'id': 'nofield', 'date': D, 'splits': {'cafe': '1000'}})
        check('команда без счёта отклонена', s in (400, 422), f'статус {s}')
    finally:
        call(base, 'POST', '/auth/delete', {}, tok)

    print('\nитог:', 'всё выдержало' if not failed else f'сбоев: {len(failed)}')
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
