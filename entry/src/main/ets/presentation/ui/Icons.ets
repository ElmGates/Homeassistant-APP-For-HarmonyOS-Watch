import { DeviceItem, RoomSummary } from '../../data/direct/HomeAssistantModels';

// Built-in line icons (resources/base/media/ic_*.svg). An icon set in Home Assistant ("mdi:…") wins
// when it maps to one of these; otherwise the entity's type (or the room's name) picks a fallback.

// Ordered keyword → icon table for HA "mdi:" names. The first keyword contained in the name wins,
// so more specific keywords come first ("robot-vacuum" before "robot", "lock-open" before "lock").
interface MdiRule {
  keyword: string;
  icon: Resource;
}

const MDI_RULES: MdiRule[] = [
  { keyword: 'robot-vacuum', icon: $r('app.media.ic_vacuum') },
  { keyword: 'vacuum', icon: $r('app.media.ic_vacuum') },
  { keyword: 'lock-open', icon: $r('app.media.ic_lock_open') },
  { keyword: 'lock', icon: $r('app.media.ic_lock') },
  { keyword: 'air-conditioner', icon: $r('app.media.ic_climate') },
  { keyword: 'thermostat', icon: $r('app.media.ic_climate') },
  { keyword: 'snowflake', icon: $r('app.media.ic_climate') },
  { keyword: 'hvac', icon: $r('app.media.ic_climate') },
  { keyword: 'air-humidifier', icon: $r('app.media.ic_humidifier') },
  { keyword: 'water', icon: $r('app.media.ic_humidifier') },
  { keyword: 'fan', icon: $r('app.media.ic_fan') },
  { keyword: 'curtains', icon: $r('app.media.ic_cover') },
  { keyword: 'blinds', icon: $r('app.media.ic_cover') },
  { keyword: 'window-shutter', icon: $r('app.media.ic_cover') },
  { keyword: 'roller-shade', icon: $r('app.media.ic_cover') },
  { keyword: 'light-switch', icon: $r('app.media.ic_power') },
  { keyword: 'lightbulb', icon: $r('app.media.ic_light') },
  { keyword: 'ceiling-light', icon: $r('app.media.ic_light') },
  { keyword: 'spotlight', icon: $r('app.media.ic_light') },
  { keyword: 'lamp', icon: $r('app.media.ic_light') },
  { keyword: 'led', icon: $r('app.media.ic_light') },
  { keyword: 'power', icon: $r('app.media.ic_power') },
  { keyword: 'toggle-switch', icon: $r('app.media.ic_power') },
  { keyword: 'television', icon: $r('app.media.ic_media') },
  { keyword: 'speaker', icon: $r('app.media.ic_media') },
  { keyword: 'cast', icon: $r('app.media.ic_media') },
  { keyword: 'music', icon: $r('app.media.ic_media') },
  { keyword: 'script', icon: $r('app.media.ic_script') },
  { keyword: 'palette', icon: $r('app.media.ic_scene') },
  { keyword: 'robot', icon: $r('app.media.ic_automation') },
  { keyword: 'flash', icon: $r('app.media.ic_automation') },
  { keyword: 'thermometer', icon: $r('app.media.ic_sensor') },
  { keyword: 'gauge', icon: $r('app.media.ic_sensor') },
  { keyword: 'sofa', icon: $r('app.media.ic_sofa') },
  { keyword: 'bed', icon: $r('app.media.ic_bed') },
  { keyword: 'door', icon: $r('app.media.ic_door') },
  { keyword: 'stove', icon: $r('app.media.ic_kitchen') },
  { keyword: 'pot', icon: $r('app.media.ic_kitchen') },
  { keyword: 'fridge', icon: $r('app.media.ic_kitchen') },
  { keyword: 'shower', icon: $r('app.media.ic_bath') },
  { keyword: 'bath', icon: $r('app.media.ic_bath') },
  { keyword: 'toilet', icon: $r('app.media.ic_bath') },
  { keyword: 'desk', icon: $r('app.media.ic_office') },
  { keyword: 'office', icon: $r('app.media.ic_office') },
  { keyword: 'monitor', icon: $r('app.media.ic_office') },
  { keyword: 'account-group', icon: $r('app.media.ic_meeting') },
  { keyword: 'silverware', icon: $r('app.media.ic_dining') },
  { keyword: 'food', icon: $r('app.media.ic_dining') },
  { keyword: 'balcony', icon: $r('app.media.ic_balcony') },
  { keyword: 'weather-sunny', icon: $r('app.media.ic_balcony') },
  { keyword: 'home', icon: $r('app.media.ic_home') },
  { keyword: 'house', icon: $r('app.media.ic_home') }
];

