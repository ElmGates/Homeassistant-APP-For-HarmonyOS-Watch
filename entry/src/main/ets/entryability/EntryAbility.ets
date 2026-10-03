import UIAbility from '@ohos.app.ability.UIAbility';
import window from '@ohos.window';
import { AppStorageV2 } from '@ohos.arkui.StateManagement';
import { DirectStore } from '../presentation/store/DirectStore';
import { safeError } from '../core/utils/SafeError';

export default class EntryAbility extends UIAbility {
  async onWindowStageCreate(windowStage: window.WindowStage): Promise<void> {
    const store: DirectStore = AppStorageV2.connect(DirectStore, 'directStore', () => new DirectStore())!;
    try {
      await store.restore(this.context);
    } catch (error) {
      store.lastError = safeError(error, '恢复登录失败');
    }
    await windowStage.loadContent('pages/Index');
    if (store.configured) store.sync();
  }

  // Coming back to the watch app after a while: states are probably stale.
  onForeground(): void {
    const store: DirectStore = AppStorageV2.connect(DirectStore, 'directStore', () => new DirectStore())!;
    store.refreshIfStale(30000);
  }
}
