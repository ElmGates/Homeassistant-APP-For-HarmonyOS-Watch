"""Walks through what the watch app does against a Home Assistant server and writes a report for review.

Logs in the way the app does (login_flow with username and password, then the token exchange), opens the
WebSocket, reads the registries and states, checks which services the app may call exist, and keeps a live
subscription (subscribe_entities, as the app now does while open) for a while to record the pushed changes.
Move a curtain or switch something in the HA web page during that time to see live updates arrive.

Nothing is switched or changed on the server. The login is revoked at the end.

    set HA_URL=https://<your-ha-host>
    python tools/ha_review_check.py            (asks for username and password)
    python tools/ha_review_check.py 60         (listen 60 s instead of 30 s)

The report goes to tools/.ha_review_report.json (git-ignored); it contains entity ids, names and states.
"""
import asyncio
import getpass
import json
import os
import sys
import time

import requests
import websockets

BASE = os.environ.get('HA_URL', '').strip().rstrip('/')
LISTEN_S = int(sys.argv[1]) if len(sys.argv) > 1 else 30
REPORT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '.ha_review_report.json')

# Mirrors HaDirectClient.ALLOWED_SERVICES and the domains the app shows.
ALLOWED_SERVICES = {
    'light': ['turn_on', 'turn_off'],
    'switch': ['turn_on', 'turn_off'],
    'input_boolean': ['turn_on', 'turn_off'],
    'fan': ['turn_on', 'turn_off', 'set_percentage'],
    'humidifier': ['turn_on', 'turn_off'],
    'cover': ['open_cover', 'stop_cover', 'close_cover', 'set_cover_position', 'open_cover_tilt', 'stop_cover_tilt',
              'close_cover_tilt'],
    'climate': ['turn_on', 'turn_off', 'set_temperature', 'set_hvac_mode', 'set_fan_mode', 'set_swing_mode',
                'set_swing_horizontal_mode', 'set_preset_mode'],
    'select': ['select_option'],
    'input_select': ['select_option'],
    'number': ['set_value'],
    'input_number': ['set_value'],
    'scene': ['turn_on'],
    'script': ['turn_on'],
    'automation': ['trigger', 'turn_on', 'turn_off'],
    'button': ['press'],
    'input_button': ['press'],
    'lock': ['lock', 'unlock'],
    'media_player': ['turn_on', 'turn_off', 'media_play', 'media_pause', 'media_next_track',
                     'media_previous_track', 'volume_set'],
    'vacuum': ['start', 'pause', 'return_to_base'],
}
SHOWN = set(ALLOWED_SERVICES) | {'sensor', 'binary_sensor'}


def step(report, name, ok, detail=''):
    report['steps'].append({'step': name, 'ok': ok, 'detail': detail})
    print(('OK   ' if ok else 'FAIL ') + name + (('  — ' + detail) if detail else ''))


def login(report, username, password):
    client_id = BASE + '/'
    t0 = time.time()
    providers = requests.get(BASE + '/auth/providers', timeout=15).json()
    provider = next((p for p in providers.get('providers', []) if p.get('type') == 'homeassistant'), None)
    if not provider:
        step(report, 'auth/providers', False, 'no homeassistant provider')
        return None
    flow = requests.post(BASE + '/auth/login_flow', timeout=15, json={
        'client_id': client_id, 'redirect_uri': client_id, 'handler': ['homeassistant', provider.get('id')]}).json()
    res = requests.post(BASE + '/auth/login_flow/' + flow['flow_id'], timeout=15, json={
        'client_id': client_id, 'username': username, 'password': password}).json()
    if res.get('type') == 'form' and res.get('step_id') == 'mfa':
        code = input('MFA code: ').strip()
        res = requests.post(BASE + '/auth/login_flow/' + flow['flow_id'], timeout=15, json={
            'client_id': client_id, 'code': code}).json()
    if res.get('type') != 'create_entry':
        step(report, 'login_flow', False, str(res.get('errors') or res.get('type')))
        return None
    tok = requests.post(BASE + '/auth/token', timeout=15, data={
        'grant_type': 'authorization_code', 'code': res['result'], 'client_id': client_id}).json()
    step(report, 'login_flow + token', 'access_token' in tok, f'{time.time() - t0:.1f}s')
    return tok


def revoke(refresh_token):
    try:
        requests.post(BASE + '/auth/revoke', timeout=15, data={'token': refresh_token})
    except requests.RequestException:
        pass


