import { http } from '@kit.NetworkKit';
import { isTransientNetworkError } from '../../core/utils/SafeError';

export interface HaEntityState {
  entity_id: string;
  state: string;
  attributes?: HaEntityAttributes;
}

export interface HaEntityAttributes {
  friendly_name?: string;
  icon?: string;
  device_class?: string;
  brightness?: number;
  supported_features?: number;
  current_position?: number;
  temperature?: number;
  current_temperature?: number;
  min_temp?: number;
  max_temp?: number;
  unit_of_measurement?: string;
  target_temp_step?: number;
  hvac_modes?: string[];
  options?: string[];
  percentage?: number;
  percentage_step?: number;
  volume_level?: number;
  media_title?: string;
  media_artist?: string;
  min?: number;
  max?: number;
  step?: number;
}

export interface ServiceData {
  brightness_pct?: number;
  position?: number;
  temperature?: number;
  hvac_mode?: string;
  option?: string;
  percentage?: number;
  volume_level?: number;
  value?: number;
}

// Only these watch-safe services may be called. Anything else is rejected before reaching HA.
export const ALLOWED_SERVICES: Record<string, string[]> = {
  'light': ['turn_on', 'turn_off'],
  'switch': ['turn_on', 'turn_off'],
  'input_boolean': ['turn_on', 'turn_off'],
  'fan': ['turn_on', 'turn_off', 'set_percentage'],
  'humidifier': ['turn_on', 'turn_off'],
  'cover': ['open_cover', 'stop_cover', 'close_cover', 'set_cover_position'],
  'climate': ['turn_on', 'turn_off', 'set_temperature', 'set_hvac_mode'],
  'select': ['select_option'],
  'input_select': ['select_option'],
  'number': ['set_value'],
  'input_number': ['set_value'],
  'scene': ['turn_on'],
  'script': ['turn_on'],
  'automation': ['trigger', 'turn_on', 'turn_off'],
  'button': ['press'],
  'input_button': ['press'],
  'lock': ['lock', 'unlock'],
  'media_player': ['turn_on', 'turn_off', 'media_play', 'media_pause', 'media_next_track',
    'media_previous_track', 'volume_set'],
  'vacuum': ['start', 'pause', 'return_to_base']
};

interface ServicePayload extends ServiceData {
  entity_id: string;
}

export class HaDirectClient {
  private baseUrl: string;
  private token: string;

  constructor(baseUrl: string, token: string) {
    const cleanUrl: string = baseUrl.trim().replace(/\/+$/, '');
    const secure: boolean = /^https:\/\/[a-z0-9.-]+(?::[0-9]{1,5})?$/i.test(cleanUrl);
    const localHttp: boolean = /^http:\/\/(?:(?:10|127|192\.168)\.[0-9.]+|172\.(?:1[6-9]|2[0-9]|3[01])\.[0-9.]+|localhost|[a-z0-9-]+\.local)(?::[0-9]{1,5})?$/i.test(cleanUrl);
    if (!secure && !localHttp) {
      throw new Error('请输入 HTTPS 地址，或局域网 HTTP 地址');
    }
    if (token.trim().length === 0) {
      throw new Error('请重新登录 HA');
    }
    this.baseUrl = cleanUrl;
    this.token = token.trim();
  }

  async readEntity(entityId: string): Promise<HaEntityState> {
    const result: string = await this.getWithRetry('/api/states/' + encodeURIComponent(entityId), 15000);
    const parsed: HaEntityState = JSON.parse(result) as HaEntityState;
    if (parsed.entity_id !== entityId || typeof parsed.state !== 'string') {
      throw new Error('HA 返回了不正确的实体状态');
    }
    return parsed;
  }

  async listStates(): Promise<HaEntityState[]> {
    // The full state list is the largest response (hundreds of KB on a big install) and often travels
    // through tunnels and mobile data, so it gets the longest timeout.
    const result: string = await this.getWithRetry('/api/states', 30000);
    const states: HaEntityState[] = JSON.parse(result) as HaEntityState[];
    if (!Array.isArray(states)) {
      throw new Error('HA 返回的实体列表格式不正确');
    }
    return states;
  }

  async callService(domain: string, service: string, entityId: string,
    extraData?: ServiceData): Promise<void> {
    const allowed: string[] | undefined = ALLOWED_SERVICES[domain];
    if (!allowed || !allowed.includes(service)) {
      throw new Error('不支持的设备操作');
    }
    const payload: ServicePayload = { entity_id: entityId };
    if (extraData) {
      payload.brightness_pct = extraData.brightness_pct;
      payload.position = extraData.position;
      payload.temperature = extraData.temperature;
      payload.hvac_mode = extraData.hvac_mode;
      payload.option = extraData.option;
      payload.percentage = extraData.percentage;
      payload.volume_level = extraData.volume_level;
      payload.value = extraData.value;
    }
    const body: string = JSON.stringify(payload);
    // Never retried automatically: a repeated command could toggle a device twice.
    await this.request('/api/services/' + domain + '/' + service, http.RequestMethod.POST, body, 15000);
  }

  // Read-only requests are repeated once after a transient network failure.
  private async getWithRetry(path: string, readTimeout: number): Promise<string> {
    try {
      return await this.request(path, http.RequestMethod.GET, undefined, readTimeout);
    } catch (error) {
      if (!isTransientNetworkError(error as Object)) throw error as Error;
      return await this.request(path, http.RequestMethod.GET, undefined, readTimeout);
    }
  }

  private async request(path: string, method: http.RequestMethod, body?: string,
    readTimeout: number = 15000): Promise<string> {
    const client: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await client.request(this.baseUrl + path, {
        method: method,
        header: {
          'Authorization': 'Bearer ' + this.token,
          'Content-Type': 'application/json'
        },
        extraData: body ?? '',
        expectDataType: http.HttpDataType.STRING,
        // Includes the TLS handshake, which is slow over Bluetooth via the phone and overseas CDNs.
        connectTimeout: 30000,
        readTimeout: readTimeout
      });
      if (response.responseCode === 401) {
        throw new Error('登录已失效，请重新登录');
      }
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error('HA HTTP ' + response.responseCode);
      }
      return response.result as string;
    } finally {
      client.destroy();
    }
  }
}
