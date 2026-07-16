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

    func materializeCompactNodes(
        _ records: [ScanArchiveCompactNode],
        topology: ScanArchiveTopology,
        expectedRootID: String
    ) throws -> ScanArchiveNodePayload {
        guard records.indices.contains(topology.rootOrdinal) else {
            throw ScanArchiveError.topology(localized: "root ordinal \(topology.rootOrdinal) is out of range")
        }

        var topologyParentByOrdinal: [Int: Int] = [:]
        topologyParentByOrdinal.reserveCapacity(max(records.count - 1, 0))
        for (parentKey, childOrdinals) in topology.childOrdinalsByOrdinal {
            guard let parentOrdinal = Int(parentKey), String(parentOrdinal) == parentKey,
                  records.indices.contains(parentOrdinal) else {
                throw ScanArchiveError.topology(localized: "parent ordinal \(parentKey) is invalid")
            }
            for childOrdinal in childOrdinals {
                guard records.indices.contains(childOrdinal) else {
                    throw ScanArchiveError.topology(localized: "child ordinal \(childOrdinal) is out of range")
                }
                if let existingParent = topologyParentByOrdinal.updateValue(parentOrdinal, forKey: childOrdinal) {
                    let detail = existingParent == parentOrdinal ? "is duplicated" : "has multiple parents"
                    throw ScanArchiveError.topology(localized: "child ordinal \(childOrdinal) \(detail)")
                }
            }
        }

        if let rootParent = topologyParentByOrdinal[topology.rootOrdinal] {
            if rootParent == topology.rootOrdinal {
                throw ScanArchiveError.topology(localized: "root node references itself as a child")
            }
            throw ScanArchiveError.topology(localized: "root node is referenced as a child")
        }
        for ordinal in records.indices where ordinal != topology.rootOrdinal {
            guard topologyParentByOrdinal[ordinal] != nil else {
                throw ScanArchiveError.topology(localized: "node ordinal \(ordinal) is not reachable")
            }
        }

        var locations = Array<ScanArchiveNodeLocation?>(repeating: nil, count: records.count)

        func resolveLocation(at ordinal: Int) throws -> ScanArchiveNodeLocation {
            if let location = locations[ordinal] {
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
                guard let parentOrdinal = topologyParentByOrdinal[cursor] else {
                    throw ScanArchiveError.topology(localized: "node ordinal \(cursor) has an invalid parent")
                }
                cursor = parentOrdinal
            }

            while let pendingOrdinal = chain.popLast() {
                let record = records[pendingOrdinal]
                let location: ScanArchiveNodeLocation
                if pendingOrdinal == topology.rootOrdinal {
                    let id = record.explicitID ?? expectedRootID
                    guard id == expectedRootID else {
                        throw ScanArchiveError.topology(localized: "root ID does not match manifest")
                    }
                    location = ScanArchiveNodeLocation(
                        id: id,
                        path: record.explicitPath ?? id
                    )
                } else {
                    guard let parentOrdinal = topologyParentByOrdinal[pendingOrdinal],
                          let parent = locations[parentOrdinal] else {
                        throw ScanArchiveError.topology(localized: "node ordinal \(pendingOrdinal) has an unresolved parent")
                    }
                    if let explicitID = record.explicitID {
                        location = ScanArchiveNodeLocation(
                            id: explicitID,
                            path: record.explicitPath ?? explicitID
                        )
                    } else {
                        guard let component = record.relativePath,
                              !component.isEmpty,
                              component != ".",
                              component != "..",
                              !component.contains("/") else {
                            throw ScanArchiveError.nodes(localized:
                                "node ordinal \(pendingOrdinal) has an invalid relative path"
                            )
                        }
                        let path = URL(filePath: parent.path, directoryHint: .isDirectory)
                            .appending(
                                path: component,
                                directoryHint: record.payload.isDirectory ? .isDirectory : .notDirectory
                            )
                            .path
                        location = ScanArchiveNodeLocation(
                            id: path,
                            path: record.explicitPath ?? path
                        )
                    }
                }
                locations[pendingOrdinal] = location
            }

            guard let location = locations[ordinal] else {
                throw ScanArchiveError.topology(localized: "node ordinal \(ordinal) could not be resolved")
            }
            return location
        }

        var nodesByID: [String: FileNodeRecord] = [:]
        nodesByID.reserveCapacity(records.count)
        var orderedNodeIDs: [String] = []
        orderedNodeIDs.reserveCapacity(records.count)
        for ordinal in records.indices {
            let location = try resolveLocation(at: ordinal)
            let node = try records[ordinal].payload.modelNode(
                resolvedID: location.id,
                resolvedPath: location.path,
                resolvedName: records[ordinal].payload.name.isEmpty
                    ? records[ordinal].relativePath
                    : nil
            )
            guard nodesByID[node.id] == nil else {
                throw ScanArchiveError.nodes(localized: "duplicate node ID \(node.id)")
            }
            nodesByID[node.id] = node
            orderedNodeIDs.append(node.id)
        }

        return ScanArchiveNodePayload(
            nodesByID: nodesByID,
            orderedNodeIDs: orderedNodeIDs
        )
    }

    private func readNodeRecords<Record: Decodable & Sendable>(
        from url: URL,
        expectedChecksum: String,
        expectedNodeCount: Int,
        progressReporter: ScanArchiveProgressReporter?
    ) async throws -> [Record] {
        let fileHandle: FileHandle
        do {
            fileHandle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ScanArchiveError.nodes(error.localizedDescription)
        }
        defer { try? fileHandle.close() }

        let decoder = Self.makeJSONDecoder()
        var records: [Record] = []
        records.reserveCapacity(min(
            expectedNodeCount,
            ScanArchiveNodeIOConstants.maximumInitialRecordCapacity
        ))
        var buffer = Data()
        var hasher = SHA256()
        var decodedNodeCount = 0

        while true {
            try Task.checkCancellation()
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

            var lineStartIndex = buffer.startIndex
            while let newlineIndex = buffer[lineStartIndex...].firstIndex(of: 0x0A) {
                let lineData = Data(buffer[lineStartIndex..<newlineIndex])
                lineStartIndex = buffer.index(after: newlineIndex)
                try validateNodeLineSize(lineData)
                if let record: Record = try decodeNodeLine(lineData, decoder: decoder) {
                    records.append(record)
                    decodedNodeCount += 1
                    try validateDecodedNodeCount(decodedNodeCount, expectedNodeCount: expectedNodeCount)
                    if ScanArchiveProgressReporting.shouldReportProgress(decodedNodeCount) ||
                        decodedNodeCount == expectedNodeCount {
                        progressReporter?.report(ScanArchiveProgress(
                            phase: .readingNodes,
                            completedUnitCount: decodedNodeCount,
                            totalUnitCount: expectedNodeCount,
                            message: "Reading node records"
                        ))
                        await Task.yield()
                    }
                }
            }
            if lineStartIndex > buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<lineStartIndex)
            }
            try validateNodeLineSize(buffer)
        }

        if !buffer.isEmpty {
            try validateNodeLineSize(buffer)
            if let record: Record = try decodeNodeLine(buffer, decoder: decoder) {
                records.append(record)
                decodedNodeCount += 1
                try validateDecodedNodeCount(decodedNodeCount, expectedNodeCount: expectedNodeCount)
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

        return records
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
}
