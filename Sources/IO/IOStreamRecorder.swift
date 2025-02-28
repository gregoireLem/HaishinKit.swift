import AVFoundation
#if canImport(SwiftPMSupport)
import SwiftPMSupport
#endif

/// The interface an IOStreamRecorderDelegate uses to inform its delegate.
public protocol IOStreamRecorderDelegate: AnyObject {
    /// Tells the receiver to recorder error occured.
    func recorder(_ recorder: IOStreamRecorder, errorOccured error: IOStreamRecorder.Error)
    /// Tells the receiver to finish writing.
    func recorder(_ recorder: IOStreamRecorder, finishWriting writer: AVAssetWriter)
}

// MARK: -
/// The IOStreamRecorder class represents video and audio recorder.
public final class IOStreamRecorder {
    /// The IOStreamRecorder error domain codes.
    public enum Error: Swift.Error {
        /// Failed to create the AVAssetWriter.
        case failedToCreateAssetWriter(error: any Swift.Error)
        /// Failed to create the AVAssetWriterInput.
        case failedToCreateAssetWriterInput(error: NSException)
        /// Failed to append the PixelBuffer or SampleBuffer.
        case failedToAppend(error: (any Swift.Error)?)
        /// Failed to finish writing the AVAssetWriter.
        case failedToFinishWriting(error: (any Swift.Error)?)
    }

