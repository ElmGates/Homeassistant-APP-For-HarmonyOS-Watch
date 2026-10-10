import { DataSourceCache, HomeAssistantDataSource } from '../../data/direct/HomeAssistantDataSource';
import { DeviceItem, DeviceGroup, HomeAssistantSnapshot, RoomSummary } from '../../data/direct/HomeAssistantModels';
import { ServiceData } from '../../data/direct/HaDirectClient';
import { common } from '@kit.AbilityKit';
import { CachedAccess, CredentialStore, ConnectionCredentials } from '../../data/security/CredentialStore';
import { SnapshotCache } from '../../data/cache/SnapshotCache';
import { RegistryCache } from '../../data/cache/RegistryCache';
import { AppPrefsStore } from '../../data/cache/AppPrefsStore';
import { isTransientNetworkError, safeError } from '../../core/utils/SafeError';
import { HaAuthClient, HaSession, LoginStep } from '../../data/direct/HaAuthClient';
import { FavoritesStore } from '../../data/cache/FavoritesStore';
import { LoginHintStore } from '../../data/cache/LoginHintStore';
import { isMajorDomain, isToggleDomain, quickAction, QuickAction } from '../ui/DomainUi';
import { WidgetBridge, WidgetForm, WidgetItem } from '../../data/widget/WidgetBridge';
import { onPreferredNetworkChange, startPreferringWifi, stopPreferringWifi, wifiBound } from '../../data/direct/WifiPreference';
import { answersLikeHa, chooseBaseUrl, detectLanUrl, forgetRoute, lanConfirmed, lanFailed,
  normalizeLanUrl } from '../../data/direct/LanRoute';

// Live updates (see DirectStore.setLive): retry after the subscription dropped, polling interval without a
// WebSocket, and how long pushed changes are collected before the screen updates.
const LIVE_RETRY_MS: number = 3000;
const LIVE_POLL_MS: number = 30000;
const LIVE_BATCH_MS: number = 400;

