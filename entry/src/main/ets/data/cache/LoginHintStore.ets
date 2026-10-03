import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

// Remembers the last HA address that logged in successfully, to prefill the login forms.
// Only the address — never the username or password. Kept across "更换服务器" on purpose.
export class LoginHintStore {
  private readonly ctx: common.UIAbilityContext;
  private readonly fileName: string = 'ha_login_hint';

  constructor(ctx: common.UIAbilityContext) {
    this.ctx = ctx;
  }

  async load(): Promise<string> {
    const prefs: preferences.Preferences = await preferences.getPreferences(this.ctx, this.fileName);
    return await prefs.get('server', '') as string;
  }

  async save(server: string): Promise<void> {
    const prefs: preferences.Preferences = await preferences.getPreferences(this.ctx, this.fileName);
    await prefs.put('server', server);
    await prefs.flush();
  }
}
