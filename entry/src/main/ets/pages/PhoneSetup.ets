import { AppStorageV2 } from '@ohos.arkui.StateManagement';
import { connection } from '@kit.NetworkKit';
import { DirectStore } from '../presentation/store/DirectStore';
import { PhoneLoginForm, PhoneSetupResult, PhoneSetupServer } from '../data/setup/PhoneSetupServer';
import { SystemHeader } from '../presentation/ui/components/SystemHeader';
import { InfoText, WideButton } from '../presentation/ui/components/Controls';
import { Theme } from '../presentation/ui/Theme';
import { safeError } from '../core/utils/SafeError';
import { ArcScrollBar } from '@kit.ArkUI';
import { focusList } from '../presentation/ui/Focus';

// Shows a QR code; a phone on the same Wi-Fi scans it, fills in the HA login on its own keyboard and
// the watch logs in with what it receives (see PhoneSetupServer).
@Entry
@ComponentV2
struct PhoneSetup {
  @Local private store: DirectStore =
    AppStorageV2.connect(DirectStore, 'directStore', () => new DirectStore())!;
  @Local private url: string = '';
  @Local private status: string = '正在准备…';
  @Local private error: string = '';
  private readonly scroller: Scroller = new Scroller();

  onPageShow(): void {
    focusList(this.getUIContext(), 'phoneSetupList');
  }

  aboutToAppear(): void {
    this.open();
  }

  aboutToDisappear(): void {
    PhoneSetupServer.shared().stop();
  }

  // Private LAN IPv4 only: skips loopback (127.x), link-local (169.254.x) and other non-routable addresses.
  private isLanIpv4(ip: string): boolean {
    return /^(10\.\d+|192\.168|172\.(1[6-9]|2\d|3[01]))\.\d+\.\d+$/.test(ip);
  }

  // The phone reaches the watch over Wi-Fi, so prefer a LAN address on a Wi-Fi/Ethernet network; any
  // other network's LAN address is only a fallback (e.g. a hotspot reported with an unusual bearer).
  private wifiAddress(): string {
    let fallback: string = '';
    try {
      const nets: connection.NetHandle[] = connection.getAllNetsSync();
      for (const net of nets) {
        let onWifi: boolean = false;
        try {
          const caps: connection.NetCapabilities = connection.getNetCapabilitiesSync(net);
          onWifi = caps.bearerTypes.includes(connection.NetBearType.BEARER_WIFI) ||
            caps.bearerTypes.includes(connection.NetBearType.BEARER_ETHERNET);
        } catch (_) {
          onWifi = false;
        }
        const props: connection.ConnectionProperties = connection.getConnectionPropertiesSync(net);
        for (const link of props.linkAddresses) {
          const ip: string = link.address.address;
          if (!this.isLanIpv4(ip)) continue;
          if (onWifi) return ip;
          if (fallback.length === 0) fallback = ip;
        }
      }
    } catch (_) {
      // Fall through to whatever was found.
    }
    return fallback;
  }

  private async open(): Promise<void> {
    const ip: string = this.wifiAddress();
    if (!ip) {
      this.status = '';
      this.error = '没有检测到手表的 Wi‑Fi 局域网地址。请让手表连接家里的 Wi‑Fi（和手机同一个网络）后重试；模拟器无法使用此功能。';
      return;
    }
    try {
      const path: string = await PhoneSetupServer.shared().start(this.store.lastServer,
        (form: PhoneLoginForm) => this.login(form));
      this.url = 'http://' + ip + path;
      this.status = '用手机扫码，在手机上填写';
      this.error = '';
    } catch (error) {
      this.status = '';
      this.error = safeError(error, '无法开启手机填写');
    }
  }

  private async login(form: PhoneLoginForm): Promise<PhoneSetupResult> {
    this.status = '收到手机信息，正在登录…';
    this.error = '';
    try {
      await this.store.configure(form.server, form.username, form.password, form.allowLocalHttp);
    } catch (error) {
      const message: string = safeError(error, '登录失败');
      this.status = '用手机扫码，在手机上填写';
      this.error = message;
      return { done: false, message: message };
    }
    if (this.store.mfaRequired) {
      this.getUIContext().getRouter().back();
      return { done: true, message: '请在手表上输入双重验证代码' };
    }
    if (this.store.configured) {
      this.getUIContext().getRouter().back();
      return { done: true, message: '登录成功' };
    }
    this.status = '用手机扫码，在手机上填写';
    return { done: false, message: '登录未完成，请重试' };
  }

  build() {
    Stack() {
      List({ scroller: this.scroller, space: 8 }) {
        ListItem() { SystemHeader({ title: '手机填写' }) }
        if (this.url.length > 0) {
          ListItem() {
            Row() {
              QRCode(this.url)
                .width(150).height(150)
                .color(Color.Black)
                .backgroundColor(Color.White);
            }
            .padding(10)
            .borderRadius(16)
            .backgroundColor(Color.White);
          }
          .width('100%')
        }
        if (this.status.length > 0) {
          ListItem() { InfoText({ text: this.status, textSize: 14, textColor: Theme.TEXT_SUB }) }
        }
        if (this.url.length > 0) {
          ListItem() { InfoText({ text: '手机需连接同一个 Wi‑Fi', textSize: 12 }) }
          ListItem() { InfoText({ text: this.url, textSize: 11 }) }
        }
        if (this.error.length > 0) {
          ListItem() { InfoText({ text: this.error, textColor: Theme.ERROR }) }
        }
        ListItem() {
          WideButton({ label: '返回手动填写', onTap: () => { this.getUIContext().getRouter().back(); } })
        }
      }
      .width('100%').height('100%')
      .alignListItem(ListItemAlign.Center)
      .id('phoneSetupList')
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
