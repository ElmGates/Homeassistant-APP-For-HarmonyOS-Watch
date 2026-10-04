import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { formBindingData, formProvider } from '@kit.FormKit';
import { DeviceItem } from '../direct/HomeAssistantModels';
import { HaEntityState } from '../direct/HaDirectClient';
import { isActive, quickAction, stateLabel } from '../../presentation/ui/DomainUi';

// One entity as the watch-face widgets show it. Everything is precomputed here: widget pages
// cannot import the app's code, they only render these fields.
export interface WidgetItem {
  id: string;
  name: string;
  domain: string;
  state: string;
  label: string;
  active: boolean;
  // Text of the one-tap action ("开", "关", "执行"…); empty when the widget can only open the app.
  action: string;
  // Key of a built-in icon (resources/base/media/ic_<icon>.svg), mapped to $r in the widget pages.
  icon: string;
}

export interface WidgetState {
  configured: boolean;
  // The app's 常用 list, in order: cards without their own selection show its first entries.
  favorites: string[];
  // Every entity any card may show (favorites plus each card's own selection).
  items: WidgetItem[];
  // Entity whose command is in flight, and when it started (a stale marker is ignored).
  pending: string;
  pendingAt: number;
  status: string;
}

// One widget instance on the watch. `name` is the form name from form_config.json (it fixes the
// size); `ids` is the user's own selection, empty to follow 常用.
export interface WidgetForm {
  id: string;
  name: string;
  ids: string[];
}

// Field names must match the @LocalStorageProp names in the widget pages.
interface CardData {
  formId: string;
  configured: boolean;
  pinned: boolean;
  itemsJson: string;
  pending: string;
  status: string;
}

interface FormError {
  code?: number;
}

const ICONS: Record<string, string> = {
  'light': 'light', 'switch': 'power', 'input_boolean': 'power', 'climate': 'climate', 'fan': 'fan',
  'humidifier': 'humidifier', 'cover': 'cover', 'scene': 'scene', 'script': 'script',
  'automation': 'automation', 'button': 'button', 'input_button': 'button', 'media_player': 'media',
  'vacuum': 'vacuum'
};

// Shared between the app (which publishes after every sync) and the widgets' FormExtensionAbility
// (which runs taps and periodic refreshes). They live in different processes, so every read
// drops the in-memory preferences cache first.
export class WidgetBridge {
  private readonly ctx: common.Context;
  private readonly fileName: string = 'ha_widget';

  constructor(ctx: common.Context) {
    this.ctx = ctx;
  }

  // How many entities a widget of this form shows.
  static slots(formName: string): number {
    if (formName === 'favorites_large') return 3;
    if (formName === 'favorites') return 2;
    return 1;
  }

  static sizeLabel(formName: string): string {
    if (formName === 'favorites_large') return '大卡片';
    if (formName === 'favorites') return '小卡片';
    if (formName === 'single_wide') return '长条卡片';
    return '圆形卡片';
  }

  static fromDevice(device: DeviceItem, name: string): WidgetItem {
    let icon: string = ICONS[device.domain] ?? 'sensor';
    if (device.domain === 'lock') icon = device.state === 'locked' ? 'lock' : 'lock_open';
    return {
      id: device.entityId,
      name: name,
      domain: device.domain,
      state: device.state,
      label: stateLabel(device),
      active: isActive(device),
      action: quickAction(device)?.label ?? '',
      icon: icon
    };
  }

  // A fresh state from HA, applied to a widget item (the widget keeps the app's display name).
  static toDevice(item: WidgetItem, state: HaEntityState): DeviceItem {
    return {
      entityId: item.id,
      name: item.name,
      domain: item.domain,
      state: state.state,
      areaId: '',
      available: state.state !== 'unavailable',
      attributes: state.attributes
    };
  }

  static clock(time: number): string {
    const date: Date = new Date(time);
    return String(date.getHours()).padStart(2, '0') + ':' + String(date.getMinutes()).padStart(2, '0');
  }

  // The entity IDs a widget shows: its own selection, or the first favorites.
  static idsFor(state: WidgetState, form: WidgetForm): string[] {
    const source: string[] = form.ids.length > 0 ? form.ids : state.favorites;
    return source.filter((id: string) => state.items.some((item: WidgetItem) => item.id === id))
      .slice(0, WidgetBridge.slots(form.name));
  }