// HA answered but refused the command (a value or action the device does not accept): the connection is fine.
function isRejection(error: Object): boolean {
  const message: string = error instanceof Error ? error.message : '';
  return message === 'HA 请求被拒绝' || message === '不支持的设备操作' || message.startsWith('HA HTTP ');
}

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
  // Widget whose content the user asked to change (from the widget or the system's edit menu).
  @Trace pendingWidgetForm: string = '';
  // LAN address used on the home Wi-Fi ('' = not set), whether the user turned it off, and whether the
  // current connection goes through it.
  @Trace lanUrl: string = '';
  @Trace lanOff: boolean = false;
  @Trace lanActive: boolean = false;
  @Trace lanAuto: boolean = false;
  // Home card shown at launch: 0 常用 · 1 我的家 · 2 场景 · 3 更多.
  @Trace startPage: number = 1;
  // Version of the usage terms the user accepted (0 = not yet).
  @Trace acceptedTerms: number = -1;
  // Use the watch's Wi-Fi instead of the phone's Bluetooth while the app is open (see WifiPreference).
  @Trace preferWifi: boolean = true;
  // Whether requests currently go through that Wi-Fi.
  @Trace onWifi: boolean = false;
  // Outcome of the last command, shown briefly next to its control: entity ('' = none) and whether HA
  // accepted it.
  @Trace resultEntityId: string = '';
  @Trace resultOk: boolean = false;
  private source: HomeAssistantDataSource | undefined = undefined;
  private credentials: CredentialStore | undefined = undefined;
  private cache: SnapshotCache | undefined = undefined;
  private registryCache: RegistryCache | undefined = undefined;
  private appPrefs: AppPrefsStore | undefined = undefined;
  // Registry read at launch, handed to the data source once it exists.
  private pendingRegistry: DataSourceCache | undefined = undefined;
  private savedRegistryAt: number = 0;
  // The first sync after launch only refreshes the shown states (see HomeAssistantDataSource.load).
  private firstSync: boolean = true;
  // Pages ask for a refresh as soon as they show; at launch that must wait for loadCaches().
  private cachesLoaded: boolean = false;
  private favoriteStore: FavoritesStore | undefined = undefined;
  private loginHint: LoginHintStore | undefined = undefined;
  private widget: WidgetBridge | undefined = undefined;
  private server: string = '';
  private refreshToken: string = '';
  private accessToken: string = '';
  private expiresAt: number = 0;
  private allowLocalHttp: boolean = false;
  private mfaFlowId: string = '';
  private mfaField: string = '';
  private refreshing: Promise<void> | undefined = undefined;
  // Address requests currently go to: the LAN address or the remote one ('' until the first request).
  private activeBase: string = '';
  private lanDetectTried: boolean = false;
  // Live updates (see setLive).
  private liveWanted: boolean = false;
  private liveTimer: number = -1;
  private liveFlushTimer: number = -1;
  private livePending: Map<string, DeviceItem> = new Map<string, DeviceItem>();
  private liveChangedFavorite: boolean = false;
  private resultTimer: number = -1;

  async restore(ctx: common.UIAbilityContext): Promise<void> {
    this.credentials = new CredentialStore(ctx);
    this.cache = new SnapshotCache(ctx);
    this.registryCache = new RegistryCache(ctx);
    this.appPrefs = new AppPrefsStore(ctx);
    this.favoriteStore = new FavoritesStore(ctx);
    this.loginHint = new LoginHintStore(ctx);
    this.widget = new WidgetBridge(ctx);
    try {
      this.lastServer = await this.loginHint.load();
    } catch (_) {
      this.lastServer = '';
    }
    try {
      this.startPage = await this.appPrefs.startPage();
      this.preferWifi = await this.appPrefs.preferWifi();
      this.acceptedTerms = await this.appPrefs.acceptedTerms();
    } catch (_) {
      this.acceptedTerms = 0;
    }
    try {
      this.favorites = await this.favoriteStore.load();
    } catch (_) {
      this.favorites = [];
    }
    const saved: ConnectionCredentials | undefined = await this.credentials.load();
    if (!saved) {
      await this.cache.clear();
      await this.registryCache.clear();
      this.pushWidget();
      return;
    }
    this.server = saved.server;
    this.refreshToken = saved.refreshToken;
    this.allowLocalHttp = saved.allowLocalHttp;
    this.lanUrl = saved.lanUrl;
    this.lanOff = saved.lanOff;
    this.lanAuto = saved.lanAuto;
    this.configured = true;
    this.credentialsPersisted = true;
    try {
      const access: CachedAccess | undefined = await this.credentials.loadAccess();
      if (access) {
        this.accessToken = access.token;
        this.expiresAt = access.expiresAt;
        this.source = this.newSource(this.server, access.token);
        this.activeBase = this.server;
      }
    } catch (_) {
      // A token that cannot be read is simply exchanged again.
    }
  }

  // Second half of the launch, after the first screen is shown: last snapshot and registry from disk.
  async loadCaches(): Promise<void> {
    try {
      await this.readCaches();
    } finally {
      this.cachesLoaded = true;
    }
  }

  private async readCaches(): Promise<void> {
    if (!this.configured) return;
    try {
      const cached: HomeAssistantSnapshot | undefined = await this.cache?.load();
      if (cached && this.fetchedAt === 0) {
        this.applySnapshot(cached);
        this.message = '缓存数据，正在同步';
      }
    } catch (_) {
      // Missing cache: the sync fills the screen.
    }
    try {
      const registry: DataSourceCache | undefined = await this.registryCache?.load();
      if (registry) {
        this.savedRegistryAt = registry.registryAt;
        if (this.source) {
          this.source.importCache(registry);
        } else {
          this.pendingRegistry = registry;
        }
      }
    } catch (_) {
      // Without it the first sync reads the registry.
    }
    this.pushWidget();
  }

  private newSource(base: string, token: string): HomeAssistantDataSource {
    const source: HomeAssistantDataSource = new HomeAssistantDataSource(base, token);
    if (this.pendingRegistry) {
      source.importCache(this.pendingRegistry);
      this.pendingRegistry = undefined;
    }
    return source;
  }

  // Keeps the registry for the next launch whenever it was re-read.
  private saveRegistry(): void {
    const cache: DataSourceCache | undefined = this.source?.exportCache();
    if (!cache || !this.registryCache || cache.registryAt === this.savedRegistryAt) return;
    this.savedRegistryAt = cache.registryAt;
    this.registryCache.save(cache).catch(() => {});
  }

  // Live updates while the app is in the foreground: states pushed by HA over the shared WebSocket (a
  // curtain's position while it moves, changes made from elsewhere). Without a WebSocket, polls instead.
  setLive(on: boolean): void {
    this.liveWanted = on;
    if (on) {
      this.scheduleLive(0);
      return;
    }
    if (this.liveTimer >= 0) clearTimeout(this.liveTimer);
    this.liveTimer = -1;
    this.source?.stopLive();
    this.flushLive();
    if (this.liveChangedFavorite) {
      this.liveChangedFavorite = false;
      this.pushWidget();
    }
  }

  private scheduleLive(delayMs: number): void {
    if (!this.liveWanted) return;
    if (this.liveTimer >= 0) clearTimeout(this.liveTimer);
    this.liveTimer = setTimeout(() => {
      this.liveTimer = -1;
      this.startLive();
    }, delayMs);
  }

  private async startLive(): Promise<void> {
    if (!this.liveWanted || !this.configured) return;
    // Wait for the launch caches and for a running sync or command (it may switch address or token).
    if (!this.cachesLoaded || this.loading || this.actionEntityId.length > 0) {
      this.scheduleLive(2000);
      return;
    }
    let live: boolean = false;
    try {
      await this.prepare();
      if (this.source && this.liveWanted) {
        live = await this.source.startLive((items: DeviceItem[]) => this.queueLive(items),
          () => this.scheduleLive(LIVE_RETRY_MS));
        // The app went to the background while the subscription was being set up.
        if (live && !this.liveWanted) {
          this.source.stopLive();
          return;
        }
      }
    } catch (_) {
      live = false;
    }
    if (!live && this.liveWanted && this.configured) {
      // No WebSocket right now (or no devices yet): poll, and try the subscription again later.
      this.refreshIfStale(LIVE_POLL_MS);
      this.scheduleLive(LIVE_POLL_MS);
    }
  }

  // Changes often come in bursts (a moving curtain, several sensors): apply them together.
  private queueLive(items: DeviceItem[]): void {
    items.forEach((item: DeviceItem) => { this.livePending.set(item.entityId, item); });
    if (this.liveFlushTimer >= 0) return;
    this.liveFlushTimer = setTimeout(() => {
      this.liveFlushTimer = -1;
      this.flushLive();
    }, LIVE_BATCH_MS);
  }

  private flushLive(): void {
    if (this.liveFlushTimer >= 0) clearTimeout(this.liveFlushTimer);
    this.liveFlushTimer = -1;
    if (this.livePending.size === 0) return;
    const pending: Map<string, DeviceItem> = this.livePending;
    this.livePending = new Map<string, DeviceItem>();
    let changed: boolean = false;
    const devices: DeviceItem[] = this.devices.map((device: DeviceItem) => {
      const update: DeviceItem | undefined = pending.get(device.entityId);
      if (!update) return device;
      changed = true;
      if (this.isFavorite(device.entityId)) this.liveChangedFavorite = true;
      return update;
    });
    if (!changed) return;
    this.devices = devices;
    this.fetchedAt = Date.now();
    this.online = true;
  }

  // App in the foreground: ask for Wi-Fi (if preferred). In the background: release it to save power.
  networkForeground(foreground: boolean): void {
    onPreferredNetworkChange(() => this.onNetworkChanged());
    if (foreground && this.preferWifi) {
      startPreferringWifi();
    } else {
      stopPreferringWifi();
    }
  }

  async setPreferWifi(on: boolean): Promise<void> {
    this.preferWifi = on;
    this.networkForeground(true);
    if (this.appPrefs) await this.appPrefs.setPreferWifi(on);
  }

  // The app switched between the bound Wi-Fi and the default network: requests now take another path, so
  // drop the open WebSocket and re-sync (over the LAN when the new network reaches it).
  private onNetworkChanged(): void {
    this.onWifi = wifiBound();
    forgetRoute();
    // A sync or command in flight finishes on the old path; the next one takes the new route.
    if (this.loading || this.actionEntityId.length > 0) return;
    this.source?.close();
    if (this.configured && this.cachesLoaded) this.sync();
  }

  async setStartPage(page: number): Promise<void> {
    this.startPage = page;
    if (this.appPrefs) await this.appPrefs.setStartPage(page);
  }

  async acceptTerms(version: number): Promise<void> {
    this.acceptedTerms = version;
    if (this.appPrefs) await this.appPrefs.acceptTerms(version);
  }

  // Settings → 重新同步: also re-reads rooms and devices.
  async fullSync(): Promise<void> {
    this.source?.forceRegistry();
    await this.sync();
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
    this.source?.close();
    this.source = this.newSource(server, session.accessToken);
    this.activeBase = server;
    this.firstSync = false;
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
        this.credentials.saveAccess(session.accessToken, session.expiresAt).catch(() => {});
        this.credentialsPersisted = true;
      } catch (error) {
        this.lastError = safeError(error, '安全存储失败') + '；仅本次会话可用，重启后需重新登录';
      }
    }
    try {
      const snapshot: HomeAssistantSnapshot = await this.source.load();
      this.applySnapshot(snapshot);
      this.saveRegistry();
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
    this.pushWidget();
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
    const session: HaSession = await new HaAuthClient(this.base(), this.server).refresh(this.refreshToken);
    this.expiresAt = session.expiresAt;
    this.accessToken = session.accessToken;
    if (this.source) {
      this.source.retarget(this.base(), session.accessToken);
    } else {
      this.source = this.newSource(this.base(), session.accessToken);
    }
    this.credentials?.saveAccess(session.accessToken, session.expiresAt).catch(() => {});
  }

  private base(): string {
    return this.activeBase || this.server;
  }

  // Picks LAN or remote for this request (cached per network) and makes sure the token is fresh.
  private async prepare(): Promise<void> {
    const base: string = await chooseBaseUrl(this.server, this.lanOff ? '' : this.lanUrl);
    this.lanActive = base !== this.server;
    if (base !== this.activeBase) {
      this.activeBase = base;
      if (this.source && this.accessToken) this.source.retarget(base, this.accessToken);
    }
    await this.ensureAccessToken();
  }

  // Asks HA for its LAN address. With `save`, a found address is stored and used right away (when none is
  // set, or replacing an automatically found one); otherwise it is returned as a suggestion.
  async detectLan(save: boolean = false): Promise<string> {
    await this.ensureAccessToken();
    const url: string = await detectLanUrl(this.server, this.accessToken);
    if (save && url && url !== this.lanUrl && !this.lanOff && (!this.lanUrl || this.lanAuto)) {
      await this.storeLan(url, false, true);
    }
    return url;
  }

  // Saves a LAN address (`auto`: the one HA reported). Resolves true when the watch can use it right now.
  async setLanUrl(value: string, auto: boolean = false): Promise<boolean> {
    const url: string = normalizeLanUrl(value, this.server);
    if (!url) throw new Error('请输入局域网地址，例如 http://192.168.1.10:8123');
    await this.storeLan(url, false, auto);
    // Wait for the full answer here (the user is looking at the result), however slow the link is.
    const reachable: boolean = await answersLikeHa(url);
    if (reachable) lanConfirmed(url);
    await this.prepare();
    return reachable;
  }

  async turnOffLan(): Promise<void> {
    await this.storeLan(this.lanUrl, true, this.lanAuto);
    await this.prepare();
  }

  private async storeLan(url: string, off: boolean, auto: boolean): Promise<void> {
    this.lanUrl = url;
    this.lanOff = off;
    this.lanAuto = auto;
    forgetRoute();
    if (this.credentials) await this.credentials.saveLan(url, off, auto);
  }

  async sync(): Promise<void> {
    if (!this.configured || this.loading) return;
    this.loading = true;
    this.lastError = '';
    try {
      const quick: boolean = this.firstSync;
      this.firstSync = false;
      let snapshot: HomeAssistantSnapshot;
      try {
        await this.prepare();
        snapshot = await this.source!.load(quick);
      } catch (error) {
        const message: string = error instanceof Error ? error.message : '';
        if (message === '登录已失效，请重新登录' || message === 'WebSocket 认证失败') {
          // The access token kept from the last launch was revoked: exchange a new one and retry once.
          this.expiresAt = 0;
        } else if (this.lanActive) {
          // The LAN address stopped answering (left home, Wi-Fi changed): retry once over the remote address.
          lanFailed(this.server, this.lanUrl);
        } else {
          throw error as Error;
        }
        await this.prepare();
        snapshot = await this.source!.load(quick);
      }
      this.applySnapshot(snapshot);
      this.saveRegistry();
      // Launch synced only the shown states; rooms and new devices follow a moment later.
      if (quick && this.source?.registryStale()) {
        setTimeout(() => { this.sync(); }, 3000);
      }
      this.online = true;
      this.message = '已同步';
      if (this.cache) {
        try { await this.cache.save(snapshot); } catch (_) {}
      }
      // Once per launch: find the LAN address, or follow HA when its IP changed (only for an address that
      // was found automatically and does not answer; one typed by the user is kept).
      if (!this.lanOff && (!this.lanUrl || (this.lanAuto && !this.lanActive)) && !this.lanDetectTried) {
        this.lanDetectTried = true;
        this.detectLan(true).catch(() => {});
      }
      // The shown entities may have changed (new devices, rooms): subscribe to the current set.
      this.scheduleLive(500);
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
      this.pushWidget();
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
    if (!this.configured || !this.cachesLoaded || this.loading || this.actionEntityId.length > 0) return;
    if (this.source?.isLive()) return;
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
      await this.prepare();
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

  // `confirmed`: for settings that do not change the state (a climate's fan speed or swing), the check that
  // the new value has arrived; read-back continues until it holds, like `expectedState`.
  async runService(device: DeviceItem, service: string, data?: ServiceData,
    expectedState?: string, confirmed?: (updated: DeviceItem) => boolean): Promise<void> {
    if (!this.configured || !this.online || this.actionEntityId.length > 0 || !device.available) return;
    this.actionEntityId = device.entityId;
    this.lastError = '';
    this.message = '正在发送…';
    this.clearResult();
    let accepted: boolean = false;
    try {
      await this.prepare();
      await this.source!.callService(device.domain, service, device.entityId, data);
      accepted = true;
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
        const done: boolean = confirmed ? confirmed(updated) : (!expectedState || updated.state === expectedState);
        if (done) {
          this.message = expectedState || confirmed ? '设备状态已确认' : 'HA 已接受，状态已重新读取';
          return;
        }
      }
      this.message = 'HA 已接受，设备状态尚未确认';
    } catch (error) {
      if (accepted) {
        // The command went through; only reading the new state back failed (live updates bring it later).
        this.message = 'HA 已接受，状态读取失败';
      } else {
        // HA answering with an error (unsupported value, device refused) is not a lost connection.
        if (!isRejection(error as Object)) this.online = false;
        this.lastError = safeError(error, '设备操作失败');
        this.message = '操作未成功';
      }
    } finally {
      this.actionEntityId = '';
      this.showResult(device.entityId, accepted);
      if (this.isFavorite(device.entityId)) this.pushWidget();
    }
  }

  // '' (nothing to show), 'ok' or 'fail' for the entity's last command, shown for a moment after it ends.
  resultFor(entityId: string): string {
    if (this.resultEntityId.length === 0 || this.resultEntityId !== entityId) return '';
    return this.resultOk ? 'ok' : 'fail';
  }

  private showResult(entityId: string, ok: boolean): void {
    if (this.resultTimer >= 0) clearTimeout(this.resultTimer);
    this.resultEntityId = entityId;
    this.resultOk = ok;
    this.resultTimer = setTimeout(() => {
      this.resultTimer = -1;
      this.resultEntityId = '';
    }, ok ? 1500 : 2500);
  }

  private clearResult(): void {
    if (this.resultTimer >= 0) clearTimeout(this.resultTimer);
    this.resultTimer = -1;
    this.resultEntityId = '';
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

  // A pinned primary entity is shown by its device name ("客厅空调", not "客厅空调 温控器").
  favoriteName(item: DeviceItem): string {
    const group: DeviceGroup | undefined = this.groups.find((candidate: DeviceGroup) =>
      candidate.entityIds.includes(item.entityId));
    return group && group.primaryEntityId === item.entityId ? group.name : item.name;
  }

  // Mirrors favorites and each widget's own selection onto the watch-face widgets.
  // Best-effort: the app never waits for it.
  private pushWidget(): void {
    if (!this.widget) return;
    const ids: string[] = this.favorites.slice();
    let forms: WidgetForm[] = [];
    try {
      forms = this.widget.forms();
    } catch (_) {
      forms = [];
    }
    forms.forEach((form: WidgetForm) => form.ids.forEach((id: string) => {
      if (!ids.includes(id)) ids.push(id);
    }));
    const items: WidgetItem[] = [];
    ids.forEach((id: string) => {
      const device: DeviceItem | undefined = this.getDevice(id);
      if (device) items.push(WidgetBridge.fromDevice(device, this.favoriteName(device)));
    });
    const status: string = this.fetchedAt > 0 ?
      (this.online ? '已更新 ' : '离线 ') + WidgetBridge.clock(this.fetchedAt) : '';
    this.widget.publish({ configured: this.configured, favorites: this.favorites.slice(), items: items,
      pending: '', pendingAt: 0, status: status }).catch(() => {});
  }

  // Widgets currently on the watch face (empty when none were added).
  widgetForms(): WidgetForm[] {
    if (!this.widget) return [];
    try {
      return this.widget.forms();
    } catch (_) {
      return [];
    }
  }

  async setWidgetSelection(formId: string, ids: string[]): Promise<void> {
    if (!this.widget) return;
    await this.widget.setSelection(formId, ids);
    this.pushWidget();
  }

  // What a widget can show: entities with a one-tap action. 常用 first, then scenes / scripts,
  // then the main function of each appliance.
  widgetCandidates(): DeviceItem[] {
    const result: DeviceItem[] = this.favoriteDevices().filter((item: DeviceItem) => !!quickAction(item) ||
      item.domain === 'climate' || item.domain === 'cover' || isToggleDomain(item.domain));
    const add = (item: DeviceItem): void => {
      if (!result.some((existing: DeviceItem) => existing.entityId === item.entityId)) result.push(item);
    };
    this.runnables().forEach(add);
    this.groups.forEach((group: DeviceGroup) => {
      const primary: DeviceItem | undefined = this.getDevice(group.primaryEntityId);
      if (primary && primary.domain !== 'lock' && (isMajorDomain(primary.domain) || isToggleDomain(primary.domain))) {
        add(primary);
      }
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
    this.pushWidget();
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
    if (this.registryCache) await this.registryCache.clear();
    this.source?.close();
    this.savedRegistryAt = 0;
    this.pendingRegistry = undefined;
    this.firstSync = true;
    if (this.favoriteStore) await this.favoriteStore.clear();
    this.favorites = [];
    this.source = undefined;
    this.accessToken = '';
    this.server = '';
    this.activeBase = '';
    this.lanUrl = '';
    this.lanOff = false;
    this.lanAuto = false;
    this.lanActive = false;
    this.lanDetectTried = false;
    forgetRoute();
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
    this.pushWidget();
    if (server && refreshToken) {
      try { await new HaAuthClient(server).revoke(refreshToken); } catch (_) {}
    }
  }
}
