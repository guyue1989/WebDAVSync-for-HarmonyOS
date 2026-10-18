export class Theme {
  static bg(dark: boolean): string {
    return dark ? '#1a1a1a' : '#ffffff';
  }

  static fg(dark: boolean): string {
    return dark ? '#e5e5e5' : '#333333';
  }

  static sub(dark: boolean): string {
    return dark ? '#888888' : '#999999';
  }

  static card(dark: boolean): string {
    return dark ? '#2a2a2a' : '#f2f3f5';
  }

  // Hover has to be painted by us: on this PC build ArkUI cannot read its hover capability
  // (the multiModalInputOptions feature lookup fails), so nothing else reacts to the pointer.
  static cardHover(dark: boolean): string {
    return dark ? '#3d3d3d' : '#dfe2e7';
  }

  static primary(dark: boolean): string {
    return dark ? '#4d8dff' : '#0a59f7';
  }
}