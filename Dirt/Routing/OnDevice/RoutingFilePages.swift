import Foundation
#if canImport(Darwin)
import Darwin
#endif

nonisolated enum RoutingPageError: Error, Equatable {
    case invalidConfiguration
    case invalidRange
    case readTooLarge
    case memoryLimit
    case leaseLimit
    case cancelled
    case closed
    case unsupportedPlatform
    case notRegularFile
    case sourceChanged
    case unexpectedEndOfFile
    case systemCall(Int32)
}

/// Shared accounting includes both cached pages and all outstanding range
/// leases, including leases retained by typed column views after source.close().
/// Counts payload bytes; object/allocator overhead must be measured separately.
fileprivate nonisolated final class RoutingPageBudget: @unchecked Sendable {
    enum Kind { case cache, lease, borrow }
    struct Snapshot {
        let cacheBytes: Int
        let leasedBytes: Int
        let leaseCount: Int
        let peakBytes: Int
        let borrowedPageReferenceBytes: Int
        let borrowedPageCount: Int
    }
    private let lock = NSLock()
    let maximumBytes: Int
    let maximumLeases: Int
    private var cacheBytes = 0
    private var leasedBytes = 0
    private var leaseCount = 0
    private var peakBytes = 0
    private var borrowedPageReferenceBytes = 0
    private var borrowedPageCount = 0

    init(maximumBytes: Int, maximumLeases: Int) {
        self.maximumBytes = maximumBytes; self.maximumLeases = maximumLeases
    }

    func reserve(_ bytes: Int, kind: Kind) throws -> RoutingPageReservation {
        lock.lock(); defer { lock.unlock() }
        if kind != .cache, leaseCount >= maximumLeases { throw RoutingPageError.leaseLimit }
        if kind != .borrow, bytes > maximumBytes - cacheBytes - leasedBytes { throw RoutingPageError.memoryLimit }
        if kind == .cache { cacheBytes += bytes }
        else if kind == .lease { leasedBytes += bytes; leaseCount += 1 }
        else { borrowedPageReferenceBytes += bytes; borrowedPageCount += 1; leaseCount += 1 }
        peakBytes = max(peakBytes, cacheBytes + leasedBytes)
        return RoutingPageReservation(budget: self, bytes: bytes, kind: kind)
    }

    func release(_ bytes: Int, kind: Kind) {
        lock.lock(); defer { lock.unlock() }
        if kind == .cache { cacheBytes -= bytes }
        else if kind == .lease { leasedBytes -= bytes; leaseCount -= 1 }
        else { borrowedPageReferenceBytes -= bytes; borrowedPageCount -= 1; leaseCount -= 1 }
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(cacheBytes: cacheBytes, leasedBytes: leasedBytes,
            leaseCount: leaseCount, peakBytes: peakBytes,
            borrowedPageReferenceBytes: borrowedPageReferenceBytes, borrowedPageCount: borrowedPageCount)
    }
}

fileprivate nonisolated final class RoutingPageReservation: @unchecked Sendable {
    let budget: RoutingPageBudget
    let bytes: Int
    let kind: RoutingPageBudget.Kind
    init(budget: RoutingPageBudget, bytes: Int, kind: RoutingPageBudget.Kind) {
        self.budget = budget; self.bytes = bytes; self.kind = kind
    }
    deinit { budget.release(bytes, kind: kind) }
}

/// Immutable owned bytes. Do not escape pointers from withUnsafeBytes. The
/// reservation follows this object through all column views until its last owner
/// releases it. No public Data getter can detach bytes from their accounting.
nonisolated final class RoutingByteLease: @unchecked Sendable {
    fileprivate let storage: Data
    private let reservation: RoutingPageReservation?
    var count: Int { storage.count }

    fileprivate init(storage: Data, reservation: RoutingPageReservation) {
        self.storage = storage; self.reservation = reservation
    }

    /// In-memory adapter for fixtures/already-owned immutable data. These bytes
    /// are owned by the caller and are not charged to a file source's budget.
    init(data: Data) { storage = data; reservation = nil }

    func withUnsafeBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
        try storage.withUnsafeBytes(body)
    }
}

