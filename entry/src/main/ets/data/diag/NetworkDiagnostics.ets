import { connection, http } from '@kit.NetworkKit';
import { HaSocket } from '../direct/HaSocket';
import { HaEntityState } from '../direct/HaDirectClient';
import { safeError } from '../../core/utils/SafeError';

// Step-by-step connectivity check shown on the 网络诊断 page. Each step reports ok/failed, duration and a
// short detail, so a screenshot tells where a timeout happens (network type, DNS, HTTPS, auth, WebSocket,
// state download). Never reports the token or the full server address.

export interface DiagStep {
  title: string;
  ok: boolean;
  detail: string;
  ms: number;
}

export type DiagReporter = (step: DiagStep) => void;
export type TokenProvider = () => Promise<string>;

function bearerName(type: connection.NetBearType): string {
  switch (type) {
    case connection.NetBearType.BEARER_WIFI: return 'Wi‑Fi';
    case connection.NetBearType.BEARER_CELLULAR: return '蜂窝数据';
    case connection.NetBearType.BEARER_BLUETOOTH: return '蓝牙（经手机）';
    case connection.NetBearType.BEARER_ETHERNET: return '以太网';
    case connection.NetBearType.BEARER_VPN: return 'VPN';
    default: return '其他';
  }
}

function hostOf(server: string): string {
  const match: RegExpMatchArray | null = server.match(/^https?:\/\/([^/:]+)/i);
  return match ? match[1] : '';
}

export class NetworkDiagnostics {
  private readonly server: string;
  private readonly tokenProvider: TokenProvider;
  private readonly report: DiagReporter;

  constructor(server: string, tokenProvider: TokenProvider, report: DiagReporter) {
    this.server = server;
    this.tokenProvider = tokenProvider;
    this.report = report;
  }

  async run(): Promise<void> {
    this.networkType();
    const dnsOk: boolean = await this.dns();
    const httpsOk: boolean = dnsOk ? await this.https() : false;
    if (!httpsOk) return;
    const token: string = await this.auth();
    if (!token) return;
    await this.socketAndStates(token);
  }

  private step(title: string, start: number, ok: boolean, detail: string): void {
    const result: DiagStep = { title: title, ok: ok, detail: detail, ms: Date.now() - start };
    this.report(result);
  }

  private networkType(): void {
    const start: number = Date.now();
    try {
      const net: connection.NetHandle = connection.getDefaultNetSync();
      if (net.netId === 0) {
        this.step('当前网络', start, false, '没有可用网络');
        return;
      }
      const caps: connection.NetCapabilities = connection.getNetCapabilitiesSync(net);
      const names: string[] = caps.bearerTypes.map((type: connection.NetBearType) => bearerName(type));
      const props: connection.ConnectionProperties = connection.getConnectionPropertiesSync(net);
      const hasV6: boolean = props.linkAddresses.some((link: connection.LinkAddress) =>
        link.address.address.includes(':') && !link.address.address.toLowerCase().startsWith('fe80'));
      this.step('当前网络', start, true, names.join(' + ') + (hasV6 ? ' · 有 IPv6' : ' · 仅 IPv4'));
    } catch (error) {
      this.step('当前网络', start, false, safeError(error as Object, '无法读取网络信息'));
    }
  }

  private async dns(): Promise<boolean> {
    const start: number = Date.now();
    const host: string = hostOf(this.server);
    try {
      const addresses: connection.NetAddress[] = await connection.getAddressesByName(host);
      const v4: number = addresses.filter((a: connection.NetAddress) => a.address.includes('.')).length;
      const v6: number = addresses.length - v4;
      this.step('域名解析', start, addresses.length > 0, 'IPv4 ' + v4 + ' 个 · IPv6 ' + v6 + ' 个');
      return addresses.length > 0;
    } catch (error) {
      this.step('域名解析', start, false, safeError(error as Object, '域名解析失败'));
      return false;
    }
  }

  // Unauthenticated GET /api/: HA answers 401 quickly, which proves the HTTPS path works end to end.
  private async https(): Promise<boolean> {
    const start: number = Date.now();
    const client: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await client.request(this.server.replace(/\/+$/, '') + '/api/', {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 30000,
        readTimeout: 15000
      });
      const ok: boolean = response.responseCode === 401 || response.responseCode === 200;
      this.step('HTTPS 连接', start, ok, 'HTTP ' + response.responseCode + (ok ? ' · 已连到 HA' : ' · 返回异常'));
      return ok;
    } catch (error) {
      this.step('HTTPS 连接', start, false, safeError(error as Object, '连接失败'));
      return false;
    } finally {
      client.destroy();
    }
  }

  private async auth(): Promise<string> {
    const start: number = Date.now();
    try {
      const token: string = await this.tokenProvider();
      this.step('登录凭证', start, token.length > 0, token.length > 0 ? '有效' : '缺失，请重新登录');
      return token;
    } catch (error) {
      this.step('登录凭证', start, false, safeError(error as Object, '续期失败'));
      return '';
    }
  }

  private async socketAndStates(token: string): Promise<void> {
    const socket: HaSocket = new HaSocket(token);
    let start: number = Date.now();
    try {
      await socket.open(this.server);
      this.step('WebSocket', start, true, '已连接并认证');
    } catch (error) {
      this.step('WebSocket', start, false, safeError(error as Object, 'WebSocket 连接失败'));
      await socket.close();
      return;
    }
    start = Date.now();
    try {
      const states: HaEntityState[] = await socket.entityStates();
      const kb: number = Math.round(JSON.stringify(states).length / 1024);
      this.step('下载设备状态', start, true, states.length + ' 个实体 · 约 ' + kb + ' KB');
    } catch (error) {
      this.step('下载设备状态', start, false, safeError(error as Object, '下载失败'));
    } finally {
      await socket.close();
    }
  }
}
