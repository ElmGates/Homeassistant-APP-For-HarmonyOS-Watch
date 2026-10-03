import { HomeAssistantDataSource } from '../../data/direct/HomeAssistantDataSource';
import { DeviceItem, DeviceGroup, HomeAssistantSnapshot, RoomSummary } from '../../data/direct/HomeAssistantModels';
import { ServiceData } from '../../data/direct/HaDirectClient';
import { common } from '@kit.AbilityKit';
import { CredentialStore, ConnectionCredentials } from '../../data/security/CredentialStore';
import { SnapshotCache } from '../../data/cache/SnapshotCache';
import { isTransientNetworkError, safeError } from '../../core/utils/SafeError';
import { HaAuthClient, HaSession, LoginStep } from '../../data/direct/HaAuthClient';
import { FavoritesStore } from '../../data/cache/FavoritesStore';
import { LoginHintStore } from '../../data/cache/LoginHintStore';
import { isToggleDomain, quickAction, QuickAction } from '../ui/DomainUi';

@ObservedV2
export class DirectStore {
  @Trace rooms: RoomSummary[] = [];
  @Trace devices: DeviceItem[] = [];
  @Trace groups: DeviceGroup[] = [];
  @Trace configured: boolean = false;
  @Trace loading: boolean = false;
  @Trace actionEntityId: string = '';
  @Trace message: string = '';
  @Trace lastError: string = '';
  @Trace fetchedAt: number = 0;
  @Trace roomSource: string = 'unavailable';
  @Trace registryError: string = '';
  @Trace online: boolean = false;
  @Trace credentialsPersisted: boolean = false;
  @Trace mfaRequired: boolean = false;
  @Trace favorites: string[] = [];
  // Last HA address that logged in, used to prefill the login forms.
  @Trace lastServer: string = '';
  private source: HomeAssistantDataSource | undefined = undefined;
  private credentials: CredentialStore | undefined = undefined;
  private cache: SnapshotCache | undefined = undefined;
  private favoriteStore: FavoritesStore | undefined = undefined;
  private loginHint: LoginHintStore | undefined = undefined;
  private server: string = '';
  private refreshToken: string = '';
  private accessToken: string = '';
  private expiresAt: number = 0;
  private allowLocalHttp: boolean = false;
  private mfaFlowId: string = '';
  private mfaField: string = '';
  private refreshing: Promise<void> | undefined = undefined;

  async restore(ctx: common.UIAbilityContext): Promise<void> {
    this.credentials = new CredentialStore(ctx);
    this.cache = new SnapshotCache(ctx);
    this.favoriteStore = new FavoritesStore(ctx);
    this.loginHint = new LoginHintStore(ctx);
    try {
      this.lastServer = await this.loginHint.load();
    } catch (_) {
      this.lastServer = '';
    }
    try {
      this.favorites = await this.favoriteStore.load();
    } catch (_) {
      this.favorites = [];
    }
    const saved: ConnectionCredentials | undefined = await this.credentials.load();
    if (!saved) {
      await this.cache.clear();
      return;
    }
    this.server = saved.server;
    this.refreshToken = saved.refreshToken;
    this.allowLocalHttp = saved.allowLocalHttp;
    this.configured = true;
    this.credentialsPersisted = true;
    const cached: HomeAssistantSnapshot | undefined = await this.cache.load();
    if (cached) {
      this.applySnapshot(cached);
      this.message = '缓存数据，正在同步';
    }
  }

  async configure(server: string, username: string, password: string,
    allowLocalHttp: boolean): Promise<void> {
    this.loading = true;
    this.lastError = '';
    this.mfaRequired = false;
    try {
      const auth: HaAuthClient = new HaAuthClient(server);
      const step: LoginStep = await auth.login(username, password, allowLocalHttp);
      if (step.session) {
        await this.completeLogin(auth.server, step.session, allowLocalHttp);
      } else if (step.mfaFlowId && step.mfaField) {
        this.server = auth.server;
        this.allowLocalHttp = allowLocalHttp;
        this.mfaFlowId = step.mfaFlowId;
        this.mfaField = step.mfaField;
        this.mfaRequired = true;
        this.message = '请输入 HA 验证码';
      }
    } finally {
      this.loading = false;
    }
  }

  async submitMfa(code: string): Promise<void> {
    if (!this.mfaRequired || this.loading) return;
    this.loading = true;
    this.lastError = '';
    try {
      const session: HaSession = await new HaAuthClient(this.server).submitMfa(
        this.mfaFlowId, this.mfaField, code);
      await this.completeLogin(this.server, session, this.allowLocalHttp);
    } finally {
      this.loading = false;
    }
  }

  cancelMfa(): void {
    this.mfaRequired = false;
    this.mfaFlowId = '';
    this.mfaField = '';
  }

