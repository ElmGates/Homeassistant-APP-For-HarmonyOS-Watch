import { AppStorageV2 } from '@ohos.arkui.StateManagement';
import { DirectStore } from '../presentation/store/DirectStore';
import { DeviceGroup, DeviceItem } from '../data/direct/HomeAssistantModels';
import { ServiceData } from '../data/direct/HaDirectClient';
import { SystemHeader } from '../presentation/ui/components/SystemHeader';
import { InfoText, StepperRow, WideButton } from '../presentation/ui/components/Controls';
import { hvacModeLabel, isActive, isNum, isToggleDomain, stateLabel } from '../presentation/ui/DomainUi';
import { entityDisplayName } from '../presentation/ui/EntityDisplayName';
import { Theme } from '../presentation/ui/Theme';
import { ArcScrollBar } from '@kit.ArkUI';

interface EntityRouteParams {
  entityId: string;
}

@Entry
@ComponentV2
struct DirectEntityDetails {
  @Local private store: DirectStore =
    AppStorageV2.connect(DirectStore, 'directStore', () => new DirectStore())!;
  @Local private entityId: string = '';
  @Local private confirmUnlock: boolean = false;
  private unlockTimer: number = -1;
  private readonly scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    const params: EntityRouteParams = this.getUIContext().getRouter().getParams() as EntityRouteParams;
    this.entityId = params?.entityId ?? '';
    if (this.entityId.length > 0) this.store.refreshEntity(this.entityId);
  }

  aboutToDisappear(): void {
    clearTimeout(this.unlockTimer);
  }

  private device(): DeviceItem | undefined {
    return this.store.getDevice(this.entityId);
  }

  private domain(): string {
    return this.device()?.domain ?? '';
  }

  private group(): DeviceGroup | undefined {
    return this.store.groups.find((item: DeviceGroup) => item.entityIds.includes(this.entityId));
  }

  private titleText(): string {
    const device: DeviceItem | undefined = this.device();
    return device ? entityDisplayName(device, this.group()) : '设备';
  }

  private modeSensorHint(): string {
    const group: DeviceGroup | undefined = this.group();
    const climate: DeviceItem | undefined = group ? this.store.entitiesInGroup(group.id)
      .find((item: DeviceItem) => item.domain === 'climate') : undefined;
    return climate ? '此项是只读读数。返回设备页，打开「' +
      entityDisplayName(climate, group) + '」切换模式。' : '此项由 HA 作为只读状态提供';
  }

  // True when a control may be sent now: online, available and no other action in flight.
  private ready(): boolean {
    return !!this.device()?.available && this.store.online && this.store.actionEntityId.length === 0;
  }

  private run(service: string, data?: ServiceData, expectedState?: string): void {
    const device: DeviceItem | undefined = this.device();
    if (device) this.store.runService(device, service, data, expectedState);
  }

  private clamp(value: number, min: number, max: number): number {
    return Math.max(min, Math.min(max, value));
  }

  // Avoids 0.1 + 0.2 style artefacts when stepping decimal values.
  private roundTo(value: number, step: number): number {
    return Number((Math.round(value / step) * step).toFixed(4));
  }

  private brightnessPercent(): number {
    return Math.round((this.device()?.attributes?.brightness ?? 0) / 255 * 100);
  }

  private setBrightness(delta: number): void {
    this.run('turn_on', { brightness_pct: this.clamp(this.brightnessPercent() + delta, 1, 100) }, 'on');
  }

  // Number of speed levels. HA reports percentage_step = 100 / speed_count (33.33… for a 3-speed fan).
  private fanLevels(): number {
    const step: number = this.device()?.attributes?.percentage_step ?? 10;
    return step >= 5 ? Math.max(1, Math.round(100 / step)) : 10;
  }

  private fanPercent(): number {
    return Math.round(this.device()?.attributes?.percentage ?? 0);
  }

  // Current speed level; an off fan is level 0, an on fan is at least level 1 even if it reports 0 %.
  private fanLevel(): number {
    if (this.device()?.state !== 'on') return 0;
    return Math.max(1, Math.round(this.fanPercent() * this.fanLevels() / 100));
  }

  private fanLabel(): string {
    if (this.device()?.state !== 'on') return '风速 · 已关闭';
    return '风速 ' + Math.round(this.fanLevel() * 100 / this.fanLevels()) + '%';
  }

  // Steps by whole speed levels so a 3-speed fan goes 0 → 33 → 67 → 100 instead of drifting to 99.
  // Below the lowest speed the fan is switched off rather than sent "0 %".
  private setFanPercentage(direction: number): void {
    const levels: number = this.fanLevels();
    const level: number = this.clamp(this.fanLevel() + direction, 0, levels);
    if (level === 0) {
      if (this.device()?.state === 'on') this.run('turn_off', undefined, 'off');
      return;
    }
    this.run('set_percentage', { percentage: Math.round(level * 100 / levels) }, 'on');
  }

  private coverPosition(): number {
    return this.device()?.attributes?.current_position ?? 0;
  }

  private setCoverPosition(delta: number): void {
    this.run('set_cover_position', { position: this.clamp(this.coverPosition() + delta, 0, 100) });
  }

  private targetTemperature(): number {
    return this.device()?.attributes?.temperature ?? 20;
  }

  private temperatureStep(): number {
    return this.device()?.attributes?.target_temp_step ?? 0.5;
  }

  private setTemperature(direction: number): void {
    const device: DeviceItem | undefined = this.device();
    if (!device) return;
    const step: number = this.temperatureStep();
    const target: number = this.clamp(this.roundTo(this.targetTemperature() + direction * step, step),
      device.attributes?.min_temp ?? 7, device.attributes?.max_temp ?? 35);
    this.run('set_temperature', { temperature: target });
  }

  private hvacModes(): string[] {
    return this.device()?.attributes?.hvac_modes ?? [];
  }

  private numberValue(): number {
    const value: number = Number.parseFloat(this.device()?.state ?? '');
    return Number.isNaN(value) ? 0 : value;
  }

  private setNumber(direction: number): void {
    const device: DeviceItem | undefined = this.device();
    if (!device) return;
    const step: number = device.attributes?.step ?? 1;
    const target: number = this.clamp(this.roundTo(this.numberValue() + direction * step, step),
      device.attributes?.min ?? 0, device.attributes?.max ?? 100);
    this.run('set_value', { value: target });
  }

  private volumePercent(): number {
    return Math.round((this.device()?.attributes?.volume_level ?? 0) * 100);
  }

  private setVolume(delta: number): void {
    const target: number = this.clamp(this.volumePercent() + delta, 0, 100);
    this.run('volume_set', { volume_level: target / 100 });
  }

  private mediaTitle(): string {
    const title: string = this.device()?.attributes?.media_title ?? '';
    const artist: string = this.device()?.attributes?.media_artist ?? '';
    return artist && title ? title + ' · ' + artist : title;
  }

  // Unlocking is the only action with a physical-security impact: require a second tap within 4 s.
  private unlockTap(): void {
    clearTimeout(this.unlockTimer);
    if (!this.confirmUnlock) {
      this.confirmUnlock = true;
      this.unlockTimer = setTimeout(() => { this.confirmUnlock = false; }, 4000);
      return;
    }
    this.confirmUnlock = false;
    this.run('unlock', undefined, 'unlocked');
  }

  build() {
    Stack() {
      List({ scroller: this.scroller, space: 8 }) {
      ListItem() { SystemHeader({ title: this.titleText() }) }
      ListItem() {
        Column() {
          Text(this.device() ? stateLabel(this.device()!) : '—')
            .width('78%').fontSize(26).fontWeight(FontWeight.Medium).maxLines(2)
            .fontColor(this.device() && isActive(this.device()!) ? Theme.WARN : Theme.TEXT)
            .textAlign(TextAlign.Center);
          Text(this.store.actionEntityId === this.entityId ? '正在执行…' :
            (this.device()?.available ? '当前状态' : '设备不可用'))
            .fontSize(13).fontColor(Theme.TEXT_DIM).margin({ top: 4 });
        }
        .width('100%').alignItems(HorizontalAlign.Center);
      }

      if (isToggleDomain(this.domain())) {
        ListItem() {
          WideButton({
            label: this.device()?.state === 'on' ? '关闭' : '开启',
            buttonColor: this.device()?.state === 'on' ? Theme.ACTIVE : Theme.ACCENT,
            buttonHeight: 58,
            canTap: this.ready(),
            onTap: () => {
              const device: DeviceItem | undefined = this.device();
              if (device) this.store.toggle(device);
            }
          })
        }
      }
      if (this.domain() === 'light' && isNum(this.device()?.attributes?.brightness)) {
        ListItem() {
          StepperRow({ label: '亮度 ' + this.brightnessPercent() + '%',
            canTap: this.ready(), onMinus: () => this.setBrightness(-10), onPlus: () => this.setBrightness(10) })
        }
      }
      // percentage_step is reported even while the fan is off, so "+" can switch it on at the lowest speed.
      if (this.domain() === 'fan' && (isNum(this.device()?.attributes?.percentage) ||
        isNum(this.device()?.attributes?.percentage_step))) {
        ListItem() {
          StepperRow({ label: this.fanLabel(),
            canTap: this.ready(), onMinus: () => this.setFanPercentage(-1), onPlus: () => this.setFanPercentage(1) })
        }
      }

      if (this.domain() === 'cover') {
        ListItem() {
          Row() {
            Button('打开').width('25%').height(52).backgroundColor(Theme.SECONDARY)
              .enabled(this.ready()).onClick(() => this.run('open_cover'));
            Button('停止').width('25%').height(52).margin({ left: 6 }).backgroundColor(Theme.SECONDARY)
              .enabled(this.ready()).onClick(() => this.run('stop_cover'));
            Button('关闭').width('25%').height(52).margin({ left: 6 }).backgroundColor(Theme.SECONDARY)
              .enabled(this.ready()).onClick(() => this.run('close_cover'));
          }
          .width('100%').justifyContent(FlexAlign.Center);
        }
        if (isNum(this.device()?.attributes?.current_position)) {
          ListItem() {
            StepperRow({ label: '位置 ' + Math.round(this.coverPosition()) + '%',
              canTap: this.ready(), onMinus: () => this.setCoverPosition(-10),
              onPlus: () => this.setCoverPosition(10) })
          }
        }
      }

      if (this.domain() === 'climate') {
        ListItem() {
          WideButton({
            label: this.device()?.state === 'off' ? '开机' : '关机',
            buttonColor: this.device()?.state === 'off' ? Theme.ACCENT : Theme.ACTIVE,
            buttonHeight: 58,
            canTap: this.ready(),
            onTap: () => {
              if (this.device()?.state === 'off') {
                this.run('turn_on');
              } else {
                this.run('turn_off', undefined, 'off');
              }
            }
          })
        }
        ListItem() {
          InfoText({ text: '当前 ' + (this.device()?.attributes?.current_temperature ?? '—') + '°  目标 ' +
            (this.device()?.attributes?.temperature ?? '—') + '°', textSize: 16, textColor: Theme.TEXT })
        }
        if (isNum(this.device()?.attributes?.temperature)) {
          ListItem() {
            StepperRow({ label: '目标 ' + this.targetTemperature() + '°', canTap: this.ready(),
              onMinus: () => this.setTemperature(-1), onPlus: () => this.setTemperature(1) })
          }
        }
        if (this.hvacModes().length > 0) {
          ListItem() { InfoText({ text: '运行模式', textSize: 15 }) }
          ForEach(this.hvacModes(), (mode: string) => {
            ListItem() {
              WideButton({
                label: hvacModeLabel(mode) + (this.device()?.state === mode ? ' · 当前' : ''),
                buttonColor: this.device()?.state === mode ? Theme.SELECTED : Theme.SECONDARY,
                canTap: this.ready() && this.device()?.state !== mode,
                onTap: () => this.run('set_hvac_mode', { hvac_mode: mode }, mode)
              })
            }
          }, (mode: string) => mode);
        }
      }

      if (this.domain() === 'select' || this.domain() === 'input_select') {
        ListItem() { InfoText({ text: '选择选项', textSize: 15 }) }
        ForEach(this.device()?.attributes?.options ?? [], (option: string) => {
          ListItem() {
            WideButton({
              label: option + (this.device()?.state === option ? ' · 当前' : ''),
              buttonColor: this.device()?.state === option ? Theme.SELECTED : Theme.SECONDARY,
              canTap: this.ready() && this.device()?.state !== option,
              onTap: () => this.run('select_option', { option: option }, option)
            })
          }
        }, (option: string) => option);
      }

      if (this.domain() === 'number' || this.domain() === 'input_number') {
        ListItem() {
          StepperRow({ label: '设定 ' + stateLabel(this.device()!),
            canTap: this.ready(), onMinus: () => this.setNumber(-1), onPlus: () => this.setNumber(1) })
        }
      }

      if (this.domain() === 'scene' || this.domain() === 'script') {
        ListItem() {
          WideButton({ label: '执行', buttonColor: Theme.ACCENT, buttonHeight: 58, canTap: this.ready(),
            onTap: () => this.run('turn_on') })
        }
      }
      if (this.domain() === 'automation') {
        ListItem() {
          WideButton({ label: '立即执行', buttonColor: Theme.ACCENT, buttonHeight: 58, canTap: this.ready(),
            onTap: () => this.run('trigger') })
        }
        ListItem() {
          WideButton({
            label: this.device()?.state === 'on' ? '停用自动化' : '启用自动化',
            canTap: this.ready(),
            onTap: () => {
              if (this.device()?.state === 'on') {
                this.run('turn_off', undefined, 'off');
              } else {
                this.run('turn_on', undefined, 'on');
              }
            }
          })
        }
      }
      if (this.domain() === 'button' || this.domain() === 'input_button') {
        ListItem() {
          WideButton({ label: '按下', buttonColor: Theme.ACCENT, buttonHeight: 58, canTap: this.ready(),
            onTap: () => this.run('press') })
        }
      }

      if (this.domain() === 'lock') {
        if (this.device()?.state === 'locked') {
          ListItem() {
            WideButton({ label: this.confirmUnlock ? '再次点击确认解锁' : '解锁',
              buttonColor: this.confirmUnlock ? Theme.DANGER : Theme.SECONDARY, buttonHeight: 58,
              canTap: this.ready(), onTap: () => this.unlockTap() })
          }
        } else {
          ListItem() {
            WideButton({ label: '上锁', buttonColor: Theme.ACCENT, buttonHeight: 58, canTap: this.ready(),
              onTap: () => this.run('lock', undefined, 'locked') })
          }
        }
      }

      if (this.domain() === 'media_player') {
        if (this.mediaTitle().length > 0) {
          ListItem() { InfoText({ text: this.mediaTitle(), textSize: 14, textColor: Theme.TEXT_SUB }) }
        }
        if (this.device()?.state !== 'off' && this.device()?.state !== 'standby') {
          ListItem() {
            Row() {
              Button('上一首').width('25%').fontSize(13).height(52).backgroundColor(Theme.SECONDARY)
                .enabled(this.ready()).onClick(() => this.run('media_previous_track'));
              Button(this.device()?.state === 'playing' ? '暂停' : '播放').width('25%').height(52).margin({ left: 6 })
                .backgroundColor(Theme.ACCENT).enabled(this.ready())
                .onClick(() => {
                  if (this.device()?.state === 'playing') {
                    this.run('media_pause', undefined, 'paused');
                  } else {
                    this.run('media_play', undefined, 'playing');
                  }
                });
              Button('下一首').width('25%').fontSize(13).height(52).margin({ left: 6 }).backgroundColor(Theme.SECONDARY)
                .enabled(this.ready()).onClick(() => this.run('media_next_track'));
            }
            .width('100%').justifyContent(FlexAlign.Center);
          }
        }
        if (isNum(this.device()?.attributes?.volume_level)) {
          ListItem() {
            StepperRow({ label: '音量 ' + this.volumePercent() + '%',
              canTap: this.ready(), onMinus: () => this.setVolume(-10), onPlus: () => this.setVolume(10) })
          }
        }
        ListItem() {
          WideButton({ label: this.device()?.state === 'off' ? '开机' : '关机', canTap: this.ready(),
            onTap: () => this.run(this.device()?.state === 'off' ? 'turn_on' : 'turn_off') })
        }
      }

      if (this.domain() === 'vacuum') {
        ListItem() {
          Row() {
            Button('开始').width('25%').height(52).backgroundColor(Theme.ACCENT)
              .enabled(this.ready()).onClick(() => this.run('start'));
            Button('暂停').width('25%').height(52).margin({ left: 6 }).backgroundColor(Theme.SECONDARY)
              .enabled(this.ready()).onClick(() => this.run('pause'));
            Button('回充').width('25%').height(52).margin({ left: 6 }).backgroundColor(Theme.SECONDARY)
              .enabled(this.ready()).onClick(() => this.run('return_to_base'));
          }
          .width('100%').justifyContent(FlexAlign.Center);
        }
      }

      if (this.domain() === 'sensor' || this.domain() === 'binary_sensor') {
        ListItem() {
          InfoText({ text: this.titleText().includes('模式') ? this.modeSensorHint() : '此项由 HA 作为只读状态提供',
            textSize: 14 })
        }
      }

      if (this.device()) {
        ListItem() {
          WideButton({
            label: this.store.isFavorite(this.entityId) ? '★ 已加入常用' : '☆ 加入常用',
            buttonColor: this.store.isFavorite(this.entityId) ? Theme.SELECTED : Theme.SECONDARY,
            onTap: () => { this.store.toggleFavorite(this.entityId); }
          })
        }
      }
      ListItem() {
        WideButton({ label: '刷新设备状态', canTap: this.store.actionEntityId.length === 0,
          onTap: () => { this.store.refreshEntity(this.entityId); } })
      }
      if (this.store.message.length > 0) {
        ListItem() { InfoText({ text: this.store.message }) }
      }
      if (this.store.lastError.length > 0) {
        ListItem() { InfoText({ text: this.store.lastError, textColor: Theme.ERROR }) }
      }
      }
      .width('100%').height('100%')
      .focusable(true).focusOnTouch(true)
      .digitalCrownSensitivity(CrownSensitivity.MEDIUM)
      .scrollBar(BarState.Off)
      .contentEndOffset(100);
      ArcScrollBar({ scroller: this.scroller, state: BarState.Auto })
        .width('100%').height('100%')
        .hitTestBehavior(HitTestMode.Transparent);
    }
    .width('100%').height('100%')
    .backgroundColor(Theme.BG);
  }
}
