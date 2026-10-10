import { DeviceItem } from '../../data/direct/HomeAssistantModels';
import { ServiceData } from '../../data/direct/HaDirectClient';
import { Theme } from './Theme';

export interface QuickAction {
  label: string;
  service: string;
  expectedState?: string;
  data?: ServiceData;
}

// Their state is the time of the last use ("unknown" before the first): shown by kind, not by state.
const STATELESS_DOMAINS: string[] = ['scene', 'button', 'input_button'];

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

// HA's supported_features bits (CoverEntityFeature, MediaPlayerEntityFeature, VacuumEntityFeature). A device
// rejects a service it does not support, so only supported controls are offered.
export const COVER_OPEN: number = 1;
export const COVER_CLOSE: number = 2;
export const COVER_SET_POSITION: number = 4;
export const COVER_STOP: number = 8;
export const COVER_OPEN_TILT: number = 16;
export const COVER_CLOSE_TILT: number = 32;
export const COVER_STOP_TILT: number = 64;
export const MEDIA_PAUSE: number = 1;
export const MEDIA_VOLUME_SET: number = 4;
export const MEDIA_PREVIOUS_TRACK: number = 16;
export const MEDIA_NEXT_TRACK: number = 32;
export const MEDIA_TURN_ON: number = 128;
export const MEDIA_TURN_OFF: number = 256;
export const MEDIA_PLAY: number = 16384;
export const VACUUM_PAUSE: number = 4;
export const VACUUM_RETURN_HOME: number = 16;
export const VACUUM_START: number = 8192;

// Whether the device supports the feature (any of them, when several bits are combined). Without
// supported_features (older integrations) everything is offered.
export function supports(item: DeviceItem, feature: number): boolean {
  const features: number | undefined = item.attributes?.supported_features;
  if (features === undefined || !isNum(features)) return true;
  return (features & feature) !== 0;
}

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

// Climate fan / swing / preset values differ per integration; the common ones get Chinese names, anything
// else (vendor-specific, already localized) is shown as reported. Numeric speeds become 「N 档」.
const FAN_LABELS: Record<string, string> = {
  'auto': '自动', 'low': '低', 'medium': '中', 'middle': '中', 'mid': '中', 'medium_low': '中低',
  'medium_high': '中高', 'high': '高', 'highest': '最高', 'lowest': '最低', 'quiet': '静音', 'silent': '静音',
  'sleep': '睡眠', 'turbo': '强劲', 'strong': '强劲', 'powerful': '强劲', 'focus': '集中', 'diffuse': '扩散',
  'on': '开', 'off': '关'
};

const SWING_LABELS: Record<string, string> = {
  'off': '关闭', 'on': '开启', 'both': '上下左右', 'vertical': '上下', 'horizontal': '左右', 'swing': '摆动',
  'auto': '自动', 'up': '上', 'down': '下', 'left': '左', 'right': '右', 'middle': '中间', 'center': '中间',
  'top': '最上', 'bottom': '最下', 'leftmost': '最左', 'rightmost': '最右'
};

const PRESET_LABELS: Record<string, string> = {
  'none': '无', 'eco': '节能', 'sleep': '睡眠', 'boost': '强劲', 'comfort': '舒适', 'away': '离家',
  'home': '在家', 'activity': '活动'
};

function modeLabel(table: Record<string, string>, mode: string): string {
  const known: string | undefined = table[mode.toLowerCase()];
  if (known) return known;
  return /^[0-9]+$/.test(mode) ? mode + ' 档' : mode;
}

export function fanModeLabel(mode: string): string {
  return modeLabel(FAN_LABELS, mode);
}

export function swingModeLabel(mode: string): string {
  return /^[0-9]+$/.test(mode) ? '位置 ' + mode : modeLabel(SWING_LABELS, mode);
}

export function presetModeLabel(mode: string): string {
  return modeLabel(PRESET_LABELS, mode);
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
  if (state === 'unknown' && !STATELESS_DOMAINS.includes(item.domain)) return '未知';
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
    case 'cover': {
      const open: boolean = item.state === 'open' || item.state === 'opening';
      if (supports(item, open ? COVER_CLOSE : COVER_OPEN)) {
        return open ? { label: '关', service: 'close_cover' } : { label: '开', service: 'open_cover' };
      }
      // Tilt-only covers (louvre roofs, blinds): one tap tilts open or closed.
      if (supports(item, COVER_OPEN_TILT | COVER_CLOSE_TILT) && !supports(item, COVER_OPEN | COVER_CLOSE)) {
        return open ? { label: '关', service: 'close_cover_tilt' } : { label: '开', service: 'open_cover_tilt' };
      }
      return undefined;
    }
    case 'media_player':
      if (item.state === 'playing') {
        return supports(item, MEDIA_PAUSE) ? { label: '暂停', service: 'media_pause', expectedState: 'paused' } :
          undefined;
      }
      if ((item.state === 'paused' || item.state === 'idle' || item.state === 'on') && supports(item, MEDIA_PLAY)) {
        return { label: '播放', service: 'media_play', expectedState: 'playing' };
      }
      return undefined;
    default:
      return undefined;
  }
}