  private async completeLogin(server: string, session: HaSession, allowLocalHttp: boolean): Promise<void> {
    this.server = server;
    this.refreshToken = session.refreshToken;
    this.expiresAt = session.expiresAt;
    this.allowLocalHttp = allowLocalHttp;
    this.accessToken = session.accessToken;
    this.source = new HomeAssistantDataSource(server, session.accessToken);
    this.configured = true;
    this.mfaRequired = false;
    this.mfaFlowId = '';
    this.mfaField = '';
    this.credentialsPersisted = false;
    this.lastServer = server;
    if (this.loginHint) {
      try { await this.loginHint.save(server); } catch (_) {}
    }
    if (this.credentials) {
      try {
        await this.credentials.save(server, session.refreshToken, allowLocalHttp);
        this.credentialsPersisted = true;
      } catch (error) {
        this.lastError = safeError(error, '安全存储失败') + '；仅本次会话可用，重启后需重新登录';
      }
    }
    try {
      const snapshot: HomeAssistantSnapshot = await this.source.load();
      this.applySnapshot(snapshot);
      this.online = true;
      this.message = '已同步';
      if (this.cache) {
        try { await this.cache.save(snapshot); } catch (_) {}
      }
    } catch (error) {
      this.online = false;
      this.lastError = safeError(error, '读取房间失败');
      this.message = '已登录，房间同步失败';
    }
  }

  // For the network diagnostics page: the server and a fresh access token (refreshing if needed).
  getServer(): string {
    return this.server;
  }

  async freshAccessToken(): Promise<string> {
    await this.ensureAccessToken();
    return this.accessToken;
  }

  private async ensureAccessToken(): Promise<void> {
    if (this.source && Date.now() + 60000 < this.expiresAt) return;
    if (this.refreshing) return await this.refreshing;
    this.refreshing = this.refreshAccessToken();
    try {
      await this.refreshing;
    } finally {
      this.refreshing = undefined;
    }
  }

  private async refreshAccessToken(): Promise<void> {
    if (!this.server || !this.refreshToken) throw new Error('请重新登录 HA');
    const session: HaSession = await new HaAuthClient(this.server).refresh(this.refreshToken);
    this.expiresAt = session.expiresAt;
    this.accessToken = session.accessToken;
    this.source = new HomeAssistantDataSource(this.server, session.accessToken);
  }

  async sync(): Promise<void> {
    if (!this.configured || this.loading) return;
    this.loading = true;
    this.lastError = '';
    try {
      await this.ensureAccessToken();
      const snapshot: HomeAssistantSnapshot = await this.source!.load();
      this.applySnapshot(snapshot);
      this.online = true;
      this.message = '已同步';
      if (this.cache) {
        try { await this.cache.save(snapshot); } catch (_) {}
      }
    } catch (error) {
      // One slow or dropped request shortly after a good sync is not an outage: keep controls usable
      // (each command reports its own failure) instead of locking everything into offline mode.
      const recent: boolean = this.online && Date.now() - this.fetchedAt < 120000;
      if (recent && isTransientNetworkError(error as Object)) {
        this.lastError = safeError(error, '同步失败');
        this.message = '本次同步未完成，显示刚才的数据';
      } else {
        this.online = false;
        this.lastError = safeError(error, '同步失败');
        this.message = '同步失败，显示上次数据';
      }
    } finally {
      this.loading = false;
    }
  }

  private applySnapshot(snapshot: HomeAssistantSnapshot): void {
    this.rooms = snapshot.rooms;
    this.devices = snapshot.devices;
    this.groups = snapshot.groups;
    this.fetchedAt = snapshot.fetchedAt;
    this.roomSource = snapshot.roomSource;
    this.registryError = snapshot.registryError ?? '';
  }

  // Re-sync when returning to the app or a page after the data has gone stale.
  async refreshIfStale(maxAgeMs: number): Promise<void> {
    if (!this.configured || this.loading || this.actionEntityId.length > 0) return;
    if (Date.now() - this.fetchedAt < maxAgeMs) return;
    await this.sync();
  }

  groupsInRoom(roomId: string): DeviceGroup[] {
    if (roomId === '__all__') return this.groups;
    return this.groups.filter((group: DeviceGroup) => group.areaId === roomId);
  }

  getGroup(groupId: string): DeviceGroup | undefined {
    return this.groups.find((group: DeviceGroup) => group.id === groupId);
  }

  entitiesInGroup(groupId: string): DeviceItem[] {
    const group: DeviceGroup | undefined = this.getGroup(groupId);
    if (!group) return [];
    return this.devices.filter((item: DeviceItem) => group.entityIds.includes(item.entityId));
  }

