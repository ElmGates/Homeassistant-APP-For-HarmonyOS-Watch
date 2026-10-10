// The digital crown scrolls whichever component holds focus. A page's list only gets focus when it is
// touched, so the first crown turn on a fresh page did nothing until the screen was tapped.
// Give the list focus as soon as the page is shown (the delay lets the page finish laying out).
export function focusList(ui: UIContext, id: string): void {
  setTimeout(() => {
    try {
      ui.getFocusController().requestFocus(id);
    } catch (_) {
      // Best-effort: a tap still focuses the list.
    }
  }, 100);
}

// Movement (vp) beyond which a touch counts as a scroll rather than a tap.
const TAP_SLOP: number = 10;

// Tells a tap from the start of a scroll, so a text field opens the keyboard only when tapped,
// not when a swipe of the page happens to begin on it.
export class TapDetector {
  private startX: number = 0;
  private startY: number = 0;
  private dragged: boolean = true;

  // True when the event ends a touch that stayed in place.
  isTap(event: TouchEvent): boolean {
    const points: TouchObject[] = event.changedTouches !== undefined && event.changedTouches.length > 0 ?
      event.changedTouches : event.touches;
    if (points.length === 0) return false;
    const point: TouchObject = points[0];
    if (event.type === TouchType.Down) {
      this.startX = point.windowX;
      this.startY = point.windowY;
      this.dragged = false;
      return false;
    }
    const far: boolean = Math.abs(point.windowX - this.startX) > TAP_SLOP ||
      Math.abs(point.windowY - this.startY) > TAP_SLOP;
    if (event.type === TouchType.Move) {
      if (far) this.dragged = true;
      return false;
    }
    const tap: boolean = event.type === TouchType.Up && !this.dragged && !far;
    this.dragged = true;
    return tap;
  }
}
