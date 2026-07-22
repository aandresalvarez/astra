import Darwin
import Foundation

package enum RunSupervisorSpoolFrameDecodeResult {
    case committed(event: RunSupervisorEvent, byteCount: Int)
    case incompleteTail
    case corruptCommittedFrame
}

package enum RunSupervisorSpoolFrameCodec {
    static let commitMarker: UInt64 = 0x415354524153504c
    static let maximumPayloadBytes = 65_536

    private static let authenticationDomain = Data("astra.run-supervisor.spool-frame.v1\0".utf8)

    static func encode(
        _ event: RunSupervisorEvent,
        capability: RunSupervisorCapability
    ) throws -> Data {
        let payload = try RunSupervisorDigests.canonicalData(event)
        guard payload.count <= maximumPayloadBytes else {
            throw RunSupervisorError.oversizedFrame(limit: maximumPayloadBytes)
        }
        var length = UInt32(payload.count).bigEndian
        let header = withUnsafeBytes(of: &length) { Data($0) }
        var marker = commitMarker.bigEndian
        let authenticated = authenticationDomain + header + payload
        return header
            + payload
            + RunSupervisorDigests.hmacBytes(authenticated, capability: capability)
            + withUnsafeBytes(of: &marker) { Data($0) }
    }

    static func decode(
        fileDescriptor: Int32,
        offset: Int,
        fileSize: Int,
        capability: RunSupervisorCapability
    ) throws -> RunSupervisorSpoolFrameDecodeResult {
        let remaining = fileSize - offset
        guard remaining >= 4 else { return .incompleteTail }
        let header = try preadExactly(4, from: fileDescriptor, offset: offset)
        let payloadLength = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
        guard payloadLength > 0, payloadLength <= maximumPayloadBytes else {
            return .corruptCommittedFrame
        }
        let total = 4 + payloadLength + 32 + 8
        guard remaining >= total else { return .incompleteTail }
        let payload = try preadExactly(payloadLength, from: fileDescriptor, offset: offset + 4)
        let expectedAuthentication = try preadExactly(
            32,
            from: fileDescriptor,
            offset: offset + 4 + payloadLength
        )
        let markerData = try preadExactly(8, from: fileDescriptor, offset: offset + 4 + payloadLength + 32)
        let marker = markerData.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).bigEndian }
        guard marker == commitMarker,
              RunSupervisorDigests.constantTimeEqual(
                  RunSupervisorDigests.hmacBytes(
                      authenticationDomain + header + payload,
                      capability: capability
                  ),
                  expectedAuthentication
              ) else {
            return .corruptCommittedFrame
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let event = try? decoder.decode(RunSupervisorEvent.self, from: payload) else {
            return .corruptCommittedFrame
        }
        return .committed(event: event, byteCount: total)
    }

    static func preadExactly(_ count: Int, from fd: Int32, offset: Int) throws -> Data {
        var data = Data(count: count)
        var consumed = 0
        while consumed < count {
            let result = data.withUnsafeMutableBytes {
                pread(fd, $0.baseAddress!.advanced(by: consumed), count - consumed, off_t(offset + consumed))
            }
            if result < 0, errno == EINTR { continue }
            guard result > 0 else { throw RunSupervisorError.truncatedFrame }
            consumed += result
        }
        return data
    }
}
