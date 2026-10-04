// Small watch-face widget (2×2, about 110 vp square): the first two favorites as round buttons.
// Same data and tap handling as FavoritesCard.ets. Widget pages cannot share code, and their top-level
// names share one scope at compile time, so everything here carries an S_ / Small prefix.
interface SmallCardItem {
  id: string;
  name: string;
  label: string;
  active: boolean;
  action: string;
  icon: string;
  domain: string;
}

const S_BG: number = 0xFF0B111A;
const S_TEXT: number = 0xFFFFFFFF;
const S_TEXT_SUB: number = 0xFFAFC3D2;
const S_TEXT_DIM: number = 0xFF9DB9CB;
const S_ICON_IDLE: number = 0xFF3A4E5E;
const S_ICON_ON: number = 0xFF2E8B74;
const S_ICON_LIGHT_ON: number = 0xFFC98A2E;

let smallStorage: LocalStorage = new LocalStorage();

@Entry(smallStorage)
@Component
struct FavoritesSmallCard {
  @LocalStorageProp('formId') formId: string = '';
  @LocalStorageProp('configured') configured: boolean = false;
  @LocalStorageProp('pinned') pinned: boolean = false;
  @LocalStorageProp('itemsJson') itemsJson: string = '[]';
  @LocalStorageProp('pending') pending: string = '';
  @LocalStorageProp('status') status: string = '';

  private items(): SmallCardItem[] {
    try {
      const parsed: SmallCardItem[] = JSON.parse(this.itemsJson) as SmallCardItem[];
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

  private glyph(item: SmallCardItem): number {
    if (!item.active) return S_ICON_IDLE;
    return item.domain === 'light' ? S_ICON_LIGHT_ON : S_ICON_ON;
  }

  private openApp(): void {
    postCardAction(this, { action: 'router', abilityName: 'EntryAbility', params: { open: 'home' } });
  }

  // Opens the app's picker for this widget's content.
  private pick(): void {
    postCardAction(this, { action: 'router', abilityName: 'EntryAbility', params: { widgetFormId: this.formId } });
  }

  private tap(item: SmallCardItem): void {
    if (item.action.length === 0) {
      this.openApp();
      return;
    }
    if (this.pending.length > 0) return;
    postCardAction(this, { action: 'message', params: { entityId: item.id } });
  }

  @Builder
  button(item: SmallCardItem) {
    Column({ space: 3 }) {
      Stack() {
        Image(this.icon(item.icon)).width(24).height(24).objectFit(ImageFit.Contain)
          .opacity(this.pending === item.id ? 0.35 : 1);
        if (this.pending === item.id) {
          Text('…').fontSize(16).fontColor(S_TEXT);
        }
      }
      .width(44).height(44).borderRadius(22)
      .backgroundColor(this.glyph(item));
      Text(item.name)
        .width(48).fontSize(10).fontColor(S_TEXT_SUB).maxLines(1)
        .textAlign(TextAlign.Center)
        .textOverflow({ overflow: TextOverflow.Ellipsis });
    }
    .onClick(() => this.tap(item));
  }

  build() {
    Column({ space: 5 }) {
      Text(this.pinned ? '快捷' : '常用').fontSize(11).fontColor(S_TEXT_DIM).fontWeight(FontWeight.Medium);
      if (!this.configured) {
        Text('打开应用登录').fontSize(11).fontColor(S_TEXT_SUB).textAlign(TextAlign.Center);
      } else if (this.items().length === 0) {
        Text('点此选择设备').fontSize(11).fontColor(S_TEXT_SUB).textAlign(TextAlign.Center)
          .onClick(() => this.pick());
      } else {
        Row({ space: 8 }) {
          ForEach(this.items().slice(0, 2), (item: SmallCardItem) => {
            this.button(item);
          }, (item: SmallCardItem) => item.id + '|' + item.active + '|' + item.action + '|' + this.pending);
        }
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(S_BG)
    .onClick(() => this.openApp());
  }
}
