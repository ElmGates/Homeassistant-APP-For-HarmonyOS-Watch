"""Create / remove a realistic Home Assistant test home for the watch app.

Usage (address, token and device name are read from the environment, never stored):
    set HA_URL=http://<your-ha-host>:8123
    set HA_TOKEN=<long-lived access token>
    set HA_NOISY_DEVICE=<name of one real device to attach junk entities to>
    python tools/ha_test_fixture.py setup      # create rooms, virtual devices and a "noisy" AC
    python tools/ha_test_fixture.py extend     # add the rest of a full test home (run after setup)
    python tools/ha_test_fixture.py cleanup    # remove everything this script (and the earlier manual test) created

What `setup` builds:
  * Rooms 客厅 / 卧室 / 玄关.
  * Virtual devices backed by hidden helpers (hidden entities must not appear on the watch):
    客厅主灯 (light + brightness), 客厅窗帘 (cover + position), 卧室台灯 (light),
    卧室风扇 (fan + speed), 入户门锁 (lock), scripts 回家模式 / 离家模式.
  * ~26 vendor-style junk entities attached to one real device named by HA_NOISY_DEVICE (child lock, buzzer, screen brightness,
    reboot buttons, temperatures, currents…) to check that the app folds them away.

Everything created is recorded in tools/.ha_fixture_state.json so `cleanup` can remove it.
"""
import asyncio
import json
import os
import sys

import requests
import websockets

BASE = os.environ.get('HA_URL', '').rstrip('/')
NOISY_DEVICE_NAME = os.environ.get('HA_NOISY_DEVICE', '').strip()
STATE_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), '.ha_fixture_state.json')
NOOP = [{'delay': {'seconds': 0}}]

# Created by hand in the HA UI before this script existed.
LEGACY_TEMPLATE_TITLES = ['滤网寿命', 'WiFi信号强度', '固件版本', '压缩机频率', '累计运行时长']
LEGACY_HELPERS = {'input_boolean': ['测试开关', '客厅主灯状态'], 'input_number': ['测试数值'],
                  'input_select': ['测试模式']}
LEGACY_AREAS = ['测试']


def svc(action, entity_id, **data):
    step = {'action': action, 'target': {'entity_id': entity_id}}
    if data:
        step['data'] = data
    return step


class Ha:
    def __init__(self, token):
        self.token = token
        self.headers = {'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'}
        self.ws = None
        self.next_id = 1

    # ---------- websocket ----------
    async def connect(self):
        self.ws = await websockets.connect(BASE.replace('http', 'ws', 1) + '/api/websocket', max_size=None)
        await self.ws.recv()
        await self.ws.send(json.dumps({'type': 'auth', 'access_token': self.token}))
        if json.loads(await self.ws.recv()).get('type') != 'auth_ok':
            raise SystemExit('令牌无效：请检查 HA_TOKEN')

    async def call(self, msg_type, **payload):
        msg_id = self.next_id
        self.next_id += 1
        await self.ws.send(json.dumps({'id': msg_id, 'type': msg_type, **payload}))
        while True:
            reply = json.loads(await self.ws.recv())
            if reply.get('id') == msg_id:
                break
        if not reply.get('success'):
            raise RuntimeError(f"{msg_type} 失败: {reply.get('error')}")
        return reply.get('result')

    # ---------- REST ----------
    def rest(self, method, path, body=None):
        r = requests.request(method, BASE + path, headers=self.headers, json=body, timeout=15)
        if r.status_code >= 400:
            raise RuntimeError(f'{method} {path} -> HTTP {r.status_code}: {r.text[:300]}')
        return r.json() if r.text else None

    def template_entry(self, kind, data):
        flow = self.rest('POST', '/api/config/config_entries/flow', {'handler': 'template'})
        fid = flow['flow_id']
        try:
            self.rest('POST', f'/api/config/config_entries/flow/{fid}', {'next_step_id': kind})
            result = self.rest('POST', f'/api/config/config_entries/flow/{fid}', data)
        except Exception:
            requests.delete(BASE + f'/api/config/config_entries/flow/{fid}', headers=self.headers)
            raise
        if result.get('type') != 'create_entry':
            raise RuntimeError(f"模板 {data.get('name')} 创建失败: {result.get('errors') or result}")
        return result['result']['entry_id']


