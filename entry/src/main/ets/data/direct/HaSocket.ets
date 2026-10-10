import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { HaEntityAttributes, HaEntityState, ServiceData } from './HaDirectClient';

// A WebSocket session to HA: authenticate, then run commands. The data source keeps one open while the
// app is in use, so syncs and device commands share one TLS connection (several handshakes over the
// phone's Bluetooth add seconds).
// Large replies (registry lists, entity states) arrive in several 'message' callbacks over wss, so text is
// buffered until it forms one complete JSON envelope.

export interface WsEnvelope {
  id?: number;
  type: string;
  success?: boolean;
  result?: object;
  message?: string;
  event?: object;
}

interface WsTarget {
  entity_id: string;
}

interface WsCommand {
  id: number;
  type: string;
  entity_ids?: string[];
  subscription?: number;
  domain?: string;
  service?: string;
  service_data?: ServiceData;
  target?: WsTarget;
}

interface Waiter {
  resolve: (message: WsEnvelope) => void;
  reject: (error: Error) => void;
  timer: number;
}

// subscribe_entities compact state: s = state, a = attributes (context / timestamps are not needed).
interface CompactState {
  s: string;
  a?: HaEntityAttributes;
}

// A change in a subscribe_entities event: "+" carries the new state and changed attributes, "-" the
// names of removed attributes.
interface CompactChange {
  s?: string;
  a?: Object;
}

interface CompactRemoval {
  a?: string[];
}

// a = full states (first event), c = changes keyed by entity ("+" / "-", see above).
interface EntitiesEvent {
  a?: Record<string, CompactState>;
  c?: Record<string, Record<string, Object>>;
}

interface AuthMessage {
  type: string;
  access_token: string;
}

const NO_STATES: Record<string, CompactState> = {};
const NO_ATTRIBUTES: HaEntityAttributes = {};

const MAX_MESSAGE_CHARS: number = 16 * 1024 * 1024;
const REQUEST_TIMEOUT_MS: number = 20000;

export class HaSocket {
  private socket: webSocket.WebSocket | undefined = undefined;
  private token: string;
  private nextId: number = 1;
  private partial: string = '';
  private results: Map<number, Waiter> = new Map<number, Waiter>();
  private events: Map<number, Waiter> = new Map<number, Waiter>();
  private authResolve: (() => void) | undefined = undefined;
  private authReject: ((error: Error) => void) | undefined = undefined;
  private closed: boolean = false;
  // Live subscription (see watch): its id (-1 = none), the latest state of each entity, the listener,
  // and who to tell when the connection drops.
  private watchId: number = -1;
  private watchStates: Map<string, CompactState> = new Map<string, CompactState>();
  private watchListener: ((states: HaEntityState[]) => void) | undefined = undefined;
  private dropListener: (() => void) | undefined = undefined;

  constructor(token: string) {
    this.token = token;
  }

