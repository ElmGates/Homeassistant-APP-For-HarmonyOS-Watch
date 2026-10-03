import router from '@ohos.router';
import { AppStorageV2 } from '@ohos.arkui.StateManagement';
import { DirectStore } from '../presentation/store/DirectStore';
import { DeviceGroup, DeviceItem } from '../data/direct/HomeAssistantModels';
import { SystemHeader } from '../presentation/ui/components/SystemHeader';
import { ControlTile } from '../presentation/ui/components/ControlTile';
import { InfoText, WideButton } from '../presentation/ui/components/Controls';
import { glyphColor, isActive, isReadOnlyDomain, quickAction, stateLabel } from '../presentation/ui/DomainUi';
import { Theme } from '../presentation/ui/Theme';
import { actionIcon, entityIcon } from '../presentation/ui/Icons';
import { ArcScrollBar } from '@kit.ArkUI';

interface RoomRouteParams {
  roomId: string;
  roomName: string;
}

interface GroupRouteParams {
  groupId: string;
}

interface EntityRouteParams {
  entityId: string;
}

class GroupRoute implements router.RouterOptions {
  url: string = 'pages/DeviceGroupDetails';
  params?: GroupRouteParams;
  constructor(id: string) { this.params = { groupId: id }; }
}

class EntityRoute implements router.RouterOptions {
  url: string = 'pages/DirectEntityDetails';
  params?: EntityRouteParams;
  constructor(id: string) { this.params = { entityId: id }; }
}

@Entry
@ComponentV2
struct RoomDevices {
  @Local private store: DirectStore =
    AppStorageV2.connect(DirectStore, 'directStore', () => new DirectStore())!;
  @Local private roomId: string = '';
  @Local private roomName: string = '设备';
  private readonly scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    const params: RoomRouteParams = this.getUIContext().getRouter().getParams() as RoomRouteParams;
    this.roomId = params?.roomId ?? '';
    this.roomName = params?.roomName ?? '设备';
  }

  onPageShow(): void {
    this.store.refreshIfStale(30000);
  }

  private openGroup(group: DeviceGroup): void {
    if (group.entityIds.length === 1) {
      this.getUIContext().getRouter().pushUrl(new EntityRoute(group.primaryEntityId), () => {});
    } else {
      this.getUIContext().getRouter().pushUrl(new GroupRoute(group.id), () => {});
    }
  }

  private primary(group: DeviceGroup): DeviceItem | undefined {
    return this.store.getDevice(group.primaryEntityId);
  }

  // The one-tap button always targets the device's primary function (climate before the vendor's
  // auxiliary switches), never one of its extra entities.
  private quickEntity(group: DeviceGroup): DeviceItem | undefined {
    const main: DeviceItem | undefined = this.primary(group);
    if (main && !isReadOnlyDomain(main.domain) && quickAction(main) !== undefined) return main;
    return undefined;
  }

  private subtitle(group: DeviceGroup): string {
    const main: DeviceItem | undefined = this.primary(group);
    return main ? stateLabel(main) : '';
  }

  private canAct(item: DeviceItem | undefined): boolean {
    return !!item && item.available && this.store.online && this.store.actionEntityId.length === 0;
  }

  build() {
    Stack() {
      List({ scroller: this.scroller, space: 8 }) {
      ListItem() { SystemHeader({ title: this.roomName }) }
      ListItem() {
        InfoText({ text: this.store.loading ? '正在同步…' :
          (this.store.online ? this.store.message : '离线缓存 · 控制已禁用'),
          textColor: this.store.online || this.store.loading ? Theme.TEXT_DIM : Theme.WARN })
      }
      if (this.store.groupsInRoom(this.roomId).length === 0) {
        ListItem() { InfoText({ text: '此房间没有可显示的设备', textSize: 14 }) }
      }
      ForEach(this.store.groupsInRoom(this.roomId), (group: DeviceGroup) => {
        ListItem() {
          Row() {
            ControlTile({
              title: group.name,
              subtitle: this.subtitle(group),
              icon: this.primary(group) ? entityIcon(this.primary(group)!) : undefined,
              actionIcon: this.quickEntity(group) ? actionIcon(this.quickEntity(group)!) : undefined,
              glyphColor: this.primary(group) ? glyphColor(this.primary(group)!) : Theme.ICON_IDLE,
              actionLabel: this.quickEntity(group) ? (quickAction(this.quickEntity(group)!)?.label ?? '') : '',
              actionColor: this.quickEntity(group) && isActive(this.quickEntity(group)!) ? Theme.ACTIVE : Theme.ACCENT,
              actionEnabled: this.canAct(this.quickEntity(group)),
              busy: this.quickEntity(group)?.entityId === this.store.actionEntityId,
              onOpen: () => this.openGroup(group),
              onAction: () => {
                const target: DeviceItem | undefined = this.quickEntity(group);
                if (target) this.store.runQuick(target);
              }
            });
          }
          .width('100%').justifyContent(FlexAlign.Center);
        }
      }, (group: DeviceGroup) => group.id + '|' + this.store.fetchedAt);
      ListItem() {
        WideButton({ label: '刷新状态', canTap: !this.store.loading, onTap: () => { this.store.sync(); } })
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
    .width('100%').height('100%')
    .backgroundColor(Theme.BG);
  }
}
