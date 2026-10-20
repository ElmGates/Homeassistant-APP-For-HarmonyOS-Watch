import { vibrator } from '@kit.SensorServiceKit';

// System haptics like the watch's own apps: a light tick while the crown scrolls a list, a short tap when a
// button is pressed, and a success / failure pattern when a command finishes. Usage "touch" follows the
// system's touch-feedback switch, so users who turned it off feel nothing.

const CROWN_EFFECT: string = 'haptic.clock.timer';
const TAP_EFFECT: string = 'haptic.effect.soft';
const SUCCESS_EFFECT: string = 'haptic.notice.success';
const FAILURE_EFFECT: string = 'haptic.notice.fail';
// Distance (vp) the crown scrolls a list per tick, and the shortest gap between two ticks / taps.
const SCROLL_STEP_VP: number = 40;
const MIN_GAP_MS: number = 40;
// A button press that also starts a command must not buzz twice.
const TAP_DEDUP_MS: number = 150;

const supported: Map<string, boolean> = new Map<string, boolean>();
let scrollTravel: number = 0;
let lastAt: number = 0;
let lastTapAt: number = 0;

function isSupported(effectId: string): boolean {
  let known: boolean | undefined = supported.get(effectId);
  if (known === undefined) {
    try {
      known = vibrator.isSupportEffectSync(effectId);
    } catch (_) {
      known = false;
    }
    supported.set(effectId, known);
  }
  return known;
}

function play(effectId: string, usage: vibrator.Usage): void {
  const now: number = Date.now();
  if (now - lastAt < MIN_GAP_MS) return;
  lastAt = now;
  const attribute: vibrator.VibrateAttribute = { usage: usage };
  try {
    if (isSupported(effectId)) {
      const preset: vibrator.VibratePreset = { type: 'preset', effectId: effectId, count: 1 };
      vibrator.startVibration(preset, attribute).catch(() => {});
    } else {
      // Watches without the preset still get a very short pulse.
      const pulse: vibrator.VibrateTime = { type: 'time', duration: 12 };
      vibrator.startVibration(pulse, attribute).catch(() => {});
    }
  } catch (_) {
    // Haptics are a nicety: never let them break a control.
  }
}

// For List .onWillScroll: one tick per SCROLL_STEP_VP scrolled by the digital crown. Crown scrolling arrives
// as OTHER_USER_INPUT (touch drags and flings are DRAG / FLING and stay silent). Listening to the crown itself
// with onDigitalCrown would replace the list's own crown scrolling, so the list is left to scroll by itself.
export function scrollTick(offset: number, source: ScrollSource): void {
  if (source !== ScrollSource.OTHER_USER_INPUT) {
    scrollTravel = 0;
    return;
  }
  scrollTravel += Math.abs(offset);
  if (scrollTravel < SCROLL_STEP_VP) return;
  scrollTravel = 0;
  play(CROWN_EFFECT, 'touch');
}

export function hapticTap(): void {
  const now: number = Date.now();
  if (now - lastTapAt < TAP_DEDUP_MS) return;
  lastTapAt = now;
  play(TAP_EFFECT, 'touch');
}

export function hapticResult(ok: boolean): void {
  lastAt = 0;
  play(ok ? SUCCESS_EFFECT : FAILURE_EFFECT, 'touch');
}
