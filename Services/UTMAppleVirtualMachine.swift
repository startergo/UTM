//
// Copyright © 2021 osy. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import Combine
import Virtualization

@available(iOS, unavailable, message: "Apple Virtualization not available on iOS")
@available(macOS 11, *)
final class UTMAppleVirtualMachine: UTMVirtualMachine {
    struct Capabilities: UTMVirtualMachineCapabilities {
        var supportsProcessKill: Bool {
            false
        }
        
        var supportsSnapshots: Bool {
            false
        }
        
        var supportsScreenshots: Bool {
            true
        }
        
        var supportsDisposibleMode: Bool {
            false
        }
        
        var supportsRecoveryMode: Bool {
            true
        }
    }
    
    static let capabilities = Capabilities()
    
    private(set) var pathUrl: URL {
        didSet {
            if isScopedAccess {
                oldValue.stopAccessingSecurityScopedResource()
            }
            isScopedAccess = pathUrl.startAccessingSecurityScopedResource()
        }
    }
    
    private(set) var isShortcut: Bool = false
    
    let isRunningAsDisposible: Bool = false
    
    weak var delegate: (any UTMVirtualMachineDelegate)?
    
    var onConfigurationChange: (() -> Void)?
    
    var onStateChange: (() -> Void)?
    
    private(set) var config: UTMAppleConfiguration {
        willSet {
            onConfigurationChange?()
        }
    }
    
    private(set) var registryEntry: UTMRegistryEntry {
        willSet {
            onConfigurationChange?()
        }
    }
    
    private(set) var state: UTMVirtualMachineState = .stopped {
        willSet {
            onStateChange?()
        }
        
        didSet {
            delegate?.virtualMachine(self, didTransitionToState: state)
        }
    }
    
    private(set) var screenshot: PlatformImage? {
        willSet {
            onStateChange?()
        }
    }
    
    private var isScopedAccess: Bool = false
    
    private weak var screenshotTimer: Timer?
    
    private let vmQueue = DispatchQueue(label: "VZVirtualMachineQueue", qos: .userInteractive)
    
    /// This variable MUST be synchronized by `vmQueue`
    private(set) var apple: VZVirtualMachine?
    
    private var installProgress: Progress?
    
    private var progressObserver: NSKeyValueObservation?
    
    private var sharedDirectoriesChanged: AnyCancellable?
    
    weak var screenshotDelegate: UTMScreenshotProvider?
    
    private var activeResourceUrls: [URL] = []
    
    @MainActor required init(packageUrl: URL, configuration: UTMAppleConfiguration? = nil, isShortcut: Bool = false) throws {
        self.isScopedAccess = packageUrl.startAccessingSecurityScopedResource()
        // load configuration
        let config: UTMAppleConfiguration
        if configuration == nil {
            guard let appleConfig = try UTMAppleConfiguration.load(from: packageUrl) as? UTMAppleConfiguration else {
                throw UTMConfigurationError.invalidBackend
            }
            config = appleConfig
        } else {
            config = configuration!
        }
        self.config = config
        self.pathUrl = packageUrl
        self.isShortcut = isShortcut
        self.registryEntry = UTMRegistryEntry.empty
        self.registryEntry = loadRegistry()
        self.screenshot = loadScreenshot()
        updateConfigFromRegistry()
    }
    
    deinit {
        if isScopedAccess {
            pathUrl.stopAccessingSecurityScopedResource()
        }
    }
    
    @MainActor func reload(from packageUrl: URL?) throws {
        let packageUrl = packageUrl ?? pathUrl
        guard let newConfig = try UTMAppleConfiguration.load(from: packageUrl) as? UTMAppleConfiguration else {
            throw UTMConfigurationError.invalidBackend
        }
        config = newConfig
        pathUrl = packageUrl
        updateConfigFromRegistry()
    }
    
