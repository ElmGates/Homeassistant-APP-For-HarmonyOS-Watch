import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { DataSourceCache } from '../direct/HomeAssistantDataSource';

// The trimmed HA registry and the list of shown entities, kept across launches so a cold start syncs only
// the states the watch needs. Not sensitive (names and IDs); cleared with the other caches on logout.
export class RegistryCache {
  private readonly ctx: common.Context;
  private readonly fileName: string = 'ha_registry_cache';
  // Preference values are size-limited; Chinese text takes 3 bytes per character in UTF-8.
  private readonly chunkSize: number = 2500;
  private readonly maxChunks: number = 400;

  constructor(ctx: common.Context) {
    this.ctx = ctx;
  }

  async load(): Promise<DataSourceCache | undefined> {
    const prefs: preferences.Preferences = await preferences.getPreferences(this.ctx, this.fileName);
    const count: number = await prefs.get('count', 0) as number;
    if (count < 1 || count > this.maxChunks) return undefined;
    let json: string = '';
    for (let i: number = 0; i < count; i++) {
      json += await prefs.get('chunk_' + i, '') as string;
    }
    try {
      const cache: DataSourceCache = JSON.parse(json) as DataSourceCache;
      if (!cache.registry || !Array.isArray(cache.registry.entities) || typeof cache.registryAt !== 'number') {
        return undefined;
      }
      return cache;
    } catch (_) {
      return undefined;
    }
  }

  async save(cache: DataSourceCache): Promise<void> {
    const json: string = JSON.stringify(cache);
    const count: number = Math.ceil(json.length / this.chunkSize);
    if (count < 1 || count > this.maxChunks) return;
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
