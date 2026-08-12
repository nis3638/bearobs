import Foundation

public struct DAVMultiStatus: Equatable, Sendable {
    public let entries: [DAVMultiStatusEntry]

    public init(entries: [DAVMultiStatusEntry]) {
        self.entries = entries
    }
}

public struct DAVMultiStatusEntry: Equatable, Sendable {
    public let href: String
    public let etagHeader: String?
    public let isCollection: Bool

    public init(href: String, etagHeader: String?, isCollection: Bool) {
        self.href = href
        self.etagHeader = etagHeader
        self.isCollection = isCollection
    }
}

/// A namespace-aware, fail-closed parser for WebDAV `multistatus` responses.
public struct DAVMultiStatusParser: Sendable {
    public init() {}

    public func parse(_ data: Data) throws -> DAVMultiStatus {
        guard !data.isEmpty else {
            throw DAVMultiStatusParserError.emptyDocument
        }
        guard data.count <= ParserDelegate.maximumDocumentBytes else {
            throw DAVMultiStatusParserError.documentTooLarge
        }

        let delegate = ParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never

        let parsed = parser.parse()
        if let failure = delegate.failure {
            throw failure
        }
        guard parsed else {
            throw DAVMultiStatusParserError.malformedXML
        }
        return try delegate.finish()
    }
}

public enum DAVMultiStatusParserError: Error, Equatable, Sendable {
    case emptyDocument
    case documentTooLarge
    case malformedXML
    case invalidRoot
    case excessiveNesting
    case tooManyResponses
    case textTooLarge
    case forbiddenDTD
    case invalidStructure
    case missingHref
    case missingPropstat
    case missingStatus
    case malformedStatus
    case failedPropstat(statusCode: Int)
    case failedResponse(statusCode: Int)
    case conflictingProperty
}

private final class ParserDelegate: NSObject, XMLParserDelegate {
    static let maximumDocumentBytes = 4 * 1_024 * 1_024
    private static let maximumDepth = 64
    private static let maximumResponses = 10_000
    private static let maximumCapturedTextCharacters = 256 * 1_024
    private static let davNamespace = "DAV:"

    private struct Element: Equatable {
        let name: String
        let namespaceURI: String?

        var isDAV: Bool {
            namespaceURI == ParserDelegate.davNamespace
        }
    }

    private struct ResponseBuilder {
        var href: String?
        var responseStatusCode: Int?
        var propstatCount = 0
        var etagHeader: String?
        var hasETag = false
        var isCollection = false
        var hasResourceType = false
    }

    private struct PropstatBuilder {
        var statusCode: Int?
        var sawPropertyContainer = false
        var etagHeader: String?
        var hasETag = false
        var isCollection = false
        var hasResourceType = false
    }

    private enum TextTarget {
        case href
        case propstatStatus
        case responseStatus
        case etag
    }

