import { connection, http } from '@kit.NetworkKit';
import { HaSocket } from '../direct/HaSocket';
import { answersLikeHa } from '../direct/LanRoute';
import { safeError } from '../../core/utils/SafeError';

// Step-by-step connectivity check shown on the 连接诊断 page. Each step reports ok/failed, duration and a
// short detail, so a screenshot tells where a delay happens (network and IP, LAN address, DNS, remote
// HTTPS, auth, WebSocket, round-trip latency), followed by a suggestion. Never reports the token or the
// full server address.

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

// The watch's own network for the Settings page, e.g. "Wi‑Fi · 192.168.1.23". IPv4 first; a global
// IPv6 address only when there is no IPv4 one.
export function localNetworkSummary(): string {
  try {
    const net: connection.NetHandle = connection.getDefaultNetSync();
    if (net.netId === 0) return '没有可用网络';
    const caps: connection.NetCapabilities = connection.getNetCapabilitiesSync(net);
    const type: string = caps.bearerTypes.map((bearer: connection.NetBearType) => bearerName(bearer)).join(' + ');
    const props: connection.ConnectionProperties = connection.getConnectionPropertiesSync(net);
    const addresses: string[] = props.linkAddresses.map((link: connection.LinkAddress) => link.address.address);
    const v4: string[] = addresses.filter((address: string) => !address.includes(':'));
    const v6: string[] = addresses.filter((address: string) =>
      address.includes(':') && !address.toLowerCase().startsWith('fe80'));
    const shown: string[] = v4.length > 0 ? v4 : v6.slice(0, 1);
    return type + ' · ' + (shown.length > 0 ? shown.join('、') : '未分配地址');
  } catch (error) {
    return safeError(error as Object, '无法读取网络信息');
  }
}

function hostOf(server: string): string {
  const match: RegExpMatchArray | null = server.match(/^https?:\/\/([^/:]+)/i);
  return match ? match[1] : '';
}

export class NetworkDiagnostics {
  private readonly server: string;
  private readonly lanUrl: string;
  private readonly tokenProvider: TokenProvider;
  private readonly report: DiagReporter;
  // Findings used for the closing suggestion.
  private online: boolean = false;
  private viaBluetooth: boolean = false;
  private lanOk: boolean = false;
  private dnsOk: boolean = false;
  private httpsOk: boolean = false;
  private httpsMs: number = 0;
  private tokenOk: boolean = false;
  private socketOk: boolean = false;
  private pingMs: number = 0;

  // `lanUrl`: the LAN address in use ('' when LAN access is off or not set).
  constructor(server: string, lanUrl: string, tokenProvider: TokenProvider, report: DiagReporter) {
    this.server = server.replace(/\/+$/, '');
    this.lanUrl = lanUrl;
    this.tokenProvider = tokenProvider;
    this.report = report;
  }

