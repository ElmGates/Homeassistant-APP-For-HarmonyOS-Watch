import router from '@ohos.router';
import { AppStorageV2 } from '@ohos.arkui.StateManagement';
import { DirectStore } from '../presentation/store/DirectStore';
import { DeviceGroup, DeviceItem } from '../data/direct/HomeAssistantModels';
import { SystemTile } from '../presentation/ui/components/SystemTile';
import { SectionLabel, SystemHeader } from '../presentation/ui/components/SystemHeader';
import { ControlTile } from '../presentation/ui/components/ControlTile';
import { InfoText, WideButton } from '../presentation/ui/components/Controls';
import { glyphColor, isActive, isMajorDomain, isReadOnlyDomain, quickAction, stateLabel } from '../presentation/ui/DomainUi';
import { Theme } from '../presentation/ui/Theme';
import { ArcScrollBar } from '@kit.ArkUI';
import { entityDisplayName } from '../presentation/ui/EntityDisplayName';
import { actionIcon, entityIcon } from '../presentation/ui/Icons';

interface GroupRouteParams {
  groupId: string;
}

interface EntityRouteParams {
  entityId: string;
}

class EntityRoute implements router.RouterOptions {
  url: string = 'pages/DirectEntityDetails';
  params?: EntityRouteParams;
  constructor(id: string) { this.params = { entityId: id }; }
}

