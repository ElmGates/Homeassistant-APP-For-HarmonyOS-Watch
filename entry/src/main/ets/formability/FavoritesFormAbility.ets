import { formBindingData, FormExtensionAbility, formInfo } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { WidgetBridge, WidgetForm, WidgetItem, WidgetState } from '../data/widget/WidgetBridge';
import { CachedAccess, ConnectionCredentials, CredentialStore } from '../data/security/CredentialStore';
import { HaAuthClient, HaSession } from '../data/direct/HaAuthClient';
import { HaDirectClient, HaEntityState } from '../data/direct/HaDirectClient';
import { DeviceItem } from '../data/direct/HomeAssistantModels';
import { QuickAction, quickAction } from '../presentation/ui/DomainUi';
import { safeError } from '../core/utils/SafeError';
import { chooseBaseUrl } from '../data/direct/LanRoute';

interface CardMessage {
  entityId?: string;
  // The status line of the large widget was tapped: refresh now.
  refresh?: boolean;
}

const STATELESS_DOMAINS: string[] = ['scene', 'script', 'automation', 'button', 'input_button'];

// Access token kept while this extension process lives, so quick successive taps skip the refresh.
let tokenServer: string = '';
let token: string = '';
let tokenExpiresAt: number = 0;
// A shared token HA rejected (revoked): never reused from the app's cache.
let rejectedToken: string = '';
// Whether HA has accepted the current token in this process (a shared one is checked once).
let tokenVerified: boolean = false;

function isAuthFailure(error: Object): boolean {
  return error instanceof Error && error.message === '登录已失效，请重新登录';
}

