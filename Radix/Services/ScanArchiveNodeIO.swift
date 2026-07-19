//
//  ScanArchiveNodeIO.swift
//  Radix
//

import CryptoKit
import Foundation

private nonisolated enum ScanArchiveNodeIOConstants {
    static let readChunkSize = 1024 * 1024
    static let maxNodeLineByteCount = 1024 * 1024
    static let maximumInitialRecordCapacity = 65_536
    static let maximumConcurrentDecodes = 8
    static let newlineData = Data([0x0A])
}

nonisolated struct ScanArchiveNodePayload: Sendable {
    let nodesByID: [String: FileNodeRecord]
    let orderedNodeIDs: [String]
}

nonisolated enum ScanArchiveEncodedNodePayload: Sendable {
    case legacy(ScanArchiveNodePayload)
    case compact([ScanArchiveCompactNode])
}

nonisolated private struct ScanArchiveNodeLocation {
    let id: String
    let path: String
}

nonisolated private struct ScanArchiveCompactTopology {
    let rootOrdinal: Int
    let parentRawIndices: [UInt32]
    let childSpans: [FileTreeChildSpan]
    let childIndices: [FileTreeNodeIndex]
    let orderedNodeIndices: [FileTreeNodeIndex]
    let parentsPrecedeChildren: Bool
}

nonisolated private struct ScanArchiveStreamingJSONWriter {
    private static let flushByteCount = 1024 * 1024

    let fileHandle: FileHandle
    private var buffer = Data()

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
        buffer.reserveCapacity(Self.flushByteCount)
    }

    mutating func append(_ text: String) throws {
        buffer.append(contentsOf: text.utf8)
        if buffer.count >= Self.flushByteCount {
            try flush()
        }
    }

    mutating func append(_ data: Data) throws {
        buffer.append(data)
        if buffer.count >= Self.flushByteCount {
            try flush()
        }
    }

    mutating func finish() throws {
        try flush()
    }

    private mutating func flush() throws {
        guard !buffer.isEmpty else { return }
        try fileHandle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }
}

extension ScanArchiveService {
    func writeNodes(
        _ treeStore: FileTreeStore,
        to url: URL,
        progressReporter: ScanArchiveProgressReporter?
    ) async throws -> String {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ScanArchiveError.nodes(localized: "could not create nodes section")
        }

        let fileHandle = try FileHandle(forWritingTo: url)
        defer { try? fileHandle.close() }

        var hasher = SHA256()
        let encoder = Self.makeJSONLineEncoder()
        let totalNodeCount = treeStore.nodeCount
        var processedNodeCount = 0
        let orderedNodeIndices = treeStore.indexedNodeIndices()
        var writer = ScanArchiveStreamingJSONWriter(fileHandle: fileHandle)

        for nodeIndex in orderedNodeIndices {
            try Task.checkCancellation()
            guard let node = treeStore.node(at: nodeIndex) else {
                throw ScanArchiveError.nodes(localized: "node index disappeared while exporting")
            }
            let parent = treeStore.parentIndex(of: nodeIndex).flatMap { treeStore.node(at: $0) }
            var lineData = try encoder.encode(
                ScanArchiveCompactNode(
                    node,
                    parent: parent
                )
            )
            lineData.append(ScanArchiveNodeIOConstants.newlineData)
            hasher.update(data: lineData)
            try writer.append(lineData)
            processedNodeCount += 1

            if ScanArchiveProgressReporting.shouldReportProgress(processedNodeCount) || processedNodeCount == totalNodeCount {
                progressReporter?.report(ScanArchiveProgress(
                    phase: .writingNodes,
                    completedUnitCount: processedNodeCount,
                    totalUnitCount: totalNodeCount,
                    message: "Writing node records"
                ))
                await Task.yield()
            }
        }
        try writer.finish()