    private func _start(options: UTMVirtualMachineStartOptions) async throws {
        try await createAppleVM()
        let boot = await config.system.boot
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) -> Void in
            vmQueue.async {
                guard let apple = self.apple else {
                    continuation.resume(throwing: UTMAppleVirtualMachineError.operationNotAvailable)
                    return
                }
                #if os(macOS) && arch(arm64)
                if #available(macOS 13, *), boot.operatingSystem == .macOS {
                    let vzoptions = VZMacOSVirtualMachineStartOptions()
                    vzoptions.startUpFromMacOSRecovery = options.contains(.bootRecovery)
                    apple.start(options: vzoptions) { result in
                        if let result = result {
                            continuation.resume(with: .failure(result))
                        } else {
                            continuation.resume()
                        }
                    }
                    return
                }
                #endif
                apple.start { result in
                    continuation.resume(with: result)
                }
            }
        }
    }
    
    func start(options: UTMVirtualMachineStartOptions = []) async throws {
        guard state == .stopped else {
            return
        }
        state = .starting
        do {
            try await beginAccessingResources()
            try await _start(options: options)
            if #available(macOS 12, *) {
                Task { @MainActor in
                    sharedDirectoriesChanged = config.sharedDirectoriesPublisher.sink { [weak self] newShares in
                        guard let self = self else {
                            return
                        }
                        self.vmQueue.async {
                            self.updateSharedDirectories(with: newShares)
                        }
                    }
                }
            }
            state = .started
            if screenshotTimer == nil {
                screenshotTimer = startScreenshotTimer()
            }
        } catch {
            await stopAccesingResources()
            state = .stopped
            throw error
        }
    }
    
    private func _stop(usingMethod method: UTMVirtualMachineStopMethod) async throws {
        if method != .request, #available(macOS 12, *) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                vmQueue.async {
                    guard let apple = self.apple else {
                        continuation.resume() // already stopped
                        return
                    }
                    apple.stop { error in
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else {
                            self.guestDidStop(apple)
                            continuation.resume()
                        }
                    }
                }
            }
        } else {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                vmQueue.async {
                    do {
                        guard let apple = self.apple else {
                            continuation.resume() // already stopped
                            return
                        }
                        try apple.requestStop()
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
    
    func stop(usingMethod method: UTMVirtualMachineStopMethod = .request) async throws {
        if let installProgress = installProgress {
            installProgress.cancel()
            return
        }
        guard state == .started || state == .paused else {
            return
        }
        state = .stopping
        do {
            try await _stop(usingMethod: method)
            state = .stopped
        } catch {
            state = .stopped
            throw error
        }
    }
    
    private func _restart() async throws {
        guard #available(macOS 12, *) else {
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vmQueue.async {
                guard let apple = self.apple else {
                    continuation.resume(throwing: UTMAppleVirtualMachineError.operationNotAvailable)
                    return
                }
                apple.stop { error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        apple.start { result in
                            continuation.resume(with: result)
                        }
                    }
                }
            }
        }
    }
    
    func restart() async throws {
        guard state == .started || state == .paused else {
            return
        }
        state = .stopping
        do {
            try await _restart()
            state = .started
        } catch {
            state = .stopped
            throw error
        }
    }
    
    private func _pause() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vmQueue.async {
                guard let apple = self.apple else {
                    continuation.resume(throwing: UTMAppleVirtualMachineError.operationNotAvailable)
                    return
                }
                Task { @MainActor in
                    await self.takeScreenshot()
                    try? self.saveScreenshot()
                }
                apple.pause { result in
                    continuation.resume(with: result)
                }
            }
        }
    }
    
    func pause() async throws {
        guard state == .started else {
            return
        }
        state = .pausing
        do {
            try await _pause()
            state = .paused
        } catch {
            state = .stopped
            throw error
        }
    }
    
    func saveSnapshot(name: String? = nil) async throws {
        // FIXME: implement this
    }
    
    func deleteSnapshot(name: String? = nil) async throws {
        // FIXME: implement this
    }
    
    func restoreSnapshot(name: String? = nil) async throws {
        // FIXME: implement this
    }
    
    private func _resume() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vmQueue.async {
                guard let apple = self.apple else {
                    continuation.resume(throwing: UTMAppleVirtualMachineError.operationNotAvailable)
                    return
                }
                apple.resume { result in
                    continuation.resume(with: result)
                }
            }
        }
    }
    
    func resume() async throws {
        guard state == .paused else {
            return
        }
        state = .resuming
        do {
            try await _resume()
            state = .started
        } catch {
            state = .stopped
            throw error
        }
    }
    
    @discardableResult @MainActor
    func takeScreenshot() async -> Bool {
        screenshot = screenshotDelegate?.screenshot
        return true
    }
    
    @MainActor private func createAppleVM() throws {
        for i in config.serials.indices {
            let (fd, sfd, name) = try createPty()
            let terminalTtyHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            let slaveTtyHandle = FileHandle(fileDescriptor: sfd, closeOnDealloc: false)
            config.serials[i].fileHandleForReading = terminalTtyHandle
            config.serials[i].fileHandleForWriting = terminalTtyHandle
            let serialPort = UTMSerialPort(portNamed: name, readFileHandle: slaveTtyHandle, writeFileHandle: slaveTtyHandle, terminalFileHandle: terminalTtyHandle)
            config.serials[i].interface = serialPort
        }
        let vzConfig = try config.appleVZConfiguration()
        vmQueue.async { [self] in
            apple = VZVirtualMachine(configuration: vzConfig, queue: vmQueue)
            apple!.delegate = self
        }
    }
    
    @available(macOS 12, *)
    private func updateSharedDirectories(with newShares: [UTMAppleConfigurationSharedDirectory]) {
        guard let fsConfig = apple?.directorySharingDevices.first(where: { device in
            if let device = device as? VZVirtioFileSystemDevice {
                return device.tag == "share"
            } else {
                return false
            }
        }) as? VZVirtioFileSystemDevice else {
            return
        }
        fsConfig.share = UTMAppleConfigurationSharedDirectory.makeDirectoryShare(from: newShares)
    }
    
    @available(macOS 12, *)
    func installVM(with ipswUrl: URL) async throws {
        guard state == .stopped else {
            return
        }
        state = .starting
        do {
            _ = ipswUrl.startAccessingSecurityScopedResource()
            defer {
                ipswUrl.stopAccessingSecurityScopedResource()
            }
            try await createAppleVM()
            #if os(macOS) && arch(arm64)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                vmQueue.async {
                    guard let apple = self.apple else {
                        continuation.resume(throwing: UTMAppleVirtualMachineError.operationNotAvailable)
                        return
                    }
                    let installer = VZMacOSInstaller(virtualMachine: apple, restoringFromImageAt: ipswUrl)
                    self.progressObserver = installer.progress.observe(\.fractionCompleted, options: [.initial, .new]) { progress, change in
                        self.delegate?.virtualMachine(self, didUpdateInstallationProgress: progress.fractionCompleted)
                    }
                    self.installProgress = installer.progress
                    installer.install { result in
                        continuation.resume(with: result)
                    }
                }
            }
            state = .started
            progressObserver = nil
            installProgress = nil
            delegate?.virtualMachine(self, didCompleteInstallation: true)
            #else
            throw UTMAppleVirtualMachineError.operatingSystemInstallNotSupported
            #endif
        } catch {
            delegate?.virtualMachine(self, didCompleteInstallation: false)
            state = .stopped
            throw error
        }
    }
    
    // taken from https://github.com/evansm7/vftool/blob/main/vftool/main.m
    private func createPty() throws -> (Int32, Int32, String) {
        let errMsg = NSLocalizedString("Cannot create virtual terminal.", comment: "UTMAppleVirtualMachine")
        var mfd: Int32 = -1
        var sfd: Int32 = -1
        var cname = [CChar](repeating: 0, count: Int(PATH_MAX))
        var tos = termios()
        guard openpty(&mfd, &sfd, &cname, nil, nil) >= 0 else {
            logger.error("openpty failed: \(errno)")
            throw errMsg
        }
        
        guard tcgetattr(mfd, &tos) >= 0 else {
            logger.error("tcgetattr failed: \(errno)")
            throw errMsg
        }
        
        cfmakeraw(&tos)
        guard tcsetattr(mfd, TCSAFLUSH, &tos) >= 0 else {
            logger.error("tcsetattr failed: \(errno)")
            throw errMsg
        }
        
        let f = fcntl(mfd, F_GETFL)
        guard fcntl(mfd, F_SETFL, f | O_NONBLOCK) >= 0 else {
            logger.error("fnctl failed: \(errno)")
            throw errMsg
        }
        
        let name = String(cString: cname)
        logger.info("fd \(mfd) connected to \(name)")
        
        return (mfd, sfd, name)
    }
    
    @MainActor private func beginAccessingResources() throws {
        for i in config.drives.indices {
            let drive = config.drives[i]
            if let url = drive.imageURL, drive.isExternal {
                if url.startAccessingSecurityScopedResource() {
                    activeResourceUrls.append(url)
                } else {
                    config.drives[i].imageURL = nil
                    throw UTMAppleVirtualMachineError.cannotAccessResource(url)
                }
            }
        }
        for i in config.sharedDirectories.indices {
            let share = config.sharedDirectories[i]
            if let url = share.directoryURL {
                if url.startAccessingSecurityScopedResource() {
                    activeResourceUrls.append(url)
                } else {
                    config.sharedDirectories[i].directoryURL = nil
                    throw UTMAppleVirtualMachineError.cannotAccessResource(url)
                }
            }
        }
    }
    
    @MainActor private func stopAccesingResources() {
        for url in activeResourceUrls {
            url.stopAccessingSecurityScopedResource()
        }
        activeResourceUrls.removeAll()
    }
}

