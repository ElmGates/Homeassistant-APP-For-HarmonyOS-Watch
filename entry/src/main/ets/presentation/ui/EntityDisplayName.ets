import { DeviceGroup, DeviceItem } from '../../data/direct/HomeAssistantModels';

function removeDevicePrefix(value: string, deviceName: string): string {
  const prefix: string = deviceName.trim();
  if (!prefix || !value.startsWith(prefix)) return '';
  return value.substring(prefix.length).replace(/^[\s·:：._\-—/]+/, '').trim();
}

function domainName(domain: string): string {
  if (domain === 'light') return '灯';
  if (domain === 'switch') return '开关';
  if (domain === 'climate') return '空调';
  if (domain === 'cover') return '窗帘';
  if (domain === 'sensor') return '状态';
  if (domain === 'binary_sensor') return '检测状态';
  if (domain === 'scene') return '场景';
  if (domain === 'script') return '脚本';
  if (domain === 'automation') return '自动化';
  if (domain === 'fan') return '风扇';
  if (domain === 'lock') return '门锁';
  if (domain === 'media_player') return '播放器';
  if (domain === 'vacuum') return '扫地机';
  if (domain === 'humidifier') return '加湿器';
  if (domain === 'button' || domain === 'input_button') return '按钮';
  if (domain === 'number' || domain === 'input_number') return '数值';
  if (domain === 'select' || domain === 'input_select') return '选项';
  return '主功能';
}

export function entityDisplayName(entity: DeviceItem, group?: DeviceGroup): string {
  const full: string = entity.name.trim();
  const specific: string = entity.itemName?.trim() ?? '';
  if (!group) return full;
  // A single-entity "device" is the entity itself: keep its full name ("卧室风扇", not "风扇").
  if (group.entityIds.length <= 1) return group.name || full;
  const fromGroup: string = removeDevicePrefix(full, group.name);
  if (fromGroup) return fromGroup;
  const fromOriginal: string = removeDevicePrefix(full, group.originalName ?? '');
  if (fromOriginal) return fromOriginal;
  if (specific && specific !== group.name && specific !== group.originalName) {
    const shortSpecific: string = removeDevicePrefix(specific, group.name) ||
      removeDevicePrefix(specific, group.originalName ?? '');
    return shortSpecific || specific;
  }
  if (full === group.name || full === group.originalName) return domainName(entity.domain);
  return full;
}