def fan_actions(fan_on, fan_pct):
    """Behave like a real fan: turning on never leaves 0 %, setting 0 % turns it off."""
    return {
        'turn_on': [svc('input_number.set_value', fan_pct, value=f"{{{{ [states('{fan_pct}') | int(0), 33] | max }}}}"),
                    svc('input_boolean.turn_on', fan_on)],
        'turn_off': [svc('input_boolean.turn_off', fan_on)],
        'set_percentage': [svc('input_number.set_value', fan_pct, value='{{ percentage }}'),
                           {'action': "input_boolean.turn_{{ 'on' if percentage | int(0) > 0 else 'off' }}",
                            'target': {'entity_id': fan_on}}],
    }


def load_state():
    if os.path.exists(STATE_FILE):
        with open(STATE_FILE, encoding='utf-8') as f:
            return json.load(f)
    return {'areas': [], 'helpers': [], 'templates': [], 'scripts': [], 'scenes': [], 'extended': False}


def save_state(state):
    with open(STATE_FILE, 'w', encoding='utf-8') as f:
        json.dump(state, f, ensure_ascii=False, indent=2)


async def entities_of_entry(ha, entry_id):
    entities = await ha.call('config/entity_registry/list')
    return [e['entity_id'] for e in entities if e.get('config_entry_id') == entry_id]


async def ensure_area(ha, state, name):
    for area in await ha.call('config/area_registry/list'):
        if area['name'] == name:
            return area['area_id']
    area = await ha.call('config/area_registry/create', name=name)
    state['areas'].append(area['area_id'])
    save_state(state)
    print('  + 房间', name)
    return area['area_id']


async def helper(ha, state, domain, name, **options):
    item = await ha.call(f'{domain}/create', name=name, **options)
    entity_id = f"{domain}.{item['id']}"
    state['helpers'].append({'domain': domain, 'id': item['id']})
    save_state(state)
    # Backing helpers are internal plumbing: hidden entities must not show up on the watch.
    await ha.call('config/entity_registry/update', entity_id=entity_id, hidden_by='user')
    return entity_id


async def template(ha, state, kind, data, area_id=None):
    entry_id = ha.template_entry(kind, data)
    state['templates'].append(entry_id)
    save_state(state)
    ids = await entities_of_entry(ha, entry_id)
    if area_id:
        for entity_id in ids:
            await ha.call('config/entity_registry/update', entity_id=entity_id, area_id=area_id)
    print(f"  + {kind:<13} {data['name']}  {', '.join(ids)}")
    return ids[0] if ids else ''


async def remove_legacy_helpers(ha):
    for domain, names in LEGACY_HELPERS.items():
        for item in await ha.call(f'{domain}/list'):
            if item.get('name') in names:
                await ha.call(f'{domain}/delete', **{f'{domain}_id': item['id']})
                print('  - 旧测试辅助元素', item['name'])
    for area in await ha.call('config/area_registry/list'):
        if area['name'] in LEGACY_AREAS:
            await ha.call('config/area_registry/delete', area_id=area['area_id'])
            print('  - 旧测试房间', area['name'])


async def scene(ha, state, scene_id, name, entities, area_id):
    ha.rest('POST', f'/api/config/scene/config/{scene_id}', {'id': scene_id, 'name': name, 'entities': entities})
    state.setdefault('scenes', []).append(scene_id)
    save_state(state)
    await asyncio.sleep(1)
    for entry in await ha.call('config/entity_registry/list'):
        if entry.get('platform') == 'homeassistant' and entry.get('unique_id') == scene_id:
            await ha.call('config/entity_registry/update', entity_id=entry['entity_id'], area_id=area_id)
            print('  + scene         ', name, ' ', entry['entity_id'])
            return entry['entity_id']
    print('  + scene         ', name)
    return ''


