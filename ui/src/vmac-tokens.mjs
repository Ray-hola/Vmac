// The VMac palette. The web theme (vmac-theme.css) and the native palette
// (desktop/VMacPalette.swift) each hold a copy; tests keep the three in step.
export const tokens = {
  light: {
    page: "#FFFFFF", chrome: "#F9FAFB", group: "#F1F3F5", popover: "#FFFFFF", line: "rgba(0,0,0,.08)",
    ink: "#0F1115", muted: "#61666B", faint: "#81858C",
    accent: "#3964FE", accentFill: "#3964FE", accentFillHover: "#2F56E8", accentFillActive: "#2648CC",
    accentText: "#2648CC", accentSoft: "#E4EDFD", hover: "rgba(38,49,72,.06)", onAccent: "#FFFFFF",
    okDot: "#22C55E", okText: "#15803D", warnDot: "#F59E0B", warnText: "#B45309", badDot: "#F25A5A", badText: "#B91C1C",
  },
  dark: {
    page: "#151517", chrome: "#1B1B1C", group: "#232324", popover: "#2C2C2E", line: "rgba(255,255,255,.1)",
    ink: "#F5F6F7", muted: "#A8ADB4", faint: "#7A8089",
    accent: "#5686FE", accentFill: "#3964FE", accentFillHover: "#2F56E8", accentFillActive: "#2648CC",
    accentText: "#8FB0FF", accentSoft: "#252E45", hover: "rgba(255,255,255,.06)", onAccent: "#FFFFFF",
    okDot: "#22C55E", okText: "#4ED17E", warnDot: "#F59E0B", warnText: "#F7AD31", badDot: "#F25A5A", badText: "#F87171",
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
