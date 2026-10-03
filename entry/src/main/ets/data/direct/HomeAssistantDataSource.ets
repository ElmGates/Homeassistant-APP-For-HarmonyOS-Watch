import { ALLOWED_SERVICES, HaDirectClient, HaEntityState, ServiceData } from './HaDirectClient';
import { DeviceItem, DeviceGroup, HomeAssistantSnapshot, RoomSummary, UNASSIGNED_ROOM } from './HomeAssistantModels';
import { loadRegistry, RegistrySnapshot, RegistryArea, RegistryDevice, RegistryEntity } from './RegistryLoader';
import { HaSocket } from './HaSocket';

// Primary-entity priority inside a physical device; earlier entries become the device's main control.
// Appliance domains rank before plain switches: vendor integrations often attach many auxiliary
// switches (child lock, indicator light, eco mode…) to an air conditioner or lamp.
const DOMAIN_RANK: string[] = ['climate', 'light', 'cover', 'fan', 'humidifier', 'media_player', 'vacuum', 'lock',
  'switch', 'input_boolean', 'select', 'input_select', 'number', 'input_number', 'button', 'input_button', 'scene',
  'script', 'automation', 'binary_sensor', 'sensor'];

export class HomeAssistantDataSource {
  private client: HaDirectClient;
  private server: string;
  private token: string;
  private areaByEntity: Map<string, string> = new Map<string, string>();
  private entityRegistry: Map<string, RegistryEntity> = new Map<string, RegistryEntity>();
  private deviceRegistry: Map<string, RegistryDevice> = new Map<string, RegistryDevice>();
  private registry: RegistrySnapshot | undefined = undefined;
  // Registry is re-read every 10 minutes; after a failure it is retried after 1 minute.
  private registryRetryAt: number = 0;
  private registryError: string = '';
  // Entities the watch actually shows, learned from the last full sync. Later syncs request only these.
  private wantedIds: string[] = [];

  constructor(server: string, token: string) {
    this.client = new HaDirectClient(server, token);
    this.server = server;
    this.token = token;
  }

  async load(): Promise<HomeAssistantSnapshot> {
    // One WebSocket session per sync: registry (every 10 min) + compact entity states. The full entity list
    // is requested together with a registry refresh (to discover new entities); otherwise only wantedIds.
    // If the socket fails, states fall back to the REST list so the watch always syncs.
    const refreshRegistry: boolean = Date.now() >= this.registryRetryAt;
    let registryTried: boolean = false;
    let states: HaEntityState[] | undefined = undefined;
    const socket: HaSocket = new HaSocket(this.token);
    try {
      await socket.open(this.server);
      if (refreshRegistry) {
        registryTried = true;
        try {
          this.registry = await loadRegistry(socket);
          this.registryError = '';
          this.registryRetryAt = Date.now() + 600000;
        } catch (error) {
          this.registryFailed(error as Object);
        }
      }
      states = await socket.entityStates(refreshRegistry || this.wantedIds.length === 0 ? undefined : this.wantedIds);
    } catch (error) {
      if (refreshRegistry && !registryTried) this.registryFailed(error as Object);
    } finally {
      await socket.close();
    }
    if (!states) states = await this.client.listStates();
    const registry: RegistrySnapshot | undefined = this.registry;
    this.areaByEntity.clear();
    this.entityRegistry.clear();
    this.deviceRegistry.clear();
    const rooms: RoomSummary[] = [];
    if (registry) {
      const deviceArea: Map<string, string> = new Map<string, string>();
      registry.devices.forEach((device: RegistryDevice) => {
        this.deviceRegistry.set(device.id, device);
        if (device.area_id) deviceArea.set(device.id, device.area_id);
      });
      registry.entities.forEach((entity: RegistryEntity) => {
        this.entityRegistry.set(entity.entity_id, entity);
        if (entity.disabled_by || entity.hidden_by) return;
        const areaId: string | undefined = entity.area_id ??
          (entity.device_id ? deviceArea.get(entity.device_id) : undefined);
        if (areaId) this.areaByEntity.set(entity.entity_id, areaId);
      });
      registry.areas.forEach((area: RegistryArea) => {
        rooms.push({ id: area.area_id, name: area.name, count: 0, icon: area.icon ?? undefined });
      });
    }
    const devices: DeviceItem[] = states
      .filter((state: HaEntityState) => this.isShownState(state) && this.isVisible(state.entity_id))
      .map((state: HaEntityState) => this.mapState(state));
    // Automations are rules, not devices: they live only on the 场景 card, never in rooms.
    // Without a room, scenes/scripts (also on the 场景 card) and device-less sensors (template/statistics
    // readings) are noise; only real devices stay in 其他设备.
    const groups: DeviceGroup[] = this.groupDevices(devices.filter((item: DeviceItem) => item.domain !== 'automation'))
      .filter((group: DeviceGroup) => group.areaId !== UNASSIGNED_ROOM || this.keepWithoutRoom(group, devices));
    // Next syncs only ask HA for what the watch shows: grouped entities plus everything on the 场景 card.
    const wanted: string[] = [];
    groups.forEach((group: DeviceGroup) => group.entityIds.forEach((id: string) => { wanted.push(id); }));
    devices.forEach((item: DeviceItem) => {
      const runnable: boolean = item.domain === 'scene' || item.domain === 'script' || item.domain === 'automation';
      if (runnable && !wanted.includes(item.entityId)) wanted.push(item.entityId);
    });
    this.wantedIds = wanted;
    groups.forEach((group: DeviceGroup) => {
      const room: RoomSummary | undefined = rooms.find((item: RoomSummary) => item.id === group.areaId);
      if (room) room.count++;
    });
    const unassignedCount: number = groups.filter((group: DeviceGroup) => group.areaId === UNASSIGNED_ROOM).length;
    if (unassignedCount > 0 || rooms.length === 0) {
      rooms.push({ id: UNASSIGNED_ROOM, name: registry ? '其他设备' : '设备（房间暂不可用）', count: unassignedCount });
    }
    // Real rooms by name; the catch-all room always last.
    rooms.sort((a: RoomSummary, b: RoomSummary) => {
      if (a.id === UNASSIGNED_ROOM) return 1;
      if (b.id === UNASSIGNED_ROOM) return -1;
      return a.name.localeCompare(b.name);
    });
    devices.sort((a: DeviceItem, b: DeviceItem) => a.name.localeCompare(b.name));
    groups.sort((a: DeviceGroup, b: DeviceGroup) => a.name.localeCompare(b.name));
    return { rooms, devices, groups, fetchedAt: Date.now(), roomSource: registry ? 'registry' : 'unavailable',
      registryError: registry ? undefined : this.registryError };
  }

