// Round 1×1 widget (about 56 vp): one entity as a big icon button. Tapping runs its one-tap
// action; without a selection it shows "+" and opens the picker in the app. Top-level names carry an
// R_ / Round prefix because all widget pages share one scope at compile time.
interface RoundCardItem {
  id: string;
  name: string;
  label: string;
  active: boolean;
  action: string;
  icon: string;
  domain: string;
}

const R_TEXT: number = 0xFFFFFFFF;
const R_ICON_IDLE: number = 0xFF3A4E5E;
const R_ICON_ON: number = 0xFF2E8B74;
const R_ICON_LIGHT_ON: number = 0xFFC98A2E;
const R_EMPTY: number = 0xFF1B2732;

let roundStorage: LocalStorage = new LocalStorage();

@Entry(roundStorage)
@Component
struct SingleRoundCard {
  @LocalStorageProp('formId') formId: string = '';
  @LocalStorageProp('configured') configured: boolean = false;
  @LocalStorageProp('itemsJson') itemsJson: string = '[]';
  @LocalStorageProp('pending') pending: string = '';

  private item(): RoundCardItem | undefined {
    try {
      const parsed: RoundCardItem[] = JSON.parse(this.itemsJson) as RoundCardItem[];
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

  private glyph(item: RoundCardItem): number {
    if (!item.active) return R_ICON_IDLE;
    return item.domain === 'light' ? R_ICON_LIGHT_ON : R_ICON_ON;
  }

  private onTap(): void {
    const item: RoundCardItem | undefined = this.item();
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
    Stack() {
      if (this.item() !== undefined) {
        Image(this.icon(this.item()!.icon))
          .width('46%').height('46%').objectFit(ImageFit.Contain)
          .opacity(this.pending === this.item()!.id ? 0.35 : 1);
        if (this.pending === this.item()!.id) {
          Text('…').fontSize(18).fontColor(R_TEXT);
        }
      } else {
        Text('+').fontSize(26).fontColor(R_TEXT);
      }
    }
    .width('100%')
    .height('100%')
    .borderRadius(999)
    .backgroundColor(this.item() !== undefined ? this.glyph(this.item()!) : R_EMPTY)
    .onClick(() => this.onTap());
  }
}
