import { DeviceItem } from '../../data/direct/HomeAssistantModels';
import { ServiceData } from '../../data/direct/HaDirectClient';
import { Theme } from './Theme';

export interface QuickAction {
  label: string;
  service: string;
  expectedState?: string;
  data?: ServiceData;
}

const TOGGLE_DOMAINS: string[] = ['light', 'switch', 'input_boolean', 'fan', 'humidifier'];

// Domains that are an appliance's real function. Other controllable entities on the same device
// (switch, select, number, button…) are usually vendor extras and get folded on the device page.
const MAJOR_DOMAINS: string[] = ['climate', 'light', 'cover', 'fan', 'humidifier', 'media_player', 'vacuum', 'lock'];


const HVAC_LABELS: Record<string, string> = {
  'off': '关闭', 'heat': '制热', 'cool': '制冷', 'heat_cool': '自动冷热', 'auto': '自动',
  'dry': '除湿', 'fan_only': '送风'
};

const COVER_LABELS: Record<string, string> = {
  'open': '已打开', 'closed': '已关闭', 'opening': '正在打开', 'closing': '正在关闭', 'stopped': '已停止'
};

const LOCK_LABELS: Record<string, string> = {
  'locked': '已上锁', 'unlocked': '已解锁', 'locking': '正在上锁', 'unlocking': '正在解锁',
  'jammed': '卡住', 'open': '已打开', 'opening': '正在打开'
};

const MEDIA_LABELS: Record<string, string> = {
  'playing': '播放中', 'paused': '已暂停', 'idle': '空闲', 'on': '已开启', 'off': '已关闭',
  'standby': '待机', 'buffering': '缓冲中'
};

const VACUUM_LABELS: Record<string, string> = {
  'cleaning': '清扫中', 'docked': '已回充', 'returning': '正在回充', 'idle': '空闲',
  'paused': '已暂停', 'error': '故障'
};

export function isToggleDomain(domain: string): boolean {
  return TOGGLE_DOMAINS.includes(domain);
}

export function isMajorDomain(domain: string): boolean {
  return MAJOR_DOMAINS.includes(domain);
}

export function isReadOnlyDomain(domain: string): boolean {
  return domain === 'sensor' || domain === 'binary_sensor';
}


export function hvacModeLabel(mode: string): string {
  return HVAC_LABELS[mode] ?? mode;
}

export function isActive(item: DeviceItem): boolean {
  if (!item.available) return false;
  switch (item.domain) {
    case 'cover': return item.state === 'open' || item.state === 'opening';
    case 'lock': return item.state !== 'locked';
    case 'media_player': return item.state === 'playing';
    case 'climate': return item.state !== 'off';
    case 'vacuum': return item.state === 'cleaning';
    default: return item.state === 'on';
  }
}

export function glyphColor(item: DeviceItem): number {
  if (!item.available) return Theme.ICON_OFFLINE;
  if (!isActive(item)) return Theme.ICON_IDLE;
  return item.domain === 'light' ? Theme.ICON_LIGHT_ON : Theme.ICON_ON;
}

// HA reports missing readings as null (e.g. an AC without a temperature probe), not as an absent key.
export function isNum(value: number | null | undefined): boolean {
  return typeof value === 'number' && !Number.isNaN(value);
}

function percentOf(raw: number | undefined, scale: number): string {
  return raw === undefined || !isNum(raw) ? '' : ' · ' + Math.round(raw / scale * 100) + '%';
}

function withUnit(item: DeviceItem): string {
  const unit: string = item.attributes?.unit_of_measurement ?? '';
  // Numbers come back as "60.0" from input_number/number entities; show "60" but keep "24.6".
  const numeric: number = Number(item.state);
  const value: string = item.state.trim().length > 0 && !Number.isNaN(numeric) ? String(numeric) : item.state;
  return unit ? value + ' ' + unit : value;
}

export function stateLabel(item: DeviceItem): string {
  const state: string = item.state;
  if (state === 'unavailable') return '不可用';
  if (state === 'unknown') return '未知';
  switch (item.domain) {
    case 'sensor':
    case 'number':
    case 'input_number':
      return withUnit(item);
    case 'binary_sensor':
      return state === 'on' ? '检测到' : (state === 'off' ? '正常' : state);
    case 'scene':
      return '场景';
    case 'script':
      return state === 'on' ? '运行中' : '脚本';
    case 'automation':
      return state === 'on' ? '自动化 · 已启用' : '自动化 · 已停用';
    case 'button':
    case 'input_button':
      return '按钮';
    case 'climate': {
      const current: number | undefined = item.attributes?.current_temperature;
      return hvacModeLabel(state) + (isNum(current) ? ' · ' + current + '°' : '');
    }
    case 'cover':
      return (COVER_LABELS[state] ?? state) + percentOf(item.attributes?.current_position, 100);
    case 'lock':
      return LOCK_LABELS[state] ?? state;
    case 'media_player':
      return MEDIA_LABELS[state] ?? state;
    case 'vacuum':
      return VACUUM_LABELS[state] ?? state;
    case 'select':
    case 'input_select':
      return state;
    case 'light':
      return state === 'on' ? '已开启' + percentOf(item.attributes?.brightness, 255) :
        (state === 'off' ? '已关闭' : state);
    case 'fan': {
      // Some integrations report "on" with 0 %: show the speed only when it is meaningful.
      const speed: number = item.attributes?.percentage ?? 0;
      return state === 'on' ? '已开启' + (speed > 0 ? percentOf(speed, 100) : '') :
        (state === 'off' ? '已关闭' : state);
    }
    default:
      return state === 'on' ? '已开启' : (state === 'off' ? '已关闭' : state);
  }
}

// The single most likely action for a one-tap button. Locks are intentionally excluded: unlocking
// needs the confirmation on the detail page. Climate turn_on restores the last HVAC mode.
export function quickAction(item: DeviceItem): QuickAction | undefined {
  if (!item.available) return undefined;
  if (isToggleDomain(item.domain)) {
    if (item.state !== 'on' && item.state !== 'off') return undefined;
    const on: boolean = item.state === 'on';
    return { label: on ? '关' : '开', service: on ? 'turn_off' : 'turn_on', expectedState: on ? 'off' : 'on' };
  }
  switch (item.domain) {
    case 'climate':
      return item.state === 'off' ? { label: '开', service: 'turn_on' } :
        { label: '关', service: 'turn_off', expectedState: 'off' };
    case 'scene':
    case 'script':
      return { label: '执行', service: 'turn_on' };
    case 'automation':
      return { label: '执行', service: 'trigger' };
    case 'button':
    case 'input_button':
      return { label: '按', service: 'press' };
    case 'cover':
      return item.state === 'open' || item.state === 'opening' ?
        { label: '关', service: 'close_cover' } : { label: '开', service: 'open_cover' };
    case 'media_player':
      if (item.state === 'playing') return { label: '暂停', service: 'media_pause', expectedState: 'paused' };
      if (item.state === 'paused' || item.state === 'idle' || item.state === 'on') {
        return { label: '播放', service: 'media_play', expectedState: 'playing' };
      }
      return undefined;
    default:
      return undefined;
  }
}