@Entry
@ComponentV2
struct DeviceGroupDetails {
  @Local private store: DirectStore =
    AppStorageV2.connect(DirectStore, 'directStore', () => new DirectStore())!;
  @Local private groupId: string = '';
  @Local private showSensors: boolean = false;
  @Local private showExtras: boolean = false;
  private readonly scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    const params: GroupRouteParams = this.getUIContext().getRouter().getParams() as GroupRouteParams;
    this.groupId = params?.groupId ?? '';
  }

  private group(): DeviceGroup | undefined {
    return this.store.getGroup(this.groupId);
  }

  private controls(): DeviceItem[] {
    return this.store.entitiesInGroup(this.groupId)
      .filter((item: DeviceItem) => !isReadOnlyDomain(item.domain));
  }

  // Shown directly: the primary entity plus other real appliance functions. A device whose controls
  // all share one domain (e.g. a 3-gang wall switch) shows every gang.
  private isMain(item: DeviceItem, primaryId: string, sameDomain: boolean): boolean {
    return item.entityId === primaryId || sameDomain || isMajorDomain(item.domain);
  }

  private mainEntities(): DeviceItem[] {
    const controls: DeviceItem[] = this.controls();
    if (controls.length === 0) return this.store.entitiesInGroup(this.groupId).slice(0, 1);
    const primaryId: string = this.group()?.primaryEntityId ?? '';
    const sameDomain: boolean = controls.every((item: DeviceItem) => item.domain === controls[0].domain);
    return controls
      .filter((item: DeviceItem) => this.isMain(item, primaryId, sameDomain))
      .sort((a: DeviceItem, b: DeviceItem) =>
        (a.entityId === primaryId ? 0 : 1) - (b.entityId === primaryId ? 0 : 1));
  }

  // Vendor extras (child lock, indicator light, eco switches…), available ones first.
  private extraEntities(): DeviceItem[] {
    const mainIds: string[] = this.mainEntities().map((item: DeviceItem) => item.entityId);
    return this.controls()
      .filter((item: DeviceItem) => !mainIds.includes(item.entityId))
      .sort((a: DeviceItem, b: DeviceItem) => (a.available ? 0 : 1) - (b.available ? 0 : 1));
  }

  private sensorEntities(): DeviceItem[] {
    const primaryId: string = this.mainEntities()[0]?.entityId ?? '';
    return this.store.entitiesInGroup(this.groupId)
      .filter((item: DeviceItem) => isReadOnlyDomain(item.domain) &&
        item.entityId !== primaryId);
  }

  private canAct(item: DeviceItem): boolean {
    return item.available && this.store.online && this.store.actionEntityId.length === 0 &&
      quickAction(item) !== undefined;
  }

  // Pinning a device pins its primary entity (e.g. the AC's climate), which the 常用 card shows by device name.
  private primaryId(): string {
    return this.group()?.primaryEntityId ?? '';
  }

  private openEntity(id: string): void {
    this.getUIContext().getRouter().pushUrl(new EntityRoute(id), () => {});
  }

  build() {
    Stack() {
      List({ scroller: this.scroller, space: 8 }) {
      ListItem() { SystemHeader({ title: this.group()?.name ?? '设备' }) }
      ListItem() { SectionLabel({ title: '主要功能' }) }
      ForEach(this.mainEntities(), (entity: DeviceItem) => {
        ListItem() {
          Row() {
            ControlTile({
              title: entityDisplayName(entity, this.group()),
              subtitle: stateLabel(entity),
              icon: entityIcon(entity),
              actionIcon: actionIcon(entity),
              glyphColor: glyphColor(entity),
              actionLabel: quickAction(entity)?.label ?? '',
              actionColor: isActive(entity) ? Theme.ACTIVE : Theme.ACCENT,
              actionEnabled: this.canAct(entity),
              busy: this.store.actionEntityId === entity.entityId,
              onOpen: () => this.openEntity(entity.entityId),
              onAction: () => { this.store.runQuick(entity); }
            });
          }
          .width('100%').justifyContent(FlexAlign.Center);
        }
      }, (entity: DeviceItem) => entity.entityId + '|' + this.store.fetchedAt);
      if (this.primaryId().length > 0) {
        ListItem() {
          WideButton({
            label: this.store.isFavorite(this.primaryId()) ? '★ 已加入常用' : '☆ 加入常用',
            buttonColor: this.store.isFavorite(this.primaryId()) ? Theme.SELECTED : Theme.SECONDARY,
            onTap: () => { this.store.toggleFavorite(this.primaryId()); }
          })
        }
      }
      if (this.extraEntities().length > 0) {
        ListItem() {
          WideButton({ label: this.showExtras ? '收起更多控制' : '更多控制 · ' + this.extraEntities().length,
            onTap: () => { this.showExtras = !this.showExtras; } })
        }
        if (this.showExtras) {
          ForEach(this.extraEntities(), (entity: DeviceItem) => {
            ListItem() {
              Row() {
                ControlTile({
                  title: entityDisplayName(entity, this.group()),
                  subtitle: stateLabel(entity),
                  icon: entityIcon(entity),
                  actionIcon: actionIcon(entity),
                  glyphColor: glyphColor(entity),
                  actionLabel: quickAction(entity)?.label ?? '',
                  actionColor: isActive(entity) ? Theme.ACTIVE : Theme.ACCENT,
                  actionEnabled: this.canAct(entity),
                  busy: this.store.actionEntityId === entity.entityId,
                  onOpen: () => this.openEntity(entity.entityId),
                  onAction: () => { this.store.runQuick(entity); }
                });
              }
              .width('100%').justifyContent(FlexAlign.Center);
            }
          }, (entity: DeviceItem) => 'extra|' + entity.entityId + '|' + this.store.fetchedAt);
        }
      }
      if (this.sensorEntities().length > 0) {
        ListItem() {
          WideButton({ label: this.showSensors ? '收起附属状态' : '查看附属状态 · ' + this.sensorEntities().length,
            onTap: () => { this.showSensors = !this.showSensors; } })
        }
        if (this.showSensors) {
          ForEach(this.sensorEntities(), (entity: DeviceItem) => {
            ListItem() {
              Row() {
                SystemTile({
                  title: entityDisplayName(entity, this.group()),
                  subtitle: stateLabel(entity),
                  iconRes: entityIcon(entity),
                  iconBgColor: glyphColor(entity),
                  showChevron: true
                });
              }
              .width('100%').justifyContent(FlexAlign.Center)
              .onClick(() => this.openEntity(entity.entityId));
            }
          }, (entity: DeviceItem) => entity.entityId + '|' + this.store.fetchedAt);
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
    .width('100%').height('100%')
    .backgroundColor(Theme.BG);
  }
}
