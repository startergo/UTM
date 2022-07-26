//
// Copyright © 2022 osy. All rights reserved.
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
import SwiftUI

struct VMDisplayHostedView: UIViewControllerRepresentable {
    internal class Coordinator: VMDisplayViewControllerDelegate {
        let vm: UTMQemuVirtualMachine
        let device: VMWindowState.Device
        @Binding var state: VMWindowState
        var vmStateCancellable: AnyCancellable?
        
        var vmState: UTMVMState {
            vm.state
        }
        
        var vmConfig: UTMQemuConfiguration! {
            vm.config.qemuConfig
        }
        
        var qemuInputLegacy: Bool {
            vmConfig.input.usbBusSupport == .disabled || vmConfig.qemu.hasPS2Controller
        }
        
        var qemuDisplayUpscaler: MTLSamplerMinMagFilter {
            vmConfig.displays[state.configIndex].upscalingFilter.metalSamplerMinMagFilter
        }
        
        var qemuDisplayDownscaler: MTLSamplerMinMagFilter {
            vmConfig.displays[state.configIndex].downscalingFilter.metalSamplerMinMagFilter
        }
        
        var qemuDisplayIsDynamicResolution: Bool {
            vmConfig.displays[state.configIndex].isDynamicResolution
        }
        
        var qemuDisplayIsNativeResolution: Bool {
            vmConfig.displays[state.configIndex].isNativeResolution
        }
        
        var qemuHasClipboardSharing: Bool {
            vmConfig.sharing.hasClipboardSharing
        }
        
        var qemuConsoleResizeCommand: String? {
            vmConfig.serials[state.configIndex].terminal?.resizeCommand
        }
        
        var isViewportChanged: Bool {
            get {
                state.isViewportChanged
            }
            
            set {
                state.isViewportChanged = newValue
            }
        }
        
        var displayOriginX: Float {
            get {
                state.displayOriginX
            }
            
            set {
                state.displayOriginX = newValue
            }
        }
        
        var displayOriginY: Float {
            get {
                state.displayOriginY
            }
            
            set {
                state.displayOriginY = newValue
            }
        }
        
        var displayScale: Float {
            get {
                state.displayScale
            }
            
            set {
                state.displayScale = newValue
            }
        }
        
        var displayViewSize: CGSize {
            get {
                state.displayViewSize
            }
            
            set {
                state.displayViewSize = newValue
            }
        }
        
        init(with vm: UTMQemuVirtualMachine, device: VMWindowState.Device, state: Binding<VMWindowState>) {
            self.vm = vm
            self.device = device
            self._state = state
        }
        
        func displayDidAssertUserInteraction() {
            state.isUserInteracting.toggle()
        }
        
        func displayDidAppear() {
            if vm.state == .vmStopped {
                vm.requestVmStart()
            }
        }
        
        func vmSaveState(onCompletion completion: @escaping (Error?) -> Void) {
            vm.vmSaveState(completion: completion)
        }
        
        func requestVmDeleteState() {
            vm.requestVmDeleteState()
        }
        
        func requestInputTablet(_ tablet: Bool) {
            vm.requestInputTablet(tablet)
        }
    }
    
    let vm: UTMQemuVirtualMachine
    let device: VMWindowState.Device
    
    @Binding var state: VMWindowState
    
    @EnvironmentObject private var session: VMSessionState
    
    func makeUIViewController(context: Context) -> VMDisplayViewController {
        let vc: VMDisplayViewController
        switch device {
        case .display(let display):
            vc = VMDisplayMetalViewController(display: display, input: session.primaryInput)
            vc.delegate = context.coordinator
        case .serial(let serial):
            vc = VMDisplayTerminalViewController(port: serial)
            vc.delegate = context.coordinator
        }
        context.coordinator.vmStateCancellable = session.$vmState.sink { vmState in
            switch vmState {
            case .vmStopped, .vmPaused:
                vc.enterSuspended(isBusy: false)
            case .vmPausing, .vmStopping, .vmStarting, .vmResuming:
                vc.enterSuspended(isBusy: true)
            case .vmStarted:
                vc.enterLive()
            @unknown default:
                break
            }
        }
        return vc
    }
    
    func updateUIViewController(_ uiViewController: VMDisplayViewController, context: Context) {
        if let vc = uiViewController as? VMDisplayMetalViewController {
            vc.vmInput = session.primaryInput
        }
        if state.isKeyboardShown != state.isKeyboardRequested {
            DispatchQueue.main.async {
                if state.isKeyboardRequested {
                    uiViewController.showKeyboard()
                } else {
                    uiViewController.hideKeyboard()
                }
            }
        }
        if state.isDrivesMenuShown {
            DispatchQueue.main.async {
                uiViewController.presentDrives(for: session.vm)
                state.isDrivesMenuShown = false
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(with: vm, device: device, state: $state)
    }
}