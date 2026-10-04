import UIAbility from '@ohos.app.ability.UIAbility';
import window from '@ohos.window';
import { AbilityConstant, Want } from '@kit.AbilityKit';
import { formInfo } from '@kit.FormKit';
import { AppStorageV2 } from '@ohos.arkui.StateManagement';
import { DirectStore } from '../presentation/store/DirectStore';
import { safeError } from '../core/utils/SafeError';

interface WidgetWantParams {
  widgetFormId?: string;
  open?: string;
}

// Which widget the user wants to change, if any. Widgets send { widgetFormId } (or { open } to just
// open the app) as router params; the system's "edit widget" menu sends only the form ID.
function widgetFormFromWant(want: Want): string {
  const params: Record<string, Object> = want.parameters ?? {};
  const raw: Object | undefined = params['params'];
  if (typeof raw === 'string') {
    try {
      return (JSON.parse(raw as string) as WidgetWantParams).widgetFormId ?? '';
    } catch (_) {
      return '';
    }
  }
  if (typeof params['widgetFormId'] === 'string') return params['widgetFormId'] as string;
  if (params['open'] !== undefined) return '';
  const formId: Object | undefined = params[formInfo.FormParam.IDENTITY_KEY];
  return typeof formId === 'string' ? formId as string : '';
}

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    this.handleWant(want);
  }

  onNewWant(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    this.handleWant(want);
  }

  async onWindowStageCreate(windowStage: window.WindowStage): Promise<void> {
    const store: DirectStore = AppStorageV2.connect(DirectStore, 'directStore', () => new DirectStore())!;
    try {
      await store.restore(this.context);
    } catch (error) {
      store.lastError = safeError(error, '恢复登录失败');
    }
    // Show the first screen as soon as the login is known; the last snapshot and the registry are read
    // from disk afterwards, then the first (quick) sync runs.
    await windowStage.loadContent('pages/Index');
    await store.loadCaches();
    if (store.configured) store.sync();
  }

  // Coming back to the watch app after a while: states are probably stale.
  onForeground(): void {
    const store: DirectStore = AppStorageV2.connect(DirectStore, 'directStore', () => new DirectStore())!;
    store.refreshIfStale(30000);
  }

  private handleWant(want: Want): void {
    const formId: string = widgetFormFromWant(want);
    if (formId.length === 0) return;
    const store: DirectStore = AppStorageV2.connect(DirectStore, 'directStore', () => new DirectStore())!;
    store.pendingWidgetForm = formId;
  }
}
