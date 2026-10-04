import { AppStorageV2 } from '@ohos.arkui.StateManagement';
import { DirectStore } from '../presentation/store/DirectStore';
import { DeviceItem } from '../data/direct/HomeAssistantModels';
import { WidgetBridge, WidgetForm } from '../data/widget/WidgetBridge';
import { SystemHeader } from '../presentation/ui/components/SystemHeader';
import { SystemTile } from '../presentation/ui/components/SystemTile';
import { InfoText, WideButton } from '../presentation/ui/components/Controls';
import { glyphColor, stateLabel } from '../presentation/ui/DomainUi';
import { entityIcon } from '../presentation/ui/Icons';
import { Theme } from '../presentation/ui/Theme';
import { safeError } from '../core/utils/SafeError';
import { ArcScrollBar } from '@kit.ArkUI';

interface WidgetRouteParams {
  formId?: string;
}

// Lists the widgets on the watch face and lets the user pick what each one shows.
// Opened from Settings (list first) or from a widget / the system's edit menu (straight to one widget).
@Entry
@ComponentV2
struct WidgetSettings {
  @Local private store: DirectStore =
    AppStorageV2.connect(DirectStore, 'directStore', () => new DirectStore())!;
  @Local private forms: WidgetForm[] = [];
  // Widget being edited; empty shows the list.
  @Local private formId: string = '';
  @Local private selected: string[] = [];
  @Local private errorText: string = '';
  private openedForOne: boolean = false;
  private readonly scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.forms = this.store.widgetForms();
    const params: WidgetRouteParams | undefined =
      this.getUIContext().getRouter().getParams() as WidgetRouteParams | undefined;
    if (params?.formId) {
      this.openedForOne = true;
      this.edit(params.formId);
    }
  }

  private current(): WidgetForm | undefined {
    return this.forms.find((form: WidgetForm) => form.id === this.formId);
  }

  private slots(): number {
    const form: WidgetForm | undefined = this.current();
    return form ? WidgetBridge.slots(form.name) : 1;
  }

  private edit(formId: string): void {
    const form: WidgetForm | undefined = this.forms.find((candidate: WidgetForm) => candidate.id === formId);
    if (!form) {
      this.errorText = '没有找到这张卡片，请在手表上重新添加';
      return;
    }
    this.errorText = '';
    this.formId = formId;
    this.selected = form.ids.slice();
  }

  private title(form: WidgetForm, index: number): string {
    const sameSize: WidgetForm[] = this.forms.filter((candidate: WidgetForm) => candidate.name === form.name);
    const position: number = this.forms.filter((candidate: WidgetForm, i: number) =>
      i <= index && candidate.name === form.name).length;
    return WidgetBridge.sizeLabel(form.name) + (sameSize.length > 1 ? ' ' + position : '');
  }

  private summary(form: WidgetForm): string {
    if (form.ids.length === 0) return '跟随常用';
    const names: string[] = [];
    form.ids.forEach((id: string) => {
      const device: DeviceItem | undefined = this.store.getDevice(id);
      names.push(device ? this.store.favoriteName(device) : '已删除的设备');
    });
    return names.join('、');
  }

  private toggle(item: DeviceItem): void {
    const id: string = item.entityId;
    if (this.selected.includes(id)) {
      this.selected = this.selected.filter((candidate: string) => candidate !== id);
      return;
    }
    if (this.slots() === 1) {
      this.selected = [id];
      this.save(false);
      return;
    }
    if (this.selected.length < this.slots()) this.selected = this.selected.concat([id]);
  }

  private async save(followFavorites: boolean): Promise<void> {
    try {
      await this.store.setWidgetSelection(this.formId, followFavorites ? [] : this.selected);
    } catch (error) {
      this.errorText = safeError(error, '保存失败');
      return;
    }
    if (this.openedForOne) {
      this.getUIContext().getRouter().back();
      return;
    }
    this.forms = this.store.widgetForms();
    this.formId = '';
  }

  private subtitleFor(item: DeviceItem): string {
    const index: number = this.selected.indexOf(item.entityId);
    if (index < 0) return stateLabel(item);
    return this.slots() > 1 ? '已选 · 第 ' + (index + 1) + ' 个' : '已选';
  }

  build() {
    Stack() {
      List({ scroller: this.scroller, space: 8 }) {
        if (this.formId.length === 0) {
          ListItem() { SystemHeader({ title: '表盘卡片' }) }
          if (this.forms.length === 0) {
            ListItem() {
              InfoText({ text: '还没有添加卡片。在手表的卡片列表中添加「腕上智家」的卡片后，可以在这里更换显示内容。',
                textSize: 13 })
            }
          }
          ForEach(this.forms, (form: WidgetForm, index: number) => {
            ListItem() {
              Row() {
                SystemTile({
                  title: this.title(form, index),
                  subtitle: this.summary(form),
                  iconRes: $r('app.media.ic_select'),
                  iconBgColor: Theme.ACCENT,
                  showChevron: true
                });
              }
              .width('100%').justifyContent(FlexAlign.Center)
              .onClick(() => this.edit(form.id));
            }
          }, (form: WidgetForm) => form.id + '|' + form.ids.join(','));
        } else {
          ListItem() { SystemHeader({ title: this.current() ? WidgetBridge.sizeLabel(this.current()!.name) : '卡片' }) }
          ListItem() {
            InfoText({ text: this.slots() > 1 ? '最多选 ' + this.slots() + ' 个，按选择顺序显示' : '选择一个设备或场景',
              textSize: 13 })
          }
          ListItem() {
            WideButton({ label: '跟随常用', buttonColor: this.selected.length === 0 ? Theme.SELECTED : Theme.SECONDARY,
              onTap: () => { this.save(true); } })
          }
          if (this.slots() > 1) {
            ListItem() {
              WideButton({ label: '保存', buttonColor: Theme.ACCENT, canTap: this.selected.length > 0,
                onTap: () => { this.save(false); } })
            }
          }
          ForEach(this.store.widgetCandidates(), (item: DeviceItem) => {
            ListItem() {
              Row() {
                SystemTile({
                  title: this.store.favoriteName(item),
                  subtitle: this.subtitleFor(item),
                  iconRes: entityIcon(item),
                  iconBgColor: glyphColor(item),
                  showChevron: false,
                  bgColor: this.selected.includes(item.entityId) ? Theme.SELECTED : Theme.TILE
                });
              }
              .width('100%').justifyContent(FlexAlign.Center)
              .onClick(() => this.toggle(item));
            }
          }, (item: DeviceItem) => item.entityId + '|' + this.selected.indexOf(item.entityId));
        }
        if (this.errorText.length > 0) {
          ListItem() { InfoText({ text: this.errorText, textColor: Theme.ERROR }) }
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