@available(macOS 11, *)
extension UTMAppleVirtualMachine: VZVirtualMachineDelegate {
    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        vmQueue.async { [self] in
            apple = nil
        }
        sharedDirectoriesChanged = nil
        Task { @MainActor in
            stopAccesingResources()
            for i in config.serials.indices {
                if let serialPort = config.serials[i].interface {
                    serialPort.close()
                    config.serials[i].interface = nil
                    config.serials[i].fileHandleForReading = nil
                    config.serials[i].fileHandleForWriting = nil
                }
            }
        }
        state = .stopped
    }
    
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        guestDidStop(virtualMachine)
        delegate?.virtualMachine(self, didErrorWithMessage: error.localizedDescription)
    }
    
    // fake methods to adhere to NSObjectProtocol
    
    func isEqual(_ object: Any?) -> Bool {
        self === object as? UTMAppleVirtualMachine
    }
    
    var hash: Int {
        0
    }
    
    var superclass: AnyClass? {
        nil
    }
    
    func `self`() -> Self {
        self
    }
    
    func perform(_ aSelector: Selector!) -> Unmanaged<AnyObject>! {
        nil
    }
    
    func perform(_ aSelector: Selector!, with object: Any!) -> Unmanaged<AnyObject>! {
        nil
    }
    
    func perform(_ aSelector: Selector!, with object1: Any!, with object2: Any!) -> Unmanaged<AnyObject>! {
        nil
    }
    
    func isProxy() -> Bool {
        false
    }
    
    func isKind(of aClass: AnyClass) -> Bool {
        false
    }
    
    func isMember(of aClass: AnyClass) -> Bool {
        false
    }
    
    func conforms(to aProtocol: Protocol) -> Bool {
        aProtocol is VZVirtualMachineDelegate
    }
    
    func responds(to aSelector: Selector!) -> Bool {
        if aSelector == #selector(VZVirtualMachineDelegate.guestDidStop(_:)) {
            return true
        }
        if aSelector == #selector(VZVirtualMachineDelegate.virtualMachine(_:didStopWithError:)) {
            return true
        }
        return false
    }
    
    var description: String {
        ""
    }
}

