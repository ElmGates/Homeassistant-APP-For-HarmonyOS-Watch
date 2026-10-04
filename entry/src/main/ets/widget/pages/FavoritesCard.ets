// Large watch-face widget (3×3): the first favorites with their state; tapping a row runs its one-tap action
// (handled by FavoritesFormAbility), tapping anywhere else opens the app. Widget pages cannot import
// app code, so the provider (data/widget/WidgetBridge.ets) sends ready-to-show fields.
interface CardItem {
  id: string;
  name: string;
  label: string;
  active: boolean;
  action: string;
  icon: string;
  domain: string;
}

const BG: number = 0xFF0B111A;
const TILE: number = 0xFF1B2732;
const TEXT: number = 0xFFFFFFFF;
const TEXT_SUB: number = 0xFFAFC3D2;
const TEXT_DIM: number = 0xFF9DB9CB;
const ICON_IDLE: number = 0xFF3A4E5E;
const ICON_ON: number = 0xFF2E8B74;
const ICON_LIGHT_ON: number = 0xFFC98A2E;
const ACCENT: number = 0xFF1F748A;
const ACTIVE: number = 0xFFB57728;

let storage: LocalStorage = new LocalStorage();

@Entry(storage)
@Component
struct FavoritesCard {
  @LocalStorageProp('formId') formId: string = '';
  @LocalStorageProp('configured') configured: boolean = false;
  @LocalStorageProp('pinned') pinned: boolean = false;
  @LocalStorageProp('itemsJson') itemsJson: string = '[]';
  @LocalStorageProp('pending') pending: string = '';
  @LocalStorageProp('status') status: string = '';

  private items(): CardItem[] {
    try {
      const parsed: CardItem[] = JSON.parse(this.itemsJson) as CardItem[];
      return Array.isArray(parsed) ? parsed : [];
    } catch (e) {
      return [];
    }
  }

  private icon(key: string): Resource {
    switch (key) {
      case 'light': return $r('app.media.ic_light');
      case 'power': return $r('app.media.ic_power');
      case 'climate': return $r('app.media.ic_climate');
      case 'fan': return $r('app.media.ic_fan');
      case 'humidifier': return $r('app.media.ic_humidifier');
      case 'cover': return $r('app.media.ic_cover');
      case 'lock': return $r('app.media.ic_lock');
      case 'lock_open': return $r('app.media.ic_lock_open');
      case 'scene': return $r('app.media.ic_scene');
      case 'script': return $r('app.media.ic_script');
      case 'automation': return $r('app.media.ic_automation');
      case 'button': return $r('app.media.ic_button');
      case 'media': return $r('app.media.ic_media');
      case 'vacuum': return $r('app.media.ic_vacuum');
      default: return $r('app.media.ic_sensor');
    }
  }

  private glyph(item: CardItem): number {
    if (!item.active) return ICON_IDLE;
    return item.domain === 'light' ? ICON_LIGHT_ON : ICON_ON;
  }

  private openApp(): void {
    postCardAction(this, { action: 'router', abilityName: 'EntryAbility', params: { open: 'home' } });
  }

  private refreshNow(): void {
    postCardAction(this, { action: 'message', params: { refresh: true } });
  }

  // Opens the app's picker for this widget's content.
  private pick(): void {
    postCardAction(this, { action: 'router', abilityName: 'EntryAbility', params: { widgetFormId: this.formId } });
  }

  private tap(item: CardItem): void {
    if (item.action.length === 0) {
      this.openApp();
      return;
    }
    if (this.pending.length > 0) return;
    postCardAction(this, { action: 'message', params: { entityId: item.id } });
  }

  // Sized for the 3×3 widget (about 170 vp square on a 1.6" watch): three rows plus title and status.
  @Builder
  row(item: CardItem) {
    Row() {
      Row() {
        Image(this.icon(item.icon)).width(17).height(17).objectFit(ImageFit.Contain);
      }
      .width(30).height(30).borderRadius(15)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(this.glyph(item));

      Column() {
        Text(item.name)
          .width('100%').fontSize(14).fontColor(TEXT).maxLines(1).textAlign(TextAlign.Start)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        Text(item.label)
          .width('100%').fontSize(11).fontColor(TEXT_SUB).maxLines(1).textAlign(TextAlign.Start)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 7, right: 4 });

      if (item.action.length > 0) {
        Text(this.pending === item.id ? '…' : item.action)
          .height(26).padding({ left: 10, right: 10 })
          .borderRadius(13)
          .fontSize(13).fontColor(TEXT)
          .backgroundColor(item.active ? ACTIVE : ACCENT);
      }
    }
    .width('94%')
    .height(40)
    .padding({ left: 5, right: 7 })
    .borderRadius(20)
    .backgroundColor(TILE)
    .alignItems(VerticalAlign.Center)
    .onClick(() => this.tap(item));
  }

  build() {
    Column({ space: 5 }) {
      Text(this.pinned ? '快捷' : '常用').fontSize(13).fontColor(TEXT_DIM).fontWeight(FontWeight.Medium);
      if (!this.configured) {
        Text('打开腕上智家登录').fontSize(13).fontColor(TEXT_SUB).textAlign(TextAlign.Center);
      } else if (this.items().length === 0) {
        Text('点此选择要显示的设备').fontSize(13).fontColor(TEXT_SUB).textAlign(TextAlign.Center)
          .onClick(() => this.pick());
      } else {
        ForEach(this.items(), (item: CardItem) => {
          this.row(item);
        }, (item: CardItem) => item.id + '|' + item.label + '|' + item.action + '|' + this.pending);
      }
      if (this.status.length > 0) {
        // Tap target taller than the text: the line is small on the watch.
        Text(this.status.startsWith('已更新') ? this.status + ' · 点此刷新' : this.status)
          .width('90%').fontSize(10).fontColor(TEXT_DIM).maxLines(1)
          .padding({ top: 4, bottom: 4 })
          .textAlign(TextAlign.Center)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .onClick(() => this.refreshNow());
      }
    }
    .width('100%')
    .height('100%')
    .padding(6)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(BG)
    .onClick(() => this.openApp());
  }
}
