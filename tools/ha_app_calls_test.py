"""Replays the watch app's Home Assistant calls against the virtual test home and checks the read-back state.

Each case mirrors what the app sends from DirectStore.runService / HaDirectClient.callService (same domain,
service and payload fields) and what it expects to read back. Only virtual devices from ha_test_fixture.py are
touched — real devices and user automations are never called.

    set HA_URL=http://<your-ha-host>:8123
    set HA_TOKEN=<long-lived access token>
    python tools/ha_app_calls_test.py
"""
import os
import sys
import time

import requests

BASE = os.environ.get('HA_URL', '').rstrip('/')
TOKEN = os.environ.get('HA_TOKEN', '').strip()
H = {'Authorization': 'Bearer ' + TOKEN, 'Content-Type': 'application/json'}


def call(domain, service, entity_id, **data):
    r = requests.post(f'{BASE}/api/services/{domain}/{service}', headers=H,
                      json={'entity_id': entity_id, **data}, timeout=10)
    r.raise_for_status()


def read(entity_id):
    r = requests.get(f'{BASE}/api/states/{entity_id}', headers=H, timeout=10)
    r.raise_for_status()
    return r.json()


def attr(name):
    return lambda s: s['attributes'].get(name)


# (label, entity, domain, service, payload, check(state) -> bool, what is expected)
CASES = [
    ('灯 开', 'light.can_ting_diao_deng', 'light', 'turn_on', {}, lambda s: s['state'] == 'on', 'on'),
    ('灯 亮度 30%', 'light.can_ting_diao_deng', 'light', 'turn_on', {'brightness_pct': 30},
     lambda s: s['state'] == 'on' and abs(attr('brightness')(s) - 77) <= 1, 'on, brightness≈77'),
    ('灯 关', 'light.can_ting_diao_deng', 'light', 'turn_off', {}, lambda s: s['state'] == 'off', 'off'),
    ('无调光灯 开', 'light.chu_fang_deng', 'light', 'turn_on', {}, lambda s: s['state'] == 'on', 'on'),
    ('无调光灯 关', 'light.chu_fang_deng', 'light', 'turn_off', {}, lambda s: s['state'] == 'off', 'off'),
    ('插座 关', 'switch.dian_shi_cha_zuo', 'switch', 'turn_off', {}, lambda s: s['state'] == 'off', 'off'),
    ('插座 开', 'switch.dian_shi_cha_zuo', 'switch', 'turn_on', {}, lambda s: s['state'] == 'on', 'on'),
    ('排气扇 开', 'fan.wei_sheng_jian_pai_qi_shan', 'fan', 'turn_on', {}, lambda s: s['state'] == 'on', 'on'),
    ('排气扇 关', 'fan.wei_sheng_jian_pai_qi_shan', 'fan', 'turn_off', {}, lambda s: s['state'] == 'off', 'off'),
    ('风扇 风速 33%', 'fan.wo_shi_feng_shan', 'fan', 'set_percentage', {'percentage': 33},
     lambda s: s['state'] == 'on' and round(attr('percentage')(s)) == 33, 'on, 33%'),
    ('风扇 最低档以下 → 关', 'fan.wo_shi_feng_shan', 'fan', 'turn_off', {}, lambda s: s['state'] == 'off', 'off'),
    ('窗帘 打开', 'cover.wo_shi_chuang_lian', 'cover', 'open_cover', {},
     lambda s: s['state'] == 'open' and attr('current_position')(s) == 100, 'open, 100'),
    ('窗帘 位置 40', 'cover.wo_shi_chuang_lian', 'cover', 'set_cover_position', {'position': 40},
     lambda s: attr('current_position')(s) == 40, '40'),
    ('窗帘 停止', 'cover.wo_shi_chuang_lian', 'cover', 'stop_cover', {}, lambda s: True, 'accepted'),
    ('窗帘 关闭', 'cover.wo_shi_chuang_lian', 'cover', 'close_cover', {},
     lambda s: s['state'] == 'closed', 'closed'),
    ('门锁 解锁', 'lock.ru_hu_men_suo', 'lock', 'unlock', {}, lambda s: s['state'] == 'unlocked', 'unlocked'),
    ('门锁 上锁', 'lock.ru_hu_men_suo', 'lock', 'lock', {}, lambda s: s['state'] == 'locked', 'locked'),
    ('扫地机 开始', 'vacuum.sao_di_ji_qi_ren', 'vacuum', 'start', {}, lambda s: s['state'] == 'cleaning', 'cleaning'),
    ('扫地机 暂停', 'vacuum.sao_di_ji_qi_ren', 'vacuum', 'pause', {}, lambda s: s['state'] == 'paused', 'paused'),
    ('扫地机 回充', 'vacuum.sao_di_ji_qi_ren', 'vacuum', 'return_to_base', {},
     lambda s: s['state'] == 'docked', 'docked'),
    ('下拉 选择 速热', 'select.re_shui_qi_mo_shi', 'select', 'select_option', {'option': '速热'},
     lambda s: s['state'] == '速热', '速热'),
    ('数值 设为 60', 'number.re_shui_qi_wen_du', 'number', 'set_value', {'value': 60},
     lambda s: float(s['state']) == 60, '60'),
    ('按钮 按下', 'button.men_ling', 'button', 'press', {}, lambda s: s['state'] not in ('unknown', 'unavailable'),
     'press timestamp'),
    ('场景 观影模式', 'scene.guan_ying_mo_shi', 'scene', 'turn_on', {},
     lambda s: read('cover.ke_ting_chuang_lian')['state'] == 'closed'
     and read('light.ke_ting_zhu_deng')['state'] == 'on', '客厅窗帘关、主灯开'),
    ('脚本 回家模式', 'script.vt_home_mode', 'script', 'turn_on', {},
     lambda s: read('cover.ke_ting_chuang_lian')['state'] == 'open', '客厅窗帘开'),
    ('场景 晚安', 'scene.wan_an', 'scene', 'turn_on', {},
     lambda s: read('light.ke_ting_zhu_deng')['state'] == 'off'
     and read('lock.ru_hu_men_suo')['state'] == 'locked', '灯全关、门已锁'),
]


def main():
    if not TOKEN or not BASE:
        raise SystemExit('请先设置环境变量 HA_URL 和 HA_TOKEN')
    failed = 0
    for label, entity_id, domain, service, payload, check, expected in CASES:
        try:
            call(domain, service, entity_id, **payload)
            time.sleep(1.2)
            state = read(entity_id)
            ok = check(state)
            got = state['state'] + ''.join(f', {k}={state["attributes"][k]}' for k in
                                           ('brightness', 'percentage', 'current_position')
                                           if k in state['attributes'] and state['attributes'][k] is not None)
        except Exception as error:  # noqa: BLE001 — report and continue with the next case
            ok, got = False, f'错误: {error}'
        failed += 0 if ok else 1
        print(f"{'通过' if ok else '失败'}  {label:<14} 期望 {expected:<18} 实际 {got}")
    # Offline device: the app must show it as unavailable and keep controls disabled.
    offline = read('light.yang_tai_deng')['state']
    ok = offline == 'unavailable'
    failed += 0 if ok else 1
    print(f"{'通过' if ok else '失败'}  {'离线设备':<14} 期望 {'unavailable':<18} 实际 {offline}")
    print(f'\n共 {len(CASES) + 1} 项，失败 {failed} 项')
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
