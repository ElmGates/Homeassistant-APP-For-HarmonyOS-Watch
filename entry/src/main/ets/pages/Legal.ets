import { SystemHeader } from '../presentation/ui/components/SystemHeader';
import { Theme } from '../presentation/ui/Theme';
import { ArcScrollBar } from '@kit.ArkUI';
import { focusList } from '../presentation/ui/Focus';
import { scrollTick } from '../presentation/ui/Haptics';
import { LegalDoc, LegalSection, PRIVACY, TERMS } from '../presentation/ui/LegalText';

interface LegalRow {
  heading: boolean;
  text: string;
}

interface LegalRouteParams {
  doc: string;
}

// Privacy policy or terms, readable on the watch (the watch has no browser to open the website).
@Entry
@ComponentV2
struct Legal {
  @Local private legal: LegalDoc = PRIVACY;
  private readonly scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    const params: LegalRouteParams | undefined = this.getUIContext().getRouter().getParams() as LegalRouteParams;
    this.legal = params?.doc === 'terms' ? TERMS : PRIVACY;
  }

  // Intro, then each section's heading and lines, as one flat list of rows.
  private rows(): LegalRow[] {
    const rows: LegalRow[] = this.legal.intro.map((line: string): LegalRow => ({ heading: false, text: line }));
    this.legal.sections.forEach((section: LegalSection) => {
      rows.push({ heading: true, text: section.title });
      section.lines.forEach((line: string) => { rows.push({ heading: false, text: line }); });
    });
    return rows;
  }

  onPageShow(): void {
    focusList(this.getUIContext(), 'legalList');
  }

  @Builder
  heading(title: string) {
    Row() {
      Text(title).width('74%').fontSize(15).fontWeight(FontWeight.Medium).fontColor(Theme.TEXT)
        .textAlign(TextAlign.Start);
    }
    .width('100%').justifyContent(FlexAlign.Center).padding({ top: 8 });
  }

  @Builder
  paragraph(line: string) {
    Row() {
      Text(line)
        .width('74%').fontSize(13).lineHeight(19)
        .fontColor(Theme.TEXT_SUB)
        .textAlign(TextAlign.Start);
    }
    .width('100%').justifyContent(FlexAlign.Center);
  }

  build() {
    Stack() {
      List({ scroller: this.scroller, space: 6 }) {
        ListItem() { SystemHeader({ title: this.legal.title }) }
        ListItem() {
          Row() {
            Text(this.legal.meta).width('78%').fontSize(11).fontColor(Theme.TEXT_DIM).textAlign(TextAlign.Center);
          }
          .width('100%').justifyContent(FlexAlign.Center);
        }
        ForEach(this.rows(), (row: LegalRow) => {
          ListItem() {
            if (row.heading) {
              this.heading(row.text)
            } else {
              this.paragraph(row.text)
            }
          }
        }, (row: LegalRow, index: number) => index + row.text);
      }
      .id('legalList')
      .width('100%').height('100%')
      .focusable(true).focusOnTouch(true)
      .digitalCrownSensitivity(CrownSensitivity.MEDIUM)
      .onWillScroll((offset: number, state: ScrollState, source: ScrollSource) => { scrollTick(offset, source); })
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