// Provider of every watch-face widget (large / small favorites, wide and round single-entity
// cards). A tap runs the same one-tap action as the app; the app pushes fresh states after each
// sync, this ability refreshes what is shown periodically.
export default class FavoritesFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    const formId: string = (want.parameters?.[formInfo.FormParam.IDENTITY_KEY] ?? '') as string;
    const formName: string = (want.parameters?.[formInfo.FormParam.NAME_KEY] ?? 'favorites') as string;
    const bridge: WidgetBridge = new WidgetBridge(this.context);
    const state: WidgetState = bridge.load();
    bridge.addForm(formId, formName).then(() => this.refresh()).catch(() => {});
    return bridge.binding(state, { id: formId, name: formName, ids: [] });
  }

  onUpdateForm(_formId: string): void {
    this.refresh().catch(() => {});
  }

  onRemoveForm(formId: string): void {
    new WidgetBridge(this.context).removeForm(formId).catch(() => {});
  }

  onFormEvent(_formId: string, message: string): void {
    let request: CardMessage;
    try {
      request = JSON.parse(message) as CardMessage;
    } catch (_) {
      return;
    }
    if (request.refresh) {
      this.refresh(true).catch(() => {});
    } else if (request.entityId) {
      this.runAction(request.entityId).catch(() => {});
    }
  }

  private async client(): Promise<HaDirectClient> {
    const store: CredentialStore = new CredentialStore(this.context);
    store.reloadFromDisk();
    const saved: ConnectionCredentials | undefined = await store.load();
    if (!saved) throw new Error('请打开应用登录');
    // At home on Wi-Fi the LAN address is much faster than the remote HTTPS one.
    const base: string = await chooseBaseUrl(saved.server, saved.lanOff ? '' : saved.lanUrl);
    if (tokenServer !== saved.server || Date.now() + 60000 >= tokenExpiresAt) {
      // The app keeps its access token (encrypted); reuse it while it is valid instead of exchanging a new
      // one on every refresh, and share a newly exchanged one back with the app.
      let access: CachedAccess | undefined = undefined;
      try {
        access = await store.loadAccess();
      } catch (_) {
        access = undefined;
      }
      if (access && access.token !== rejectedToken) {
        token = access.token;
        tokenExpiresAt = access.expiresAt;
        tokenVerified = false;
      } else {
        const session: HaSession = await new HaAuthClient(base, saved.server).refresh(saved.refreshToken);
        token = session.accessToken;
        tokenExpiresAt = session.expiresAt;
        tokenVerified = true;
        store.saveAccess(session.accessToken, session.expiresAt).catch(() => {});
      }
      tokenServer = saved.server;
    }
    return new HaDirectClient(base, token);
  }

  // `manual`: the user tapped the status line, so the widget shows that it is refreshing.
  // A client whose token HA accepts. A token shared by the app is checked once per process with one small
  // read (no more than the exchange it saves); if HA revoked it, a new one is exchanged.
  private async authorizedClient(): Promise<HaDirectClient> {
    const client: HaDirectClient = await this.client();
    if (tokenVerified) return client;
    try {
      await client.readConfig();
      tokenVerified = true;
      return client;
    } catch (error) {
      if (!isAuthFailure(error as Object)) return client;
      rejectedToken = token;
      tokenExpiresAt = 0;
      return await this.client();
    }
  }

  private async refresh(manual: boolean = false): Promise<void> {
    const bridge: WidgetBridge = new WidgetBridge(this.context);
    const state: WidgetState = bridge.load();
    if (manual && state.configured) {
      state.status = '正在刷新…';
      await bridge.publish(state);
    }
    // Only what is on the watch face right now, not the whole 常用 list.
    const shown: string[] = [];
    bridge.forms().forEach((form: WidgetForm) => {
      WidgetBridge.idsFor(state, form).forEach((id: string) => {
        if (!shown.includes(id)) shown.push(id);
      });
    });
    const targets: WidgetItem[] = state.items.filter((item: WidgetItem) => shown.includes(item.id));
    if (!state.configured || targets.length === 0) {
      await bridge.publish(state);
      return;
    }
    try {
      const client: HaDirectClient = await this.authorizedClient();
      const fresh: WidgetItem[] = await Promise.all(targets.map((item: WidgetItem) =>
        client.readEntity(item.id)
          .then((current: HaEntityState) => WidgetBridge.fromDevice(WidgetBridge.toDevice(item, current), item.name))
          .catch(() => item)));
      state.items = state.items.map((item: WidgetItem) =>
        fresh.find((candidate: WidgetItem) => candidate.id === item.id) ?? item);
      state.status = '已更新 ' + WidgetBridge.clock(Date.now());
    } catch (error) {
      state.status = safeError(error as Object, '刷新失败');
    }
    // Re-read before saving: the app may have published newer favorites meanwhile.
    const latest: WidgetState = bridge.load();
    latest.items = latest.items.map((item: WidgetItem) =>
      state.items.find((candidate: WidgetItem) => candidate.id === item.id) ?? item);
    latest.status = state.status;
    await bridge.publish(latest);
  }

  private async runAction(entityId: string): Promise<void> {
    const bridge: WidgetBridge = new WidgetBridge(this.context);
    const state: WidgetState = bridge.load();
    const item: WidgetItem | undefined = state.items.find((candidate: WidgetItem) => candidate.id === entityId);
    if (!item || !state.configured) return;
    // One command at a time, like the app: a second tap during a slow request is ignored.
    if (state.pending.length > 0 && Date.now() - state.pendingAt < 20000) return;
    state.pending = entityId;
    state.pendingAt = Date.now();
    state.status = '正在发送…';
    await bridge.publish(state);

    let updated: WidgetItem = item;
    let status: string = '';
    try {
      const client: HaDirectClient = await this.authorizedClient();
      // Read first: the widget's copy may be stale, and toggling from a stale state flips the wrong way.
      let device: DeviceItem = WidgetBridge.toDevice(item, await client.readEntity(entityId));
      const action: QuickAction | undefined = quickAction(device);
      if (!action) throw new Error('请在应用中操作此设备');
      const before: string = device.state;
      await client.callService(device.domain, action.service, entityId, action.data);
      // Wait for the expected state; without one (covers, climate on…), wait until the state moves.
      // Scenes, scripts and buttons have nothing to wait for.
      const stateless: boolean = STATELESS_DOMAINS.includes(device.domain);
      const delays: number[] = [700, 1300, 2000];
      for (let i: number = 0; i < delays.length; i++) {
        await new Promise<void>((resolve: () => void) => setTimeout(resolve, delays[i]));
        device = WidgetBridge.toDevice(item, await client.readEntity(entityId));
        if (stateless) break;
        if (action.expectedState ? device.state === action.expectedState : device.state !== before) break;
      }
      updated = WidgetBridge.fromDevice(device, item.name);
      status = '已执行 ' + WidgetBridge.clock(Date.now());
    } catch (error) {
      status = safeError(error as Object, '操作失败');
    }
    const latest: WidgetState = bridge.load();
    latest.items = latest.items.map((candidate: WidgetItem) => candidate.id === entityId ? updated : candidate);
    latest.pending = '';
    latest.pendingAt = 0;
    latest.status = status;
    await bridge.publish(latest);
  }
}
