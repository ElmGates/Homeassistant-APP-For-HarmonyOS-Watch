import { http } from '@kit.NetworkKit';

interface AuthProvider {
  type: string;
  id?: string | null;
}

interface ProvidersResponse {
  providers?: AuthProvider[];
}

interface FlowField {
  name?: string;
}

interface FlowResponse {
  type?: string;
  flow_id?: string;
  step_id?: string;
  result?: string;
  data_schema?: FlowField[];
  errors?: Record<string, string>;
}

interface TokenResponse {
  access_token?: string;
  refresh_token?: string;
  expires_in?: number;
}

interface FlowSubmitBody {
  client_id: string;
  username?: string;
  password?: string;
  code?: string;
}

export interface HaSession {
  accessToken: string;
  refreshToken: string;
  expiresAt: number;
}

export interface LoginStep {
  session?: HaSession;
  mfaFlowId?: string;
  mfaField?: string;
}

export class HaAuthClient {
  readonly server: string;
  private readonly clientId: string;
  private readonly direct: boolean;

  // `server` is the address requests go to; `clientServer` the address the login was made with (HA ties
  // refresh tokens to that client_id), when the request goes through the LAN address instead.
  constructor(server: string, clientServer?: string) {
    this.server = server.trim().replace(/\/+$/, '');
    const secure: boolean = /^https:\/\/[a-z0-9.-]+(?::[0-9]{1,5})?$/i.test(this.server);
    const local: boolean = /^http:\/\/(?:(?:10|127|192\.168)\.[0-9.]+|172\.(?:1[6-9]|2[0-9]|3[01])\.[0-9.]+|localhost|[a-z0-9-]+\.local)(?::[0-9]{1,5})?$/i.test(this.server);
    if (!secure && !local) throw new Error('请输入 HTTPS 地址，或局域网 HTTP 地址');
    this.direct = local;
    this.clientId = (clientServer ? clientServer.trim().replace(/\/+$/, '') : this.server) + '/';
  }

  async login(username: string, password: string, allowLocalHttp: boolean): Promise<LoginStep> {
    if (this.server.startsWith('http://') && !allowLocalHttp) {
      throw new Error('HTTP 会明文传输密码，请先确认仅在可信局域网使用');
    }
    if (!username.trim() || !password) throw new Error('请输入用户名和密码');
    const providers: ProvidersResponse = JSON.parse(await this.request('/auth/providers', http.RequestMethod.GET)) as ProvidersResponse;
    const provider: AuthProvider | undefined = providers.providers?.find((item: AuthProvider) => item.type === 'homeassistant');
    if (!provider) throw new Error('此 HA 未启用内置用户名密码登录');
    const started: FlowResponse = JSON.parse(await this.request('/auth/login_flow', http.RequestMethod.POST,
      JSON.stringify({ client_id: this.clientId, redirect_uri: this.clientId,
        handler: [provider.type, provider.id ?? null] }))) as FlowResponse;
    if (started.type !== 'form' || started.step_id !== 'init' || !started.flow_id) {
      throw new Error('HA 登录流程无法启动');
    }
    const body: FlowSubmitBody = { client_id: this.clientId, username: username.trim(), password };
    const result: FlowResponse = await this.submitFlow(started.flow_id, body);
    return await this.handleResult(result);
  }

  async submitMfa(flowId: string, field: string, code: string): Promise<HaSession> {
    if (!flowId || !field || !code.trim()) throw new Error('请输入验证码');
    if (field !== 'code') throw new Error('此 HA 验证方式暂不支持');
    const body: FlowSubmitBody = { client_id: this.clientId, code: code.trim() };
    const result: FlowResponse = await this.submitFlow(flowId, body);
    const step: LoginStep = await this.handleResult(result);
    if (!step.session) throw new Error('需要其他验证方式，当前手表暂不支持');
    return step.session;
  }

  async refresh(refreshToken: string): Promise<HaSession> {
    const result: TokenResponse = JSON.parse(await this.request('/auth/token', http.RequestMethod.POST,
      'grant_type=refresh_token&refresh_token=' + encodeURIComponent(refreshToken) +
      '&client_id=' + encodeURIComponent(this.clientId), 'application/x-www-form-urlencoded')) as TokenResponse;
    if (!result.access_token || !result.expires_in) throw new Error('HA 刷新凭证格式不正确');
    return { accessToken: result.access_token, refreshToken,
      expiresAt: Date.now() + result.expires_in * 1000 };
  }

  async revoke(refreshToken: string): Promise<void> {
    await this.request('/auth/revoke', http.RequestMethod.POST,
      'token=' + encodeURIComponent(refreshToken), 'application/x-www-form-urlencoded');
  }

  private async handleResult(result: FlowResponse): Promise<LoginStep> {
    if (result.type === 'create_entry' && result.result) {
      const token: TokenResponse = JSON.parse(await this.request('/auth/token', http.RequestMethod.POST,
        'grant_type=authorization_code&code=' + encodeURIComponent(result.result) +
        '&client_id=' + encodeURIComponent(this.clientId), 'application/x-www-form-urlencoded')) as TokenResponse;
      if (!token.access_token || !token.refresh_token || !token.expires_in) {
        throw new Error('HA 登录凭证格式不正确');
      }
      return { session: { accessToken: token.access_token, refreshToken: token.refresh_token,
        expiresAt: Date.now() + token.expires_in * 1000 } };
    }
    if (result.type === 'form' && result.errors && Object.keys(result.errors).length > 0) {
      if (result.step_id === 'init') throw new Error('用户名或密码错误');
      if (result.step_id === 'mfa') throw new Error('验证码错误或已过期');
    }
    if (result.type === 'form' && result.step_id === 'mfa' && result.flow_id) {
      const field: string | undefined = result.data_schema?.find((item: FlowField) => !!item.name)?.name;
      if (!field) throw new Error('HA 验证码格式暂不支持');
      return { mfaFlowId: result.flow_id, mfaField: field };
    }
    throw new Error('此 HA 登录步骤暂不支持');
  }

  private async submitFlow(flowId: string, body: FlowSubmitBody): Promise<FlowResponse> {
    return JSON.parse(await this.request('/auth/login_flow/' + encodeURIComponent(flowId),
      http.RequestMethod.POST, JSON.stringify(body))) as FlowResponse;
  }

  private async request(path: string, method: http.RequestMethod, body?: string,
    contentType: string = 'application/json'): Promise<string> {
    const client: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await client.request(this.server + path, {
        method,
        header: { 'Content-Type': contentType },
        extraData: body ?? '',
        expectDataType: http.HttpDataType.STRING,
        usingProxy: !this.direct,
        connectTimeout: this.direct ? 5000 : 30000,
        readTimeout: 20000
      });
      if (response.responseCode === 400 && path === '/auth/token') {
        throw new Error('登录已失效，请重新登录');
      }
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error('HA 登录接口返回 HTTP ' + response.responseCode);
      }
      return response.result as string;
    } finally {
      client.destroy();
    }
  }
}
