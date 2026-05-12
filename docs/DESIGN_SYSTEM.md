# Chronoframe Design System

The **Darkroom** design language — dark-first, dynamic, deeply rooted in native macOS.

## Overview

Chronoframe uses a semantic design token system to ensure consistency across the native macOS UI. All colors, spacing, and layout values are defined centrally, making it easy to maintain a cohesive look and feel as the app evolves.

**Source of Truth:** [`DesignTokens.swift`](../ui/Sources/ChronoframeApp/App/DesignTokens.swift)

---

## Design Philosophy

The **Darkroom** aesthetic is inspired by professional photo and video tools (Final Cut Pro, Adobe Lightroom, Darkroom app):

- **Dark-first:** Optimized for viewing and organizing media on dark backgrounds
- **Dynamic:** Adapts to macOS light/dark appearance without jarring transitions
- **Native:** Uses SF Pro (not SF Rounded) and native macOS materials
- **Minimal:** Hairline separators, vibrancy, restraint

---

## Color System

All colors adapt to light and dark modes automatically via `dynamicColor(light:dark:)`.

### Surfaces

Used for backgrounds and containers:

| Token | Light | Dark | Usage |
|-------|-------|------|-------|
| `canvas` | Warm paper | Graphite | Window/canvas background |
| `panel` | White + opacity | Dark gray | Content panels, lists |
| `elevated` | White + opacity | Darker gray | Focus states, popovers, modals |

### Ink (Text)

For typography and labels:

| Token | Light | Dark | Usage |
|-------|-------|------|-------|
| `inkPrimary` | Dark gray | Light | Headings, metric values, primary text |
| `inkSecondary` | Medium gray | Light gray | Body copy, standard labels |
| `inkMuted` | Light gray | Muted light | Helper text, captions, eyebrow labels |

### Accents

Brand and interactive colors:

| Token | Light | Dark | Purpose |
|-------|-------|------|---------|
| `accentWaypoint` | Orange | Bright orange | Brand color, "moment a memory finds its place" |
| `accentAction` | Indigo | Bright indigo | Primary buttons, progress bars, CTA |

### Status Colors

For feedback and confidence levels:

| Token | Light | Dark | Usage |
|-------|-------|------|-------|
| `statusReady` | Indigo | Bright indigo | Ready to proceed (same as `accentAction`) |
| `statusActive` | Teal | Bright teal | Active, running, in progress |
| `statusSuccess` | Green | Bright green | Successful, high confidence, complete |
| `statusWarning` | Gold | Bright gold | Warning, medium confidence, caution |
| `statusDanger` | Red | Bright red | Error, danger, deleted, low confidence |
| `statusIdle` | Muted | Muted | Idle, disabled, waiting |

### Other

| Token | Usage |
|-------|-------|
| `hairline` | Subtle 0.5pt separators between sections |
| `dividerEmphasis` | Bold divider visible over images (comparison sliders) |
| `shadow` | Deep shadow for modals and popovers |

---

## Using Design Tokens

### In Swift Code

All color tokens are `SwiftUI.Color` values. Use them directly:

```swift
Text("Organized")
    .foregroundStyle(DesignTokens.ColorSystem.statusSuccess)

Rectangle()
    .fill(DesignTokens.ColorSystem.canvas)
```

### For Legacy Code

A backward-compatible `Color` namespace preserves old names:

```swift
// Old way (still works):
Text("Done")
    .foregroundStyle(DesignTokens.Color.success)

// New way (preferred):
Text("Done")
    .foregroundStyle(DesignTokens.ColorSystem.statusSuccess)
```

---

## Layout & Spacing

Consistent spacing throughout the app:

### Spacing Scale

| Token | Value | Typical Use |
|-------|-------|-------------|
| `Spacing.xxs` | 2pt | Micro spacing, icon padding |
| `Spacing.xs` | 4pt | Tight spacing, badge padding |
| `Spacing.sm` | 8pt | Small spacing, list item gaps |
| `Spacing.md` | 12pt | Medium spacing, section gaps |
| `Spacing.lg` | 16pt | Large spacing, card padding |
| `Spacing.xl` | 24pt | Extra large, section separation |
| `Spacing.xxl` | 32pt | Hero spacing, major sections |

