import { AppStorageV2 } from '@ohos.arkui.StateManagement';
import router from '@ohos.router';
import { DirectStore } from '../presentation/store/DirectStore';
import { DeviceGroup, DeviceItem, RoomSummary } from '../data/direct/HomeAssistantModels';
import { SystemTile } from '../presentation/ui/components/SystemTile';
import { SystemHeader } from '../presentation/ui/components/SystemHeader';
import { ControlTile } from '../presentation/ui/components/ControlTile';
import { InfoText, WideButton } from '../presentation/ui/components/Controls';
import { glyphColor, isActive, quickAction, stateLabel } from '../presentation/ui/DomainUi';
import { Theme } from '../presentation/ui/Theme';
import { actionIcon, entityIcon, roomIcon } from '../presentation/ui/Icons';
import { safeError } from '../core/utils/SafeError';
import { ArcScrollBar } from '@kit.ArkUI';

interface RoomRouteParams {
  roomId: string;
  roomName: string;
}

interface EntityRouteParams {
  entityId: string;
}

class RoomRoute implements router.RouterOptions {
  url: string = 'pages/RoomDevices';
  params?: RoomRouteParams;
  constructor(room: RoomSummary) {
    this.params = { roomId: room.id, roomName: room.name };
  }
}

class EntityRoute implements router.RouterOptions {
  url: string = 'pages/DirectEntityDetails';
  params?: EntityRouteParams;
  constructor(id: string) { this.params = { entityId: id }; }
}

class SettingsRoute implements router.RouterOptions {
  url: string = 'pages/Settings';
}

class AboutRoute implements router.RouterOptions {
  url: string = 'pages/About';
}

class PhoneSetupRoute implements router.RouterOptions {
  url: string = 'pages/PhoneSetup';
}

// Home cards, left to right. 我的家 opens first.
const CARD_LISTS: string[] = ['favoritesList', 'roomsList', 'scenesList', 'moreList'];

