import { connection, http } from '@kit.NetworkKit';
import { HaSocket, WsEnvelope } from './HaSocket';
import { HaConfigInfo, HaDirectClient } from './HaDirectClient';
import { safeError } from '../../core/utils/SafeError';

// Picks the address used to reach HA: the LAN address when the watch is on Wi-Fi (or Ethernet in the
// emulator) and that address answers like Home Assistant, otherwise the remote (HTTPS) address.
// Online through the phone's Bluetooth the LAN is never tried: the phone relays only to the internet and
// drops requests to private addresses even when the phone itself is on the home Wi-Fi (tested on a
// HUAWEI WATCH 5: timeout 2300028 with and without the system proxy).
// Only reachability counts, never latency. A request waits for the probe only briefly; a slow probe keeps
// running and its result serves the next request. The decision is cached per network.

interface RouteCache {
  netId: number;
  internal: string;
  base: string;
  until: number;
}

interface NetworkUrls {
  internal?: string | null;
}

// Part of the `network` command (admin only): HA's own network adapters.
interface NetworkAddress {
  address?: string;
}

interface NetworkAdapter {
  enabled?: boolean;
  ipv4?: NetworkAddress[];
}

interface NetworkInfo {
  adapters?: NetworkAdapter[];
}

// Leaving the Wi-Fi changes the network (and re-evaluates); a failed LAN request also switches back at once.
const LAN_KEEP_MS: number = 300000;
// Away from home a probe can take up to PROBE_TIMEOUT_MS in the background; remember the failure longer.
const REMOTE_KEEP_MS: number = 300000;
// Generous: this decides whether HA can be reached at all, not whether it is fast.
const PROBE_TIMEOUT_MS: number = 8000;
// How long a request waits for a running probe before going to the remote address.
const PROBE_WAIT_MS: number = 3000;

const LOCAL_HTTP: RegExp =
  /^http:\/\/(?:(?:10|127|192\.168)\.[0-9.]+|172\.(?:1[6-9]|2[0-9]|3[01])\.[0-9.]+|localhost|[a-z0-9-]+\.local)(?::[0-9]{1,5})?$/i;
const HTTPS: RegExp = /^https:\/\/[a-z0-9.-]+(?::[0-9]{1,5})?$/i;

let cache: RouteCache | undefined = undefined;
// The probe in flight (shared by concurrent requests) and the LAN address it checks.
let probing: Promise<boolean> | undefined = undefined;
let probingFor: string = '';

// The network this app's requests actually use: the one it is bound to (see WifiPreference), otherwise
// the system default.
export function activeNet(): connection.NetHandle {
  const bound: connection.NetHandle = connection.getAppNetSync();
  return bound.netId !== 0 ? bound : connection.getDefaultNetSync();
}

function currentNetId(): number {
  try {
    return activeNet().netId;
  } catch (_) {
    return 0;
  }
}

// Whether the app's network can reach a LAN at all: Wi-Fi, or Ethernet in the emulator. Not the phone's
// Bluetooth relay, nor cellular.
export function onLanCapableNetwork(): boolean {
  try {
    const net: connection.NetHandle = activeNet();
    if (net.netId === 0) return false;
    const bearers: connection.NetBearType[] = connection.getNetCapabilitiesSync(net).bearerTypes;
    return bearers.includes(connection.NetBearType.BEARER_WIFI) ||
      bearers.includes(connection.NetBearType.BEARER_ETHERNET);
  } catch (_) {
    return false;
  }
}

// Unauthenticated check that the address is a Home Assistant, before any token is sent to it. Resolves ''
// whenever HA answers (however long that takes within `timeoutMs`), otherwise why it did not.
// Uses the system proxy setting like every other request (a forced bypass gained nothing).
export async function lanProbe(base: string, timeoutMs: number = PROBE_TIMEOUT_MS): Promise<string> {
  const client: http.HttpRequest = http.createHttp();
  try {
    const response: http.HttpResponse = await client.request(base + '/auth/providers', {
      method: http.RequestMethod.GET,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: timeoutMs,
      readTimeout: timeoutMs
    });
    if (response.responseCode === 200 && (response.result as string).includes('"providers"')) return '';
    return '地址有回应，但不是 Home Assistant（HTTP ' + response.responseCode + '）';
  } catch (error) {
    return safeError(error as Object, '连接失败');
  } finally {
    client.destroy();
  }
}

