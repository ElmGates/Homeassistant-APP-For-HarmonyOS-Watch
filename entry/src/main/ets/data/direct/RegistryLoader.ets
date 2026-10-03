import { HaSocket, WsEnvelope } from './HaSocket';

export interface RegistryArea {
  area_id: string;
  name: string;
  icon?: string | null;
}

export interface RegistryDevice {
  id: string;
  area_id?: string;
  name?: string;
  name_by_user?: string;
  entry_type?: string;
}

export interface RegistryEntity {
  entity_id: string;
  name?: string;
  original_name?: string;
  area_id?: string;
  device_id?: string;
  disabled_by?: string;
  hidden_by?: string;
  entity_category?: string;
}

export interface RegistrySnapshot {
  areas: RegistryArea[];
  devices: RegistryDevice[];
  entities: RegistryEntity[];
}

// Reads the area, device and entity registries over an open HaSocket.
export async function loadRegistry(socket: HaSocket): Promise<RegistrySnapshot> {
  const areas: WsEnvelope = await socket.query('config/area_registry/list');
  const devices: WsEnvelope = await socket.query('config/device_registry/list');
  const entities: WsEnvelope = await socket.query('config/entity_registry/list');
  return {
    areas: areas.result as RegistryArea[] ?? [],
    devices: devices.result as RegistryDevice[] ?? [],
    entities: entities.result as RegistryEntity[] ?? []
  };
}