def light_data(name, on, level=None):
    data = {'name': name, 'state': f"{{{{ is_state('{on}', 'on') }}}}",
            'turn_on': [svc('input_boolean.turn_on', on)], 'turn_off': [svc('input_boolean.turn_off', on)]}
    if level:
        data['level'] = f"{{{{ states('{level}') | int(0) }}}}"
        data['set_level'] = [svc('input_number.set_value', level, value='{{ brightness }}'),
                             svc('input_boolean.turn_on', on)]
    return data


def plug_data(name, on):
    return {'name': name, 'value_template': f"{{{{ is_state('{on}', 'on') }}}}",
            'turn_on': [svc('input_boolean.turn_on', on)], 'turn_off': [svc('input_boolean.turn_off', on)]}


async def extend(ha):
    """Phase 2: one of every device type the watch app supports, spread over more rooms."""
    state = load_state()
    if not state['templates']:
        raise SystemExit('请先运行 setup')
    if state.get('extended'):
        raise SystemExit('已经扩展过；如需重建请先运行 cleanup')
    print('房间')
    areas = {}
    for name in ['客厅', '卧室', '玄关', '餐厅', '书房', '厨房', '卫生间', '阳台']:
        areas[name] = await ensure_area(ha, state, name)

    print('隐藏的状态辅助元素')
    dining_on = await helper(ha, state, 'input_boolean', 'vt dining light on', initial=True)
    dining_level = await helper(ha, state, 'input_number', 'vt dining light level', min=0, max=255, step=1,
                                mode='slider', initial=200)
    study_on = await helper(ha, state, 'input_boolean', 'vt study lamp on')
    study_level = await helper(ha, state, 'input_number', 'vt study lamp level', min=0, max=255, step=1,
                               mode='slider', initial=120)
    kitchen_on = await helper(ha, state, 'input_boolean', 'vt kitchen light on')
    exhaust_on = await helper(ha, state, 'input_boolean', 'vt exhaust fan on')
    tv_plug_on = await helper(ha, state, 'input_boolean', 'vt tv plug on', initial=True)
    water_on = await helper(ha, state, 'input_boolean', 'vt water dispenser on', initial=True)
    curtain2 = await helper(ha, state, 'input_number', 'vt bedroom curtain position', min=0, max=100, step=1,
                            mode='slider', initial=0)
    vacuum_state = await helper(ha, state, 'input_select', 'vt vacuum state',
                                options=['docked', 'cleaning', 'paused', 'returning'], initial='docked')
    heater_mode = await helper(ha, state, 'input_select', 'vt heater mode', options=['节能', '标准', '速热'],
                               initial='标准')
    heater_temp = await helper(ha, state, 'input_number', 'vt heater temperature', min=30, max=75, step=5,
                               mode='box', initial=50, unit_of_measurement='°C')

    print('设备')
    await template(ha, state, 'light', light_data('餐厅吊灯', dining_on, dining_level), areas['餐厅'])
    await template(ha, state, 'light', light_data('书房台灯', study_on, study_level), areas['书房'])
    await template(ha, state, 'light', light_data('厨房灯', kitchen_on), areas['厨房'])
    await template(ha, state, 'fan', {
        'name': '卫生间排气扇', 'state': f"{{{{ is_state('{exhaust_on}', 'on') }}}}",
        'turn_on': [svc('input_boolean.turn_on', exhaust_on)],
        'turn_off': [svc('input_boolean.turn_off', exhaust_on)],
    }, areas['卫生间'])
    await template(ha, state, 'switch', plug_data('电视插座', tv_plug_on), areas['客厅'])
    await template(ha, state, 'switch', plug_data('饮水机', water_on), areas['餐厅'])
    await template(ha, state, 'cover', {
        'name': '卧室窗帘',
        'state': f"{{{{ 'open' if states('{curtain2}') | int(0) > 0 else 'closed' }}}}",
        'position': f"{{{{ states('{curtain2}') | int(0) }}}}",
        'open_cover': [svc('input_number.set_value', curtain2, value=100)],
        'close_cover': [svc('input_number.set_value', curtain2, value=0)],
        'stop_cover': NOOP,
        'set_cover_position': [svc('input_number.set_value', curtain2, value='{{ position }}')],
        'device_class': 'curtain',
    }, areas['卧室'])
    await template(ha, state, 'vacuum', {
        'name': '扫地机器人', 'state': f"{{{{ states('{vacuum_state}') }}}}",
        'start': [svc('input_select.select_option', vacuum_state, option='cleaning')],
        'pause': [svc('input_select.select_option', vacuum_state, option='paused')],
        'stop': [svc('input_select.select_option', vacuum_state, option='docked')],
        'return_to_base': [svc('input_select.select_option', vacuum_state, option='docked')],
    }, areas['客厅'])
    await template(ha, state, 'select', {
        'name': '热水器模式', 'state': f"{{{{ states('{heater_mode}') }}}}",
        'options': f"{{{{ state_attr('{heater_mode}', 'options') }}}}",
        'select_option': [svc('input_select.select_option', heater_mode, option='{{ option }}')],
    }, areas['卫生间'])
    await template(ha, state, 'number', {
        'name': '热水器温度', 'state': f"{{{{ states('{heater_temp}') | float(0) }}}}",
        'min': 30, 'max': 75, 'step': 5, 'unit_of_measurement': '°C',
        'set_value': [svc('input_number.set_value', heater_temp, value='{{ value }}')],
    }, areas['卫生间'])
    await template(ha, state, 'button', {'name': '门铃', 'press': NOOP}, areas['玄关'])
    await template(ha, state, 'binary_sensor', {'name': '入户门磁', 'state': 'off', 'device_class': 'door'},
                   areas['玄关'])
    await template(ha, state, 'binary_sensor', {'name': '客厅人体感应', 'state': 'on', 'device_class': 'motion'},
                   areas['客厅'])
    await template(ha, state, 'sensor', {'name': '客厅温度', 'state': '24.6', 'unit_of_measurement': '°C'},
                   areas['客厅'])
    await template(ha, state, 'sensor', {'name': '客厅湿度', 'state': '52', 'unit_of_measurement': '%'},
                   areas['客厅'])
    # Permanently unavailable, to check how the app shows an offline device.
    await template(ha, state, 'light', {
        'name': '阳台灯', 'state': 'off', 'turn_on': NOOP, 'turn_off': NOOP,
        'advanced_options': {'availability': '{{ false }}'},
    }, areas['阳台'])

    print('场景')
    await scene(ha, state, 'vt_scene_movie', '观影模式', {
        'light.ke_ting_zhu_deng': {'state': 'on', 'brightness': 60},
        'cover.ke_ting_chuang_lian': {'state': 'closed'},
        'switch.dian_shi_cha_zuo': {'state': 'on'},
    }, areas['客厅'])
    goodnight = {eid: {'state': 'off'} for eid in ['light.ke_ting_zhu_deng', 'light.wo_shi_tai_deng',
                                                    'light.can_ting_diao_deng', 'light.shu_fang_tai_deng',
                                                    'light.chu_fang_deng']}
    goodnight['lock.ru_hu_men_suo'] = {'state': 'locked'}
    goodnight['cover.wo_shi_chuang_lian'] = {'state': 'closed'}
    await scene(ha, state, 'vt_scene_goodnight', '晚安', goodnight, areas['卧室'])

    state['extended'] = True
    save_state(state)
    print('完成。模板实体共', len(state['templates']), '个')


