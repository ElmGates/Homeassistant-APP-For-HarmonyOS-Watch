import { connection, http } from '@kit.NetworkKit';
import { HaSocket, WsEnvelope } from './HaSocket';
import { HaConfigInfo, HaDirectClient } from './HaDirectClient';

// Picks the address used to reach HA: the LAN address when it answers like Home Assistant within a short
// timeout, otherwise the remote (HTTPS) address. The network type is deliberately not used: at home the
// watch is often online through the phone over Bluetooth, and the phone's Wi-Fi still reaches the LAN.
// The decision is cached per network, so a sync does not probe every time; switching network re-evaluates.

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

// Short: over the phone's Bluetooth the network ID stays the same when the phone leaves the home Wi-Fi.
// Re-checking at home is cheap (one LAN round trip).
const LAN_KEEP_MS: number = 60000;
// Away from home the probe costs up to PROBE_TIMEOUT_MS, so a failed probe is remembered longer.
const REMOTE_KEEP_MS: number = 180000;
const PROBE_TIMEOUT_MS: number = 1500;

const LOCAL_HTTP: RegExp =
  /^http:\/\/(?:(?:10|127|192\.168)\.[0-9.]+|172\.(?:1[6-9]|2[0-9]|3[01])\.[0-9.]+|localhost|[a-z0-9-]+\.local)(?::[0-9]{1,5})?$/i;
const HTTPS: RegExp = /^https:\/\/[a-z0-9.-]+(?::[0-9]{1,5})?$/i;

let cache: RouteCache | undefined = undefined;

function currentNetId(): number {
  try {
    return connection.getDefaultNetSync().netId;
  } catch (_) {
    return 0;
  }
}

// Unauthenticated check that the address is a Home Assistant, before any token is sent to it.
export async function answersLikeHa(base: string): Promise<boolean> {
  const client: http.HttpRequest = http.createHttp();
  try {
    const response: http.HttpResponse = await client.request(base + '/auth/providers', {
      method: http.RequestMethod.GET,
      expectDataType: http.HttpDataType.STRING,
      usingProxy: false,
      connectTimeout: PROBE_TIMEOUT_MS,
      readTimeout: PROBE_TIMEOUT_MS
    });
    return response.responseCode === 200 && (response.result as string).includes('"providers"');
  } catch (_) {
    return false;
  } finally {
    client.destroy();
  }
}

// A usable LAN address: local HTTP or HTTPS, without a path, and not the remote address itself.
export function normalizeLanUrl(value: string, remote: string): string {
  const url: string = value.trim().replace(/\/+$/, '');
  if (!url || url === remote.replace(/\/+$/, '')) return '';
  return LOCAL_HTTP.test(url) || HTTPS.test(url) ? url : '';
}

export async function chooseBaseUrl(remote: string, internal: string): Promise<string> {
  if (!internal) return remote;
  const netId: number = currentNetId();
  if (cache && cache.internal === internal && cache.netId === netId && Date.now() < cache.until) return cache.base;
  let base: string = remote;
  if (await answersLikeHa(internal)) base = internal;
  cache = { netId: netId, internal: internal, base: base,
    until: Date.now() + (base === internal ? LAN_KEEP_MS : REMOTE_KEEP_MS) };
  return base;
}

// The LAN address stopped answering mid-session: use the remote address for a while.
export function lanFailed(remote: string, internal: string): void {
  cache = { netId: currentNetId(), internal: internal, base: remote, until: Date.now() + REMOTE_KEEP_MS };
}

export function forgetRoute(): void {
  cache = undefined;
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
