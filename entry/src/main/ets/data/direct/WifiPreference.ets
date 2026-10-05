import { connection } from '@kit.NetworkKit';
import { forgetRoute } from './LanRoute';

// Prefers the watch's Wi-Fi over the phone's Bluetooth while the app is in the foreground.
// On a watch the system's default network is Bluetooth whenever the phone is connected, even with Wi-Fi up
// (getDefaultNet: "蓝牙（手表）> WIFI > 蜂窝"), and the Bluetooth relay cannot reach the LAN. So the app
// asks for a Wi-Fi network (the system tries to bring it up if it is not active) and binds itself to it
// with setAppNet; when Wi-Fi goes away it unbinds and falls back to the default network. In the background
// the request is released and the binding removed, so the watch does not keep Wi-Fi on for this app.

let request: connection.NetConnection | undefined = undefined;
let boundNetId: number = 0;
let changed: () => void = () => {};

// Called after the app switched network (Wi-Fi bound or released), e.g. to re-sync over the new route.
export function onPreferredNetworkChange(callback: () => void): void {
  changed = callback;
}

export function startPreferringWifi(): void {
  if (request) return;
  const wifi: connection.NetConnection = connection.createNetConnection({
    netCapabilities: {
      bearerTypes: [connection.NetBearType.BEARER_WIFI],
      networkCap: [connection.NetCap.NET_CAPABILITY_INTERNET]
    }
  }, 15000);
  wifi.on('netAvailable', (net: connection.NetHandle) => {
    if (net.netId === boundNetId) return;
    connection.setAppNet(net).then(() => {
      boundNetId = net.netId;
      forgetRoute();
      changed();
    }).catch(() => {
      // Binding refused: the app keeps using the default network.
    });
  });
  wifi.on('netLost', (net: connection.NetHandle) => {
    if (net.netId === boundNetId) release();
  });
  wifi.register(() => {
    // Registration errors leave the app on the default network, which still works.
  });
  request = wifi;
}

export function stopPreferringWifi(): void {
  const wifi: connection.NetConnection | undefined = request;
  request = undefined;
  if (wifi) wifi.unregister(() => {});
  release();
}

// Whether requests currently go through the bound Wi-Fi.
export function wifiBound(): boolean {
  return boundNetId !== 0;
}

function release(): void {
  if (boundNetId === 0) return;
  boundNetId = 0;
  try {
    const none: connection.NetHandle = connection.getDefaultNetSync();
    none.netId = 0;
    connection.setAppNet(none).catch(() => {});
  } catch (_) {
    // Nothing bound any more from the app's point of view.
  }
  forgetRoute();
  changed();
}
