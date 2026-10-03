import { Theme } from '../Theme';

@ComponentV2
export struct SystemHeader {
  @Param title: string = '';

  build() {
    Row() {
      Text(this.title)
        .width('72%')
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT)
        .maxLines(1)
        .textAlign(TextAlign.Center)
        .textOverflow({ overflow: TextOverflow.MARQUEE });
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 27, bottom: 8 });
  }
}

// Small dim caption separating list sections, e.g. "常用" / "房间".
@ComponentV2
export struct SectionLabel {
  @Param title: string = '';

  build() {
    Row() {
      Text(this.title)
        .fontSize(13).fontColor(Theme.TEXT_DIM);
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 6 });
  }
}