        return Data(hasher.finalize()).base64EncodedString()
    }

    /// Writes topology incrementally. Building and encoding the complete
    /// topology at once can consume hundreds of megabytes on a large scan.
    func writeTopology(
        _ treeStore: FileTreeStore,
        to url: URL,
        progressReporter: ScanArchiveProgressReporter?
    ) async throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ScanArchiveError.topology(localized: "could not create topology section")
        }

        let fileHandle = try FileHandle(forWritingTo: url)
        defer { try? fileHandle.close() }

        let orderedNodeIndices = treeStore.indexedNodeIndices()
        var ordinalByNodeOffset = Array(repeating: -1, count: treeStore.nodeCount)
        for (ordinal, nodeIndex) in orderedNodeIndices.enumerated() {
            let offset = Int(nodeIndex.rawValue)
            guard ordinalByNodeOffset.indices.contains(offset) else {
                throw ScanArchiveError.topology(localized: "node index is out of range")
            }
            ordinalByNodeOffset[offset] = ordinal
        }

        guard let rootIndex = treeStore.nodeIndex(id: treeStore.rootID) else {
            throw ScanArchiveError.topology(localized: "root node is missing from node order")
        }
        let rootOffset = Int(rootIndex.rawValue)
        guard ordinalByNodeOffset.indices.contains(rootOffset),
              ordinalByNodeOffset[rootOffset] >= 0 else {
            throw ScanArchiveError.topology(localized: "root node is missing from node order")
        }

        var writer = ScanArchiveStreamingJSONWriter(fileHandle: fileHandle)
        try writer.append("{\"r\":\(ordinalByNodeOffset[rootOffset]),\"c\":{")
        var wroteParent = false

        for (processedOffset, parentIndex) in orderedNodeIndices.enumerated() {
            try Task.checkCancellation()
            let childIndices = treeStore.childIndices(of: parentIndex)
            if !childIndices.isEmpty {
                let parentOffset = Int(parentIndex.rawValue)
                guard ordinalByNodeOffset.indices.contains(parentOffset),
                      ordinalByNodeOffset[parentOffset] >= 0 else {
                    throw ScanArchiveError.topology(localized: "parent node is missing from node order")
                }

                if wroteParent {
                    try writer.append(",")
                }
                wroteParent = true
                try writer.append("\"\(ordinalByNodeOffset[parentOffset])\":[")

                for (childOffset, childIndex) in childIndices.enumerated() {
                    let nodeOffset = Int(childIndex.rawValue)
                    guard ordinalByNodeOffset.indices.contains(nodeOffset),
                          ordinalByNodeOffset[nodeOffset] >= 0 else {
                        throw ScanArchiveError.topology(localized: "child node is missing from node order")
                    }
                    if childOffset > 0 {
                        try writer.append(",")
                    }
                    try writer.append(String(ordinalByNodeOffset[nodeOffset]))
                }
                try writer.append("]")
            }

            let completedCount = processedOffset + 1
            if ScanArchiveProgressReporting.shouldReportProgress(completedCount) ||
                completedCount == orderedNodeIndices.count {
                progressReporter?.report(ScanArchiveProgress(
                    phase: .writingTopology,
                    completedUnitCount: completedCount,
                    totalUnitCount: orderedNodeIndices.count,
                    message: "Writing topology"
                ))
                await Task.yield()
            }
        }

        try writer.append("}}")
        try writer.finish()
    }

    func readNodes(
        from url: URL,
        expectedChecksum: String,
        expectedNodeCount: Int,
        formatVersion: Int,
        progressReporter: ScanArchiveProgressReporter?
    ) async throws -> ScanArchiveEncodedNodePayload {
        if formatVersion == 3 {
            let records: [ScanArchiveNode] = try await readNodeRecords(
                from: url,
                expectedChecksum: expectedChecksum,
                expectedNodeCount: expectedNodeCount,
                progressReporter: progressReporter
            )
            var nodesByID: [String: FileNodeRecord] = [:]
            var orderedNodeIDs: [String] = []
            orderedNodeIDs.reserveCapacity(records.count)
            for record in records {
                let node = try record.modelNode()
                guard nodesByID[node.id] == nil else {
                    throw ScanArchiveError.nodes(localized: "duplicate node ID \(node.id)")
                }
                nodesByID[node.id] = node
                orderedNodeIDs.append(node.id)
            }
            return .legacy(ScanArchiveNodePayload(
                nodesByID: nodesByID,
                orderedNodeIDs: orderedNodeIDs
            ))
        }

        let records: [ScanArchiveCompactNode] = try await readNodeRecords(
            from: url,
            expectedChecksum: expectedChecksum,
            expectedNodeCount: expectedNodeCount,
            progressReporter: progressReporter
        )
        return .compact(records)
    }

    private func prepareCompactTopology(
        _ topology: ScanArchiveTopology,
        expectedNodeCount: Int
    ) throws -> ScanArchiveCompactTopology {
        guard expectedNodeCount > 0,
              expectedNodeCount <= Int(UInt32.max) else {
            throw ScanArchiveError.nodes(localized:
                "manifest expected \(expectedNodeCount) nodes, exceeding the supported node count"
            )
        }
        guard (0..<expectedNodeCount).contains(topology.rootOrdinal) else {
            throw ScanArchiveError.topology(localized: "root ordinal \(topology.rootOrdinal) is out of range")
        }

        var edgeCount = 0
        for (parentKey, childOrdinals) in topology.childOrdinalsByOrdinal {
            try Task.checkCancellation()
            guard let parentOrdinal = Int(parentKey),
                  String(parentOrdinal) == parentKey,
                  (0..<expectedNodeCount).contains(parentOrdinal) else {
                throw ScanArchiveError.topology(localized: "parent ordinal \(parentKey) is invalid")
            }
            for childOrdinal in childOrdinals {
                guard (0..<expectedNodeCount).contains(childOrdinal) else {
                    throw ScanArchiveError.topology(localized: "child ordinal \(childOrdinal) is out of range")
                }
                let (updatedEdgeCount, overflow) = edgeCount.addingReportingOverflow(1)
                guard !overflow, updatedEdgeCount < expectedNodeCount else {
                    throw ScanArchiveError.topology(localized: "topology contains too many child references")
                }
                edgeCount = updatedEdgeCount
            }
        }
        guard edgeCount == expectedNodeCount - 1 else {
            try diagnoseMalformedCompactTopology(
                topology,
                rootOrdinal: topology.rootOrdinal,
                edgeCount: edgeCount
            )
            throw ScanArchiveError.topology(localized:
                "\(expectedNodeCount - edgeCount - 1) node(s) are not reachable from root"
            )
        }

        let noParent = UInt32.max
        var parentRawIndices = Array(repeating: noParent, count: expectedNodeCount)
        var childSpans = Array(repeating: FileTreeChildSpan(), count: expectedNodeCount)
        var childIndices: [FileTreeNodeIndex] = []
        childIndices.reserveCapacity(edgeCount)
        var parentsPrecedeChildren = true

        for (parentKey, childOrdinals) in topology.childOrdinalsByOrdinal {
            let parentOrdinal = Int(parentKey)!
            let childStart = childIndices.count
            for childOrdinal in childOrdinals {
                if childOrdinal == parentOrdinal {
                    let subject = childOrdinal == topology.rootOrdinal ? "root node" : "node ordinal \(childOrdinal)"
                    throw ScanArchiveError.topology(localized: "\(subject) references itself as a child")
                }
                let previousParent = parentRawIndices[childOrdinal]
                guard previousParent == noParent else {
                    let detail = previousParent == UInt32(parentOrdinal) ? "is duplicated" : "has multiple parents"
                    throw ScanArchiveError.topology(localized: "child ordinal \(childOrdinal) \(detail)")
                }
                parentRawIndices[childOrdinal] = UInt32(parentOrdinal)
                childIndices.append(FileTreeNodeIndex(rawValue: UInt32(childOrdinal)))
                parentsPrecedeChildren = parentsPrecedeChildren && parentOrdinal < childOrdinal
            }
            childSpans[parentOrdinal] = FileTreeChildSpan(
                start: UInt32(childStart),
                count: UInt32(childIndices.count - childStart)
            )
        }

        if parentRawIndices[topology.rootOrdinal] != noParent {
            if parentRawIndices[topology.rootOrdinal] == UInt32(topology.rootOrdinal) {
                throw ScanArchiveError.topology(localized: "root node references itself as a child")
            }
            throw ScanArchiveError.topology(localized: "root node is referenced as a child")
        }
        for ordinal in 0..<expectedNodeCount where ordinal != topology.rootOrdinal {
            guard parentRawIndices[ordinal] != noParent else {
                throw ScanArchiveError.topology(localized: "node ordinal \(ordinal) is not reachable")
            }
        }

        let rootIndex = FileTreeNodeIndex(rawValue: UInt32(topology.rootOrdinal))
        var visited = Array(repeating: false, count: expectedNodeCount)
        var orderedNodeIndices: [FileTreeNodeIndex] = []
        orderedNodeIndices.reserveCapacity(expectedNodeCount)
        var stack = [rootIndex]
        while let nodeIndex = stack.popLast() {
            if orderedNodeIndices.count.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            let offset = Int(nodeIndex.rawValue)
            guard !visited[offset] else {
                throw ScanArchiveError.topology(localized: "cycle detected at node ordinal \(offset)")
            }
            visited[offset] = true
            orderedNodeIndices.append(nodeIndex)
            let span = childSpans[offset]
            let start = Int(span.start)
            let end = start + Int(span.count)
            stack.append(contentsOf: childIndices[start..<end].reversed())
        }
        guard orderedNodeIndices.count == expectedNodeCount else {
            throw ScanArchiveError.topology(localized:
                "\(expectedNodeCount - orderedNodeIndices.count) node(s) are not reachable from root"
            )
        }

        return ScanArchiveCompactTopology(
            rootOrdinal: topology.rootOrdinal,
            parentRawIndices: parentRawIndices,
            childSpans: childSpans,
            childIndices: childIndices,
            orderedNodeIndices: orderedNodeIndices,
            parentsPrecedeChildren: parentsPrecedeChildren
        )
    }

    private func diagnoseMalformedCompactTopology(
        _ topology: ScanArchiveTopology,
        rootOrdinal: Int,
        edgeCount: Int
    ) throws {
        var parentByChild: [Int: Int] = [:]
        parentByChild.reserveCapacity(min(edgeCount, ScanArchiveNodeIOConstants.maximumInitialRecordCapacity))
        for (parentKey, childOrdinals) in topology.childOrdinalsByOrdinal {
            let parentOrdinal = Int(parentKey)!
            for childOrdinal in childOrdinals {
                if childOrdinal == parentOrdinal {
                    let subject = childOrdinal == rootOrdinal ? "root node" : "node ordinal \(childOrdinal)"
                    throw ScanArchiveError.topology(localized: "\(subject) references itself as a child")
                }
                if let existingParent = parentByChild.updateValue(parentOrdinal, forKey: childOrdinal) {
                    let detail = existingParent == parentOrdinal ? "is duplicated" : "has multiple parents"
                    throw ScanArchiveError.topology(localized: "child ordinal \(childOrdinal) \(detail)")
                }
            }
        }
        if parentByChild[rootOrdinal] != nil {
            throw ScanArchiveError.topology(localized: "root node is referenced as a child")
        }
    }

    private func compactNodeLocation(
        _ record: ScanArchiveCompactNode,
        ordinal: Int,
        rootOrdinal: Int,
        expectedRootID: String,
        parent: ScanArchiveNodeLocation?
    ) throws -> ScanArchiveNodeLocation {
        if ordinal == rootOrdinal {
            let id = record.explicitID ?? expectedRootID
            guard id == expectedRootID else {
                throw ScanArchiveError.topology(localized: "root ID does not match manifest")
            }
            return ScanArchiveNodeLocation(id: id, path: record.explicitPath ?? id)
        }
        guard let parent else {
            throw ScanArchiveError.topology(localized: "node ordinal \(ordinal) has an unresolved parent")
        }
        if let explicitID = record.explicitID {
            return ScanArchiveNodeLocation(id: explicitID, path: record.explicitPath ?? explicitID)
        }
        guard let component = record.relativePath,
              !component.isEmpty,
              component != ".",
              component != "..",
              !component.contains("\0"),
              !component.contains("/") else {
            throw ScanArchiveError.nodes(localized:
                "node ordinal \(ordinal) has an invalid relative path"
            )
        }
        let separator = parent.path == "/" || parent.path.hasSuffix("/") ? "" : "/"
        let path = parent.path + separator + component
        return ScanArchiveNodeLocation(id: path, path: record.explicitPath ?? path)
    }

    private func modelCompactNode(
        _ record: ScanArchiveCompactNode,
        location: ScanArchiveNodeLocation,
        ordinal: Int,
        rootOrdinal: Int,
        expectedTargetPath: String
    ) throws -> FileNodeRecord {
        let hasValidatedRelativeLocation = ordinal != rootOrdinal &&
            record.explicitID == nil &&
            record.explicitPath == nil &&
            record.relativePath != nil
        let node = try record.payload.modelNode(
            resolvedID: location.id,
            resolvedPath: location.path,
            resolvedName: record.payload.name.isEmpty ? record.relativePath : nil,
            locationAlreadyValidated: hasValidatedRelativeLocation
        )
        if ordinal == rootOrdinal, node.url.path != expectedTargetPath {
            throw ScanArchiveError.topology(localized: "root path does not match target path")
        }
        if !node.isSynthetic,
           !Self.path(node.id, isContainedIn: expectedTargetPath) {
            throw ScanArchiveError.topology(localized: "node \(node.id) path is outside target")
        }
        return node
    }

    func materializeCompactTreeStore(
        _ records: [ScanArchiveCompactNode],
        topology: ScanArchiveTopology,
        expectedRootID: String,
        expectedTargetPath: String,
        progressReporter: ScanArchiveProgressReporter?
    ) async throws -> FileTreeStore {
        let compactTopology = try prepareCompactTopology(
            topology,
            expectedNodeCount: records.count
        )
        return try await materializeCompactTreeStore(
            records,
            topology: compactTopology,
            expectedRootID: expectedRootID,
            expectedTargetPath: expectedTargetPath,
            progressReporter: progressReporter
        )
    }

    private func materializeCompactTreeStore(
        _ records: [ScanArchiveCompactNode],
        topology: ScanArchiveCompactTopology,
        expectedRootID: String,
        expectedTargetPath: String,
        progressReporter: ScanArchiveProgressReporter?
    ) async throws -> FileTreeStore {
        let noParent = UInt32.max

        var locations = Array<ScanArchiveNodeLocation?>(repeating: nil, count: records.count)

        func makeLocation(at ordinal: Int, parent: ScanArchiveNodeLocation?) throws -> ScanArchiveNodeLocation {
            let record = records[ordinal]
            return try compactNodeLocation(
                record,
                ordinal: ordinal,
                rootOrdinal: topology.rootOrdinal,
                expectedRootID: expectedRootID,
                parent: parent
            )
        }

        func resolveLocation(at ordinal: Int) throws -> ScanArchiveNodeLocation {
            if let location = locations[ordinal] {
                return location
            }
            if ordinal == topology.rootOrdinal {
                let location = try makeLocation(at: ordinal, parent: nil)
                locations[ordinal] = location
                return location
            }
            let directParentOrdinal = Int(topology.parentRawIndices[ordinal])
            if let parent = locations[directParentOrdinal] {
                let location = try makeLocation(at: ordinal, parent: parent)
                locations[ordinal] = location
                return location
            }

            var chain: [Int] = []
            var chainOrdinals = Set<Int>()
            var cursor = ordinal
            while locations[cursor] == nil {
                guard chainOrdinals.insert(cursor).inserted else {
                    throw ScanArchiveError.topology(localized: "cycle detected at node ordinal \(cursor)")
                }
                chain.append(cursor)
                guard cursor != topology.rootOrdinal else { break }
                let parentOrdinal = topology.parentRawIndices[cursor]
                guard parentOrdinal != noParent else {
                    throw ScanArchiveError.topology(localized: "node ordinal \(cursor) has an invalid parent")
                }
                cursor = Int(parentOrdinal)
            }

            while let pendingOrdinal = chain.popLast() {
                let parent = pendingOrdinal == topology.rootOrdinal
                    ? nil
                    : locations[Int(topology.parentRawIndices[pendingOrdinal])]
                let location = try makeLocation(at: pendingOrdinal, parent: parent)
                locations[pendingOrdinal] = location
            }

            guard let location = locations[ordinal] else {
                throw ScanArchiveError.topology(localized: "node ordinal \(ordinal) could not be resolved")
            }
            return location
        }

        var nodes: [FileNodeRecord] = []
        nodes.reserveCapacity(records.count)
        var indexByNodeID: [String: FileTreeNodeIndex] = [:]
        indexByNodeID.reserveCapacity(records.count)
        for ordinal in records.indices {
            if ordinal.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            let location = try resolveLocation(at: ordinal)
            let node = try modelCompactNode(
                records[ordinal],
                location: location,
                ordinal: ordinal,
                rootOrdinal: topology.rootOrdinal,
                expectedTargetPath: expectedTargetPath
            )
            if topology.childSpans[ordinal].count > 0, !node.isDirectory {
                throw ScanArchiveError.topology(localized: "non-directory node ordinal \(ordinal) has children")
            }
            let nodeIndex = FileTreeNodeIndex(rawValue: UInt32(ordinal))
            guard indexByNodeID.updateValue(nodeIndex, forKey: node.id) == nil else {
                throw ScanArchiveError.nodes(localized: "duplicate node ID \(node.id)")
            }
            nodes.append(node)

            let completedCount = ordinal + 1
            if ScanArchiveProgressReporting.shouldReportProgress(completedCount) || completedCount == records.count {
                progressReporter?.report(ScanArchiveProgress(
                    phase: .validatingTopology,
                    completedUnitCount: completedCount,
                    totalUnitCount: records.count,
                    message: "Validating topology"
                ))
                await Task.yield()
            }
        }

        let rootIndex = FileTreeNodeIndex(rawValue: UInt32(topology.rootOrdinal))
        return FileTreeStore(
            verifiedRootIndex: rootIndex,
            nodes: &nodes,
            indexByNodeID: indexByNodeID,
            parentRawIndices: topology.parentRawIndices,
            childSpans: topology.childSpans,
            childIndices: topology.childIndices,
            orderedNodeIndices: topology.orderedNodeIndices
        )
    }

    func readCompactTreeStore(
        from url: URL,
        expectedChecksum: String,
        expectedNodeCount: Int,
        topology archivedTopology: ScanArchiveTopology,
        expectedRootID: String,
        expectedTargetPath: String,
        progressReporter: ScanArchiveProgressReporter?
    ) async throws -> FileTreeStore {
        let topology = try prepareCompactTopology(
            archivedTopology,
            expectedNodeCount: expectedNodeCount
        )
        guard topology.parentsPrecedeChildren else {
            let records: [ScanArchiveCompactNode] = try await readNodeRecords(
                from: url,
                expectedChecksum: expectedChecksum,
                expectedNodeCount: expectedNodeCount,
                progressReporter: progressReporter
            )
            guard records.count == expectedNodeCount else {
                throw ScanArchiveError.nodes(localized:
                    "manifest expected \(expectedNodeCount) nodes, found \(records.count)"
                )
            }
            return try await materializeCompactTreeStore(
                records,
                topology: topology,
                expectedRootID: expectedRootID,
                expectedTargetPath: expectedTargetPath,
                progressReporter: progressReporter
            )
        }

        var nodes: [FileNodeRecord] = []
        nodes.reserveCapacity(expectedNodeCount)
        var indexByNodeID: [String: FileTreeNodeIndex] = [:]
        indexByNodeID.reserveCapacity(expectedNodeCount)
        var explicitPathByOrdinal: [Int: String] = [:]

        try await readNodeBatches(
            from: url,
            expectedChecksum: expectedChecksum,
            expectedNodeCount: expectedNodeCount,
            progressReporter: progressReporter
        ) { (batch: [ScanArchiveCompactNode]) in
            for record in batch {
                let ordinal = nodes.count
                if ordinal.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                let parent: ScanArchiveNodeLocation?
                if ordinal == topology.rootOrdinal {
                    parent = nil
                } else {
                    let parentOrdinal = Int(topology.parentRawIndices[ordinal])
                    guard nodes.indices.contains(parentOrdinal) else {
                        throw ScanArchiveError.topology(localized:
                            "node ordinal \(ordinal) has an unresolved parent"
                        )
                    }
                    let parentNode = nodes[parentOrdinal]
                    parent = ScanArchiveNodeLocation(
                        id: parentNode.id,
                        path: explicitPathByOrdinal[parentOrdinal] ?? parentNode.id
                    )
                }

                let location = try compactNodeLocation(
                    record,
                    ordinal: ordinal,
                    rootOrdinal: topology.rootOrdinal,
                    expectedRootID: expectedRootID,
                    parent: parent
                )
                if location.path != location.id {
                    explicitPathByOrdinal[ordinal] = location.path
                }
                let node = try modelCompactNode(
                    record,
                    location: location,
                    ordinal: ordinal,
                    rootOrdinal: topology.rootOrdinal,
                    expectedTargetPath: expectedTargetPath
                )
                if topology.childSpans[ordinal].count > 0, !node.isDirectory {
                    throw ScanArchiveError.topology(localized:
                        "non-directory node ordinal \(ordinal) has children"
                    )
                }
                let nodeIndex = FileTreeNodeIndex(rawValue: UInt32(ordinal))
                guard indexByNodeID.updateValue(nodeIndex, forKey: node.id) == nil else {
                    throw ScanArchiveError.nodes(localized: "duplicate node ID \(node.id)")
                }
                nodes.append(node)
            }
        }

        guard nodes.count == expectedNodeCount else {
            throw ScanArchiveError.nodes(localized:
                "manifest expected \(expectedNodeCount) nodes, found \(nodes.count)"
            )
        }
        let rootIndex = FileTreeNodeIndex(rawValue: UInt32(topology.rootOrdinal))
        return FileTreeStore(
            verifiedRootIndex: rootIndex,
            nodes: &nodes,
            indexByNodeID: indexByNodeID,
            parentRawIndices: topology.parentRawIndices,
            childSpans: topology.childSpans,
            childIndices: topology.childIndices,
            orderedNodeIndices: topology.orderedNodeIndices
        )
    }

    private func readNodeRecords<Record: Decodable & Sendable>(
        from url: URL,
        expectedChecksum: String,
        expectedNodeCount: Int,
        progressReporter: ScanArchiveProgressReporter?
    ) async throws -> [Record] {
        var records: [Record] = []
        records.reserveCapacity(min(
            expectedNodeCount,
            ScanArchiveNodeIOConstants.maximumInitialRecordCapacity
        ))
        try await readNodeBatches(
            from: url,
            expectedChecksum: expectedChecksum,
            expectedNodeCount: expectedNodeCount,
            progressReporter: progressReporter
        ) { batch in
            records.append(contentsOf: batch)
        }
        return records
    }

    private func readNodeBatches<Record: Decodable & Sendable>(
        from url: URL,
        expectedChecksum: String,
        expectedNodeCount: Int,
        progressReporter: ScanArchiveProgressReporter?,
        consumeBatch: ([Record]) throws -> Void
    ) async throws {
        let fileHandle: FileHandle
        do {
            fileHandle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ScanArchiveError.nodes(error.localizedDescription)
        }
        defer { try? fileHandle.close() }

        var buffer = Data()
        var hasher = SHA256()
        var decodedNodeCount = 0
        var nextBatchIndex = 0
        var nextBatchToAppend = 0
        var pendingBatches: [Int: [Record]] = [:]
        var inFlightBatchCount = 0
        let maximumConcurrentDecodes = min(
            max(ProcessInfo.processInfo.activeProcessorCount, 1),
            ScanArchiveNodeIOConstants.maximumConcurrentDecodes
        )

        try await withThrowingTaskGroup(of: (Int, [Record]).self) { group in
            func appendReadyBatches() throws -> Bool {
                var appendedBatch = false
                while let batch = pendingBatches.removeValue(forKey: nextBatchToAppend) {
                    let updatedNodeCount = decodedNodeCount + batch.count
                    try validateDecodedNodeCount(updatedNodeCount, expectedNodeCount: expectedNodeCount)
                    try consumeBatch(batch)
                    decodedNodeCount = updatedNodeCount
                    nextBatchToAppend += 1
                    appendedBatch = true
                    progressReporter?.report(ScanArchiveProgress(
                        phase: .readingNodes,
                        completedUnitCount: decodedNodeCount,
                        totalUnitCount: expectedNodeCount,
                        message: "Reading node records"
                    ))
                }
                return appendedBatch
            }

            func enqueue(_ batchData: Data) {
                let batchIndex = nextBatchIndex
                nextBatchIndex += 1
                inFlightBatchCount += 1
                group.addTask {
                    let decoder = Self.makeJSONDecoder()
                    return (batchIndex, try decodeNodeBatch(batchData, decoder: decoder))
                }
            }

            while true {
                try Task.checkCancellation()
                while inFlightBatchCount + pendingBatches.count >= maximumConcurrentDecodes,
                      let completedBatch = try await group.next() {
                    inFlightBatchCount -= 1
                    pendingBatches[completedBatch.0] = completedBatch.1
                    if try appendReadyBatches() {
                        await Task.yield()
                    }
                }

                let chunk: Data
                do {
                    chunk = try fileHandle.read(upToCount: ScanArchiveNodeIOConstants.readChunkSize) ?? Data()
                } catch let error as ScanArchiveError {
                    throw error
                } catch {
                    throw ScanArchiveError.nodes(error.localizedDescription)
                }
                guard !chunk.isEmpty else { break }
                hasher.update(data: chunk)
                buffer.append(chunk)

                if let newlineIndex = buffer.lastIndex(of: 0x0A) {
                    let lineEndIndex = buffer.index(after: newlineIndex)
                    enqueue(Data(buffer[..<lineEndIndex]))
                    buffer.removeSubrange(..<lineEndIndex)
                }
                try validateNodeLineSize(buffer)
            }

            if !buffer.isEmpty {
                try validateNodeLineSize(buffer)
                enqueue(buffer)
                buffer = Data()
            }

            while let completedBatch = try await group.next() {
                inFlightBatchCount -= 1
                pendingBatches[completedBatch.0] = completedBatch.1
                if try appendReadyBatches() {
                    await Task.yield()
                }
            }
        }

        progressReporter?.report(ScanArchiveProgress(
            phase: .readingNodes,
            completedUnitCount: decodedNodeCount,
            totalUnitCount: expectedNodeCount,
            message: "Reading node records"
        ))

        let actualChecksum = Data(hasher.finalize()).base64EncodedString()
        guard actualChecksum == expectedChecksum else {
            throw ScanArchiveError.integrity(localized: "nodes checksum mismatch")
        }

    }

    private func validateNodeLineSize(_ lineData: Data) throws {
        guard lineData.count <= ScanArchiveNodeIOConstants.maxNodeLineByteCount else {
            throw ScanArchiveError.nodes(localized: "node record is too large")
        }
    }

    private func validateDecodedNodeCount(_ decodedNodeCount: Int, expectedNodeCount: Int) throws {
        guard decodedNodeCount <= expectedNodeCount else {
            throw ScanArchiveError.nodes(localized: "node payload contains more nodes than manifest expected")
        }
    }

    private func decodeNodeLine<Record: Decodable>(
        _ lineData: Data,
        decoder: JSONDecoder
    ) throws -> Record? {
        guard !lineData.isEmpty else { return nil }
        do {
            return try decoder.decode(Record.self, from: lineData)
        } catch let error as ScanArchiveError {
            throw error
        } catch {
            throw ScanArchiveError.nodes(localized: "invalid JSONL node: \(error.localizedDescription)")
        }
    }

    private func decodeNodeBatch<Record: Decodable & Sendable>(
        _ data: Data,
        decoder: JSONDecoder
    ) throws -> [Record] {
        var result: [Record] = []
        var lineStartIndex = data.startIndex
        while let newlineIndex = data[lineStartIndex...].firstIndex(of: 0x0A) {
            let lineData = data[lineStartIndex..<newlineIndex]
            lineStartIndex = data.index(after: newlineIndex)
            try validateNodeLineSize(lineData)
            if let record: Record = try decodeNodeLine(lineData, decoder: decoder) {
                result.append(record)
            }
        }
        if lineStartIndex < data.endIndex {
            let lineData = data[lineStartIndex...]
            try validateNodeLineSize(lineData)
            if let record: Record = try decodeNodeLine(lineData, decoder: decoder) {
                result.append(record)
            }
        }
        return result
    }
}