// Room name keywords (Chinese and English) used when the area has no icon in HA.
interface RoomRule {
  keywords: string[];
  icon: Resource;
}

const ROOM_RULES: RoomRule[] = [
  { keywords: ['卧室', '主卧', '次卧', '客卧', '儿童房', 'bedroom'], icon: $r('app.media.ic_bed') },
  { keywords: ['客厅', '起居', 'living'], icon: $r('app.media.ic_sofa') },
  { keywords: ['厨房', 'kitchen'], icon: $r('app.media.ic_kitchen') },
  { keywords: ['卫生间', '浴室', '洗手间', '厕所', 'bath', 'toilet'], icon: $r('app.media.ic_bath') },
  { keywords: ['玄关', '门厅', '入户', '走廊', 'hall', 'entry'], icon: $r('app.media.ic_door') },
  { keywords: ['餐厅', '饭厅', 'dining'], icon: $r('app.media.ic_dining') },
  { keywords: ['会议', 'meeting'], icon: $r('app.media.ic_meeting') },
  { keywords: ['办公', '书房', '工作', 'office', 'study'], icon: $r('app.media.ic_office') },
  { keywords: ['阳台', '露台', '花园', 'balcony', 'garden'], icon: $r('app.media.ic_balcony') }
];

function fromMdi(icon: string | undefined): Resource | undefined {
  if (!icon || !icon.startsWith('mdi:')) return undefined;
  const name: string = icon.substring(4).toLowerCase();
  const rule: MdiRule | undefined = MDI_RULES.find((item: MdiRule) => name.includes(item.keyword));
  return rule?.icon;
}

function domainIcon(item: DeviceItem): Resource {
  switch (item.domain) {
    case 'light': return $r('app.media.ic_light');
    case 'switch':
    case 'input_boolean': return $r('app.media.ic_power');
    case 'climate': return $r('app.media.ic_climate');
    case 'fan': return $r('app.media.ic_fan');
    case 'humidifier': return $r('app.media.ic_humidifier');
    case 'cover': return $r('app.media.ic_cover');
    case 'lock': return item.state === 'locked' ? $r('app.media.ic_lock') : $r('app.media.ic_lock_open');
    case 'scene': return $r('app.media.ic_scene');
    case 'script': return $r('app.media.ic_script');
    case 'automation': return $r('app.media.ic_automation');
    case 'button':
    case 'input_button': return $r('app.media.ic_button');
    case 'media_player': return $r('app.media.ic_media');
    case 'vacuum': return $r('app.media.ic_vacuum');
    case 'select':
    case 'input_select': return $r('app.media.ic_select');
    case 'number':
    case 'input_number': return $r('app.media.ic_number');
    case 'binary_sensor': {
      const deviceClass: string = item.attributes?.device_class ?? '';
      return deviceClass === 'door' || deviceClass === 'window' || deviceClass === 'opening' ?
        $r('app.media.ic_door') : $r('app.media.ic_binary');
    }
    default: return $r('app.media.ic_sensor');
  }
}

export function entityIcon(item: DeviceItem): Resource {
  // A lock's open/closed state matters more than a custom icon, so locks always use the state icon.
  if (item.domain === 'lock') return domainIcon(item);
  return fromMdi(item.attributes?.icon) ?? domainIcon(item);
}

export function roomIcon(room: RoomSummary): Resource {
  const fromHa: Resource | undefined = fromMdi(room.icon);
  if (fromHa) return fromHa;
  const name: string = room.name.toLowerCase();
  const rule: RoomRule | undefined = ROOM_RULES.find((item: RoomRule) =>
    item.keywords.some((keyword: string) => name.includes(keyword)));
  return rule?.icon ?? $r('app.media.ic_home');
}

// Icon for the one-tap button of runnable items; undefined keeps the text label (开 / 关).
export function actionIcon(item: DeviceItem): Resource | undefined {
  switch (item.domain) {
    case 'scene':
    case 'script':
    case 'automation':
    case 'button':
    case 'input_button':
      return $r('app.media.ic_action_play');
    case 'media_player':
      return item.state === 'playing' ? $r('app.media.ic_action_pause') : $r('app.media.ic_action_play');
    default:
      return undefined;
  }
}