async def setup(ha):
    state = load_state()
    if state['templates']:
        raise SystemExit('已经创建过测试数据；如需重建请先运行 cleanup')
    print('移除之前手动建的抽象测试项')
    await remove_legacy_helpers(ha)
    print('房间')
    living = await ensure_area(ha, state, '客厅')
    bedroom = await ensure_area(ha, state, '卧室')
    hallway = await ensure_area(ha, state, '玄关')

    print('隐藏的状态辅助元素')
    living_on = await helper(ha, state, 'input_boolean', 'vt living light on')
    living_level = await helper(ha, state, 'input_number', 'vt living light level', min=0, max=255, step=1,
                                mode='slider', initial=180)
    curtain_pos = await helper(ha, state, 'input_number', 'vt curtain position', min=0, max=100, step=1,
                               mode='slider', initial=60)
    lamp_on = await helper(ha, state, 'input_boolean', 'vt bedroom lamp on')
    fan_on = await helper(ha, state, 'input_boolean', 'vt bedroom fan on')
    fan_pct = await helper(ha, state, 'input_number', 'vt bedroom fan percentage', min=0, max=100, step=1,
                           mode='slider', initial=66)
    door_locked = await helper(ha, state, 'input_boolean', 'vt front door locked', initial=True)

    print('虚拟设备')
    living_light = await template(ha, state, 'light', {
        'name': '客厅主灯',
        'state': f"{{{{ is_state('{living_on}', 'on') }}}}",
        'level': f"{{{{ states('{living_level}') | int(0) }}}}",
        'turn_on': [svc('input_boolean.turn_on', living_on)],
        'turn_off': [svc('input_boolean.turn_off', living_on)],
        'set_level': [svc('input_number.set_value', living_level, value='{{ brightness }}'),
                      svc('input_boolean.turn_on', living_on)],
    }, living)
    curtain = await template(ha, state, 'cover', {
        'name': '客厅窗帘',
        'state': f"{{{{ 'open' if states('{curtain_pos}') | int(0) > 0 else 'closed' }}}}",
        'position': f"{{{{ states('{curtain_pos}') | int(0) }}}}",
        'open_cover': [svc('input_number.set_value', curtain_pos, value=100)],
        'close_cover': [svc('input_number.set_value', curtain_pos, value=0)],
        'stop_cover': NOOP,
        'set_cover_position': [svc('input_number.set_value', curtain_pos, value='{{ position }}')],
        'device_class': 'curtain',
    }, living)
    bedroom_lamp = await template(ha, state, 'light', {
        'name': '卧室台灯',
        'state': f"{{{{ is_state('{lamp_on}', 'on') }}}}",
        'turn_on': [svc('input_boolean.turn_on', lamp_on)],
        'turn_off': [svc('input_boolean.turn_off', lamp_on)],
    }, bedroom)
    await template(ha, state, 'fan', {
        'name': '卧室风扇',
        'state': f"{{{{ is_state('{fan_on}', 'on') }}}}",
        'percentage': f"{{{{ states('{fan_pct}') | int(0) }}}}",
        **fan_actions(fan_on, fan_pct),
        'speed_count': 3,
    }, bedroom)
    door = await template(ha, state, 'lock', {
        'name': '入户门锁',
        'state': f"{{{{ 'locked' if is_state('{door_locked}', 'on') else 'unlocked' }}}}",
        'lock': [svc('input_boolean.turn_on', door_locked)],
        'unlock': [svc('input_boolean.turn_off', door_locked)],
    }, hallway)

    print('场景脚本')
    scripts = {
        'vt_home_mode': ('回家模式', [svc('light.turn_on', living_light, brightness_pct=70),
                                     svc('cover.open_cover', curtain)]),
        'vt_away_mode': ('离家模式', [svc('light.turn_off', [living_light, bedroom_lamp]), svc('cover.close_cover', curtain),
                                     svc('lock.lock', door)]),
    }
    for script_id, (alias, sequence) in scripts.items():
        ha.rest('POST', f'/api/config/script/config/{script_id}', {'alias': alias, 'sequence': sequence})
        state['scripts'].append(script_id)
        save_state(state)
        await asyncio.sleep(1)
        try:
            await ha.call('config/entity_registry/update', entity_id=f'script.{script_id}', area_id=hallway)
        except RuntimeError:
            pass
        print('  + script        ', alias)

    print(f'「{NOISY_DEVICE_NAME}」上的杂项实体')
    device_id = next((d['id'] for d in await ha.call('config/device_registry/list')
                      if (d.get('name_by_user') or d.get('name')) == NOISY_DEVICE_NAME), None)
    if not device_id:
        raise SystemExit(f'找不到设备 {NOISY_DEVICE_NAME}')
    for name in ['童锁', '指示灯', '蜂鸣器', '防直吹', '自清洁', '睡眠模式', 'ECO节能', '防霉干燥']:
        await template(ha, state, 'switch', {'name': name, 'device_id': device_id})
    await template(ha, state, 'select', {'name': '屏显模式', 'state': '自动',
                                         'options': "{{ ['常亮', '自动', '关闭'] }}", 'select_option': NOOP,
                                         'device_id': device_id})
    await template(ha, state, 'number', {'name': '屏幕亮度', 'state': '80', 'min': 0, 'max': 100, 'step': 10,
                                         'set_value': NOOP, 'device_id': device_id})
    for name in ['重启WiFi模组', '滤网复位', '一键诊断']:
        await template(ha, state, 'button', {'name': name, 'press': NOOP, 'device_id': device_id})
    for name, value in [('滤网需清洗', 'off'), ('门窗联动', 'on'), ('缺氟告警', 'off')]:
        await template(ha, state, 'binary_sensor', {'name': name, 'state': value, 'device_id': device_id})
    for name, value, unit in [('室外温度', '31.5', '°C'), ('蒸发器温度', '12.3', '°C'), ('冷凝器温度', '46.8', '°C'),
                              ('运行电流', '3.2', 'A'), ('电压', '221', 'V'), ('实时功率', '680', 'W'),
                              ('PM2.5', '18', 'µg/m³'), ('错误代码', 'E0', None), ('上次在线', '2026-10-01 18:00', None),
                              ('模组固件', 'WM2.1.8', None)]:
        data = {'name': name, 'state': value, 'device_id': device_id}
        if unit:
            data['unit_of_measurement'] = unit
        await template(ha, state, 'sensor', data)

    print('完成。共创建模板实体', len(state['templates']), '个，记录在', STATE_FILE)


