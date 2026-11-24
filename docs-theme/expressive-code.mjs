// Syntax colors from Supabase Docs' --code-token-* palette (2026-11-24).
const syntaxTheme = (type) => {
  const dark = type === 'dark';
  const foreground = dark ? '#ffffff' : '#454545';
  return {
    name: `supabase-${type}`, type,
    colors: { 'editor.background': dark ? '#191a19' : '#ffffff', 'editor.foreground': foreground },
    tokenColors: [
      { scope: ['comment', 'punctuation.definition.comment'], settings: { foreground: dark ? '#949494' : '#6a6a6a' } },
      { scope: ['keyword', 'storage'], settings: { foreground: dark ? '#bda4ff' : '#5f2fc4' } },
      { scope: ['string'], settings: { foreground: dark ? '#ffcda1' : '#9a5200' } },
      { scope: ['constant', 'entity.name.function', 'support.function', 'support.type', 'entity.name.type', 'variable.other.property'], settings: { foreground: dark ? '#3ecf8e' : '#15593b' } },
      { scope: ['constant.numeric', 'punctuation', 'variable.parameter'], settings: { foreground } },
    ],
  };
};

// Shared Starlight / Expressive Code settings for all documentation sites.
export default {
  themes: [syntaxTheme('dark'), syntaxTheme('light')],
  styleOverrides: {
    codeFontFamily: 'var(--sl-font-mono)',
    codeFontSize: '0.8125rem',
    codeLineHeight: '1.4285714',
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
