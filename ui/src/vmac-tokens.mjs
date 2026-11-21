// The VMac palette is DeepSeek's own, read from its stylesheet: a white page,
// a #F9FAFB sidebar, #F1F3F5 fields, near-black text with two quieter steps
// for secondary lines, one blue for action and the current item, and its green
// for a good state. VMac is always light. The web theme (vmac-theme.css) and the native palette
// (desktop/VMacPalette.swift) each hold a copy; tests keep the three in step.
export const tokens = {
  light: {
    page: "#FFFFFF", chrome: "#F9FAFB", fill: "#F1F3F5", navActive: "#EBEEF2", popover: "#FFFFFF",
    ink: "#0F1115", secondary: "#61666B", tertiary: "#81858C", caption: "#ADB2B8",
    accent: "#3964FE", accentFill: "#3964FE", accentFillHover: "#5686FE", accentText: "#3964FE",
    accentSoft: "#E4EDFD", accentFaint: "#EDF3FE", accentBorder: "#B7C8FE", onAccent: "#FFFFFF",
    ok: "#22C55E", okSoft: "#E6FAED", warn: "#F59E0B", warnText: "#DD8629", bad: "#EC1313", badOnDark: "#F25A5A", toast: "#353638",
  },
};

function luminance(hex) {
  const [r, g, b] = [1, 3, 5].map(index => {
    const channel = parseInt(hex.slice(index, index + 2), 16) / 255;
    return channel <= 0.04045 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

// WCAG contrast ratio of two #RRGGBB colors.
export function contrast(a, b) {
  const [light, dark] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (light + 0.05) / (dark + 0.05);
}
