import Markdown

struct ASTProbe: MarkupWalker {
    private(set) var nodeKinds: [MarkdownSpike.ASTNodeKind] = []
    private(set) var standardLinks: [String] = []
    private(set) var standardImages: [String] = []
    private(set) var excludedRanges: [SourceRange] = []
    private(set) var restoredRanges: [SourceRange] = []

    var result: MarkdownSpike.AST {
        .init(
            nodeKinds: nodeKinds,
            standardLinks: standardLinks,
            standardImages: standardImages
        )
    }

    mutating func visitHeading(_ heading: Heading) {
        add(.heading)
        descendInto(heading)
    }

    mutating func visitParagraph(_ paragraph: Paragraph) {
        add(.paragraph)
        descendInto(paragraph)
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        add(.emphasis)
        descendInto(emphasis)
    }

    mutating func visitStrong(_ strong: Strong) {
        add(.strong)
        descendInto(strong)
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
        add(.strikethrough)
        descendInto(strikethrough)
    }

    mutating func visitLink(_ link: Link) {
        add(.link)
        if let destination = link.destination {
            standardLinks.append(destination)
        }
        exclude(link.range)
        restoreTextRanges(in: link)
        descendInto(link)
    }

    mutating func visitImage(_ image: Image) {
        add(.image)
        if let source = image.source {
            standardImages.append(source)
        }
        exclude(image.range)
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        add(.inlineCode)
        exclude(inlineCode.range)
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        add(.codeBlock)
        exclude(codeBlock.range)
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        add(.blockQuote)
        descendInto(blockQuote)
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) {
        add(.orderedList)
        descendInto(orderedList)
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) {
        add(.unorderedList)
        descendInto(unorderedList)
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
        exclude(inlineHTML.range)
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        exclude(html.range)
    }

    private mutating func add(_ kind: MarkdownSpike.ASTNodeKind) {
        guard !nodeKinds.contains(kind) else {
            return
        }
        nodeKinds.append(kind)
    }

    private mutating func exclude(_ range: SourceRange?) {
        if let range {
            excludedRanges.append(range)
        }
    }

    private mutating func restoreTextRanges(in markup: Markup) {
        if markup is Image || markup is InlineCode || markup is InlineHTML {
            return
        }
        if let text = markup as? Text, let range = text.range {
            restoredRanges.append(range)
        }
        for child in markup.children {
            restoreTextRanges(in: child)
        }
    }
}
