import { bundleManager } from '@kit.AbilityKit';
import { SectionLabel, SystemHeader } from '../presentation/ui/components/SystemHeader';
import { InfoText } from '../presentation/ui/components/Controls';
import { Theme } from '../presentation/ui/Theme';
import { ArcScrollBar } from '@kit.ArkUI';

// Product site (docs/site/ is deployed here).
const WEBSITE: string = 'https://watch.superjia.org';

interface OpenSourceReference {
  name: string;
  author: string;
  license: string;
  usage: string;
  url: string;
}

// Keep in sync with NOTICE.md in the project root.
const REFERENCES: OpenSourceReference[] = [
  {
    name: 'Home-Assistant-HarmonyOS-Next',
    author: 'gentslava',
    license: 'MIT（以原项目声明为准）',
    usage: '参考了最初的手表端工程结构和部分界面组件，现已大部分重写',
    url: 'github.com/gentslava/Home-Assistant-HarmonyOS-Next'
  },
  {
    name: 'Home Assistant 开发者文档',
    author: 'Open Home Foundation',
    license: '仅参考接口说明，未包含其代码',
    usage: '参考 REST 与 WebSocket 接口协议',
    url: 'developers.home-assistant.io'
  }
];

@Entry
@ComponentV2
struct About {
  @Local private version: string = '';
  private readonly scroller: Scroller = new Scroller();

  // Read from the installed bundle so the page always matches AppScope/app.json5 (major.minor.patch).
  aboutToAppear(): void {
    bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)
      .then((info: bundleManager.BundleInfo) => { this.version = info.versionName; })
      .catch(() => { this.version = '未知'; });
  }

  build() {
    Stack() {
      List({ scroller: this.scroller, space: 10 }) {
        ListItem() { SystemHeader({ title: '关于' }) }
        ListItem() { InfoText({ text: '由 SuperJia 开发', textSize: 17, textColor: Theme.TEXT }) }
        ListItem() { InfoText({ text: '当前版本：' + (this.version || '读取中…'), textSize: 14 }) }
        ListItem() {
          Row() {
            // White quiet zone around the code keeps it scannable on the dark watch background.
            QRCode(WEBSITE)
              .width(150).height(150)
              .color(Color.Black)
              .backgroundColor(Color.White);
          }
          .padding(10)
          .borderRadius(16)
          .backgroundColor(Color.White);
        }
        .width('100%')
        ListItem() { InfoText({ text: 'watch.superjia.org', textSize: 13 }) }
        ListItem() { SectionLabel({ title: '开源代码参考' }) }
        ForEach(REFERENCES, (ref: OpenSourceReference) => {
          ListItem() {
            Column({ space: 3 }) {
              Text(ref.name)
                .width('100%').fontSize(15).fontWeight(FontWeight.Medium).fontColor(Theme.TEXT)
                .textAlign(TextAlign.Center);
              Text(ref.author + ' · ' + ref.license)
                .width('100%').fontSize(12).fontColor(Theme.TEXT_DIM).textAlign(TextAlign.Center);
              Text(ref.usage)
                .width('100%').fontSize(12).fontColor(Theme.TEXT_SUB).textAlign(TextAlign.Center);
              Text(ref.url)
                .width('100%').fontSize(11).fontColor(Theme.TEXT_DIM).textAlign(TextAlign.Center)
                .wordBreak(WordBreak.BREAK_ALL);
            }
            .width('84%')
            .padding({ left: 12, right: 12, top: 10, bottom: 10 })
            .borderRadius(18)
            .backgroundColor(Theme.TILE);
          }
          .width('100%')
        }, (ref: OpenSourceReference) => ref.name)
        ListItem() { InfoText({ text: 'Home Assistant 是 Open Home Foundation 的商标。本应用为独立开发的第三方应用。', textSize: 11 }) }
      }
      .width('100%').height('100%')
      .alignListItem(ListItemAlign.Center)
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
