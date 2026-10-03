import { IconBadge } from './IconBadge';
import { Theme } from '../Theme';

@ComponentV2
export struct SystemTile {
  @Param title: string | Resource = '';
  @Param subtitle: string | Resource = '';
  @Param iconText: string = '?';
  @Param iconRes: Resource | undefined = undefined;
  @Param iconBgColor: number = Theme.ACCENT;
  @Param showChevron: boolean = true;
  @Param bgColor: number = Theme.TILE;

  build() {
    Row() {
      IconBadge({ text: this.iconText, res: this.iconRes, bgColor: this.iconBgColor, badgeSize: 36 });

      Column() {
        Text(this.title)
          .width('100%')
          .textAlign(TextAlign.Start)
          .fontSize(17)
          .maxLines(1)
          .fontColor(Theme.TEXT)
          .textOverflow({ overflow: TextOverflow.MARQUEE });

        if (this.subtitle) {
          Text(this.subtitle)
            .width('100%')
            .textAlign(TextAlign.Start)
            .fontSize(13)
            .maxLines(1)
            .fontColor(Theme.TEXT_SUB)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 2 });
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 6, right: 4 });

      if (this.showChevron) {
        Image($r("app.media.chevron_right"))
          .width(30)
          .height(30)
          .opacity(0.65)
          .objectFit(ImageFit.Contain)
          .margin({ right: 0 });
      }
    }
    .width('92%')
    .borderRadius(30)
    .backgroundColor(this.bgColor)
    .padding({ left: 6, right: 6, top: 8, bottom: 8 })
    .alignItems(VerticalAlign.Center);
  }
}