    /// The default output settings for an IOStreamRecorder.
    public static let defaultSettings: [AVMediaType: [String: Any]] = [
        .audio: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 0,
            AVNumberOfChannelsKey: 0
        ],
        .video: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoHeightKey: 0,
            AVVideoWidthKey: 0
        ]
    ]

    /// Specifies the delegate.
    public weak var delegate: (any IOStreamRecorderDelegate)?
    /// Specifies the recorder settings.
    public var settings: [AVMediaType: [String: Any]] = IOStreamRecorder.defaultSettings
    /// The running indicies whether recording or not.
    public private(set) var isRunning: Atomic<Bool> = .init(false)

    private let lockQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.IORecorder.lock")
    private var isReadyForStartWriting: Bool {
        guard let writer = writer else {
            return false
        }
        return settings.count == writer.inputs.count
    }
    private var writer: AVAssetWriter?
    private var writerInputs: [AVMediaType: AVAssetWriterInput] = [:]
    private var audioPresentationTime: CMTime = .zero
    private var videoPresentationTime: CMTime = .zero
    private var dimensions: CMVideoDimensions = .init(width: 0, height: 0)

    #if os(iOS)
    private lazy var moviesDirectory: URL = {
        URL(fileURLWithPath: NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0])
    }()
    #else
    private lazy var moviesDirectory: URL = {
        URL(fileURLWithPath: NSSearchPathForDirectoriesInDomains(.moviesDirectory, .userDomainMask, true)[0])
    }()
    #endif

    /// Append a sample buffer for recording.
    func append(_ sampleBuffer: CMSampleBuffer) {
        guard isRunning.value else {
            return
        }
        let mediaType: AVMediaType = (sampleBuffer.formatDescription?.mediaType == .video) ? .video : .audio
        lockQueue.async {
            guard
                let writer = self.writer,
                let input = self.makeWriterInput(mediaType, sourceFormatHint: sampleBuffer.formatDescription),
                self.isReadyForStartWriting else {
                return
            }

            switch writer.status {
            case .unknown:
                writer.startWriting()
                writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            default:
                break
            }

            if input.isReadyForMoreMediaData {
                switch mediaType {
                case .audio:
                    if input.append(sampleBuffer) {
                        self.audioPresentationTime = sampleBuffer.presentationTimeStamp
                    } else {
                        self.delegate?.recorder(self, errorOccured: .failedToAppend(error: writer.error))
                    }
                case .video:
                    if input.append(sampleBuffer) {
                        self.videoPresentationTime = sampleBuffer.presentationTimeStamp
                    } else {
                        self.delegate?.recorder(self, errorOccured: .failedToAppend(error: writer.error))
                    }
                default:
                    break
                }
            }
        }
    }

    func append(_ audioPCMBuffer: AVAudioPCMBuffer, when: AVAudioTime) {
        guard isRunning.value else {
            return
        }
        if let sampleBuffer = audioPCMBuffer.makeSampleBuffer(when) {
            append(sampleBuffer)
        }
    }

    func finishWriting() {
        guard let writer = writer, writer.status == .writing else {
            delegate?.recorder(self, errorOccured: .failedToFinishWriting(error: writer?.error))
            return
        }
        let dispatchGroup = DispatchGroup()
        dispatchGroup.enter()
        for (_, input) in writerInputs {
            input.markAsFinished()
        }
        writer.finishWriting {
            self.delegate?.recorder(self, finishWriting: writer)
            self.writer = nil
            self.writerInputs.removeAll()
            dispatchGroup.leave()
        }
        dispatchGroup.wait()
    }

    private func makeWriterInput(_ mediaType: AVMediaType, sourceFormatHint: CMFormatDescription?) -> AVAssetWriterInput? {
        guard writerInputs[mediaType] == nil else {
            return writerInputs[mediaType]
        }

        var outputSettings: [String: Any] = [:]
        if let defaultOutputSettings: [String: Any] = self.settings[mediaType] {
            switch mediaType {
            case .audio:
                guard
                    let format = sourceFormatHint,
                    let inSourceFormat = format.audioStreamBasicDescription else {
                    break
                }
                for (key, value) in defaultOutputSettings {
                    switch key {
                    case AVSampleRateKey:
                        outputSettings[key] = AnyUtil.isZero(value) ? inSourceFormat.mSampleRate : value
                    case AVNumberOfChannelsKey:
                        outputSettings[key] = AnyUtil.isZero(value) ? Int(inSourceFormat.mChannelsPerFrame) : value
                    default:
                        outputSettings[key] = value
                    }
                }
            case .video:
                for (key, value) in defaultOutputSettings {
                    switch key {
                    case AVVideoHeightKey:
                        outputSettings[key] = AnyUtil.isZero(value) ? Int(dimensions.height) : value
                    case AVVideoWidthKey:
                        outputSettings[key] = AnyUtil.isZero(value) ? Int(dimensions.width) : value
                    default:
                        outputSettings[key] = value
                    }
                }
            default:
                break
            }
        }
        var input: AVAssetWriterInput?
        nstry {
            input = AVAssetWriterInput(mediaType: mediaType, outputSettings: outputSettings, sourceFormatHint: sourceFormatHint)
            input?.expectsMediaDataInRealTime = true
            self.writerInputs[mediaType] = input
            if let input {
                self.writer?.add(input)
            }
        } _: { exception in
            self.delegate?.recorder(self, errorOccured: .failedToCreateAssetWriterInput(error: exception))
        }
        return input
    }
}

extension IOStreamRecorder: IOStreamObserver {
    // MARK: IOStreamObserver
    public func stream(_ stream: IOStream, didOutput video: CMSampleBuffer) {
        append(video)
    }

    public func stream(_ stream: IOStream, didOutput audio: AVAudioBuffer, when: AVAudioTime) {
        if let audio = audio as? AVAudioPCMBuffer {
            append(audio, when: when)
        }
    }
}

extension IOStreamRecorder: Running {
    // MARK: Running
    public func startRunning() {
        lockQueue.async {
            guard !self.isRunning.value else {
                return
            }
            do {
                self.videoPresentationTime = .zero
                self.audioPresentationTime = .zero
                let url = self.moviesDirectory.appendingPathComponent((UUID().uuidString)).appendingPathExtension("mp4")
                self.writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
                self.isRunning.mutate { $0 = true }
            } catch {
                self.delegate?.recorder(self, errorOccured: .failedToCreateAssetWriter(error: error))
            }
        }
    }

    public func stopRunning() {
        lockQueue.async {
            guard self.isRunning.value else {
                return
            }
            self.finishWriting()
            self.isRunning.mutate { $0 = false }
        }
    }
}
