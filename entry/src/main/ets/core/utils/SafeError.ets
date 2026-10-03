interface ErrorLike {
  code?: number;
  message?: string;
}

// Network Kit http errors are 2300000 + the libcurl error number.
const NETWORK_MESSAGES: Record<number, string> = {
  2300003: '服务器地址格式不正确',
  2300006: '无法解析服务器域名，请检查地址或网络',
  2300007: '无法连接到服务器，请检查网络或 HA 是否在线',
  2300028: '连接 HA 超时，网络较慢或服务器暂时没有响应',
  2300035: 'HTTPS 握手失败，请检查服务器的证书配置',
  2300052: '服务器没有返回数据，请稍后重试',
  2300055: '网络连接中断，请重试',
  2300056: '网络连接中断，请重试',
  2300060: 'HTTPS 证书无效或不受信任'
};

// Temporary network conditions where repeating a read-only request is safe and likely to help.
const TRANSIENT_CODES: number[] = [2300007, 2300028, 2300052, 2300055, 2300056];

export function isTransientNetworkError(error: Object): boolean {
  const code: number | undefined = (error as ErrorLike).code;
  return typeof code === 'number' && TRANSIENT_CODES.includes(code);
}

// Native BusinessError.toString() can display only "[object Object]". Never
// interpolate an unknown message: network errors may contain the request URL.
export function safeError(error: Object, fallback: string): string {
  const details: ErrorLike = error as ErrorLike;
  if (typeof details.code === 'number') {
    const known: string | undefined = NETWORK_MESSAGES[details.code];
    return known ? known + '（' + details.code + '）' : fallback + '（错误码 ' + details.code + '）';
  }
  if (error instanceof Error && error.message && error.message !== '[object Object]') {
    return error.message;
  }
  return fallback;
}
