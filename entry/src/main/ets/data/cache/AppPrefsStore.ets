import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

// Small app preferences that are not tied to a HA login: the home card shown at launch and the version of
// the usage terms the user accepted.
export class AppPrefsStore {
  private readonly ctx: common.Context;
  private readonly fileName: string = 'app_prefs';

  constructor(ctx: common.Context) {
    this.ctx = ctx;
  }

  async startPage(): Promise<number> {
    const prefs: preferences.Preferences = await preferences.getPreferences(this.ctx, this.fileName);
    const page: number = await prefs.get('start_page', 1) as number;
    return page >= 0 && page <= 3 ? page : 1;
  }

  async setStartPage(page: number): Promise<void> {
    const prefs: preferences.Preferences = await preferences.getPreferences(this.ctx, this.fileName);
    await prefs.put('start_page', page);
    await prefs.flush();
  }

  // Prefer the watch's Wi-Fi over the phone's Bluetooth while the app is open (on by default).
  async preferWifi(): Promise<boolean> {
    const prefs: preferences.Preferences = await preferences.getPreferences(this.ctx, this.fileName);
    return await prefs.get('prefer_wifi', true) as boolean;
  }

  async setPreferWifi(on: boolean): Promise<void> {
    const prefs: preferences.Preferences = await preferences.getPreferences(this.ctx, this.fileName);
    await prefs.put('prefer_wifi', on);
    await prefs.flush();
  }

  async acceptedTerms(): Promise<number> {
    const prefs: preferences.Preferences = await preferences.getPreferences(this.ctx, this.fileName);
    return await prefs.get('terms_version', 0) as number;
  }

  async acceptTerms(version: number): Promise<void> {
    const prefs: preferences.Preferences = await preferences.getPreferences(this.ctx, this.fileName);
    await prefs.put('terms_version', version);
    await prefs.flush();
  }
}
