import { HaEntityAttributes } from './HaDirectClient';

export interface RoomSummary {
  id: string;
  name: string;
  count: number;
  icon?: string;
}

export interface DeviceItem {
  entityId: string;
  name: string;
  itemName?: string;
  domain: string;
  state: string;
  areaId: string;
  deviceId?: string;
  entityCategory?: string;
  available: boolean;
  attributes?: HaEntityAttributes;
}

export interface DeviceGroup {
  id: string;
  name: string;
  originalName?: string;
  areaId: string;
  primaryEntityId: string;
  entityIds: string[];
}

export interface HomeAssistantSnapshot {
  rooms: RoomSummary[];
  devices: DeviceItem[];
  groups: DeviceGroup[];
  fetchedAt: number;
  roomSource: 'registry' | 'unavailable';
  // Why the room/device registry could not be read (shown in Settings to diagnose remote setups).
  registryError?: string;
}

export const UNASSIGNED_ROOM: string = '__unassigned__';
