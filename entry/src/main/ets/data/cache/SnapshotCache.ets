import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { HomeAssistantSnapshot } from '../direct/HomeAssistantModels';

export class SnapshotCache {
  private readonly ctx: common.UIAbilityContext;
  private readonly fileName: string = 'ha_snapshot_cache';
  private readonly chunkSize: number = 4000;

  constructor(ctx: common.UIAbilityContext) {
    this.ctx = ctx;
  }

  async load(): Promise<HomeAssistantSnapshot | undefined> {
    const prefs: preferences.Preferences = await preferences.getPreferences(this.ctx, this.fileName);
    const count: number = await prefs.get('count', 0) as number;
    if (count < 1 || count > 50) return undefined;
    let json: string = '';
    for (let i: number = 0; i < count; i++) {
      json += await prefs.get('chunk_' + i, '') as string;
    }
    if (!json) return undefined;
    try {
      const snapshot: HomeAssistantSnapshot = JSON.parse(json) as HomeAssistantSnapshot;
      if (!Array.isArray(snapshot.rooms) || !Array.isArray(snapshot.devices) || !Array.isArray(snapshot.groups) ||
        typeof snapshot.fetchedAt !== 'number') return undefined;
      return snapshot;
    } catch (_) {
      return undefined;
    }
  }

  async save(snapshot: HomeAssistantSnapshot): Promise<void> {
    const json: string = JSON.stringify(snapshot);
    const count: number = Math.ceil(json.length / this.chunkSize);
    if (count < 1 || count > 50) return;
    const prefs: preferences.Preferences = await preferences.getPreferences(this.ctx, this.fileName);
    const oldCount: number = await prefs.get('count', 0) as number;
    for (let i: number = 0; i < count; i++) {
      await prefs.put('chunk_' + i, json.substring(i * this.chunkSize, (i + 1) * this.chunkSize));
    }
    for (let i: number = count; i < oldCount; i++) await prefs.delete('chunk_' + i);
    await prefs.put('count', count);
    await prefs.flush();
  }

  async clear(): Promise<void> {
    const prefs: preferences.Preferences = await preferences.getPreferences(this.ctx, this.fileName);
    const count: number = await prefs.get('count', 0) as number;
    for (let i: number = 0; i < count; i++) await prefs.delete('chunk_' + i);
    await prefs.delete('count');
    await prefs.flush();
  }
}