  getDevice(entityId: string): DeviceItem | undefined {
    return this.devices.find((device: DeviceItem) => device.entityId === entityId);
  }

  async refreshEntity(entityId: string): Promise<void> {
    if (!this.configured) return;
    try {
      await this.ensureAccessToken();
      const current: DeviceItem = await this.source!.readEntity(entityId);
      this.devices = this.devices.map((device: DeviceItem) =>
        device.entityId === entityId ? current : device);
      this.fetchedAt = Date.now();
      this.online = true;
    } catch (error) {
      this.online = false;
      this.lastError = safeError(error, '读取设备失败');
    }
  }

  async runService(device: DeviceItem, service: string, data?: ServiceData,
    expectedState?: string): Promise<void> {
    if (!this.configured || !this.online || this.actionEntityId.length > 0 || !device.available) return;
    this.actionEntityId = device.entityId;
    this.lastError = '';
    this.message = '正在发送…';
    try {
      await this.ensureAccessToken();
      await this.source!.callService(device.domain, service, device.entityId, data);
      this.message = 'HA 已接受，正在确认…';
      const delays: number[] = [0, 700, 1300, 2500];
      for (let i: number = 0; i < delays.length; i++) {
        if (delays[i] > 0) {
          await new Promise<void>((resolve: () => void) => setTimeout(resolve, delays[i]));
        }
        const updated: DeviceItem = await this.source!.readEntity(device.entityId);
        this.devices = this.devices.map((item: DeviceItem) =>
          item.entityId === device.entityId ? updated : item);
        this.fetchedAt = Date.now();
        if (!expectedState || updated.state === expectedState) {
          this.message = expectedState ? '设备状态已确认' : 'HA 已接受，状态已重新读取';
          return;
        }
      }
      this.message = 'HA 已接受，设备状态尚未确认';
    } catch (error) {
      this.online = false;
      this.lastError = safeError(error, '设备操作失败');
      this.message = '结果未知，请先刷新状态';
    } finally {
      this.actionEntityId = '';
    }
  }

  async runQuick(device: DeviceItem): Promise<void> {
    const action: QuickAction | undefined = quickAction(device);
    if (action) await this.runService(device, action.service, action.data, action.expectedState);
  }

  // Everything that can be "run": scenes first, then scripts, then automations; by name within each.
  runnables(): DeviceItem[] {
    const order: string[] = ['scene', 'script', 'automation'];
    return this.devices
      .filter((item: DeviceItem) => order.includes(item.domain))
      .sort((a: DeviceItem, b: DeviceItem) => {
        const byDomain: number = order.indexOf(a.domain) - order.indexOf(b.domain);
        return byDomain !== 0 ? byDomain : a.name.localeCompare(b.name);
      });
  }

  isFavorite(entityId: string): boolean {
    return this.favorites.includes(entityId);
  }

  favoriteDevices(): DeviceItem[] {
    const result: DeviceItem[] = [];
    this.favorites.forEach((id: string) => {
      const device: DeviceItem | undefined = this.getDevice(id);
      if (device) result.push(device);
    });
    return result;
  }

  async toggleFavorite(entityId: string): Promise<void> {
    const next: string[] = this.isFavorite(entityId) ?
      this.favorites.filter((id: string) => id !== entityId) : this.favorites.concat([entityId]);
    await this.saveFavorites(next);
  }

  async clearFavorites(): Promise<void> {
    await this.saveFavorites([]);
  }

  private async saveFavorites(ids: string[]): Promise<void> {
    this.favorites = ids;
    if (!this.favoriteStore) return;
    try {
      await this.favoriteStore.save(ids);
    } catch (error) {
      this.lastError = safeError(error, '常用设备保存失败');
    }
  }

  async toggle(device: DeviceItem): Promise<void> {
    if (!isToggleDomain(device.domain)) return;
    const target: string = device.state === 'on' ? 'off' : 'on';
    await this.runService(device, target === 'on' ? 'turn_on' : 'turn_off', undefined, target);
  }

  async clear(): Promise<void> {
    const server: string = this.server;
    const refreshToken: string = this.refreshToken;
    if (this.credentials) await this.credentials.clear();
    if (this.cache) await this.cache.clear();
    if (this.favoriteStore) await this.favoriteStore.clear();
    this.favorites = [];
    this.source = undefined;
    this.accessToken = '';
    this.server = '';
    this.refreshToken = '';
    this.expiresAt = 0;
    this.mfaRequired = false;
    this.configured = false;
    this.rooms = [];
    this.devices = [];
    this.groups = [];
    this.fetchedAt = 0;
    this.online = false;
    this.credentialsPersisted = false;
    this.message = '';
    this.lastError = '';
    if (server && refreshToken) {
      try { await new HaAuthClient(server).revoke(refreshToken); } catch (_) {}
    }
  }
}
