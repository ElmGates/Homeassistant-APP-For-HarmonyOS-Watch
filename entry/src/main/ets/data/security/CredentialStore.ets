import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { huks } from '@kit.UniversalKeystoreKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';

export interface ConnectionCredentials {
  server: string;
  refreshToken: string;
  allowLocalHttp: boolean;
  // LAN address used at home ('' when not set), and whether the user turned LAN access off.
  lanUrl: string;
  lanOff: boolean;
  // The LAN address was found automatically (re-detected at launch) rather than typed by the user.
  lanAuto: boolean;
}

// The short-lived access token, kept so a restart within its lifetime skips the token exchange
// (one HTTPS round trip, slow over the phone's Bluetooth).
export interface CachedAccess {
  token: string;
  expiresAt: number;
}

interface HuksFailure {
  code?: number;
}

export class CredentialStore {
  private readonly ctx: common.Context;
  private readonly alias: string = 'ha_watch_refresh_aes_gcm_v1';
  private readonly legacyAlias: string = 'ha_watch_token_aes_gcm_v1';
  private readonly fileName: string = 'ha_connection';

  constructor(ctx: common.Context) {
    this.ctx = ctx;
  }

  // The widget runs in its own process: drop its cached copy so a new login in the app is picked up.
  reloadFromDisk(): void {
    preferences.removePreferencesFromCacheSync(this.ctx, { name: this.fileName });
  }

  async load(): Promise<ConnectionCredentials | undefined> {
    const prefs: preferences.Preferences = await preferences.getPreferences(this.ctx, this.fileName);
    await this.purgeLegacy(prefs);
    const server: string = await prefs.get('oauth_server', '') as string;
    const nonceHex: string = await prefs.get('oauth_nonce', '') as string;
    const cipherHex: string = await prefs.get('oauth_cipher', '') as string;
    const allowLocalHttp: boolean = await prefs.get('oauth_local_http', false) as boolean;
    if (!server || !nonceHex || !cipherHex) return undefined;
    if (!await this.keyExists()) {
      throw new Error('安全密钥丢失，请重新授权');
    }
    const nonce: Uint8Array = this.fromHex(nonceHex);
    const ciphertext: Uint8Array = this.fromHex(cipherHex);
    if (nonce.length !== 12 || ciphertext.length < 17) {
      throw new Error('安全凭证损坏，请重新授权');
    }
    const options: huks.HuksOptions = {
      properties: this.operationProperties(huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT, nonce,
        ciphertext.slice(ciphertext.length - 16)),
      inData: ciphertext.slice(0, ciphertext.length - 16)
    };
    const session: huks.HuksSessionHandle = await huks.initSession(this.alias, options);
    const result: huks.HuksReturnResult = await huks.finishSession(session.handle, options);
    if (!result.outData) throw new Error('安全凭证解密失败');
    const lanUrl: string = await prefs.get('lan_url', '') as string;
    const lanOff: boolean = await prefs.get('lan_off', false) as boolean;
    const lanAuto: boolean = await prefs.get('lan_auto', false) as boolean;
    return { server, refreshToken: this.fromBytes(result.outData), allowLocalHttp, lanUrl, lanOff, lanAuto };
  }

  async save(server: string, refreshToken: string, allowLocalHttp: boolean): Promise<void> {
    await this.ensureKey();
    const nonce: Uint8Array = cryptoFramework.createRandom().generateRandomSync(12).data;
    const options: huks.HuksOptions = {
      properties: this.operationProperties(huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT, nonce),
      inData: this.toBytes(refreshToken)
    };
    const session: huks.HuksSessionHandle = await huks.initSession(this.alias, options);
    const result: huks.HuksReturnResult = await huks.finishSession(session.handle, options);
    if (!result.outData || result.outData.length < 17) throw new Error('刷新凭证加密失败');
    const prefs: preferences.Preferences = await preferences.getPreferences(this.ctx, this.fileName);
    await this.purgeLegacy(prefs);
    await prefs.put('oauth_server', server);
    await prefs.put('oauth_nonce', this.toHex(nonce));
    await prefs.put('oauth_cipher', this.toHex(result.outData));
    await prefs.put('oauth_local_http', allowLocalHttp);
    await prefs.flush();
  }

  async saveAccess(token: string, expiresAt: number): Promise<void> {
    if (!await this.keyExists()) return;
    const nonce: Uint8Array = cryptoFramework.createRandom().generateRandomSync(12).data;
    const options: huks.HuksOptions = {
      properties: this.operationProperties(huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT, nonce),
      inData: this.toBytes(token)
    };
    const session: huks.HuksSessionHandle = await huks.initSession(this.alias, options);
    const result: huks.HuksReturnResult = await huks.finishSession(session.handle, options);
    if (!result.outData || result.outData.length < 17) return;
    const prefs: preferences.Preferences = await preferences.getPreferences(this.ctx, this.fileName);
    await prefs.put('access_nonce', this.toHex(nonce));
    await prefs.put('access_cipher', this.toHex(result.outData));
    await prefs.put('access_expires', expiresAt);
    await prefs.flush();
  }

