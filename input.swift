import GameController
import simd

class InputController {
#if os(macOS)
    var mouse = simd_float2.zero
    var keys: [Bool] = Array(repeating: false, count: 1024)
    var cursorHidden = false
    var mouseInWindow: (() -> Bool)?
#else
    var leftControllerDelta = simd_float2.zero
    var rightControllerDelta = simd_float2.zero
    var controller: GCVirtualController?
#endif

    func setupInput() {
#if os(macOS)
        NotificationCenter.default.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: nil, using: keyboardDidConnect)
        NotificationCenter.default.addObserver(forName: .GCMouseDidConnect, object: nil, queue: nil, using: mouseDidConnect)
#else
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: nil, using: controllerDidConnect)
        let config = GCVirtualController.Configuration()
        config.elements = [GCInputLeftThumbstick, GCInputRightThumbstick]
        controller = GCVirtualController(configuration: config)
        controller?.connect()
#endif
    }
    
#if os(macOS)
    func keyboardDidConnect(notification: Notification) {
        guard let keyboard = notification.object as? GCKeyboard,
              let keyboardInput = keyboard.keyboardInput else { return }
        keyboardInput.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
            self?.keys[keyCode.rawValue] = pressed
        }
    }
    
    func mouseDidConnect(notification: Notification) {
        guard let mouse = notification.object as? GCMouse,
              let mouseInput = mouse.mouseInput else { return }
        mouseInput.mouseMovedHandler = { [weak self] _, deltaX, deltaY in
            if self?.cursorHidden == true {
                self?.mouse.x += deltaX
                self?.mouse.y += deltaY
            }
        }
        mouseInput.leftButton.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed {
                if self?.cursorHidden == true {
                    self?.cursorHidden = false
                    NSCursor.unhide()
                    CGAssociateMouseAndMouseCursorPosition(1)
                } else if self?.mouseInWindow?() == true {
                    self?.cursorHidden = true
                    NSCursor.hide()
                    CGAssociateMouseAndMouseCursorPosition(0)
                }
            }
        }
    }
#else
    func controllerDidConnect(notification: Notification) {
        guard let controller = notification.object as? GCController else { return }
        for ts in [GCInputLeftThumbstick, GCInputRightThumbstick] {
            controller.physicalInputProfile.dpads[ts]?.valueChangedHandler = { [weak self] pad, deltaX, deltaY in
                if pad.localizedName == GCInputLeftThumbstick {
                    self?.leftControllerDelta.x = deltaX
                    self?.leftControllerDelta.y = deltaY
                } else {
                    self?.rightControllerDelta.x = deltaX
                    self?.rightControllerDelta.y = deltaY
                }
            }
        }
    }
#endif
    
    func updateInput(_ input: inout Input) {
#if os(macOS)
        if keys[GCKeyCode.escape.rawValue] { NSApplication.shared.terminate(nil) }
        let speed: Float = keys[GCKeyCode.leftShift.rawValue] || keys[GCKeyCode.rightShift.rawValue] ? 2 : 1
        input.left = keys[GCKeyCode.keyA.rawValue] ? speed : 0
        input.right = keys[GCKeyCode.keyD.rawValue] ? speed : 0
        input.up = keys[GCKeyCode.keyW.rawValue] ? speed : 0
        input.down = keys[GCKeyCode.keyS.rawValue] ? speed : 0
        if cursorHidden {
            input.mouse = mouse
        }
#else
        input.left = leftControllerDelta.x > 0 ? 0 : -leftControllerDelta.x
        input.right = leftControllerDelta.x > 0 ? leftControllerDelta.x : 0
        input.up = leftControllerDelta.y > 0 ? leftControllerDelta.y : 0
        input.down = leftControllerDelta.y > 0 ? 0 : -leftControllerDelta.y
        input.mouse += 6 * rightControllerDelta
#endif
    }
}
