import AMSMB2
import Foundation
import Libmpv

final class SMBReadSource: @unchecked Sendable {
    private let client: SMB2Manager
    private let path: String
    private let length: Int64
    let uri: String

    init(client: SMB2Manager, path: String, length: Int64) {
        self.client = client
        self.path = path
        self.length = length
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        uri = "cinemasmb://play/video." + (MediaLibrary.fileExtensions.contains(ext) ? ext : "mkv")
    }

    // The player retains this source until mpv_terminate_destroy returns.
    func register(on handle: OpaquePointer) -> Int32 {
        mpv_stream_cb_add_ro(handle, "cinemasmb", Unmanaged.passUnretained(self).toOpaque()) {
            userData, uri, info in
            guard let userData, let uri, let info else { return Int32(MPV_ERROR_LOADING_FAILED.rawValue) }
            let source = Unmanaged<SMBReadSource>.fromOpaque(userData).takeUnretainedValue()
            guard String(cString: uri) == source.uri else { return Int32(MPV_ERROR_LOADING_FAILED.rawValue) }

            let cursor = SMBCursor(source)
            info.pointee.cookie = Unmanaged.passRetained(cursor).toOpaque()
            info.pointee.read_fn = { cookie, buffer, count in
                guard let cookie, let buffer else { return -1 }
                return Unmanaged<SMBCursor>.fromOpaque(cookie).takeUnretainedValue().read(buffer, count: count)
            }
            info.pointee.seek_fn = { cookie, offset in
                guard let cookie else { return -1 }
                return Unmanaged<SMBCursor>.fromOpaque(cookie).takeUnretainedValue().seek(offset)
            }
            info.pointee.size_fn = { cookie in
                guard let cookie else { return -1 }
                return Unmanaged<SMBCursor>.fromOpaque(cookie).takeUnretainedValue().length
            }
            info.pointee.cancel_fn = { cookie in
                if let cookie { Unmanaged<SMBCursor>.fromOpaque(cookie).takeUnretainedValue().cancel() }
            }
            info.pointee.close_fn = { cookie in
                if let cookie { Unmanaged<SMBCursor>.fromOpaque(cookie).release() }
            }
            return 0
        }
    }

    private final class SMBCursor {
        private let source: SMBReadSource
        private var offset: Int64 = 0
        private var bufferStart: Int64 = 0
        private var data = Data()
        private let lock = NSLock()
        private var pending: SMBReadRequest?
        private var cancelled = false

        init(_ source: SMBReadSource) { self.source = source }

        var length: Int64 { source.length }

        func seek(_ position: Int64) -> Int64 {
            guard (0...length).contains(position) else { return -1 }
            offset = position
            return position
        }

        func read(_ destination: UnsafeMutablePointer<CChar>, count: UInt64) -> Int64 {
            if count == 0 || offset == length { return 0 }
            guard offset >= 0, offset < length else { return -1 }

            if offset < bufferStart || offset - bufferStart >= Int64(data.count) {
                let burst = min(length - offset, 2 * 1024 * 1024)
                guard let bytes = fetch(offset..<(offset + burst)), !bytes.isEmpty else { return -1 }
                bufferStart = offset
                data = bytes
            }

            let start = Int(offset - bufferStart)
            let amount = Int(min(count, UInt64(data.count - start)))
            let bytes = UnsafeMutableRawBufferPointer(start: destination, count: amount)
            _ = data.copyBytes(to: bytes, from: start..<(start + amount))
            offset += Int64(amount)
            return Int64(amount)
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let request = pending
            lock.unlock()
            request?.done.signal()
        }

        private func fetch(_ range: Range<Int64>) -> Data? {
            let request = SMBReadRequest()
            lock.lock()
            if cancelled {
                lock.unlock()
                return nil
            }
            pending = request
            lock.unlock()

            source.client.contents(atPath: source.path, range: range, progress: nil) {
                request.complete(try? $0.get())
            }
            let waited = request.done.wait(timeout: .now() + 12)

            lock.lock()
            pending = nil
            let wasCancelled = cancelled
            lock.unlock()
            return waited == .success && !wasCancelled ? request.bytes : nil
        }
    }

    private final class SMBReadRequest: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var result: Data?

        var bytes: Data? {
            lock.lock()
            defer { lock.unlock() }
            return result
        }

        func complete(_ data: Data?) {
            lock.lock()
            result = data
            lock.unlock()
            done.signal()
        }
    }
}
