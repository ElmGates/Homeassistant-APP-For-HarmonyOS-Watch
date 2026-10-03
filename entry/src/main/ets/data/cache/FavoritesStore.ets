import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

// Ordered list of entity IDs pinned to the home screen. Not sensitive, stored in plain preferences.
export class FavoritesStore {
  private readonly ctx: common.UIAbilityContext;
  private readonly fileName: string = 'ha_favorites';

  constructor(ctx: common.UIAbilityContext) {
    this.ctx = ctx;
  }

  async load(): Promise<string[]> {
    const prefs: preferences.Preferences = await preferences.getPreferences(this.ctx, this.fileName);
    const raw: string = await prefs.get('ids', '[]') as string;
    try {
      const parsed: string[] = JSON.parse(raw) as string[];
      if (!Array.isArray(parsed)) return [];
      const ids: string[] = [];
      parsed.forEach((value: string) => {
        if (typeof value === 'string' && value.length > 0 && !ids.includes(value)) ids.push(value);
      });
      return ids;
    } catch (_) {
      return [];
    }
  }

  async save(ids: string[]): Promise<void> {
    const prefs: preferences.Preferences = await preferences.getPreferences(this.ctx, this.fileName);
    await prefs.put('ids', JSON.stringify(ids));
    await prefs.flush();
  }

  async clear(): Promise<void> {
    const prefs: preferences.Preferences = await preferences.getPreferences(this.ctx, this.fileName);
    await prefs.delete('ids');
    await prefs.flush();
  }
}