protocol UTMScreenshotProvider: AnyObject {
    var screenshot: PlatformImage? { get }
}

enum UTMAppleVirtualMachineError: Error {
    case cannotAccessResource(URL)
    case operatingSystemInstallNotSupported
    case operationNotAvailable
}

extension UTMAppleVirtualMachineError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .cannotAccessResource(let url):
            return String.localizedStringWithFormat(NSLocalizedString("Cannot access resource: %@", comment: "UTMAppleVirtualMachine"), url.path)
        case .operatingSystemInstallNotSupported:
            return NSLocalizedString("The operating system cannot be installed on this machine.", comment: "UTMAppleVirtualMachine")
        case .operationNotAvailable:
            return NSLocalizedString("The operation is not available.", comment: "UTMAppleVirtualMachine")
        }
    }
}

// MARK: - Registry access
extension UTMAppleVirtualMachine {
    @MainActor func updateRegistryFromConfig() async throws {
        // save a copy to not collide with updateConfigFromRegistry()
        let configShares = config.sharedDirectories
        let configDrives = config.drives
        try await updateRegistryBasics()
        registryEntry.sharedDirectories.removeAll(keepingCapacity: true)
        for sharedDirectory in configShares {
            if let url = sharedDirectory.directoryURL {
                _ = url.startAccessingSecurityScopedResource()
                let file = try UTMRegistryEntry.File(url: url, isReadOnly: sharedDirectory.isReadOnly)
                registryEntry.sharedDirectories.append(file)
                url.stopAccessingSecurityScopedResource()
            }
        }
        for drive in configDrives {
            if drive.isExternal, let url = drive.imageURL {
                _ = url.startAccessingSecurityScopedResource()
                let file = try UTMRegistryEntry.File(url: url, isReadOnly: drive.isReadOnly)
                registryEntry.externalDrives[drive.id] = file
                url.stopAccessingSecurityScopedResource()
            }
        }
        // remove any unreferenced drives
        registryEntry.externalDrives = registryEntry.externalDrives.filter({ element in
            configDrives.contains(where: { $0.id == element.key && $0.isExternal })
        })
        // save IPSW reference
        if let url = config.system.boot.macRecoveryIpswURL {
            _ = url.startAccessingSecurityScopedResource()
            registryEntry.macRecoveryIpsw = try UTMRegistryEntry.File(url: url, isReadOnly: true)
            url.stopAccessingSecurityScopedResource()
        }
    }
    