async def ws_checks(report, access_token):
    url = BASE.replace('http', 'ws', 1) + '/api/websocket'
    async with websockets.connect(url, max_size=64 * 1024 * 1024) as ws:
        await ws.recv()
        await ws.send(json.dumps({'type': 'auth', 'access_token': access_token}))
        auth = json.loads(await ws.recv())
        step(report, 'websocket auth', auth.get('type') == 'auth_ok', auth.get('ha_version', ''))
        report['ha_version'] = auth.get('ha_version')
        next_id = [1]

        async def query(msg_type, **extra):
            mid = next_id[0]
            next_id[0] += 1
            await ws.send(json.dumps({'id': mid, 'type': msg_type, **extra}))
            while True:
                msg = json.loads(await ws.recv())
                if msg.get('id') == mid and msg.get('type') == 'result':
                    return msg

        user = await query('auth/current_user')
        report['user'] = {k: user.get('result', {}).get(k) for k in ('is_admin', 'is_owner')}
        step(report, 'current user', user.get('success'), json.dumps(report['user']))

        registry = {}
        for kind in ('area', 'device', 'entity'):
            res = await query(f'config/{kind}_registry/list')
            ok = res.get('success', False)
            registry[kind] = res.get('result') or []
            step(report, f'{kind} registry', ok, f'{len(registry[kind])} items' if ok else str(res.get('error')))

        states = (await query('get_states')).get('result') or []
        services = (await query('get_services')).get('result') or {}
        step(report, 'states', True, f'{len(states)} entities')

        missing = {d: [s for s in names if s not in services.get(d, {})] for d, names in ALLOWED_SERVICES.items()}
        report['services_missing'] = {d: m for d, m in missing.items() if m and d in services}

        areas = {a['area_id']: a['name'] for a in registry['area']}
        devices = {d['id']: d for d in registry['device']}
        reg = {e['entity_id']: e for e in registry['entity']}
        shown = []
        for st in states:
            eid = st['entity_id']
            domain = eid.split('.')[0]
            if domain not in SHOWN:
                continue
            e = reg.get(eid, {})
            dev = devices.get(e.get('device_id')) if e.get('device_id') else None
            shown.append({
                'entity_id': eid, 'state': st['state'], 'name': st['attributes'].get('friendly_name'),
                'area': areas.get(e.get('area_id') or (dev or {}).get('area_id')),
                'device': (dev or {}).get('name_by_user') or (dev or {}).get('name'),
                'device_entry_type': (dev or {}).get('entry_type'),
                'category': e.get('entity_category'), 'hidden': e.get('hidden_by'), 'disabled': e.get('disabled_by'),
                'in_registry': eid in reg,
                'attributes': st['attributes'],
            })
        report['entities'] = shown
        report['areas'] = list(areas.values())

        ids = [s['entity_id'] for s in shown]
        mid = next_id[0]
        next_id[0] += 1
        await ws.send(json.dumps({'id': mid, 'type': 'subscribe_entities', 'entity_ids': ids}))
        print(f'Listening {LISTEN_S}s for live changes of {len(ids)} entities '
              '(move a curtain or switch something in HA now)…')
        events, samples, first_size = 0, [], 0
        end = time.time() + LISTEN_S
        while time.time() < end:
            try:
                raw = await asyncio.wait_for(ws.recv(), timeout=max(0.1, end - time.time()))
            except asyncio.TimeoutError:
                break
            msg = json.loads(raw)
            if msg.get('id') != mid or msg.get('type') != 'event':
                continue
            event = msg['event']
            if 'a' in event:
                first_size = len(raw)
                continue
            events += 1
            for eid, diff in (event.get('c') or {}).items():
                if len(samples) < 60:
                    samples.append({'entity_id': eid, 'diff': diff, 't': round(LISTEN_S - (end - time.time()), 1)})
                print(f'  change {eid}: {json.dumps(diff, ensure_ascii=False)[:160]}')
        report['live'] = {'initial_bytes': first_size, 'change_events': events, 'samples': samples}
        step(report, 'live subscription', first_size > 0, f'first event {first_size} bytes, {events} change events')


def main():
    if not BASE:
        sys.exit('Set HA_URL first, e.g. set HA_URL=https://ha.example.org')
    username = os.environ.get('HA_USER') or input('HA username: ').strip()
    password = os.environ.get('HA_PASSWORD') or getpass.getpass('HA password: ')
    report = {'server': BASE, 'checked_at': time.strftime('%Y-%m-%d %H:%M:%S'), 'steps': []}
    tok = login(report, username, password)
    if tok:
        try:
            asyncio.run(ws_checks(report, tok['access_token']))
        except Exception as error:  # report what broke instead of a bare traceback
            step(report, 'websocket', False, repr(error))
        finally:
            revoke(tok.get('refresh_token', ''))
    with open(REPORT, 'w', encoding='utf-8') as f:
        json.dump(report, f, ensure_ascii=False, indent=1)
    print('Report written to ' + REPORT)


if __name__ == '__main__':
    main()