  async open(baseUrl: string): Promise<void> {
    const url: string = baseUrl.replace(/^http/, 'ws').replace(/\/+$/, '') + '/api/websocket';
    const socket: webSocket.WebSocket = webSocket.createWebSocket();
    this.socket = socket;
    socket.on('message', (error: BusinessError, data: string | ArrayBuffer) => {
      if (error) return;
      const text: string = typeof data === 'string' ? data :
        util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(data as ArrayBuffer));
      this.onChunk(text);
    });
    socket.on('close', () => this.onClosed());
    socket.on('error', () => this.onClosed());
    const auth: Promise<void> = new Promise<void>((resolve: () => void, reject: (error: Error) => void) => {
      this.authResolve = resolve;
      this.authReject = reject;
    });
    if (url.startsWith('ws://')) {
      // Plain ws:// is only used for LAN addresses. Bound connect + auth together so a LAN that stopped
      // answering (the phone just left home) falls back to the remote address; generous enough for the
      // several round trips of the handshake through the phone's Bluetooth (~1.5 s each).
      const connected: Promise<void> = socket.connect(url).then(() => auth);
      await this.withTimeout<void>(connected, 12000, '局域网连接超时');
      return;
    }
    await socket.connect(url);
    await this.withTimeout<void>(auth, REQUEST_TIMEOUT_MS, 'WebSocket 认证超时');
  }

  // Sends a command and resolves with its result envelope.
  async query(type: string): Promise<WsEnvelope> {
    const id: number = this.nextId++;
    const result: Promise<WsEnvelope> = this.wait(this.results, id, 'HA 请求超时');
    await this.send({ id, type });
    return await result;
  }

  isOpen(): boolean {
    return this.socket !== undefined && !this.closed;
  }

  // Runs a service on one entity and waits for HA to accept it.
  async callService(domain: string, service: string, entityId: string, data?: ServiceData): Promise<void> {
    const id: number = this.nextId++;
    const result: Promise<WsEnvelope> = this.wait(this.results, id, 'HA 未确认操作');
    await this.send({ id: id, type: 'call_service', domain: domain, service: service,
      service_data: data, target: { entity_id: entityId } });
    await result;
  }

  // Current state of the given entities (all entities when ids is undefined), via subscribe_entities.
  // The first event of that subscription carries the full compact state; the subscription is then
  // cancelled so the open session does not keep receiving changes.
  async entityStates(ids?: string[]): Promise<HaEntityState[]> {
    const id: number = this.nextId++;
    const result: Promise<WsEnvelope> = this.wait(this.results, id, 'HA 状态请求超时');
    const first: Promise<WsEnvelope> = this.wait(this.events, id, 'HA 状态数据超时');
    const command: WsCommand = { id, type: 'subscribe_entities' };
    if (ids) command.entity_ids = ids;
    try {
      await this.send(command);
      await result;
      const envelope: WsEnvelope = await first;
      const event: EntitiesEvent | undefined = envelope.event as EntitiesEvent | undefined;
      const added: Record<string, CompactState> = event?.a ?? NO_STATES;
      this.unsubscribe(id);
      return Object.keys(added).map((entityId: string) => {
        const compact: CompactState = added[entityId];
        const state: HaEntityState = { entity_id: entityId, state: compact.s, attributes: compact.a };
        return state;
      });
    } finally {
      this.cancel(this.events, id);
    }
  }

  // Keeps the given entities subscribed: `onChange` receives the full current state of each entity that
  // changed (all of them right after subscribing). Replaces an earlier watch.
  async watch(ids: string[], onChange: (states: HaEntityState[]) => void): Promise<void> {
    this.unwatch();
    const id: number = this.nextId++;
    const result: Promise<WsEnvelope> = this.wait(this.results, id, 'HA 订阅超时');
    this.watchId = id;
    this.watchStates.clear();
    this.watchListener = onChange;
    try {
      await this.send({ id: id, type: 'subscribe_entities', entity_ids: ids });
      await result;
    } catch (error) {
      if (this.watchId === id) {
        this.watchId = -1;
        this.watchListener = undefined;
      }
      throw error as Error;
    }
  }

  unwatch(): void {
    if (this.watchId < 0) return;
    const id: number = this.watchId;
    this.watchId = -1;
    this.watchListener = undefined;
    this.watchStates.clear();
    if (this.isOpen()) this.unsubscribe(id);
  }

  isWatching(): boolean {
    return this.watchId >= 0 && this.isOpen();
  }

  // Called once when the server or the network closes the connection (not on close()).
  onDrop(listener: () => void): void {
    this.dropListener = listener;
  }

  private onWatchEvent(event: EntitiesEvent | undefined): void {
    const listener: ((states: HaEntityState[]) => void) | undefined = this.watchListener;
    if (!event || !listener) return;
    const changed: string[] = [];
    const added: Record<string, CompactState> | undefined = event.a;
    if (added) {
      Object.keys(added).forEach((entityId: string) => {
        this.watchStates.set(entityId, added[entityId]);
        changed.push(entityId);
      });
    }
    const changes: Record<string, Record<string, Object>> | undefined = event.c;
    if (changes) {
      Object.keys(changes).forEach((entityId: string) => {
        const previous: CompactState | undefined = this.watchStates.get(entityId);
        if (!previous) return;
        const diff: Record<string, Object> = changes[entityId];
        const plus: CompactChange | undefined = diff['+'] as CompactChange | undefined;
        const minus: CompactRemoval | undefined = diff['-'] as CompactRemoval | undefined;
        const next: CompactState = {
          s: plus?.s ?? previous.s,
          a: plus?.a !== undefined || minus?.a !== undefined ?
            mergeAttributes(previous.a, plus?.a, minus?.a) : previous.a
        };
        this.watchStates.set(entityId, next);
        if (!changed.includes(entityId)) changed.push(entityId);
      });
    }
    if (changed.length === 0) return;
    listener(changed.map((entityId: string) => {
      const compact: CompactState = this.watchStates.get(entityId)!;
      const state: HaEntityState = { entity_id: entityId, state: compact.s, attributes: compact.a };
      return state;
    }));
  }

  // Fire and forget: a lost unsubscribe only means a few ignored change events.
  private unsubscribe(subscription: number): void {
    const id: number = this.nextId++;
    this.wait(this.results, id, '').catch(() => {});
    this.send({ id: id, type: 'unsubscribe_events', subscription: subscription }).catch(() => {});
  }

  // The server or the network closed the connection: fail pending requests right away instead of
  // letting each wait for its timeout.
  private onClosed(): void {
    if (this.closed) return;
    this.closed = true;
    const failure: Error = new Error('HA 连接已断开');
    this.results.forEach((waiter: Waiter) => { clearTimeout(waiter.timer); waiter.reject(failure); });
    this.events.forEach((waiter: Waiter) => { clearTimeout(waiter.timer); waiter.reject(failure); });
    this.results.clear();
    this.events.clear();
    this.authReject?.(failure);
    this.watchId = -1;
    this.watchListener = undefined;
    const dropped: (() => void) | undefined = this.dropListener;
    this.dropListener = undefined;
    dropped?.();
  }

  async close(): Promise<void> {
    this.closed = true;
    this.watchId = -1;
    this.watchListener = undefined;
    this.dropListener = undefined;
    this.results.forEach((waiter: Waiter) => clearTimeout(waiter.timer));
    this.events.forEach((waiter: Waiter) => clearTimeout(waiter.timer));
    this.results.clear();
    this.events.clear();
    const socket: webSocket.WebSocket | undefined = this.socket;
    this.socket = undefined;
    this.token = '';
    if (socket) {
      try { await socket.close(); } catch (_) {}
    }
  }

  private async send(command: WsCommand): Promise<void> {
    if (!this.socket || this.closed) throw new Error('HA 连接已关闭');
    await this.socket.send(JSON.stringify(command));
  }

  private wait(map: Map<number, Waiter>, id: number, timeoutMessage: string): Promise<WsEnvelope> {
    return new Promise<WsEnvelope>((resolve: (message: WsEnvelope) => void, reject: (error: Error) => void) => {
      const timer: number = setTimeout(() => {
        map.delete(id);
        reject(new Error(timeoutMessage));
      }, REQUEST_TIMEOUT_MS);
      map.set(id, { resolve, reject, timer });
    });
  }

  private cancel(map: Map<number, Waiter>, id: number): void {
    const waiter: Waiter | undefined = map.get(id);
    if (waiter) {
      clearTimeout(waiter.timer);
      map.delete(id);
    }
  }

  // Joins fragments until they parse as one message. A chunk that is itself a complete envelope while a
  // stale fragment is pending means the fragment was lost; drop it so later messages are not blocked.
  private onChunk(text: string): void {
    const combined: string = this.partial + text;
    let message: WsEnvelope | undefined = this.tryParse(combined);
    if (message) {
      this.partial = '';
    } else if (this.partial.length > 0 && text.startsWith('{"') && (message = this.tryParse(text)) !== undefined) {
      this.partial = '';
    } else {
      this.partial = combined.length > MAX_MESSAGE_CHARS ? '' : combined;
      return;
    }
    this.onMessage(message);
  }

  private tryParse(raw: string): WsEnvelope | undefined {
    try {
      const value: WsEnvelope = JSON.parse(raw) as WsEnvelope;
      return typeof value === 'object' && value !== null && typeof value.type === 'string' ? value : undefined;
    } catch (_) {
      return undefined;
    }
  }

  private onMessage(message: WsEnvelope): void {
    if (message.type === 'auth_required') {
      const auth: AuthMessage = { type: 'auth', access_token: this.token };
      this.socket?.send(JSON.stringify(auth));
      return;
    }
    if (message.type === 'auth_ok') {
      this.authResolve?.();
      return;
    }
    if (message.type === 'auth_invalid') {
      this.authReject?.(new Error('WebSocket 认证失败'));
      return;
    }
    if (message.id === undefined) return;
    if (message.type === 'event' && message.id === this.watchId) {
      this.onWatchEvent(message.event as EntitiesEvent | undefined);
      return;
    }
    const map: Map<number, Waiter> = message.type === 'event' ? this.events : this.results;
    const waiter: Waiter | undefined = map.get(message.id);
    if (!waiter) return;
    clearTimeout(waiter.timer);
    map.delete(message.id);
    if (message.type === 'result' && message.success === false) {
      waiter.reject(new Error('HA 请求被拒绝'));
    } else {
      waiter.resolve(message);
    }
  }

  private async withTimeout<T>(request: Promise<T>, delayMs: number, message: string): Promise<T> {
    return await new Promise<T>((resolve: (value: T) => void, reject: (error: Error) => void) => {
      const timer: number = setTimeout(() => reject(new Error(message)), delayMs);
      request.then((value: T) => { clearTimeout(timer); resolve(value); })
        .catch((error: Error) => { clearTimeout(timer); reject(error); });
    });
  }
}

// Applies a change event to an entity's attributes: changed values replace old ones, removed names go away.
// Attributes are typed for the fields the watch reads, so they are merged as plain JSON objects.
function mergeAttributes(base: HaEntityAttributes | undefined, changed: Object | undefined,
  removed: string[] | undefined): HaEntityAttributes {
  const merged: Record<string, Object> = JSON.parse(JSON.stringify(base ?? NO_ATTRIBUTES)) as Record<string, Object>;
  if (changed) {
    const updates: Record<string, Object> = JSON.parse(JSON.stringify(changed)) as Record<string, Object>;
    Object.keys(updates).forEach((key: string) => {
      merged[key] = updates[key];
    });
  }
  const kept: Record<string, Object> = {};
  Object.keys(merged).forEach((key: string) => {
    if (!removed || !removed.includes(key)) kept[key] = merged[key];
  });
  return JSON.parse(JSON.stringify(kept)) as HaEntityAttributes;
}
