// Shared Starlight / Expressive Code settings for all documentation sites.
export default {
  themes: ['github-dark', 'github-light'],
  styleOverrides: {
    codeFontFamily: 'var(--sl-font-mono)',
    codeFontSize: '0.875rem',
    codeLineHeight: '1.7',
    codePaddingBlock: '1.1rem',
    codePaddingInline: '1.25rem',
    borderRadius: '0.5rem',
    borderColor: 'var(--sl-color-hairline)',
    codeBackground: 'var(--docs-code-bg)',
    frames: {
      frameBoxShadowCssValue: 'none',
      editorTabBarBackground: 'var(--docs-code-header-bg)',
      editorActiveTabBackground: 'var(--docs-code-bg)',
      editorActiveTabIndicatorTopColor: 'var(--sl-color-accent)',
      terminalBackground: 'var(--docs-code-bg)',
      terminalTitlebarBackground: 'var(--docs-code-header-bg)',
      terminalTitlebarBorderBottomColor: 'var(--sl-color-hairline)',
    },
  },
};