@Entry
@ComponentV2
struct Index {
  @Local private store: DirectStore =
    AppStorageV2.connect(DirectStore, 'directStore', () => new DirectStore())!;
  @Local private server: string = '';
  @Local private username: string = '';
  @Local private password: string = '';
  @Local private mfaCode: string = '';
  @Local private allowLocalHttp: boolean = false;
  // Index into CARD_LISTS: 0 常用 · 1 我的家 · 2 场景 · 3 更多.
  @Local private page: number = 1;
  private readonly scroller: Scroller = new Scroller();
  private readonly favoritesScroller: Scroller = new Scroller();
  private readonly roomsScroller: Scroller = new Scroller();
  private readonly scenesScroller: Scroller = new Scroller();
  private readonly moreScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    if (this.server.length === 0) this.server = this.store.lastServer;
  }

  onPageShow(): void {
    this.store.refreshIfStale(30000);
  }

  private async connect(): Promise<void> {
    if (this.store.loading) return;
    try {
      await this.store.configure(this.server, this.username, this.password, this.allowLocalHttp);
      if (this.store.configured) this.username = '';
    } catch (error) {
      this.store.lastError = safeError(error, '连接失败');
    } finally {
      this.password = '';
    }
  }

  private async verifyMfa(): Promise<void> {
    try {
      await this.store.submitMfa(this.mfaCode);
      if (this.store.configured) {
        this.mfaCode = '';
        this.username = '';
      }
    } catch (error) {
      this.store.lastError = safeError(error, '验证失败');
      this.mfaCode = '';
    }
  }

  private openRoom(room: RoomSummary): void {
    this.getUIContext().getRouter().pushUrl(new RoomRoute(room), () => {});
  }

  private openEntity(entityId: string): void {
    this.getUIContext().getRouter().pushUrl(new EntityRoute(entityId), () => {});
  }

  private openSettings(): void {
    this.getUIContext().getRouter().pushUrl(new SettingsRoute(), () => {});
  }

  private openPhoneSetup(): void {
    this.getUIContext().getRouter().pushUrl(new PhoneSetupRoute(), () => {});
  }

  private openAbout(): void {
    this.getUIContext().getRouter().pushUrl(new AboutRoute(), () => {});
  }

  // A pinned primary entity is shown by its device name ("客厅空调", not "客厅空调 温控器").
  private favoriteTitle(item: DeviceItem): string {
    const group: DeviceGroup | undefined = this.store.groups.find((candidate: DeviceGroup) =>
      candidate.entityIds.includes(item.entityId));
    return group && group.primaryEntityId === item.entityId ? group.name : item.name;
  }

  private canAct(item: DeviceItem): boolean {
    return item.available && this.store.online && this.store.actionEntityId.length === 0 &&
      quickAction(item) !== undefined;
  }

  private syncLabel(): string {
    if (this.store.fetchedAt === 0) return '尚未同步';
    const time: string = new Date(this.store.fetchedAt).toLocaleTimeString();
    return (this.store.online ? '已更新 ' : '离线缓存 · 控制已禁用 ') + time +
      (this.store.credentialsPersisted ? '' : ' · 本次会话');
  }

  // Keep the digital crown scrolling the list of the visible card.
  private onPageChange(index: number): void {
    this.page = index;
    try {
      this.getUIContext().getFocusController().requestFocus(CARD_LISTS[index] ?? 'roomsList');
    } catch (_) {
      // Focus is best-effort: touch scrolling still works without it.
    }
  }

  build() {
    Stack() {
      if (this.store.configured) {
        Swiper() {
          this.favoritesCard();
          this.roomsCard();
          this.scenesCard();
          this.moreCard();
        }
        .width('100%').height('100%')
        .index(this.page)
        .loop(false)
        .indicator(new DotIndicator()
          .itemWidth(6).itemHeight(6).selectedItemWidth(6).selectedItemHeight(6)
          .color(0x55FFFFFF).selectedColor(Color.White)
          .bottom(10))
        .onChange((index: number) => this.onPageChange(index));
      } else {
        this.loginCard();
      }
    }
    .width('100%').height('100%')
    .backgroundColor(Theme.BG);
  }

  // Left card: one-tap control of pinned devices.
  @Builder
  favoritesCard() {
    Stack() {
      List({ scroller: this.favoritesScroller, space: 8 }) {
        ListItem() { SystemHeader({ title: '常用' }) }
        if (this.store.favoriteDevices().length === 0) {
          ListItem() { InfoText({ text: '暂无常用设备', textSize: 14 }) }
        }
        ForEach(this.store.favoriteDevices(), (item: DeviceItem) => {
          ListItem() {
            Row() {
              ControlTile({
                title: this.favoriteTitle(item),
                subtitle: stateLabel(item),
                icon: entityIcon(item),
                actionIcon: actionIcon(item),
                glyphColor: glyphColor(item),
                actionLabel: quickAction(item)?.label ?? '',
                actionColor: isActive(item) ? Theme.ACTIVE : Theme.ACCENT,
                actionEnabled: this.canAct(item),
                busy: this.store.actionEntityId === item.entityId,
                onOpen: () => this.openEntity(item.entityId),
                onAction: () => { this.store.runQuick(item); }
              });
            }
            .width('100%').justifyContent(FlexAlign.Center);
          }
        }, (item: DeviceItem) => item.entityId + '|' + this.store.fetchedAt);
        if (this.store.lastError.length > 0) {
          ListItem() { InfoText({ text: this.store.lastError, textColor: Theme.ERROR }) }
        }
      }
      .id('favoritesList')
      .width('100%').height('100%')
      .focusable(true).focusOnTouch(true)
      .digitalCrownSensitivity(CrownSensitivity.MEDIUM)
      .scrollBar(BarState.Off)
      .contentEndOffset(100);
      ArcScrollBar({ scroller: this.favoritesScroller, state: BarState.Auto })
        .width('100%').height('100%')
        .hitTestBehavior(HitTestMode.Transparent);
    }
    .width('100%').height('100%');
  }

  // Second card (shown first): rooms.
  @Builder
  roomsCard() {
    Stack() {
      List({ scroller: this.roomsScroller, space: 8 }) {
        ListItem() { SystemHeader({ title: '我的家' }) }
        ListItem() {
          InfoText({ text: this.store.loading ? '正在同步…' : this.syncLabel(),
            textColor: this.store.online || this.store.loading ? Theme.TEXT_DIM : Theme.WARN })
        }
        ForEach(this.store.rooms, (room: RoomSummary) => {
          ListItem() {
            Row() {
              SystemTile({
                title: room.name,
                subtitle: room.count + ' 个设备',
                iconRes: roomIcon(room),
                iconBgColor: Theme.ACCENT,
                showChevron: true
              });
            }
            .width('100%').justifyContent(FlexAlign.Center)
            .onClick(() => this.openRoom(room));
          }
        }, (room: RoomSummary) => room.id + '|' + room.count);
        if (this.store.lastError.length > 0) {
          ListItem() { InfoText({ text: this.store.lastError, textColor: Theme.ERROR }) }
        }
      }
      .id('roomsList')
      .defaultFocus(true)
      .width('100%').height('100%')
      .focusable(true).focusOnTouch(true)
      .digitalCrownSensitivity(CrownSensitivity.MEDIUM)
      .scrollBar(BarState.Off)
      .contentEndOffset(100);
      ArcScrollBar({ scroller: this.roomsScroller, state: BarState.Auto })
        .width('100%').height('100%')
        .hitTestBehavior(HitTestMode.Transparent);
    }
    .width('100%').height('100%');
  }

  // Third card: scenes, scripts and automations, each with a one-tap 执行.
  @Builder
  scenesCard() {
    Stack() {
      List({ scroller: this.scenesScroller, space: 8 }) {
        ListItem() { SystemHeader({ title: '场景' }) }
        if (this.store.runnables().length === 0) {
          ListItem() { InfoText({ text: '暂无场景、脚本或自动化', textSize: 14 }) }
        }
        ForEach(this.store.runnables(), (item: DeviceItem) => {
          ListItem() {
            Row() {
              ControlTile({
                title: item.name,
                subtitle: stateLabel(item),
                icon: entityIcon(item),
                actionIcon: actionIcon(item),
                glyphColor: glyphColor(item),
                actionLabel: quickAction(item)?.label ?? '',
                actionColor: Theme.ACCENT,
                actionEnabled: this.canAct(item),
                busy: this.store.actionEntityId === item.entityId,
                onOpen: () => this.openEntity(item.entityId),
                onAction: () => { this.store.runQuick(item); }
              });
            }
            .width('100%').justifyContent(FlexAlign.Center);
          }
        }, (item: DeviceItem) => item.entityId + '|' + this.store.fetchedAt);
        if (this.store.lastError.length > 0) {
          ListItem() { InfoText({ text: this.store.lastError, textColor: Theme.ERROR }) }
        }
      }
      .id('scenesList')
      .width('100%').height('100%')
      .focusable(true).focusOnTouch(true)
      .digitalCrownSensitivity(CrownSensitivity.MEDIUM)
      .scrollBar(BarState.Off)
      .contentEndOffset(100);
      ArcScrollBar({ scroller: this.scenesScroller, state: BarState.Auto })
        .width('100%').height('100%')
        .hitTestBehavior(HitTestMode.Transparent);
    }
    .width('100%').height('100%');
  }

  // Last card: sync status, refresh, settings and about.
  @Builder
  moreCard() {
    Stack() {
      List({ scroller: this.moreScroller, space: 8 }) {
        ListItem() { SystemHeader({ title: '更多' }) }
        ListItem() {
          InfoText({ text: this.store.loading ? '正在同步…' : this.syncLabel(),
            textColor: this.store.online || this.store.loading ? Theme.TEXT_DIM : Theme.WARN })
        }
        ListItem() {
          WideButton({ label: this.store.loading ? '同步中…' : '刷新', buttonColor: Theme.ACCENT,
            canTap: !this.store.loading, onTap: () => { this.store.sync(); } })
        }
        ListItem() {
          WideButton({ label: '设置', onTap: () => this.openSettings() })
        }
        ListItem() {
          WideButton({ label: '关于', onTap: () => this.openAbout() })
        }
        if (this.store.lastError.length > 0) {
          ListItem() { InfoText({ text: this.store.lastError, textColor: Theme.ERROR }) }
        }
      }
      .id('moreList')
      .width('100%').height('100%')
      .focusable(true).focusOnTouch(true)
      .digitalCrownSensitivity(CrownSensitivity.MEDIUM)
      .scrollBar(BarState.Off)
      .contentEndOffset(100);
      ArcScrollBar({ scroller: this.moreScroller, state: BarState.Auto })
        .width('100%').height('100%')
        .hitTestBehavior(HitTestMode.Transparent);
    }
    .width('100%').height('100%');
  }

  @Builder
  loginCard() {
    Stack() {
      List({ scroller: this.scroller, space: 8 }) {
      ListItem() { SystemHeader({ title: '连接 HA' }) }
      if (!this.store.configured && this.store.mfaRequired) {
        ListItem() { InfoText({ text: '输入 HA 的双重验证代码', textSize: 14, textColor: Theme.TEXT_SUB }) }
        ListItem() {
          Row() {
            TextInput({ placeholder: '验证码', text: this.mfaCode })
              .type(InputType.Number).fontSize(16).placeholderFont({ size: 16 })
              .onChange((value: string) => { this.mfaCode = value; })
              .width('78%').height(48);
          }
          .width('100%').justifyContent(FlexAlign.Center);
        }
        ListItem() {
          WideButton({ label: this.store.loading ? '验证中…' : '完成登录', canTap: !this.store.loading,
            buttonColor: Theme.ACCENT, buttonHeight: 52, onTap: () => { this.verifyMfa(); } })
        }
        ListItem() {
          WideButton({ label: '返回登录', onTap: () => { this.store.cancelMfa(); } })
        }
      } else if (!this.store.configured) {
        ListItem() {
          WideButton({ label: '用手机填写', buttonColor: Theme.ACCENT, buttonHeight: 52,
            canTap: !this.store.loading, onTap: () => this.openPhoneSetup() })
        }
        ListItem() { InfoText({ text: '或在手表上直接填写', textSize: 13, textColor: Theme.TEXT_SUB }) }
        ListItem() {
          Row() {
            TextInput({ placeholder: 'HA 地址', text: this.server })
              .type(InputType.URL).fontSize(16).placeholderFont({ size: 16 })
              .onChange((value: string) => {
                if (value !== this.server) this.allowLocalHttp = false;
                this.server = value;
              })
              .width('78%').height(48);
          }
          .width('100%').justifyContent(FlexAlign.Center);
        }
        ListItem() {
          Row() {
            TextInput({ placeholder: '用户名', text: this.username })
              .fontSize(16).placeholderFont({ size: 16 })
              .onChange((value: string) => { this.username = value; })
              .width('78%').height(48);
          }
          .width('100%').justifyContent(FlexAlign.Center);
        }
        ListItem() {
          Row() {
            TextInput({ placeholder: '密码', text: this.password })
              .type(InputType.Password).fontSize(16).placeholderFont({ size: 16 })
              .onChange((value: string) => { this.password = value; })
              .width('78%').height(48);
          }
          .width('100%').justifyContent(FlexAlign.Center);
        }
        if (this.server.trim().startsWith('http://')) {
          ListItem() {
            Row() {
              Button(this.allowLocalHttp ? '已确认：仅可信局域网' : 'HTTP 会明文传输密码 · 点此确认')
                .width('78%').height(48).fontSize(12)
                .backgroundColor(this.allowLocalHttp ? Theme.SELECTED : Theme.DANGER)
                .onClick(() => { this.allowLocalHttp = !this.allowLocalHttp; });
            }
            .width('100%').justifyContent(FlexAlign.Center);
          }
        }
        ListItem() {
          WideButton({ label: this.store.loading ? '登录中…' : '登录', canTap: !this.store.loading,
            buttonColor: Theme.ACCENT, buttonHeight: 52, onTap: () => { this.connect(); } })
        }
      }
      if (this.store.lastError.length > 0) {
        ListItem() { InfoText({ text: this.store.lastError, textColor: Theme.ERROR }) }
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
    .width('100%').height('100%');
  }
}