  private prefs(): preferences.Preferences {
    preferences.removePreferencesFromCacheSync(this.ctx, { name: this.fileName });
    return preferences.getPreferencesSync(this.ctx, { name: this.fileName });
  }

  load(): WidgetState {
    const empty: WidgetState =
      { configured: false, favorites: [], items: [], pending: '', pendingAt: 0, status: '' };
    try {
      const parsed: WidgetState = JSON.parse(this.prefs().getSync('state', '') as string) as WidgetState;
      if (typeof parsed.configured !== 'boolean' || !Array.isArray(parsed.items)) return empty;
      // 1.6.0–1.6.2 stored only the first favorites as items.
      if (!Array.isArray(parsed.favorites)) parsed.favorites = parsed.items.map((item: WidgetItem) => item.id);
      return parsed;
    } catch (_) {
      return empty;
    }
  }

  forms(): WidgetForm[] {
    return this.readForms(this.prefs());
  }

  binding(state: WidgetState, form: WidgetForm): formBindingData.FormBindingData {
    const pendingFresh: boolean = state.pending.length > 0 && Date.now() - state.pendingAt < 20000;
    const ids: string[] = WidgetBridge.idsFor(state, form);
    const items: WidgetItem[] = [];
    ids.forEach((id: string) => {
      const item: WidgetItem | undefined = state.items.find((candidate: WidgetItem) => candidate.id === id);
      if (item) items.push(item);
    });
    const data: CardData = {
      formId: form.id,
      configured: state.configured,
      pinned: form.ids.length > 0,
      itemsJson: JSON.stringify(items),
      pending: pendingFresh ? state.pending : '',
      status: state.status
    };
    return formBindingData.createFormBindingData(data);
  }

  // Saves the state and redraws every widget on the watch.
  async publish(state: WidgetState): Promise<void> {
    const prefs: preferences.Preferences = this.prefs();
    prefs.putSync('state', JSON.stringify(state));
    await prefs.flush();
    const forms: WidgetForm[] = this.readForms(prefs);
    const gone: string[] = [];
    for (let i: number = 0; i < forms.length; i++) {
      try {
        await formProvider.updateForm(forms[i].id, this.binding(state, forms[i]));
      } catch (error) {
        // 16501001: the widget was removed while the app was not running.
        if ((error as FormError).code === 16501001) gone.push(forms[i].id);
      }
    }
    if (gone.length > 0) {
      await this.editForms((list: WidgetForm[]) => list.filter((form: WidgetForm) => !gone.includes(form.id)));
    }
  }

  async addForm(formId: string, formName: string): Promise<void> {
    await this.editForms((list: WidgetForm[]) => list.some((form: WidgetForm) => form.id === formId) ? list :
      list.concat([{ id: formId, name: formName, ids: [] }]));
  }

  async removeForm(formId: string): Promise<void> {
    await this.editForms((list: WidgetForm[]) => list.filter((form: WidgetForm) => form.id !== formId));
  }

  // The user's selection for one widget; an empty list makes it follow 常用 again.
  async setSelection(formId: string, ids: string[]): Promise<void> {
    await this.editForms((list: WidgetForm[]) => list.map((form: WidgetForm): WidgetForm =>
      form.id === formId ? { id: form.id, name: form.name, ids: ids.slice(0, WidgetBridge.slots(form.name)) } : form));
  }

  private async editForms(change: (list: WidgetForm[]) => WidgetForm[]): Promise<void> {
    const prefs: preferences.Preferences = this.prefs();
    prefs.putSync('forms', JSON.stringify(change(this.readForms(prefs))));
    await prefs.flush();
  }

  private readForms(prefs: preferences.Preferences): WidgetForm[] {
    try {
      const list: Object[] = JSON.parse(prefs.getSync('forms', '[]') as string) as Object[];
      if (!Array.isArray(list)) return [];
      const result: WidgetForm[] = [];
      list.forEach((entry: Object) => {
        if (typeof entry === 'string') {
          // 1.6.0–1.6.2 stored bare form IDs of the favorites widgets.
          result.push({ id: entry as string, name: 'favorites_large', ids: [] });
          return;
        }
        const form: WidgetForm = entry as WidgetForm;
        if (typeof form.id !== 'string' || form.id.length === 0) return;
        result.push({ id: form.id, name: typeof form.name === 'string' ? form.name : 'favorites_large',
          ids: Array.isArray(form.ids) ? form.ids : [] });
      });
      return result;
    } catch (_) {
      return [];
    }
  }
}
