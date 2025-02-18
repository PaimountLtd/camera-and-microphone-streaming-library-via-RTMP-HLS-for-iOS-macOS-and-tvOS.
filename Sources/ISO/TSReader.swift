import AVFoundation
import Foundation
import Logboard

/// The interface an MPEG-2 TS (Transport Stream) reader uses to inform its delegates.
public protocol TSReaderDelegate: AnyObject {
    func reader(_ reader: TSReader<Self>, id: UInt16, didRead formatDescription: CMFormatDescription)
    func reader(_ reader: TSReader<Self>, id: UInt16, didRead sampleBuffer: CMSampleBuffer)
}

/// The TSReader class represents read MPEG-2 transport stream data.
public class TSReader<T: TSReaderDelegate> {
    /// Specifies the delegate object.
    public weak var delegate: T?

    private var pat: TSProgramAssociation? {
        didSet {
            guard let pat else {
                return
            }
            for (channel, PID) in pat.programs {
                programs[PID] = channel
            }
            if logger.isEnabledFor(level: .trace) {
                logger.trace(programs)
            }
        }
    }
    private var pmt: [UInt16: TSProgramMap] = [:] {
        didSet {
            for pmt in pmt.values {
                for data in pmt.elementaryStreamSpecificData where esSpecData[data.elementaryPID] != data {
                    esSpecData[data.elementaryPID] = data
                }
            }
            if logger.isEnabledFor(level: .trace) {
                logger.trace(esSpecData)
            }
        }
    }
    private var programs: [UInt16: UInt16] = [:]
    private var esSpecData: [UInt16: ESSpecificData] = [:]
    private var nalUnitReader = NALUnitReader()
    private var formatDescriptions: [UInt16: CMFormatDescription] = [:]
    private var packetizedElementaryStreams: [UInt16: PacketizedElementaryStream] = [:]
    private var previousPresentationTimeStamps: [UInt16: CMTime] = [:]

    /// Create a  new TSReader instance.
    public init() {
    }

    /// Reads transport-stream data.
    public func read(_ data: Data) -> Int {
        let count = data.count / TSPacket.size
        for i in 0..<count {
            guard let packet = TSPacket(data: data.subdata(in: i * TSPacket.size..<(i + 1) * TSPacket.size)) else {
                continue
            }
            if packet.pid == 0x0000 {
                pat = TSProgramAssociation(packet.payload)
                continue
            }
            if let channel = programs[packet.pid] {
                pmt[channel] = TSProgramMap(packet.payload)
                continue
            }
            readPacketizedElementaryStream(packet)
        }
        return count * TSPacket.size
    }

    /// Clears the reader object for new transport stream.
    public func clear() {
        pat = nil
        pmt.removeAll()
        programs.removeAll()
        esSpecData.removeAll()
        formatDescriptions.removeAll()
        packetizedElementaryStreams.removeAll()
        previousPresentationTimeStamps.removeAll()
    }

    private func readPacketizedElementaryStream(_ packet: TSPacket) {
        if packet.payloadUnitStartIndicator {
            if let sampleBuffer = makeSampleBuffer(packet.pid, forUpdate: true) {
                delegate?.reader(self, id: packet.pid, didRead: sampleBuffer)
            }
            packetizedElementaryStreams[packet.pid] = PacketizedElementaryStream(packet.payload)
            return
        }
        _ = packetizedElementaryStreams[packet.pid]?.append(packet.payload)
        if let sampleBuffer = makeSampleBuffer(packet.pid) {
            delegate?.reader(self, id: packet.pid, didRead: sampleBuffer)
        }
    }

    private func makeSampleBuffer(_ id: UInt16, forUpdate: Bool = false) -> CMSampleBuffer? {
        guard
            let data = esSpecData[id],
            var pes = packetizedElementaryStreams[id], pes.isEntired || forUpdate else {
            return nil
        }
        defer {
            packetizedElementaryStreams[id] = nil
        }
        let formatDescription = makeFormatDescription(data, pes: &pes)
        if let formatDescription, formatDescriptions[id] != formatDescription {
            formatDescriptions[id] = formatDescription
            delegate?.reader(self, id: id, didRead: formatDescription)
        }
        var isNotSync = true
        switch data.streamType {
        case .h264:
            let units = nalUnitReader.read(&pes.data, type: AVCNALUnit.self)
            if let unit = units.first(where: { $0.type == .idr || $0.type == .slice }) {
                var data = Data([0x00, 0x00, 0x00, 0x01])
                data.append(unit.data)
                pes.data = data
            }
            isNotSync = !units.contains { $0.type == .idr }
        case .h265:
            let units = nalUnitReader.read(&pes.data, type: HEVCNALUnit.self)
            isNotSync = units.contains { $0.type == .sps }
        case .adtsAac:
            isNotSync = false
        default:
            break
        }
        let sampleBuffer = pes.makeSampleBuffer(
            data.streamType,
            previousPresentationTimeStamp: previousPresentationTimeStamps[id] ?? .invalid,
            formatDescription: formatDescriptions[id]
        )
        sampleBuffer?.isNotSync = isNotSync
        previousPresentationTimeStamps[id] = sampleBuffer?.presentationTimeStamp
        return sampleBuffer
    }

    private func makeFormatDescription(_ data: ESSpecificData, pes: inout PacketizedElementaryStream) -> CMFormatDescription? {
        switch data.streamType {
        case .adtsAac:
            return ADTSHeader(data: pes.data).makeFormatDescription()
        case .h264, .h265:
            return nalUnitReader.makeFormatDescription(&pes.data, type: data.streamType)
        default:
            return nil
        }
    }
}
