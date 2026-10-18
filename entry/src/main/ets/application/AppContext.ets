import common from '@ohos.app.ability.common';

export class AppContext {
  private static context: common.UIAbilityContext | null = null;
  private static restoreHandler: (() => void) | null = null;

  static setContext(ctx: common.UIAbilityContext): void {
    AppContext.context = ctx;
  }

  static getContext(): common.UIAbilityContext | null {
    return AppContext.context;
  }

  // The hide state (hidden vs minimized) belongs to the main ability, and only it knows how to undo
  // the right one, so the ability registers its own restore path here for the status-bar panel.
  static setRestoreHandler(handler: (() => void) | null): void {
    AppContext.restoreHandler = handler;
  }

  static restore(): boolean {
    const handler = AppContext.restoreHandler;
    if (handler === null) {
      return false;
    }
    handler();
    return true;
  }
}