  async readEntity(entityId: string): Promise<DeviceItem> {
    return this.mapState(await this.client.readEntity(entityId));
  }

  async callService(domain: string, service: string, entityId: string,
    data?: ServiceData): Promise<void> {
    await this.client.callService(domain, service, entityId, data);
  }

  private mapState(state: HaEntityState): DeviceItem {
    const domain: string = state.entity_id.split('.')[0];
    const registry: RegistryEntity | undefined = this.entityRegistry.get(state.entity_id);
    return {
      entityId: state.entity_id,
      name: state.attributes?.friendly_name ?? state.entity_id,
      itemName: registry?.name ?? registry?.original_name,
      domain,
      state: state.state,
      areaId: this.areaByEntity.get(state.entity_id) ?? UNASSIGNED_ROOM,
      deviceId: registry?.device_id,
      entityCategory: registry?.entity_category,
      available: state.state !== 'unavailable' && state.state !== 'unknown',
      attributes: state.attributes
    };
  }

  // REST states are still useful without the registry; the UI labels room mapping as unavailable.
  private registryFailed(error: Object): void {
    const message: string = error instanceof Error ? error.message : '';
    this.registryError = message && message !== '[object Object]' ? message : '房间数据读取失败';
    this.registryRetryAt = Date.now() + 60000;
  }

  private keepWithoutRoom(group: DeviceGroup, devices: DeviceItem[]): boolean {
    if (group.id.startsWith('device:')) return true;
    const item: DeviceItem | undefined = devices.find((device: DeviceItem) => device.entityId === group.primaryEntityId);
    if (!item) return false;
    return !['scene', 'script', 'sensor', 'binary_sensor'].includes(item.domain);
  }

  private isVisible(entityId: string): boolean {
    const entry: RegistryEntity | undefined = this.entityRegistry.get(entityId);
    const device: RegistryDevice | undefined = entry?.device_id ? this.deviceRegistry.get(entry.device_id) : undefined;
    // Service "devices" (Backup, weather forecast, TTS…) are HA internals, not hardware to control.
    return !entry?.disabled_by && !entry?.hidden_by && device?.entry_type !== 'service' &&
      entry?.entity_category !== 'diagnostic' && entry?.entity_category !== 'config';
  }

  private groupDevices(entities: DeviceItem[]): DeviceGroup[] {
    const byId: Map<string, DeviceGroup> = new Map<string, DeviceGroup>();
    entities.forEach((entity: DeviceItem) => {
      const id: string = entity.deviceId ? 'device:' + entity.deviceId : 'entity:' + entity.entityId;
      let group: DeviceGroup | undefined = byId.get(id);
      if (!group) {
        const registry: RegistryDevice | undefined = entity.deviceId ? this.deviceRegistry.get(entity.deviceId) : undefined;
        group = {
          id,
          name: registry?.name_by_user ?? registry?.name ?? entity.name,
          originalName: registry?.name,
          areaId: registry?.area_id ?? entity.areaId,
          primaryEntityId: entity.entityId,
          entityIds: []
        };
        byId.set(id, group);
      }
      group.entityIds.push(entity.entityId);
      const currentPrimary: DeviceItem | undefined = entities.find((item: DeviceItem) => item.entityId === group!.primaryEntityId);
      if (currentPrimary && this.rank(entity.domain) < this.rank(currentPrimary.domain)) {
        group.primaryEntityId = entity.entityId;
      }
    });
    return Array.from(byId.values());
  }

  private rank(domain: string): number {
    const position: number = DOMAIN_RANK.indexOf(domain);
    return position < 0 ? DOMAIN_RANK.length : position;
  }

  private isShownState(state: HaEntityState): boolean {
    const domain: string = state.entity_id.split('.')[0];
    if (domain !== 'sensor' && domain !== 'binary_sensor' && ALLOWED_SERVICES[domain] === undefined) {
      return false;
    }
    if (domain === 'select' || domain === 'input_select') {
      return state.state !== 'unavailable' && state.state !== 'unknown' &&
        (state.attributes?.options?.length ?? 0) > 0;
    }
    return true;
  }
}