/// A counted immutable reference to an already charged cached page. The page's
/// original payload reservation remains alive even after eviction or close.
/// Reference bytes can overlap (two borrowers of one page); do not add them to
/// payload bytes. The borrow reservation consumes one of maximumLeases.
nonisolated final class RoutingPageBorrow: @unchecked Sendable {
    let fileOffset: Int
    private let page: RoutingByteLease
    private let reservation: RoutingPageReservation
    var count: Int { page.count }
    fileprivate init(fileOffset: Int,page: RoutingByteLease,reservation: RoutingPageReservation) {
        self.fileOffset=fileOffset;self.page=page;self.reservation=reservation
    }
    func withUnsafeBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
        try page.withUnsafeBytes(body)
    }
}

/// Read-only descriptor with bounded cache AND retained range-lease payload.
/// Source hashes/format pairing must be verified by acquisition before use.
/// This helper does not claim the graph is validated or selectively searched.
nonisolated final class RoutingFilePages: @unchecked Sendable {
    struct Limits: Sendable {
        let pageBytes: Int
        let maximumCachedBytes: Int
        let maximumReadBytes: Int
        let maximumLivePayloadBytes: Int
        let maximumLeases: Int
    }
    struct Statistics: Sendable {
        let fileBytes: Int
        let cachedPages: Int
        /// Includes cached pages pinned by borrowers after cache eviction.
        let cachedPayloadBytes: Int
        let borrowedPageReferenceBytes: Int
        let borrowedPageCount: Int
        let leasedPayloadBytes: Int
        let leaseCount: Int
        let peakLivePayloadBytes: Int
        let maximumLivePayloadBytes: Int
        let bytesRead: UInt64
        let readCalls: UInt64
        let cacheHits: UInt64
        let cacheMisses: UInt64
        let closed: Bool
    }
    private struct Page {
        let lease: RoutingByteLease
        var lastUse: UInt64
    }
    private let lock = NSLock()
    private let limits: Limits
    private let budget: RoutingPageBudget
    private var descriptor: Int32 = -1
    private var pages: [Int: Page] = [:]
    private var cachedBytes = 0
    private var tick: UInt64 = 0
    private var bytesRead: UInt64 = 0
    private var readCalls: UInt64 = 0
    private var hits: UInt64 = 0
    private var misses: UInt64 = 0
    let fileBytes: Int
    #if canImport(Darwin)
    private let originalSize: off_t
    private let originalModified: timespec
    private let originalChanged: timespec
    #endif

    init(url: URL, limits: Limits) throws {
        guard limits.pageBytes > 0, limits.maximumCachedBytes >= limits.pageBytes,
              limits.maximumReadBytes > 0, limits.maximumLeases > 0,
              limits.maximumReadBytes <= limits.maximumLivePayloadBytes,
              limits.pageBytes <= limits.maximumLivePayloadBytes - limits.maximumReadBytes else {
            throw RoutingPageError.invalidConfiguration
        }
        self.limits = limits
        budget = RoutingPageBudget(maximumBytes: limits.maximumLivePayloadBytes,
            maximumLeases: limits.maximumLeases)
        #if canImport(Darwin)
        let fd = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard fd >= 0 else { throw RoutingPageError.systemCall(errno) }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let code = errno; Darwin.close(fd); throw RoutingPageError.systemCall(code)
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            Darwin.close(fd); throw RoutingPageError.notRegularFile
        }
        guard info.st_size >= 0, UInt64(info.st_size) <= UInt64(Int.max) else {
            Darwin.close(fd); throw RoutingPageError.invalidRange
        }
        fileBytes = Int(info.st_size)
        originalSize = info.st_size
        originalModified = info.st_mtimespec
        originalChanged = info.st_ctimespec
        descriptor = fd
        #else
        throw RoutingPageError.unsupportedPlatform
        #endif
    }

    deinit { close() }

    func close() {
        lock.lock(); defer { lock.unlock() }
        pages.removeAll(); cachedBytes = 0
        #if canImport(Darwin)
        if descriptor >= 0 { Darwin.close(descriptor) }
        #endif
        descriptor = -1
    }

    var statistics: Statistics {
        lock.lock(); defer { lock.unlock() }
        let live = budget.snapshot()
        return Statistics(fileBytes: fileBytes, cachedPages: pages.count,
            cachedPayloadBytes: live.cacheBytes,
            borrowedPageReferenceBytes: live.borrowedPageReferenceBytes, borrowedPageCount: live.borrowedPageCount,
            leasedPayloadBytes: live.leasedBytes,
            leaseCount: live.leaseCount, peakLivePayloadBytes: live.peakBytes,
            maximumLivePayloadBytes: limits.maximumLivePayloadBytes,
            bytesRead: bytesRead, readCalls: readCalls, cacheHits: hits,
            cacheMisses: misses, closed: descriptor < 0)
    }

    /// Query boundaries must validate even when every row came from a retained
    /// immutable lease and no new disk read was necessary.
    func validate(cancelled: () -> Bool = { false }) throws {
        lock.lock(); defer { lock.unlock() }
        guard descriptor >= 0 else { throw RoutingPageError.closed }
        guard !cancelled() else { throw RoutingPageError.cancelled }
        try verifyUnchanged()
    }

    /// Borrows the physical page containing offset without copying its bytes.
    /// Checks source identity on acquisition. Queries using retained borrows
    /// must additionally validate before and after the entire query.
    func borrowPage(containing offset: Int,cancelled: () -> Bool = { false }) throws -> RoutingPageBorrow {
        lock.lock();defer { lock.unlock() }
        guard descriptor >= 0 else { throw RoutingPageError.closed }
        guard offset >= 0,offset < fileBytes else { throw RoutingPageError.invalidRange }
        guard !cancelled() else { throw RoutingPageError.cancelled }
        try verifyUnchanged()
        let first=offset/limits.pageBytes*limits.pageBytes
        let length=min(limits.pageBytes,fileBytes-first)
        // Count the borrow before reading. A failed load releases this token.
        let reservation=try budget.reserve(length,kind: .borrow)
        let page=try cachedPage(offset/limits.pageBytes,cancelled: cancelled)
        guard !cancelled() else { throw RoutingPageError.cancelled }
        try verifyUnchanged()
        RoutingWorkContext.measurement?.increment(.filePageBorrowAcquisitions)
        RoutingWorkContext.measurement?.increment(.filePageBytesBorrowed,by: UInt64(page.count))
        return RoutingPageBorrow(fileOffset: first,page: page,reservation: reservation)
    }

    /// Returns a bounded owned range. I/O, truncation, mutation and cancellation
    /// throw; no partially populated or zero-filled result escapes on failure.
    /// The cancellation callback must not re-enter this source.
    func read(at offset: Int, count: Int, cancelled: () -> Bool = { false }) throws -> RoutingByteLease {
        lock.lock(); defer { lock.unlock() }
        guard descriptor >= 0 else { throw RoutingPageError.closed }
        guard offset >= 0, count >= 0, offset <= fileBytes, count <= fileBytes - offset else {
            throw RoutingPageError.invalidRange
        }
        guard count <= limits.maximumReadBytes else { throw RoutingPageError.readTooLarge }
        guard !cancelled() else { throw RoutingPageError.cancelled }
        try verifyUnchanged()
        let reservation = try reserve(count, kind: .lease)
        var output = Data(count: count)
        try output.withUnsafeMutableBytes { raw in
            var copied = 0
            while copied < count {
                guard !cancelled() else { throw RoutingPageError.cancelled }
                let position = offset + copied
                let pageIndex = position / limits.pageBytes
                let within = position % limits.pageBytes
                let page = try cachedPage(pageIndex, cancelled: cancelled)
                let length = min(count - copied, page.count - within)
                page.withUnsafeBytes { input in
                    raw.baseAddress!.advanced(by: copied).copyMemory(
                        from: input.baseAddress!.advanced(by: within), byteCount: length)
                }
                copied += length
            }
        }
        guard !cancelled() else { throw RoutingPageError.cancelled }
        try verifyUnchanged()
        RoutingWorkContext.measurement?.increment(.fileBytesAccessed,by: UInt64(count))
        return RoutingByteLease(storage: output, reservation: reservation)
    }

    private func reserve(_ bytes: Int, kind: RoutingPageBudget.Kind) throws -> RoutingPageReservation {
        while true {
            do { return try budget.reserve(bytes, kind: kind) }
            catch RoutingPageError.memoryLimit {
                guard evictOne() else { throw RoutingPageError.memoryLimit }
            }
        }
    }

    private func evictOne() -> Bool {
        guard let key = pages.min(by: { $0.value.lastUse < $1.value.lastUse })?.key else { return false }
        cachedBytes -= pages[key]!.lease.count
        pages.removeValue(forKey: key)
        return true
    }

    private func cachedPage(_ index: Int, cancelled: () -> Bool) throws -> RoutingByteLease {
        // A wrap affects eviction recency only; bytes and source identities do
        // not change. Resetting the bounded cache avoids ambiguous old stamps.
        if tick == UInt64.max { pages.removeAll(); cachedBytes = 0; tick = 0 }
        tick += 1
        if var hit = pages[index] {
            hits = Self.add(hits, 1); hit.lastUse = tick; pages[index] = hit
            return hit.lease
        }
        misses = Self.add(misses, 1)
        let offset = index * limits.pageBytes
        let length = min(limits.pageBytes, fileBytes - offset)
        while length > limits.maximumCachedBytes - cachedBytes {
            guard evictOne() else { throw RoutingPageError.memoryLimit }
        }
        let reservation = try reserve(length, kind: .cache)
        var data = Data(count: length)
        #if canImport(Darwin)
        try data.withUnsafeMutableBytes { raw in
            var done = 0
            while done < length {
                guard !cancelled() else { throw RoutingPageError.cancelled }
                let n = Darwin.pread(descriptor, raw.baseAddress!.advanced(by: done),
                    length - done, off_t(offset + done))
                readCalls = Self.add(readCalls, 1)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw RoutingPageError.systemCall(errno)
                }
                guard n > 0 else { throw RoutingPageError.unexpectedEndOfFile }
                done += n; bytesRead = Self.add(bytesRead, UInt64(n))
            }
        }
        #else
        throw RoutingPageError.unsupportedPlatform
        #endif
        let lease = RoutingByteLease(storage: data, reservation: reservation)
        pages[index] = Page(lease: lease, lastUse: tick)
        cachedBytes += length
        return lease
    }

    private func verifyUnchanged() throws {
        #if canImport(Darwin)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw RoutingPageError.systemCall(errno) }
        guard info.st_size == originalSize,
              info.st_mtimespec.tv_sec == originalModified.tv_sec,
              info.st_mtimespec.tv_nsec == originalModified.tv_nsec,
              info.st_ctimespec.tv_sec == originalChanged.tv_sec,
              info.st_ctimespec.tv_nsec == originalChanged.tv_nsec else {
            pages.removeAll(); cachedBytes = 0
            throw RoutingPageError.sourceChanged
        }
        #else
        throw RoutingPageError.unsupportedPlatform
        #endif
    }

    private static func add(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (result, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : result
    }
}
