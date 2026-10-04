import { AppStorageV2 } from '@ohos.arkui.StateManagement';
import { DirectStore } from '../presentation/store/DirectStore';
import { SystemHeader } from '../presentation/ui/components/SystemHeader';
import { InfoText, WideButton } from '../presentation/ui/components/Controls';
import { Theme } from '../presentation/ui/Theme';
import { safeError } from '../core/utils/SafeError';
import { ArcScrollBar } from '@kit.ArkUI';

// LAN access: on the home Wi-Fi the watch talks to HA's LAN address directly (much faster than the
// remote HTTPS address through a tunnel or CDN); elsewhere it falls back to the remote address.
@Entry
@ComponentV2
struct LanAccess {
  @Local private store: DirectStore =
    AppStorageV2.connect(DirectStore, 'directStore', () => new DirectStore())!;
  @Local private address: string = '';
  // Address HA reported via 自动获取; saving it unchanged keeps it auto-updating.
  @Local private detected: string = '';
  @Local private busy: boolean = false;
  // Text field allowed to take focus (see beginEdit); '' = none.
  @Local private editing: string = '';
  @Local private resultText: string = '';
  @Local private resultColor: number = Theme.TEXT_DIM;
  private readonly scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.address = this.store.lanUrl;
  }

  // Text fields take focus only when touched directly. Otherwise a tap anywhere in the focusable list
  // (needed for the digital crown) hands focus to the first field and pops up the keyboard.
  private beginEdit(field: string): void {
    if (this.editing === field) return;
    this.editing = field;
    setTimeout(() => {
      try {
        this.getUIContext().getFocusController().requestFocus('input_' + field);
      } catch (_) {
        // The field is focusable now; a second tap focuses it.
      }
    }, 50);
  }

  private endEdit(field: string, editing: boolean): void {
    if (!editing && this.editing === field) this.editing = '';
  }

  private statusText(): string {
    if (!this.store.lanUrl || this.store.lanOff) return '未开启';
    const source: string = this.store.lanAuto ? '（自动获取）' : '（手动填写）';
    return (this.store.lanActive ? '当前：局域网直连' : '当前：远程地址（局域网地址暂时连不上）') + source;
  }

  private report(text: string, color: number): void {
    this.resultText = text;
    this.resultColor = color;
  }

  private async detect(): Promise<void> {
    this.busy = true;
    this.report('正在向 HA 查询…', Theme.TEXT_DIM);
    try {
      const url: string = await this.store.detectLan();
      if (url) {
        this.address = url;
        this.detected = url;
        this.report('已从 HA 读取，点「保存」启用', Theme.OK);
      } else {
        this.report('HA 没有提供局域网地址，请手动填写', Theme.WARN);
      }
    } catch (error) {
      this.report(safeError(error, '查询失败'), Theme.ERROR);
    } finally {
      this.busy = false;
    }
  }

  private async save(): Promise<void> {
    this.busy = true;
    this.report('正在测试…', Theme.TEXT_DIM);
    try {
      const auto: boolean = this.detected.length > 0 && this.address.trim() === this.detected;
      const reachable: boolean = await this.store.setLanUrl(this.address, auto);
      this.address = this.store.lanUrl;
      this.report(reachable ? '已保存，现在走局域网直连' : '已保存。在家能连上这个地址时会自动使用',
        reachable ? Theme.OK : Theme.WARN);
      this.store.sync();
    } catch (error) {
      this.report(safeError(error, '保存失败'), Theme.ERROR);
    } finally {
      this.busy = false;
    }
  }

  private async turnOff(): Promise<void> {
    this.busy = true;
    try {
      await this.store.turnOffLan();
      this.report('已关闭，始终使用远程地址', Theme.TEXT_DIM);
    } catch (error) {
      this.report(safeError(error, '操作失败'), Theme.ERROR);
    } finally {
      this.busy = false;
    }
  }

  build() {
    Stack() {
      List({ scroller: this.scroller, space: 10 }) {
        ListItem() { SystemHeader({ title: '局域网直连' }) }
        ListItem() {
          InfoText({ text: this.statusText(), textSize: 15,
            textColor: this.store.lanActive ? Theme.OK : Theme.TEXT_SUB })
        }
        ListItem() {
          InfoText({ text: '在家时（手表连 Wi‑Fi 或经手机蓝牙上网都可以）直接访问 HA 的局域网地址，速度更快；连不上时自动改用远程地址。自动获取的地址会在 HA 的 IP 变化后自动更新。', textSize: 12 })
        }
        ListItem() {
          Row() {
            TextInput({ placeholder: 'http://192.168.1.10:8123', text: this.address })
              .type(InputType.URL).fontSize(15).placeholderFont({ size: 13 })
              .onChange((value: string) => { this.address = value; })
              .id('input_address')
              .focusable(this.editing === 'address')
              .onTouch((event: TouchEvent) => {
                if (event.type === TouchType.Down) this.beginEdit('address');
              })
              .onEditChange((editing: boolean) => this.endEdit('address', editing))
              .width('78%').height(48);
          }
          .width('100%').justifyContent(FlexAlign.Center);
        }
        ListItem() {
          WideButton({ label: '保存', buttonColor: Theme.ACCENT, canTap: !this.busy && this.address.trim().length > 0,
            onTap: () => { this.save(); } })
        }
        ListItem() {
          WideButton({ label: '从 HA 自动获取', canTap: !this.busy, onTap: () => { this.detect(); } })
        }
        if (this.store.lanUrl && !this.store.lanOff) {
          ListItem() {
            WideButton({ label: '关闭局域网直连', buttonColor: Theme.DANGER, canTap: !this.busy,
              onTap: () => { this.turnOff(); } })
          }
        }
        if (this.resultText.length > 0) {
          ListItem() { InfoText({ text: this.resultText, textColor: this.resultColor }) }
        }
        ListItem() {
          InfoText({ text: '局域网内使用 HTTP 明文传输。每次使用前会先在不发送登录凭证的情况下确认该地址确实是 Home Assistant。',
            textSize: 11 })
        }
      }
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