export async function answersLikeHa(base: string, timeoutMs: number = PROBE_TIMEOUT_MS): Promise<boolean> {
  return (await lanProbe(base, timeoutMs)) === '';
}

// A usable LAN address: local HTTP or HTTPS, without a path, and not the remote address itself.
export function normalizeLanUrl(value: string, remote: string): string {
  const url: string = value.trim().replace(/\/+$/, '');
  if (!url || url === remote.replace(/\/+$/, '')) return '';
  return LOCAL_HTTP.test(url) || HTTPS.test(url) ? url : '';
}

export async function chooseBaseUrl(remote: string, internal: string): Promise<string> {
  if (!internal || !onLanCapableNetwork()) return remote;
  const netId: number = currentNetId();
  if (cache && cache.internal === internal && cache.netId === netId && Date.now() < cache.until) return cache.base;
  let current: Promise<boolean> | undefined = probingFor === internal ? probing : undefined;
  if (!current) {
    const probe: Promise<boolean> = answersLikeHa(internal);
    probing = probe;
    probingFor = internal;
    current = probe;
    probe.then((ok: boolean) => {
      cache = { netId: netId, internal: internal, base: ok ? internal : remote,
        until: Date.now() + (ok ? LAN_KEEP_MS : REMOTE_KEEP_MS) };
      if (probing === probe) probing = undefined;
    });
  }
  const waitLimit: Promise<boolean> = new Promise<boolean>((resolve: (value: boolean) => void) => {
    setTimeout(() => resolve(false), PROBE_WAIT_MS);
  });
  // A slow answer (Bluetooth via the phone) still counts: it is cached for the next request.
  const answered: boolean = await Promise.race<boolean>([current, waitLimit]);
  return answered ? internal : remote;
}

// A full probe (e.g. when the user saves the address) confirmed the LAN address: use it right away.
export function lanConfirmed(internal: string): void {
  cache = { netId: currentNetId(), internal: internal, base: internal, until: Date.now() + LAN_KEEP_MS };
}

// The LAN address stopped answering mid-session: use the remote address for a while.
export function lanFailed(remote: string, internal: string): void {
  cache = { netId: currentNetId(), internal: internal, base: remote, until: Date.now() + REMOTE_KEEP_MS };
}

export function forgetRoute(): void {
  cache = undefined;
  probing = undefined;
  probingFor = '';
}

// The LAN address HA knows about: network/url (admin users), the configured internal_url, or as a last
// resort the IPv4 address of HA's own network adapter on the default port, if it answers right now.
export async function detectLanUrl(remote: string, token: string): Promise<string> {
  const candidates: string[] = [];
  const adapterGuesses: string[] = [];
  const socket: HaSocket = new HaSocket(token);
  try {
    await socket.open(remote);
    try {
      const reply: WsEnvelope = await socket.query('network/url');
      const urls: NetworkUrls | undefined = reply.result as NetworkUrls | undefined;
      const internal: string | null | undefined = urls?.internal;
      if (typeof internal === 'string') candidates.push(internal);
    } catch (_) {
      // Not an admin, or an older HA.
    }
    try {
      const reply: WsEnvelope = await socket.query('network');
      const info: NetworkInfo | undefined = reply.result as NetworkInfo | undefined;
      const adapters: NetworkAdapter[] = info?.adapters ?? [];
      adapters.forEach((adapter: NetworkAdapter) => {
        if (adapter.enabled === false) return;
        const addresses: NetworkAddress[] = adapter.ipv4 ?? [];
        addresses.forEach((entry: NetworkAddress) => {
          if (typeof entry.address === 'string') adapterGuesses.push('http://' + entry.address + ':8123');
        });
      });
    } catch (_) {
      // Not an admin.
    }
  } catch (_) {
    // WebSocket unavailable: the configuration below still works over REST.
  } finally {
    try { await socket.close(); } catch (_) {}
  }
  try {
    const config: HaConfigInfo = await new HaDirectClient(remote, token).readConfig();
    if (typeof config.internal_url === 'string') candidates.push(config.internal_url);
  } catch (_) {
    // Nothing more to try.
  }
  for (let i: number = 0; i < candidates.length; i++) {
    const url: string = normalizeLanUrl(candidates[i], remote);
    if (url) return url;
  }
  for (let i: number = 0; i < adapterGuesses.length; i++) {
    const url: string = normalizeLanUrl(adapterGuesses[i], remote);
    if (url && await answersLikeHa(url)) return url;
  }
  return '';
}