  async loadAccess(): Promise<CachedAccess | undefined> {
    const prefs: preferences.Preferences = await preferences.getPreferences(this.ctx, this.fileName);
    const expiresAt: number = await prefs.get('access_expires', 0) as number;
    const nonceHex: string = await prefs.get('access_nonce', '') as string;
    const cipherHex: string = await prefs.get('access_cipher', '') as string;
    if (Date.now() + 120000 >= expiresAt || !nonceHex || !cipherHex || !await this.keyExists()) return undefined;
    const nonce: Uint8Array = this.fromHex(nonceHex);
    const ciphertext: Uint8Array = this.fromHex(cipherHex);
    if (nonce.length !== 12 || ciphertext.length < 17) return undefined;
    const options: huks.HuksOptions = {
      properties: this.operationProperties(huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT, nonce,
        ciphertext.slice(ciphertext.length - 16)),
      inData: ciphertext.slice(0, ciphertext.length - 16)
    };
    const session: huks.HuksSessionHandle = await huks.initSession(this.alias, options);
    const result: huks.HuksReturnResult = await huks.finishSession(session.handle, options);
    if (!result.outData) return undefined;
    return { token: this.fromBytes(result.outData), expiresAt: expiresAt };
  }

  // Not secret (a LAN address), so stored in plain preferences next to the encrypted token.
  async saveLan(lanUrl: string, lanOff: boolean, lanAuto: boolean): Promise<void> {
    const prefs: preferences.Preferences = await preferences.getPreferences(this.ctx, this.fileName);
    await prefs.put('lan_url', lanUrl);
    await prefs.put('lan_off', lanOff);
    await prefs.put('lan_auto', lanAuto);
    await prefs.flush();
  }

  async clear(): Promise<void> {
    const prefs: preferences.Preferences = await preferences.getPreferences(this.ctx, this.fileName);
    await prefs.delete('lan_url');
    await prefs.delete('lan_off');
    await prefs.delete('lan_auto');
    await prefs.delete('access_nonce');
    await prefs.delete('access_cipher');
    await prefs.delete('access_expires');
    await prefs.delete('oauth_server');
    await prefs.delete('oauth_nonce');
    await prefs.delete('oauth_cipher');
    await prefs.delete('oauth_local_http');
    await prefs.flush();
    if (await this.keyExists()) {
      await huks.deleteKeyItem(this.alias, {});
    }
    await this.purgeLegacy(prefs);
  }

  private async purgeLegacy(prefs: preferences.Preferences): Promise<void> {
    const oldCipher: string = await prefs.get('cipher', '') as string;
    const oldServer: string = await prefs.get('server', '') as string;
    if (oldCipher || oldServer) {
      await prefs.delete('server');
      await prefs.delete('nonce');
      await prefs.delete('cipher');
      await prefs.flush();
    }
    try {
      if (await huks.isKeyItemExist(this.legacyAlias, {})) {
        await huks.deleteKeyItem(this.legacyAlias, {});
      }
    } catch (_) {
      // A missing legacy key is normal during the migration.
    }
  }

  private async ensureKey(): Promise<void> {
    if (await this.keyExists()) return;
    const properties: huks.HuksParam[] = [
      { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
      { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
      { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value:
        huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT | huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT },
      { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE },
      { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM }
    ];
    await huks.generateKeyItem(this.alias, { properties });
  }

  private async keyExists(): Promise<boolean> {
    try {
      return await huks.isKeyItemExist(this.alias, {});
    } catch (error) {
      // A missing key is reported as an exception on some HUKS implementations.
      const failure: HuksFailure = error as HuksFailure;
      if (failure?.code === 12000011 || failure?.code === -13) return false;
      throw new Error('安全密钥检查失败' +
        (typeof failure?.code === 'number' ? '（错误码 ' + failure.code + '）' : ''));
    }
  }

  private operationProperties(purpose: huks.HuksKeyPurpose, nonce: Uint8Array,
    tag?: Uint8Array): huks.HuksParam[] {
    const properties: huks.HuksParam[] = [
      { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
      { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
      { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: purpose },
      { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE },
      { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM },
      { tag: huks.HuksTag.HUKS_TAG_NONCE, value: nonce }
    ];
    if (tag) properties.push({ tag: huks.HuksTag.HUKS_TAG_AE_TAG, value: tag });
    return properties;
  }

  private toBytes(value: string): Uint8Array {
    const bytes: number[] = [];
    for (let i: number = 0; i < value.length; i++) bytes.push(value.charCodeAt(i));
    return new Uint8Array(bytes);
  }

  private fromBytes(bytes: Uint8Array): string {
    let result: string = '';
    for (let i: number = 0; i < bytes.length; i++) result += String.fromCharCode(bytes[i]);
    return result;
  }

  private toHex(bytes: Uint8Array): string {
    let result: string = '';
    for (let i: number = 0; i < bytes.length; i++) result += bytes[i].toString(16).padStart(2, '0');
    return result;
  }

  private fromHex(hex: string): Uint8Array {
    const bytes: number[] = [];
    for (let i: number = 0; i < hex.length; i += 2) bytes.push(parseInt(hex.substring(i, i + 2), 16));
    return new Uint8Array(bytes);
  }
}