    private var stack: [Element] = []
    private var response: ResponseBuilder?
    private var propstat: PropstatBuilder?
    private var textTarget: TextTarget?
    private var capturedText = ""
    private var sawRoot = false
    private var closedRoot = false
    private var responseCount = 0
    private(set) var entries: [DAVMultiStatusEntry] = []
    private(set) var failure: DAVMultiStatusParserError?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName _: String?,
        attributes _: [String: String] = [:]
    ) {
        guard failure == nil else {
            return
        }
        guard textTarget == nil else {
            fail(.invalidStructure, parser: parser)
            return
        }
        guard stack.count < Self.maximumDepth else {
            fail(.excessiveNesting, parser: parser)
            return
        }

        let element = Element(name: elementName, namespaceURI: namespaceURI)
        let parent = stack.last
        stack.append(element)

        if !sawRoot {
            guard element.isDAV, element.name == "multistatus", parent == nil else {
                fail(.invalidRoot, parser: parser)
                return
            }
            sawRoot = true
            return
        }

        guard !closedRoot else {
            fail(.invalidStructure, parser: parser)
            return
        }
        guard element.isDAV else {
            return
        }

        switch element.name {
        case "response":
            guard parent?.isDAV == true,
                parent?.name == "multistatus",
                response == nil,
                propstat == nil
            else {
                fail(.invalidStructure, parser: parser)
                return
            }
            guard responseCount < Self.maximumResponses else {
                fail(.tooManyResponses, parser: parser)
                return
            }
            responseCount += 1
            response = ResponseBuilder()

        case "href":
            guard parent?.isDAV == true,
                parent?.name == "response",
                response != nil,
                response?.href == nil
            else {
                fail(.invalidStructure, parser: parser)
                return
            }
            beginCapturing(.href)

        case "propstat":
            guard parent?.isDAV == true,
                parent?.name == "response",
                response != nil,
                propstat == nil
            else {
                fail(.invalidStructure, parser: parser)
                return
            }
            propstat = PropstatBuilder()

        case "prop":
            guard parent?.isDAV == true,
                parent?.name == "propstat",
                propstat != nil,
                propstat?.sawPropertyContainer == false
            else {
                fail(.invalidStructure, parser: parser)
                return
            }
            propstat?.sawPropertyContainer = true

        case "status":
            if parent?.isDAV == true, parent?.name == "propstat", propstat != nil {
                guard propstat?.statusCode == nil else {
                    fail(.invalidStructure, parser: parser)
                    return
                }
                beginCapturing(.propstatStatus)
            } else if parent?.isDAV == true, parent?.name == "response", response != nil {
                guard response?.responseStatusCode == nil else {
                    fail(.invalidStructure, parser: parser)
                    return
                }
                beginCapturing(.responseStatus)
            } else {
                fail(.invalidStructure, parser: parser)
            }

        case "getetag":
            guard parent?.isDAV == true,
                parent?.name == "prop",
                propstat != nil,
                propstat?.hasETag == false
            else {
                fail(.invalidStructure, parser: parser)
                return
            }
            propstat?.hasETag = true
            beginCapturing(.etag)

        case "resourcetype":
            guard parent?.isDAV == true,
                parent?.name == "prop",
                propstat != nil,
                propstat?.hasResourceType == false
            else {
                fail(.invalidStructure, parser: parser)
                return
            }
            propstat?.hasResourceType = true

        case "collection":
            guard parent?.isDAV == true,
                parent?.name == "resourcetype",
                propstat != nil
            else {
                fail(.invalidStructure, parser: parser)
                return
            }
            propstat?.isCollection = true

        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName _: String?
    ) {
        guard failure == nil else {
            return
        }

        let element = Element(name: elementName, namespaceURI: namespaceURI)
        guard stack.last == element else {
            fail(.invalidStructure, parser: parser)
            return
        }

        if let target = textTarget {
            do {
                try finishCapturing(target)
            } catch let parserError as DAVMultiStatusParserError {
                fail(parserError, parser: parser)
                return
            } catch {
                fail(.invalidStructure, parser: parser)
                return
            }
        }

        if element.isDAV {
            switch element.name {
            case "propstat":
                finishPropstat(parser: parser)
            case "response":
                finishResponse(parser: parser)
            case "multistatus":
                guard stack.count == 1, response == nil, propstat == nil else {
                    fail(.invalidStructure, parser: parser)
                    return
                }
                closedRoot = true
            default:
                break
            }
        }

        stack.removeLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        appendCapturedText(string, parser: parser)
    }

    func parser(_ parser: XMLParser, foundCDATA cdataBlock: Data) {
        guard let value = String(data: cdataBlock, encoding: .utf8) else {
            fail(.malformedXML, parser: parser)
            return
        }
        appendCapturedText(value, parser: parser)
    }

    func parser(
        _ parser: XMLParser,
        foundInternalEntityDeclarationWithName _: String,
        value _: String?
    ) {
        fail(.forbiddenDTD, parser: parser)
    }

    func parser(
        _ parser: XMLParser,
        foundExternalEntityDeclarationWithName _: String,
        publicID _: String?,
        systemID _: String?
    ) {
        fail(.forbiddenDTD, parser: parser)
    }

    func parser(
        _ parser: XMLParser,
        foundUnparsedEntityDeclarationWithName _: String,
        publicID _: String?,
        systemID _: String?,
        notationName _: String?
    ) {
        fail(.forbiddenDTD, parser: parser)
    }

    func parser(
        _ parser: XMLParser,
        foundNotationDeclarationWithName _: String,
        publicID _: String?,
        systemID _: String?
    ) {
        fail(.forbiddenDTD, parser: parser)
    }

    func parser(
        _ parser: XMLParser,
        resolveExternalEntityName _: String,
        systemID _: String?
    ) -> Data? {
        fail(.forbiddenDTD, parser: parser)
        return nil
    }

    func finish() throws -> DAVMultiStatus {
        if let failure {
            throw failure
        }
        guard sawRoot, closedRoot, stack.isEmpty, response == nil, propstat == nil else {
            throw DAVMultiStatusParserError.invalidStructure
        }
        return DAVMultiStatus(entries: entries)
    }

    private func beginCapturing(_ target: TextTarget) {
        textTarget = target
        capturedText = ""
    }

    private func appendCapturedText(_ value: String, parser: XMLParser) {
        guard textTarget != nil, failure == nil else {
            return
        }
        guard capturedText.count + value.count <= Self.maximumCapturedTextCharacters else {
            fail(.textTooLarge, parser: parser)
            return
        }
        capturedText.append(value)
    }

    private func finishCapturing(_ target: TextTarget) throws {
        let value = capturedText.trimmingCharacters(in: .whitespacesAndNewlines)
        textTarget = nil
        capturedText = ""

        switch target {
        case .href:
            guard !value.isEmpty else {
                throw DAVMultiStatusParserError.missingHref
            }
            response?.href = value

        case .propstatStatus:
            propstat?.statusCode = try Self.parseStatusCode(value)

        case .responseStatus:
            response?.responseStatusCode = try Self.parseStatusCode(value)

        case .etag:
            propstat?.etagHeader = value
        }
    }

    private func finishPropstat(parser: XMLParser) {
        guard let completed = propstat else {
            fail(.invalidStructure, parser: parser)
            return
        }
        guard completed.sawPropertyContainer else {
            fail(.invalidStructure, parser: parser)
            return
        }
        guard let statusCode = completed.statusCode else {
            fail(.missingStatus, parser: parser)
            return
        }
        guard (200..<300).contains(statusCode) else {
            fail(.failedPropstat(statusCode: statusCode), parser: parser)
            return
        }
        guard response != nil else {
            fail(.invalidStructure, parser: parser)
            return
        }

        if completed.hasETag {
            guard response?.hasETag == false else {
                fail(.conflictingProperty, parser: parser)
                return
            }
            response?.hasETag = true
            response?.etagHeader = completed.etagHeader
        }
        if completed.hasResourceType {
            guard response?.hasResourceType == false else {
                fail(.conflictingProperty, parser: parser)
                return
            }
            response?.hasResourceType = true
            response?.isCollection = completed.isCollection
        }

        response?.propstatCount += 1
        propstat = nil
    }

    private func finishResponse(parser: XMLParser) {
        guard propstat == nil, let completed = response else {
            fail(.invalidStructure, parser: parser)
            return
        }
        guard let href = completed.href else {
            fail(.missingHref, parser: parser)
            return
        }
        if let statusCode = completed.responseStatusCode {
            guard completed.propstatCount == 0 else {
                fail(.invalidStructure, parser: parser)
                return
            }
            guard (200..<300).contains(statusCode) else {
                fail(.failedResponse(statusCode: statusCode), parser: parser)
                return
            }
        }
        guard completed.responseStatusCode == nil, completed.propstatCount > 0 else {
            fail(.missingPropstat, parser: parser)
            return
        }

        entries.append(
            DAVMultiStatusEntry(
                href: href,
                etagHeader: completed.etagHeader,
                isCollection: completed.isCollection
            )
        )
        response = nil
    }

    private func fail(_ error: DAVMultiStatusParserError, parser: XMLParser) {
        guard failure == nil else {
            return
        }
        failure = error
        parser.abortParsing()
    }

    private static func parseStatusCode(_ statusLine: String) throws -> Int {
        let fields = statusLine.split(whereSeparator: { $0.isWhitespace })
        guard fields.count >= 2,
            fields[0].hasPrefix("HTTP/"),
            fields[1].count == 3,
            fields[1].allSatisfy({ $0.isASCII && $0.isNumber }),
            let statusCode = Int(fields[1]),
            (100..<600).contains(statusCode)
        else {
            throw DAVMultiStatusParserError.malformedStatus
        }
        return statusCode
    }
}