    @MainActor func updateConfigFromRegistry() {
        config.sharedDirectories = registryEntry.sharedDirectories.map({ UTMAppleConfigurationSharedDirectory(directoryURL: $0.url, isReadOnly: $0.isReadOnly )})
        for i in config.drives.indices {
            let id = config.drives[i].id
            if config.drives[i].isExternal {
                config.drives[i].imageURL = registryEntry.externalDrives[id]?.url
            }
        }
        if let file = registryEntry.macRecoveryIpsw {
            config.system.boot.macRecoveryIpswURL = file.url
        }
    }
    
    @MainActor func changeUuid(to uuid: UUID, name: String? = nil, copyingEntry entry: UTMRegistryEntry? = nil) {
        config.information.uuid = uuid
        if let name = name {
            config.information.name = name
        }
        registryEntry = UTMRegistry.shared.entry(for: self)
        if let entry = entry {
            registryEntry.update(copying: entry)
        }
    }
}

// MARK: - Non-asynchronous version (to be removed)

extension UTMAppleVirtualMachine {
    @available(macOS 12, *)
    func requestInstallVM(with url: URL) {
        Task {
            do {
                try await installVM(with: url)
            } catch {
                delegate?.virtualMachine(self, didErrorWithMessage: error.localizedDescription)
            }
        }
    }
}
