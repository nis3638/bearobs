# Inline tag fixture

Visible tags are #AI, #project/mobile, and #研发/ios.

Inline code is excluded: `#ignored-inline [[IgnoredInlineLink]]`.

URL fragments are excluded: https://fixture.invalid/page#ignored-url

HTML attributes are excluded: <span data-topic="#ignored-html">synthetic span</span>

```swift
let tag = "#ignored-fence"
let link = "[[IgnoredFenceLink]]"
```
