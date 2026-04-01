# Resource Mapping — Advanced Matching Logic

SwiftPrism performs multi-strategy resource analysis combining AST-based detection, static property alias tracking, protocol conformance analysis, and heuristic string matching.

## Strategy 1: Direct API Detection (High Confidence)

The `ResourceRefCollector` walks SwiftSyntax AST nodes to extract string literals from known resource-loading APIs.

### Matched Patterns

```swift
Image("logo")                           // Direct init
UIImage(named: "logo")                  // Named init
NSImage(named: "logo")                  // macOS variant
Color("primary")                        // SwiftUI color
UIColor(named: "primary")               // UIKit color
Bundle.main.url(forResource: "config")  // Bundle access
Bundle.main.path(forResource: "data")   // Bundle path
```

All direct API matches produce `resource_link` with `confidence: "high"`.

## Strategy 2: Custom Function Tracking (Medium Confidence)

The collector recognizes common design-system wrapper method names, even inside custom types:

```swift
MyDesignSystem.getColor("primary")      // .getColor recognized
ThemeManager.loadImage("icon_home")     // .loadImage recognized  
styleKit.color("accent")               // .color recognized
AppAssets.namedImage("banner")          // .namedImage recognized
```

### Recognized Wrapper Methods

`getColor`, `getImage`, `color`, `image`, `asset`, `resource`, `loadImage`, `loadColor`, `namedColor`, `namedImage`

Any `receiver.method("stringLiteral")` where `method` matches this list produces `resource_link` with `confidence: "medium"`.

## Strategy 3: Extension Static Property Analysis (High Confidence)

The `StaticResourcePropertyCollector` analyzes extension blocks and type declarations for static properties that return Image/Color instances initialized with string literals.

### Matched Patterns

```swift
extension Color {
    static let primary = Color("primary")         // Stored static
    static var accent: Color { Color("accent") }  // Computed static
}

extension UIImage {
    static let logo = UIImage(named: "logo")!
    static var banner: UIImage { UIImage(named: "banner")! }
}
```

Each static property creates a `resource_alias` link with `confidence: "high"` connecting the property symbol (e.g., `Color.primary`) to the physical asset (e.g., `asset:Assets/primary`).

### What is Tracked

- Stored static properties with initializer expressions
- Computed static properties with getter bodies containing a `return` statement
- Both `static let` and `static var`
- Handles both direct init (`Color("name")`) and named init (`UIImage(named: "name")`)

## Strategy 4: Protocol-based Asset Conformance (High Confidence)

When a struct or class conforms to a recognized "resource provider" protocol, all of its members are deeply scanned for resource references with elevated confidence.

### Recognized Protocols

`ResourceProvider`, `AssetProvider`, `ImageProvider`, `ColorProvider`, `ThemeProvider`, `DesignTokenProvider`

### Example

```swift
struct AppTheme: ThemeProvider {
    func backgroundColor() -> Color {
        Color("background")              // Detected as high-confidence resource_link
    }
    
    func accentImage() -> Image {
        Image("chevron")                  // Detected as high-confidence resource_link
    }
}
```

All members of conforming types produce `resource_link` with `confidence: "high"`, even if the function calling pattern would normally yield a lower confidence.

## Strategy 5: Heuristic String Matching (High Confidence)

The most aggressive strategy. Any string literal in any function call is checked against the known resource name index. If an exact 100% match is found, a link is created.

### How It Works

1. The `ResourceScanner` discovers all physical assets and builds a `Set<String>` of resource names
2. The `ResourceRefCollector` receives this set via `knownResourceNames`
3. For every `FunctionCallExprSyntax` not already captured by Strategies 1-2, all string arguments are checked against the set
4. Matches produce `heuristic_link` with `confidence: "high"`

### Example

```swift
func loadTheme() {
    let config = CustomLoader.fetch("theme_dark")   // If "theme_dark" matches a resource name → heuristic_link
    analytics.track("primary")                       // If "primary" matches a color set → heuristic_link
}
```

### Standalone String Literals

String literals that appear outside function calls but inside function bodies are also checked:

```swift
let assetName = "logo"    // If "logo" matches a resource → heuristic_link
```

These are only emitted when the literal is not already inside a known resource call (to avoid double-counting).

## Confidence Levels

| Level | When Applied | Visual |
|---|---|---|
| `high` | Direct API calls, extension static properties, protocol conformers, 100% heuristic name match | Green badge |
| `medium` | Custom wrapper methods (`.getColor`, `.loadImage`, etc.) | Orange badge |
| `low` | Reserved for future fuzzy matching | Red badge |

## Link Types

| Type | Meaning | Dash Pattern |
|---|---|---|
| `resource_link` | Direct code → asset reference | `[6, 3]` |
| `resource_alias` | Static property → asset mapping | `[3, 3]` |
| `heuristic_link` | String literal match → asset | `[2, 4]` |

## UI Representation

### Guide Tab Sections

| Section | Badge | Content |
|---|---|---|
| Types | Purple `S` | All struct/class/enum/actor/protocol declarations |
| Resources | Blue `R` | All discovered assets and files |
| Resource Usage | Blue `R` | Direct `resource_link` connections with confidence |
| Static Resource Aliases | Indigo `A` | Extension static properties mapped to assets |
| Heuristic Matches | Orange `H` | String literal matches with confidence badges |
| Documentation | Blue `R` | Detected `.md` files |

### Confidence Badges

Each resource connection in the Guide shows a colored confidence badge:
- **High** — Green — Direct API, static alias, protocol member, or exact heuristic match
- **Medium** — Orange — Custom wrapper function match
- **Low** — Red — Future fuzzy/partial matches

### Interactive Highlighting

Hovering any item in the Guide highlights all related node IDs in the 3D graph. For resource connections, both the source symbol and target resource are highlighted simultaneously.

## Edge Cases

| Scenario | Behavior |
|---|---|
| `MyDesignSystem.getColor("primary")` | `resource_link` medium confidence via wrapper method detection |
| `extension Color { static let primary = Color("primary") }` | `resource_alias` high confidence from static property collector |
| `struct AppTheme: ThemeProvider { ... }` | All members scanned at high confidence via protocol conformance |
| String `"logo"` matching asset name inside unknown function | `heuristic_link` high confidence |
| Same resource matched by multiple strategies | Deduplicated — first match wins (by link type key) |
| `#imageLiteral` / `#colorLiteral` | Not matched — compiler magic, not string-based |
| String interpolation `"\(prefix)_icon"` | Not matched — only plain literals |
