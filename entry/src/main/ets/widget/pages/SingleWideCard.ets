// Wide 1×2 widget (about 112 × 56 vp): one entity with its name and state. Tapping runs its one-tap
// action; without a selection it opens the picker in the app. Top-level names carry a W_ / Wide
// prefix because all widget pages share one scope at compile time.
interface WideCardItem {
  id: string;
  name: string;
  label: string;
  active: boolean;
  action: string;
  icon: string;
  domain: string;
}

const W_BG: number = 0xFF0B111A;
const W_TEXT: number = 0xFFFFFFFF;
const W_TEXT_SUB: number = 0xFFAFC3D2;
const W_ICON_IDLE: number = 0xFF3A4E5E;
const W_ICON_ON: number = 0xFF2E8B74;
const W_ICON_LIGHT_ON: number = 0xFFC98A2E;

let wideStorage: LocalStorage = new LocalStorage();

@Entry(wideStorage)
@Component
struct SingleWideCard {
  @LocalStorageProp('formId') formId: string = '';
  @LocalStorageProp('configured') configured: boolean = false;
  @LocalStorageProp('itemsJson') itemsJson: string = '[]';
  @LocalStorageProp('pending') pending: string = '';

  private item(): WideCardItem | undefined {
    try {
      const parsed: WideCardItem[] = JSON.parse(this.itemsJson) as WideCardItem[];
      return Array.isArray(parsed) && parsed.length > 0 ? parsed[0] : undefined;
    } catch (e) {
      return undefined;
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

  private glyph(item: WideCardItem): number {
    if (!item.active) return W_ICON_IDLE;
    return item.domain === 'light' ? W_ICON_LIGHT_ON : W_ICON_ON;
  }

  private onTap(): void {
    const item: WideCardItem | undefined = this.item();
    if (!this.configured) {
      postCardAction(this, { action: 'router', abilityName: 'EntryAbility', params: { open: 'home' } });
    } else if (!item) {
      postCardAction(this, { action: 'router', abilityName: 'EntryAbility', params: { widgetFormId: this.formId } });
    } else if (item.action.length === 0) {
      postCardAction(this, { action: 'router', abilityName: 'EntryAbility', params: { open: 'home' } });
    } else if (this.pending.length === 0) {
      postCardAction(this, { action: 'message', params: { entityId: item.id } });
    }
  }

  build() {
    Row() {
      if (this.item() !== undefined) {
        Stack() {
          Image(this.icon(this.item()!.icon)).width(22).height(22).objectFit(ImageFit.Contain)
            .opacity(this.pending === this.item()!.id ? 0.35 : 1);
          if (this.pending === this.item()!.id) {
            Text('…').fontSize(16).fontColor(W_TEXT);
          }
        }
        .width(40).height(40).borderRadius(20)
        .backgroundColor(this.glyph(this.item()!));
        Column() {
          Text(this.item()!.name)
            .width('100%').fontSize(13).fontColor(W_TEXT).maxLines(1).textAlign(TextAlign.Start)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
          Text(this.item()!.label)
            .width('100%').fontSize(10).fontColor(W_TEXT_SUB).maxLines(1).textAlign(TextAlign.Start)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 6 });
      } else {
        Text(this.configured ? '+ 选择设备' : '打开应用登录')
          .width('100%').fontSize(12).fontColor(W_TEXT_SUB).textAlign(TextAlign.Center);
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 8, right: 10 })
    .borderRadius(999)
    .alignItems(VerticalAlign.Center)
    .backgroundColor(W_BG)
    .onClick(() => this.onTap());
  }
}
