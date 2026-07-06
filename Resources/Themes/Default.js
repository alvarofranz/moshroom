// hterm stock ANSI 16 palette + default foreground/background.
var theme = {
  color: [
    '#000000',
    '#CC0000',
    '#4E9A06',
    '#C4A000',
    '#3465A4',
    '#75507B',
    '#06989A',
    '#D3D7CF',
    '#555753',
    '#EF2929',
    '#00BA13',
    '#FCE94F',
    '#729FCF',
    '#F200CB',
    '#00B5BD',
    '#EEEEEC',
  ],
  foreground: 'rgb(240, 240, 240)',
  background: 'rgb(16, 16, 16)',
};

term_applySexyTheme(theme);

term_set('cursor-color', 'rgba(63, 222, 233, 0.5)');
term_set('cursor-blink', true);