### Corner Radius

| Token | Value | Usage |
|--------|-------|-------|
| `Corner.hero` | 20pt | Large cards, hero sections |
| `Corner.card` | 14pt | Standard cards, panels |
| `Corner.innerCard` | 10pt | Buttons, input fields, nested elements |
| `Corner.badge` | 999pt | Capsule badges, pills |

### Window Sizes

| Token | Value | Purpose |
|-------|-------|---------|
| `Window.mainMinWidth` | 900pt | Main window minimum width |
| `Window.mainIdealWidth` | 1180pt | Comfortable viewing width |
| `Window.mainMinHeight` | 700pt | Main window minimum height |
| `Window.settingsMinWidth` | 460pt | Settings window minimum width |

---

## Typography

Chronoframe uses **SF Pro** exclusively (not SF Rounded) for a professional, native macOS look:

- **Headings:** System font, bold, `inkPrimary`
- **Body:** System font, regular, `inkSecondary`
- **Captions:** System font, regular, `inkMuted`

No custom font scaling; rely on standard macOS Dynamic Type.

---

## Adding New Tokens

When you need a new color or value:

1. **Determine if it's semantic.** Is it a status? A surface? An accent? Name it accordingly.

2. **Add it to `ColorSystem` (not `Color`).** New tokens go in the semantic namespace:
   ```swift
   static let myNewColor = dynamicColor(
       light: NSColor(srgbRed: 0.9, green: 0.8, blue: 0.7, alpha: 1),
       dark: NSColor(srgbRed: 0.2, green: 0.1, blue: 0.05, alpha: 1)
   )
   ```

3. **Use it consistently.** Find-replace any hardcoded colors or magic values.

4. **Document the purpose.** Add a comment explaining the token's intended use.

5. **Test in both modes.** Verify the color looks right in light and dark appearance.

---

## Light/Dark Adaptation

All colors are **dynamic** and adapt automatically to macOS light/dark appearance. To test:

1. Open **System Preferences** → **General**
2. Toggle **Appearance** between Light and Dark
3. Chronoframe updates in real-time

**Do not hardcode color values.** Always use semantic tokens.

---

## Accessibility

All color choices have been tested for:
- **Sufficient contrast** against their background surfaces
- **Not relying on color alone** to convey meaning (icons, text, patterns)
- **Colorblind-friendly** palette

When adding new colors, verify contrast ratios meet WCAG AA standards (4.5:1 for text, 3:1 for graphics).

---

## File Structure

**Core design token definitions:**
- [`DesignTokens.swift`](../ui/Sources/ChronoframeApp/App/DesignTokens.swift) — all tokens, `dynamicColor()` helper, view modifiers

**Usage patterns:**
- UI views use `DesignTokens.ColorSystem.*` directly
- Test views use design tokens for consistency
- No hardcoded colors should appear in view code

---

## Examples

### Status Badge

```swift
let color = switch status {
case .success: DesignTokens.ColorSystem.statusSuccess
case .warning: DesignTokens.ColorSystem.statusWarning
case .danger: DesignTokens.ColorSystem.statusDanger
default: DesignTokens.ColorSystem.statusIdle
}

Label(status.label, systemImage: status.icon)
    .foregroundStyle(color)
    .padding(DesignTokens.Spacing.sm)
    .background(color.opacity(0.2))
    .cornerRadius(DesignTokens.Corner.badge)
```

### Card Container

```swift
VStack(spacing: DesignTokens.Spacing.lg) {
    // Content
}
.padding(DesignTokens.Spacing.lg)
.background(DesignTokens.ColorSystem.panel)
.cornerRadius(DesignTokens.Corner.card)
```

### Divider

```swift
Divider()
    .foregroundStyle(DesignTokens.ColorSystem.hairline)
```

---

## Questions?

The best reference is [`DesignTokens.swift`](../ui/Sources/ChronoframeApp/App/DesignTokens.swift) itself. If you need a value, check there first—it's the canonical source.
