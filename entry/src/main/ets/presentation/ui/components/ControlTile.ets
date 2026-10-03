import { IconBadge } from './IconBadge';
import { Theme } from '../Theme';

// Device row: tapping the text opens details; the round button on the right runs the quick action.
// Without an action label the row shows a chevron and the whole row opens details.
@ComponentV2
export struct ControlTile {
  @Param title: string = '';
  @Param subtitle: string = '';
  @Param icon: Resource | undefined = undefined;
  @Param glyphColor: number = Theme.ICON_IDLE;
  @Param actionLabel: string = '';
  // When set, the action button shows this icon (e.g. ▶ for 执行) instead of actionLabel.
  @Param actionIcon: Resource | undefined = undefined;
  @Param actionColor: number = Theme.ACCENT;
  @Param actionEnabled: boolean = true;
  @Param busy: boolean = false;
  @Event onOpen: () => void = () => {};
  @Event onAction: () => void = () => {};

  build() {
    Row() {
      Row() {
        IconBadge({ text: '', res: this.icon, bgColor: this.glyphColor, badgeSize: 36 });
        // Only ~4–5 Chinese characters fit per line on the 1.6" round screen: long device names
        // scroll (marquee only moves when the text overflows), the state line ellipsizes.
        Column() {
          Text(this.title)
            .width('100%').textAlign(TextAlign.Start)
            .fontSize(17).fontColor(Theme.TEXT).maxLines(1)
            .textOverflow({ overflow: TextOverflow.MARQUEE });
          Text(this.subtitle)
            .width('100%').textAlign(TextAlign.Start)
            .fontSize(13).fontColor(Theme.TEXT_SUB).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 2 });
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 6, right: 4 });
      }
      .layoutWeight(1)
      .alignItems(VerticalAlign.Center)
      .onClick(() => this.onOpen());

      if (this.actionIcon !== undefined && !this.busy) {
        Button({ type: ButtonType.Capsule, stateEffect: true }) {
          Image(this.actionIcon).width(22).height(22).objectFit(ImageFit.Contain);
        }
        .width(52).height(44)
        .backgroundColor(this.actionColor)
        .enabled(this.actionEnabled)
        .onClick(() => this.onAction());
      } else if (this.actionLabel.length > 0 || this.busy) {
        Button(this.busy ? '…' : this.actionLabel)
          .width(52).height(44).fontSize(15)
          .backgroundColor(this.actionColor)
          .enabled(this.actionEnabled)
          .onClick(() => this.onAction());
      } else {
        Image($r('app.media.chevron_right'))
          .width(28).height(28).opacity(0.65)
          .objectFit(ImageFit.Contain)
          .onClick(() => this.onOpen());
      }
    }
    .width('92%')
    .padding({ left: 6, right: 6, top: 8, bottom: 8 })
    .borderRadius(30)
    .backgroundColor(Theme.TILE)
    .alignItems(VerticalAlign.Center);
  }
}
