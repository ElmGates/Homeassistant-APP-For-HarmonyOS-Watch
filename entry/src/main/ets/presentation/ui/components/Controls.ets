import { Theme } from '../Theme';

// Centered full-width button sized for the round 466×466 screen.
@ComponentV2
export struct WideButton {
  @Param label: string = '';
  @Param canTap: boolean = true;
  @Param buttonColor: number = Theme.SECONDARY;
  @Param buttonHeight: number = 50;
  @Event onTap: () => void = () => {};

  build() {
    Row() {
      Button(this.label)
        .width('78%').height(this.buttonHeight).fontSize(16)
        .backgroundColor(this.buttonColor)
        .enabled(this.canTap)
        .onClick(() => this.onTap());
    }
    .width('100%').justifyContent(FlexAlign.Center);
  }
}

// Value label with a − / + pair underneath. The value (with unit) lives in the label; the buttons
// only show the symbol so they never truncate on the 466×466 round screen.
@ComponentV2
export struct StepperRow {
  @Param label: string = '';
  @Param canTap: boolean = true;
  @Event onMinus: () => void = () => {};
  @Event onPlus: () => void = () => {};

  build() {
    Column() {
      Text(this.label)
        .width('78%').fontSize(17).fontColor(Theme.TEXT).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center);
      Row() {
        Button('−').width('37%').height(50).fontSize(26)
          .backgroundColor(Theme.SECONDARY)
          .enabled(this.canTap).onClick(() => this.onMinus());
        Button('+').width('37%').height(50).fontSize(26).margin({ left: 10 })
          .backgroundColor(Theme.SECONDARY)
          .enabled(this.canTap).onClick(() => this.onPlus());
      }
      .width('100%').justifyContent(FlexAlign.Center).margin({ top: 6 });
    }
    .width('100%').alignItems(HorizontalAlign.Center);
  }
}

// Centered informational text line.
@ComponentV2
export struct InfoText {
  @Param text: string = '';
  @Param textColor: number = Theme.TEXT_DIM;
  @Param textSize: number = 13;

  build() {
    Row() {
      Text(this.text)
        .width('78%').fontSize(this.textSize).fontColor(this.textColor)
        .textAlign(TextAlign.Center);
    }
    .width('100%').justifyContent(FlexAlign.Center);
  }
}