  async run(): Promise<void> {
    this.networkType();
    if (this.online) {
      if (this.lanUrl) await this.lan();
      this.dnsOk = await this.dns();
      if (this.dnsOk) this.httpsOk = await this.https();
      if (this.lanOk || this.httpsOk) {
        const token: string = await this.auth();
        if (token) await this.socketAndLatency(token);
      }
    }
    this.suggest();
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
      this.viaBluetooth = caps.bearerTypes.includes(connection.NetBearType.BEARER_BLUETOOTH);
      const props: connection.ConnectionProperties = connection.getConnectionPropertiesSync(net);
      const hasV6: boolean = props.linkAddresses.some((link: connection.LinkAddress) =>
        link.address.address.includes(':') && !link.address.address.toLowerCase().startsWith('fe80'));
      this.online = true;
      this.step('当前网络', start, true, localNetworkSummary() + (hasV6 ? ' · 有 IPv6' : ''));
    } catch (error) {
      this.step('当前网络', start, false, safeError(error as Object, '无法读取网络信息'));
    }
  }

  // The LAN address: reachable and really a Home Assistant? (No token is sent.)
  private async lan(): Promise<void> {
    const start: number = Date.now();
    this.lanOk = await answersLikeHa(this.lanUrl);
    this.step('局域网地址', start, this.lanOk,
      this.lanOk ? '可以直连' : '连不上：不在家，或 HA 的局域网 IP 已变化');
  }

  private async dns(): Promise<boolean> {
    const start: number = Date.now();
    const host: string = hostOf(this.server);
    if (/^[0-9.]+$/.test(host)) {
      this.step('域名解析', start, true, '地址是 IP，无需解析');
      return true;
    }
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

  // Unauthenticated GET /api/: HA answers 401 quickly, which proves the remote path works end to end.
  private async https(): Promise<boolean> {
    const start: number = Date.now();
    const client: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await client.request(this.server + '/api/', {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 30000,
        readTimeout: 15000
      });
      const ok: boolean = response.responseCode === 401 || response.responseCode === 200;
      this.httpsMs = Date.now() - start;
      this.step('远程连接', start, ok, 'HTTP ' + response.responseCode + (ok ? ' · 已连到 HA' : ' · 返回异常'));
      return ok;
    } catch (error) {
      this.step('远程连接', start, false, safeError(error as Object, '连接失败'));
      return false;
    } finally {
      client.destroy();
    }
  }

  private async auth(): Promise<string> {
    const start: number = Date.now();
    try {
      const token: string = await this.tokenProvider();
      this.tokenOk = token.length > 0;
      this.step('登录凭证', start, this.tokenOk, this.tokenOk ? '有效' : '缺失，请重新登录');
      return token;
    } catch (error) {
      this.step('登录凭证', start, false, safeError(error as Object, '续期失败'));
      return '';
    }
  }

  // WebSocket over the route the app uses (LAN when reachable), then the round-trip time of a few pings:
  // that latency is what every tap on the watch costs.
  private async socketAndLatency(token: string): Promise<void> {
    const route: string = this.lanOk ? '局域网' : '远程';
    const socket: HaSocket = new HaSocket(token);
    let start: number = Date.now();
    try {
      await socket.open(this.lanOk ? this.lanUrl : this.server);
      this.socketOk = true;
      this.step('WebSocket（' + route + '）', start, true, '已连接并认证');
    } catch (error) {
      this.step('WebSocket（' + route + '）', start, false, safeError(error as Object, 'WebSocket 连接失败'));
      await socket.close();
      return;
    }
    start = Date.now();
    try {
      const rounds: number = 3;
      for (let i: number = 0; i < rounds; i++) await socket.query('ping');
      this.pingMs = Math.round((Date.now() - start) / rounds);
      this.step('往返延迟', start, true, '平均 ' + this.pingMs + ' ms（' + route + '）');
    } catch (error) {
      this.step('往返延迟', start, false, safeError(error as Object, '测试失败'));
    } finally {
      await socket.close();
    }
  }

  private suggest(): void {
    let text: string = '';
    let ok: boolean = true;
    if (!this.online) {
      ok = false;
      text = '手表没有网络：连接 Wi‑Fi，或确认手机蓝牙已连接且手机能上网。';
    } else if (this.lanOk && this.socketOk) {
      text = '正在使用局域网直连，这是最快的方式。';
    } else if (!this.dnsOk && !this.lanOk) {
      ok = false;
      text = '域名解析失败：检查服务器地址，或手机的网络和 DNS 设置。';
    } else if (!this.httpsOk && !this.lanOk) {
      ok = false;
      text = '连不上远程地址：确认 HA 在线、端口转发或隧道正常，证书有效。';
    } else if (!this.tokenOk) {
      ok = false;
      text = '登录凭证无效：请在设置中清除数据后重新登录。';
    } else if (!this.socketOk) {
      ok = false;
      text = 'WebSocket 被拦截：检查反向代理是否放行 WebSocket（Upgrade 头）。应用会自动改用较慢的 HTTP 方式。';
    } else if (!this.lanUrl && (this.httpsMs > 3000 || this.pingMs > 500)) {
      text = '远程连接较慢' + (this.viaBluetooth ? '（经手机蓝牙）' : '') + '：在家时可在设置中开启「局域网直连」。';
    } else if (this.lanUrl && !this.lanOk) {
      text = '局域网地址连不上，正在使用远程地址。在家也连不上时，请检查局域网直连中的地址。';
    } else {
      text = '连接正常。';
    }
    this.report({ title: '建议', ok: ok, detail: text, ms: 0 });
  }
}
