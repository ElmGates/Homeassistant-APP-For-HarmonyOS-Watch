import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';

// Lets a phone on the same Wi-Fi fill in the login form: the watch serves a one-page HTML form over
// plain HTTP on the LAN. Every session has a random 128-bit path token, so the form can't be reached
// by guessing, and the token is dropped as soon as the login succeeds or the setup page closes.

export interface PhoneLoginForm {
  server: string;
  username: string;
  password: string;
  allowLocalHttp: boolean;
}

export interface PhoneSetupResult {
  // true: the session is finished (logged in, or waiting for a 2FA code on the watch).
  done: boolean;
  message: string;
}

export type PhoneSubmitHandler = (form: PhoneLoginForm) => Promise<PhoneSetupResult>;

const FIRST_PORT: number = 8800;
const LAST_PORT: number = 8820;
const MAX_REQUEST_BYTES: number = 16384;

class PendingRequest {
  chunks: Uint8Array[] = [];
  length: number = 0;
  handled: boolean = false;
}

export class PhoneSetupServer {
  private static instance: PhoneSetupServer | undefined = undefined;
  private server: socket.TCPSocketServer | undefined = undefined;
  private port: number = 0;
  private token: string = '';
  private serverHint: string = '';
  private handler: PhoneSubmitHandler | undefined = undefined;
  private busy: boolean = false;

  static shared(): PhoneSetupServer {
    if (!PhoneSetupServer.instance) PhoneSetupServer.instance = new PhoneSetupServer();
    return PhoneSetupServer.instance;
  }

  // Starts (or reuses) the listener and opens a new session. Returns the URL path to put in the QR code.
  async start(serverHint: string, handler: PhoneSubmitHandler): Promise<string> {
    await this.ensureListening();
    this.token = this.randomToken();
    this.serverHint = serverHint;
    this.handler = handler;
    return ':' + this.port + '/' + this.token;
  }

  // Closes the session. The socket keeps listening (there is no portable close for the server socket)
  // but answers every request with "expired" until a new session starts.
  stop(): void {
    this.token = '';
    this.handler = undefined;
    this.busy = false;
  }

  private async ensureListening(): Promise<void> {
    if (this.server) return;
    for (let port: number = FIRST_PORT; port <= LAST_PORT; port++) {
      const server: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
      try {
        await server.listen({ address: '0.0.0.0', port: port, family: 1 });
      } catch (_) {
        continue;
      }
      server.on('connect', (client: socket.TCPSocketConnection) => {
        const pending: PendingRequest = new PendingRequest();
        client.on('message', (info: socket.SocketMessageInfo) => {
          this.onData(client, pending, new Uint8Array(info.message));
        });
      });
      this.server = server;
      this.port = port;
      return;
    }
    throw new Error('无法开启手机填写服务（端口被占用）');
  }

  private onData(client: socket.TCPSocketConnection, pending: PendingRequest, data: Uint8Array): void {
    if (pending.handled) return;
    pending.chunks.push(data);
    pending.length += data.length;
    if (pending.length > MAX_REQUEST_BYTES) {
      pending.handled = true;
      this.respond(client, '413 Payload Too Large', this.page('请求过大', '<p>请重新扫码。</p>'));
      return;
    }
    const bytes: Uint8Array = this.concat(pending.chunks, pending.length);
    const headerEnd: number = this.findHeaderEnd(bytes);
    if (headerEnd < 0) return;
    const head: string = this.decode(bytes.subarray(0, headerEnd));
    const lines: string[] = head.split('\r\n');
    const parts: string[] = lines.length > 0 ? lines[0].split(' ') : [];
    const method: string = parts.length > 0 ? parts[0] : '';
    const path: string = parts.length > 1 ? parts[1].split('?')[0] : '';
    let contentLength: number = 0;
    lines.forEach((line: string) => {
      const index: number = line.indexOf(':');
      if (index > 0 && line.substring(0, index).trim().toLowerCase() === 'content-length') {
        const parsed: number = Number.parseInt(line.substring(index + 1).trim());
        contentLength = Number.isNaN(parsed) ? 0 : parsed;
      }
    });
    const bodyStart: number = headerEnd + 4;
    if (bytes.length - bodyStart < contentLength) return;
    pending.handled = true;
    const body: string = this.decode(bytes.subarray(bodyStart, bodyStart + contentLength));
    this.route(client, method, path, body);
  }

  private async route(client: socket.TCPSocketConnection, method: string, path: string, body: string): Promise<void> {
    if (this.token.length === 0 || path !== '/' + this.token) {
      await this.respond(client, '404 Not Found', this.page('链接已失效', '<p>请在手表上重新打开「用手机填写」并扫码。</p>'));
      return;
    }
    if (method === 'GET') {
      await this.respond(client, '200 OK', this.form(this.serverHint, '', false, ''));
      return;
    }
    if (method !== 'POST') {
      await this.respond(client, '405 Method Not Allowed', this.page('不支持的请求', ''));
      return;
    }
    if (this.busy || !this.handler) {
      await this.respond(client, '409 Conflict', this.page('手表正在登录', '<p>请稍候查看手表。</p>'));
      return;
    }
    const form: PhoneLoginForm = this.parseForm(body);
    this.busy = true;
    let result: PhoneSetupResult;
    try {
      result = await this.handler(form);
    } catch (_) {
      result = { done: false, message: '登录失败，请检查后重试' };
    }
    this.busy = false;
    if (result.done) {
      this.stop();
      await this.respond(client, '200 OK', this.page(result.message, '<p>可以关闭此页面了。</p>'));
    } else {
      // Keep the session so the user can fix the input on the phone and submit again.
      await this.respond(client, '200 OK', this.form(form.server, form.username, form.allowLocalHttp, result.message));
    }
  }

