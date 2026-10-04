import { ALLOWED_SERVICES, HaDirectClient, HaEntityState, ServiceData } from './HaDirectClient';
import { DeviceItem, DeviceGroup, HomeAssistantSnapshot, RoomSummary, UNASSIGNED_ROOM } from './HomeAssistantModels';
import { loadRegistry, RegistrySnapshot, RegistryArea, RegistryDevice, RegistryEntity } from './RegistryLoader';
import { HaSocket } from './HaSocket';

// What the data source remembers across app launches, so a cold start can sync only the states of what
// the watch shows (one small request) instead of re-reading the whole registry and every entity.
export interface DataSourceCache {
  registry: RegistrySnapshot;
  registryAt: number;
  wantedIds: string[];
}

// The registry (areas, devices, entities) changes rarely; re-reading it often costs a lot over the phone's
// Bluetooth on a large install.
const REGISTRY_MAX_AGE_MS: number = 1800000;
// An idle shared WebSocket is closed after this long.
const SESSION_IDLE_MS: number = 45000;
// After the WebSocket failed (proxy without WebSocket support, …), use REST for a while.
const SOCKET_BACKOFF_MS: number = 60000;

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
  // When the registry was read, and when it is due again (after a failure: retried after 1 minute).
  private registryAt: number = 0;
  private registryRetryAt: number = 0;
  private registryError: string = '';
  // Entities the watch actually shows, learned from the last sync. Later syncs request only these.
  private wantedIds: string[] = [];
  // Shared WebSocket session (see HaSocket) and its idle timer.
  private live: HaSocket | undefined = undefined;
  private idleTimer: number = -1;
  private socketBackoffUntil: number = 0;

  constructor(server: string, token: string) {
    this.client = new HaDirectClient(server, token);
    this.server = server;
    this.token = token;
  }

  // Switches address (LAN ↔ remote) or access token while keeping the registry and the wanted entities.
  retarget(server: string, token: string): void {
    if (server === this.server && token === this.token) return;
    this.dropSession();
    this.client = new HaDirectClient(server, token);
    this.server = server;
    this.token = token;
    this.socketBackoffUntil = 0;
  }

  importCache(cache: DataSourceCache): void {
    if (!cache.registry || !Array.isArray(cache.registry.entities)) return;
    this.registry = cache.registry;
    this.registryAt = cache.registryAt;
    this.registryRetryAt = cache.registryAt + REGISTRY_MAX_AGE_MS;
    this.wantedIds = Array.isArray(cache.wantedIds) ? cache.wantedIds : [];
  }

  exportCache(): DataSourceCache | undefined {
    if (!this.registry) return undefined;
    return { registry: this.registry, registryAt: this.registryAt, wantedIds: this.wantedIds };
  }

  hasRegistry(): boolean {
    return this.registry !== undefined && this.wantedIds.length > 0;
  }

  registryStale(): boolean {
    return Date.now() >= this.registryRetryAt;
  }

  // Makes the next load() re-read the registry (Settings → 重新同步).
  forceRegistry(): void {
    this.registryRetryAt = 0;
  }

  close(): void {
    this.dropSession();
  }

  // The shared session, opened on demand. Undefined while the WebSocket is backing off.
  private async session(): Promise<HaSocket | undefined> {
    if (Date.now() < this.socketBackoffUntil) return undefined;
    if (this.live && this.live.isOpen()) {
      this.touchSession();
      return this.live;
    }
    this.dropSession();
    const socket: HaSocket = new HaSocket(this.token);
    try {
      await socket.open(this.server);
    } catch (error) {
      try { await socket.close(); } catch (_) {}
      this.socketBackoffUntil = Date.now() + SOCKET_BACKOFF_MS;
      throw error as Error;
    }
    this.live = socket;
    this.touchSession();
    return socket;
  }

  private touchSession(): void {
    if (this.idleTimer >= 0) clearTimeout(this.idleTimer);
    this.idleTimer = setTimeout(() => this.dropSession(), SESSION_IDLE_MS);
  }

  private dropSession(): void {
    if (this.idleTimer >= 0) clearTimeout(this.idleTimer);
    this.idleTimer = -1;
    const socket: HaSocket | undefined = this.live;
    this.live = undefined;
    if (socket) socket.close().catch(() => {});
  }

  // Entities worth asking HA about after a registry refresh: what the watch showed last time plus every
  // registry entity of a shown domain (to discover new devices) — instead of the full state list.
  private candidateIds(): string[] | undefined {
    if (!this.registry || this.wantedIds.length === 0) return undefined;
    const ids: string[] = this.wantedIds.slice();
    const services: Map<string, RegistryDevice> = new Map<string, RegistryDevice>();
    this.registry.devices.forEach((device: RegistryDevice) => {
      if (device.entry_type === 'service') services.set(device.id, device);
    });
    this.registry.entities.forEach((entity: RegistryEntity) => {
      if (entity.disabled_by || entity.hidden_by) return;
      if (entity.entity_category === 'diagnostic' || entity.entity_category === 'config') return;
      if (entity.device_id && services.has(entity.device_id)) return;
      if (!isShownDomain(entity.entity_id.split('.')[0])) return;
      if (!ids.includes(entity.entity_id)) ids.push(entity.entity_id);
    });
    return ids;
  }

  // `quick`: states of the shown entities only, even if the registry is due (used right after a cold start
  // with a cached registry; the caller refreshes the registry in the background afterwards).
  async load(quick: boolean = false): Promise<HomeAssistantSnapshot> {
    // Over the shared WebSocket: the registry when due, then compact states of the shown entities (plus
    // the registry's candidates after a registry refresh; everything only on the very first sync).
    // If the socket fails, states fall back to the REST list so the watch always syncs.
    const refreshRegistry: boolean = !(quick && this.hasRegistry()) && Date.now() >= this.registryRetryAt;
    let registryTried: boolean = false;
    let states: HaEntityState[] | undefined = undefined;
    try {
      const socket: HaSocket | undefined = await this.session();
      if (socket) {
        if (refreshRegistry) {
          registryTried = true;
          try {
            this.registry = trimRegistry(await loadRegistry(socket));
            this.registryError = '';
            this.registryAt = Date.now();
            this.registryRetryAt = this.registryAt + REGISTRY_MAX_AGE_MS;
          } catch (error) {
            this.registryFailed(error as Object);
          }
        }
        const ids: string[] | undefined = refreshRegistry ? this.candidateIds() :
          (this.wantedIds.length > 0 ? this.wantedIds : undefined);
        states = await socket.entityStates(ids);
      }
    } catch (error) {
      this.dropSession();
      if (refreshRegistry && !registryTried) this.registryFailed(error as Object);
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
    try {
      const socket: HaSocket | undefined = await this.session();
      if (socket) {
        const states: HaEntityState[] = await socket.entityStates([entityId]);
        const found: HaEntityState | undefined = states.find((state: HaEntityState) => state.entity_id === entityId);
        if (found) return this.mapState(found);
      }
    } catch (_) {
      this.dropSession();
    }
    return this.mapState(await this.client.readEntity(entityId));
  }

  async callService(domain: string, service: string, entityId: string,
    data?: ServiceData): Promise<void> {
    const allowed: string[] | undefined = ALLOWED_SERVICES[domain];
    if (!allowed || !allowed.includes(service)) throw new Error('不支持的设备操作');
    let socket: HaSocket | undefined = undefined;
    try {
      socket = await this.session();
    } catch (_) {
      socket = undefined;
    }
    if (!socket) {
      await this.client.callService(domain, service, entityId, data);
      return;
    }
    // Once sent, a command is never repeated over REST: it could switch a device twice.
    try {
      await socket.callService(domain, service, entityId, data);
    } catch (error) {
      this.dropSession();
      throw error as Error;
    }
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
    if (!isShownDomain(domain)) return false;
    if (domain === 'select' || domain === 'input_select') {
      return state.state !== 'unavailable' && state.state !== 'unknown' &&
        (state.attributes?.options?.length ?? 0) > 0;
    }
    return true;
  }
}

function isShownDomain(domain: string): boolean {
  return domain === 'sensor' || domain === 'binary_sensor' || ALLOWED_SERVICES[domain] !== undefined;
}

// Keeps only the registry fields and entities the watch uses: smaller in memory and in the cache.
function trimRegistry(full: RegistrySnapshot): RegistrySnapshot {
  return {
    areas: full.areas.map((area: RegistryArea): RegistryArea =>
      ({ area_id: area.area_id, name: area.name, icon: area.icon })),
    devices: full.devices.map((device: RegistryDevice): RegistryDevice => ({
      id: device.id, area_id: device.area_id, name: device.name, name_by_user: device.name_by_user,
      entry_type: device.entry_type
    })),
    entities: full.entities
      .filter((entity: RegistryEntity) => isShownDomain(entity.entity_id.split('.')[0]))
      .map((entity: RegistryEntity): RegistryEntity => ({
        entity_id: entity.entity_id, name: entity.name, original_name: entity.original_name,
        area_id: entity.area_id, device_id: entity.device_id, disabled_by: entity.disabled_by,
        hidden_by: entity.hidden_by, entity_category: entity.entity_category
      }))
  };
}