async def cleanup(ha):
    state = load_state()
    entries = ha.rest('GET', '/api/config/config_entries/entry')
    legacy = [e['entry_id'] for e in entries if e.get('domain') == 'template' and e.get('title') in LEGACY_TEMPLATE_TITLES]
    for entry_id in state['templates'] + legacy:
        try:
            ha.rest('DELETE', f'/api/config/config_entries/entry/{entry_id}')
            print('  - template', entry_id)
        except RuntimeError as error:
            print('  ! ', error)
    for scene_id in state.get('scenes', []):
        try:
            ha.rest('DELETE', f'/api/config/scene/config/{scene_id}')
            print('  - scene', scene_id)
        except RuntimeError as error:
            print('  ! ', error)
    for script_id in state['scripts']:
        try:
            ha.rest('DELETE', f'/api/config/script/config/{script_id}')
            print('  - script', script_id)
        except RuntimeError as error:
            print('  ! ', error)
    await remove_legacy_helpers(ha)
    for item in state['helpers']:
        try:
            await ha.call(f"{item['domain']}/delete", **{f"{item['domain']}_id": item['id']})
            print('  - helper', f"{item['domain']}.{item['id']}")
        except RuntimeError as error:
            print('  ! ', error)
    for area_id in state['areas']:
        try:
            await ha.call('config/area_registry/delete', area_id=area_id)
            print('  - 房间', area_id)
        except RuntimeError as error:
            print('  ! ', error)
    if os.path.exists(STATE_FILE):
        os.remove(STATE_FILE)
    print('清理完成')


async def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ('setup', 'extend', 'cleanup'):
        raise SystemExit(__doc__)
    token = os.environ.get('HA_TOKEN', '').strip()
    if not token or not BASE:
        raise SystemExit('请先设置环境变量 HA_URL 和 HA_TOKEN')
    if sys.argv[1] == 'setup' and not NOISY_DEVICE_NAME:
        raise SystemExit('请先设置环境变量 HA_NOISY_DEVICE（挂杂项实体的那台真实设备名称）')
    ha = Ha(token)
    await ha.connect()
    try:
        commands = {'setup': setup, 'extend': extend, 'cleanup': cleanup}
        await commands[sys.argv[1]](ha)
    finally:
        await ha.ws.close()


if __name__ == '__main__':
    asyncio.run(main())