  private parseForm(body: string): PhoneLoginForm {
    const values: Map<string, string> = new Map<string, string>();
    body.split('&').forEach((pair: string) => {
      const index: number = pair.indexOf('=');
      if (index <= 0) return;
      try {
        values.set(decodeURIComponent(pair.substring(0, index).replace(/\+/g, ' ')),
          decodeURIComponent(pair.substring(index + 1).replace(/\+/g, ' ')));
      } catch (_) {
        // Ignore a malformed field; the login will report what is missing.
      }
    });
    return {
      server: (values.get('server') ?? '').trim(),
      username: (values.get('username') ?? '').trim(),
      password: values.get('password') ?? '',
      allowLocalHttp: values.get('lan') === 'on'
    };
  }

  private async respond(client: socket.TCPSocketConnection, status: string, html: string): Promise<void> {
    const encoder: util.TextEncoder = new util.TextEncoder();
    const body: Uint8Array = encoder.encodeInto(html);
    const head: Uint8Array = encoder.encodeInto('HTTP/1.1 ' + status + '\r\n' +
      'Content-Type: text/html; charset=utf-8\r\n' +
      'Content-Length: ' + body.length + '\r\n' +
      'Cache-Control: no-store\r\n' +
      'Referrer-Policy: no-referrer\r\n' +
      'Connection: close\r\n\r\n');
    const all: Uint8Array = new Uint8Array(head.length + body.length);
    all.set(head, 0);
    all.set(body, head.length);
    try {
      await client.send({ data: all.buffer });
    } catch (_) {
      // The phone went away; nothing to do.
    }
    try {
      await client.close();
    } catch (_) {
      // Already closed.
    }
  }

  private form(server: string, username: string, lan: boolean, error: string): string {
    return this.page('登录 Home Assistant',
      (error ? '<p class="err">' + this.escape(error) + '</p>' : '') +
      '<form method="post" autocomplete="off">' +
      '<label>HA 地址<input name="server" type="url" required placeholder="http://192.168.1.10:8123" value="' +
      this.escape(server) + '"></label>' +
      '<label>用户名<input name="username" required autocapitalize="none" value="' + this.escape(username) + '"></label>' +
      '<label>密码<input name="password" type="password" required></label>' +
      '<label class="row"><input name="lan" type="checkbox"' + (lan ? ' checked' : '') +
      '>地址是 http:// 局域网地址，我确认只在可信网络使用</label>' +
      '<button type="submit">发送到手表</button></form>' +
      '<p class="hint">信息只在局域网内直接发给手表，不经过其他服务器；密码不会保存在手表上。</p>');
  }

  private page(title: string, content: string): string {
    return '<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">' +
      '<meta name="viewport" content="width=device-width,initial-scale=1"><title>腕上智家</title><style>' +
      'body{font-family:system-ui,sans-serif;background:#0b111a;color:#fff;margin:0;padding:24px;max-width:480px}' +
      'h1{font-size:20px;font-weight:500}label{display:block;margin:14px 0;color:#afc3d2;font-size:14px}' +
      'input[type=url],input[name=username],input[type=password]{display:block;width:100%;box-sizing:border-box;' +
      'margin-top:6px;padding:12px;border-radius:10px;border:1px solid #314453;background:#1b2732;color:#fff;font-size:16px}' +
      '.row{display:flex;gap:8px;align-items:flex-start}button{width:100%;padding:14px;border:0;border-radius:24px;' +
      'background:#1f748a;color:#fff;font-size:16px;margin-top:8px}.err{color:#ff9b9b}.hint{color:#9db9cb;font-size:12px}' +
      '</style></head><body><h1>' + this.escape(title) + '</h1>' + content + '</body></html>';
  }

  private escape(value: string): string {
    return value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  private concat(chunks: Uint8Array[], length: number): Uint8Array {
    if (chunks.length === 1) return chunks[0];
    const out: Uint8Array = new Uint8Array(length);
    let offset: number = 0;
    chunks.forEach((chunk: Uint8Array) => {
      out.set(chunk, offset);
      offset += chunk.length;
    });
    return out;
  }

  private findHeaderEnd(bytes: Uint8Array): number {
    for (let i: number = 0; i + 3 < bytes.length; i++) {
      if (bytes[i] === 13 && bytes[i + 1] === 10 && bytes[i + 2] === 13 && bytes[i + 3] === 10) return i;
    }
    return -1;
  }

  private decode(bytes: Uint8Array): string {
    return util.TextDecoder.create('utf-8').decodeToString(bytes);
  }

  private randomToken(): string {
    const bytes: Uint8Array = cryptoFramework.createRandom().generateRandomSync(16).data;
    let token: string = '';
    for (let i: number = 0; i < bytes.length; i++) token += bytes[i].toString(16).padStart(2, '0');
    return token;
  }
}
