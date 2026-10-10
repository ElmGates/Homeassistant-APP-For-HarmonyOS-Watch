import { AppStorageV2 } from '@ohos.arkui.StateManagement';
import { DirectStore } from '../presentation/store/DirectStore';
import { DiagStep, NetworkDiagnostics } from '../data/diag/NetworkDiagnostics';
import { SystemHeader } from '../presentation/ui/components/SystemHeader';
import { InfoText, WideButton } from '../presentation/ui/components/Controls';
import { Theme } from '../presentation/ui/Theme';
import { ArcScrollBar } from '@kit.ArkUI';
import { focusList } from '../presentation/ui/Focus';

@Entry
@ComponentV2
struct NetworkDiagnose {
  @Local private store: DirectStore =
    AppStorageV2.connect(DirectStore, 'directStore', () => new DirectStore())!;
  @Local private steps: DiagStep[] = [];
  @Local private running: boolean = false;
  private readonly scroller: Scroller = new Scroller();

  onPageShow(): void {
    focusList(this.getUIContext(), 'diagnoseList');
  }

  aboutToAppear(): void {
    this.start();
  }

  private async start(): Promise<void> {
    if (this.running || !this.store.configured) return;
    this.running = true;
    this.steps = [];
    const diagnostics: NetworkDiagnostics = new NetworkDiagnostics(this.store.getServer(),
      this.store.lanOff ? '' : this.store.lanUrl,
      () => this.store.freshAccessToken(),
      (step: DiagStep) => { this.steps = this.steps.concat([step]); });
    try {
      await diagnostics.run();
    } finally {
      this.running = false;
    }
  }

  build() {
    Stack() {
      List({ scroller: this.scroller, space: 6 }) {
        ListItem() { SystemHeader({ title: '连接诊断' }) }
        if (!this.store.configured) {
          ListItem() { InfoText({ text: '请先登录 Home Assistant', textSize: 14 }) }
        }
        ForEach(this.steps, (step: DiagStep, index: number) => {
          ListItem() {
            Column({ space: 2 }) {
              Row() {
                Text(step.ok ? '✓' : '✗')
                  .fontSize(16).fontWeight(FontWeight.Bold)
                  .fontColor(step.ok ? Theme.OK : Theme.ERROR).margin({ right: 6 });
                Text(step.title).fontSize(15).fontColor(Theme.TEXT).layoutWeight(1);
                Text(step.ms + ' ms').fontSize(12).fontColor(Theme.TEXT_DIM);
              }
              .width('100%');
              Text(step.detail)
                .width('100%').fontSize(12).fontColor(step.ok ? Theme.TEXT_SUB : Theme.WARN);
            }
            .width('84%')
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .borderRadius(18)
            .backgroundColor(Theme.TILE);
          }
          .width('100%')
        }, (step: DiagStep, index: number) => index + step.title)
        if (this.running) {
          ListItem() { InfoText({ text: '正在测试…', textSize: 13 }) }
        }
        ListItem() {
          WideButton({ label: this.running ? '测试中…' : '重新诊断', buttonColor: Theme.ACCENT,
            canTap: !this.running && this.store.configured, onTap: () => { this.start(); } })
        }
        ListItem() { InfoText({ text: '把这一页截图发给开发者，可快速定位问题。不包含密码和令牌。', textSize: 11 }) }
      }
      .width('100%').height('100%')
      .alignListItem(ListItemAlign.Center)
      .id('diagnoseList')
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
