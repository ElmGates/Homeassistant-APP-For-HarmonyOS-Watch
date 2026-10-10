import { AppStorageV2 } from '@ohos.arkui.StateManagement';
import router from '@ohos.router';
import { DirectStore } from '../presentation/store/DirectStore';
import { safeError } from '../core/utils/SafeError';
import { SystemHeader } from '../presentation/ui/components/SystemHeader';
import { InfoText, WideButton } from '../presentation/ui/components/Controls';
import { Theme } from '../presentation/ui/Theme';
import { ArcScrollBar } from '@kit.ArkUI';
import { focusList } from '../presentation/ui/Focus';
import { localNetworkSummary } from '../data/diag/NetworkDiagnostics';

class DiagnoseRoute implements router.RouterOptions {
  url: string = 'pages/NetworkDiagnose';
}

class WidgetRoute implements router.RouterOptions {
  url: string = 'pages/WidgetSettings';
}

class LanRoute implements router.RouterOptions {
  url: string = 'pages/LanAccess';
}

@Entry
@ComponentV2
struct Settings {
  @Local private store: DirectStore =
    AppStorageV2.connect(DirectStore, 'directStore', () => new DirectStore())!;
  @Local private confirmClear: boolean = false;
  @Local private errorText: string = '';
  @Local private networkText: string = '';
  private readonly startNames: string[] = ['常用', '我的家', '场景', '更多'];
  private readonly scroller: Scroller = new Scroller();

  onPageShow(): void {
    focusList(this.getUIContext(), 'settingsList');
    this.networkText = localNetworkSummary();
  }

  private async clearConnection(): Promise<void> {
    if (!this.confirmClear) {
      this.confirmClear = true;
      return;
    }
    try {
      await this.store.clear();
      this.getUIContext().getRouter().back();
    } catch (error) {
      this.errorText = safeError(error, '清除数据失败');
    }
  }

  build() {
    Stack() {
      List({ scroller: this.scroller, space: 10 }) {
      ListItem() { SystemHeader({ title: '设置' }) }
      ListItem() {
        Row() {
          Text(this.store.online ? '已连接 Home Assistant' : '离线 · 显示缓存')
            .width('78%').fontSize(16).fontColor(this.store.online ? Theme.OK : Theme.WARN)
            .textAlign(TextAlign.Center);
        }
        .width('100%').justifyContent(FlexAlign.Center);
      }
      ListItem() {
        // Tap to re-read after switching network (Wi‑Fi ↔ phone Bluetooth).
        Row() {
          Text('本机 ' + this.networkText)
            .width('78%').fontSize(13).fontColor(Theme.TEXT_SUB)
            .textAlign(TextAlign.Center);
        }
        .width('100%').justifyContent(FlexAlign.Center)
        .onClick(() => { this.networkText = localNetworkSummary(); });
      }
      if (this.store.roomSource !== 'registry' && this.store.registryError.length > 0) {
        ListItem() {
          InfoText({ text: '原因：' + this.store.registryError, textSize: 12, textColor: Theme.WARN })
        }
      }
      ListItem() {
        Row() {
          Text(this.store.roomSource === 'registry' ? '房间归属已同步' : '房间归属暂不可用')
            .width('78%').fontSize(14).fontColor(Theme.TEXT_SUB)
            .textAlign(TextAlign.Center);
        }
        .width('100%').justifyContent(FlexAlign.Center);
      }
      ListItem() {
        InfoText({ text: '常用设备 ' + this.store.favorites.length + ' 个', textSize: 14, textColor: Theme.TEXT_SUB })
      }
      ListItem() {
        WideButton({ label: '重新同步', buttonColor: Theme.ACCENT, canTap: !this.store.loading,
          onTap: () => { this.store.fullSync(); } })
      }
      ListItem() {
        // Each tap moves to the next card; takes effect at the next launch.
        WideButton({ label: '启动页：' + (this.startNames[this.store.startPage] ?? '我的家'),
          onTap: () => { this.store.setStartPage((this.store.startPage + 1) % 4).catch(() => {}); } })
      }
      ListItem() {
        WideButton({ label: this.store.lanActive ? '局域网直连 · 使用中' : '局域网直连',
          buttonColor: this.store.lanActive ? Theme.SELECTED : Theme.SECONDARY,
          onTap: () => { this.getUIContext().getRouter().pushUrl(new LanRoute(), () => {}); } })
      }
      ListItem() {
        WideButton({ label: '表盘卡片',
          onTap: () => { this.getUIContext().getRouter().pushUrl(new WidgetRoute(), () => {}); } })
      }
      ListItem() {
        WideButton({ label: '连接诊断',
          onTap: () => { this.getUIContext().getRouter().pushUrl(new DiagnoseRoute(), () => {}); } })
      }
      if (this.store.favorites.length > 0) {
        ListItem() {
          WideButton({ label: '清空常用设备', onTap: () => { this.store.clearFavorites(); } })
        }
      }
      ListItem() {
        Row() {
          Button(this.confirmClear ? '再次点击确认清除' : '更换服务器 / 清除本地数据')
            .width('78%').height(52).backgroundColor(Theme.DANGER)
            .onClick(() => { this.clearConnection(); });
        }
        .width('100%').justifyContent(FlexAlign.Center);
      }
      if (this.errorText.length > 0) {
        ListItem() {
          Row() {
            Text(this.errorText)
              .width('78%').fontSize(13).fontColor(Theme.ERROR)
              .textAlign(TextAlign.Center);
          }
          .width('100%').justifyContent(FlexAlign.Center);
        }
      }
      }
      .id('settingsList')
      .width('100%').height('100%')
      .focusable(true).focusOnTouch(true)
      .digitalCrownSensitivity(CrownSensitivity.MEDIUM)
      .scrollBar(BarState.Off)
      .contentEndOffset(100);
      ArcScrollBar({ scroller: this.scroller, state: BarState.Auto })
        .width('100%').height('100%')
        .hitTestBehavior(HitTestMode.Transparent);
    }
    .width('100%').height('100%')
    .backgroundColor(Theme.BG);
  }
}
