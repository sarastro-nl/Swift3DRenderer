import Darwin
import AppKit

#if !CPP
struct PixelData {
    var pixelBuffer: UnsafeMutablePointer<UInt32>
    var width: Int32
    var height: Int32
    let bytesPerPixel: Int32
    var bufferSize: Int32
}

struct Input {
    var up: Float
    var down: Float
    var left: Float
    var right: Float
    var mouseX: Float
    var mouseY: Float
}
#endif

func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.finishLaunching()
    guard let screen = NSScreen.main else { fatalError() }
    let window = NSWindow(contentRect: CGRectInset(screen.frame, (screen.frame.width - 960) / 2, (screen.frame.height - 540) / 2), // 960 x 540
                          styleMask: [.resizable, .miniaturizable, .closable, .titled],
                          backing: .buffered, defer: false)
    window.minSize = CGSize(width: 200, height: 200)
    window.orderFrontRegardless()
    guard let device = MTLCreateSystemDefaultDevice(),
          let commandQueue = device.makeCommandQueue(),
          let contentView = window.contentView else { fatalError() }
    let metalLayer = CAMetalLayer()
    contentView.layer = metalLayer
    metalLayer.framebufferOnly = false
    metalLayer.device = device
    metalLayer.contentsGravity = .center
    let ciContext = CIContext(mtlDevice: device)
    let colorSpace = CGColorSpaceCreateDeviceRGB()

#if CPP
    guard let executablePath = Bundle.main.executablePath,
          let lastIndex = executablePath.lastIndex(of: "/"),
          let handle = dlopen(executablePath.prefix(upTo: lastIndex) + "/render-cpp/render.dylib", RTLD_NOW),
          let sym = dlsym(handle, "updateAndRender") else { fatalError() }
    typealias updateAndRenderFunc = @convention(c) (UnsafePointer<PixelData>, UnsafePointer<Input>) -> Void
    let updateAndRender = unsafeBitCast(sym, to: updateAndRenderFunc.self)
#endif
    var input = Input(up: 0, down: 0, left: 0, right: 0, mouseX: 0, mouseY: 0)

    var lastTime = CACurrentMediaTime()
    var loopNr = 0
    let timeInterval = 1.0
    
    var isRunning = true
    var logEnabled = false
    var mark = 0.0
    
    var mouseX: Float = 0
    var mouseY: Float = 0
    var cursorHidden = false

    let semaphore = DispatchSemaphore(value: 1)
    
    var currentBufferIndex = 0
    var pixelBufferMemory: UnsafeMutablePointer<UInt32> = .allocate(capacity: 0)
    var pixelData = PixelData(pixelBuffer: pixelBufferMemory, width: 0, height: 0, bytesPerPixel: 4, bufferSize: 0)
    var frameSize = CGSize.zero
    
    NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: nil, queue: .main) { _ in
        frameSize = contentView.frame.size
//        frameSize.width *= screen.backingScaleFactor
//        frameSize.height *= screen.backingScaleFactor
        metalLayer.drawableSize = frameSize
        pixelData.width = Int32(frameSize.width)
        pixelData.height = Int32(frameSize.height)
        pixelData.bufferSize = pixelData.bytesPerPixel * pixelData.width * pixelData.height
        pixelBufferMemory = unsafeBitCast(realloc(pixelBufferMemory, 2 * Int(pixelData.bufferSize)), to: UnsafeMutablePointer<UInt32>.self)
    }
    NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: nil)
    
    while (isRunning) {
        autoreleasepool {
            if CACurrentMediaTime() > lastTime + timeInterval {
                lastTime = CACurrentMediaTime()
                print("# loops: \(loopNr)")
                loopNr = 0
                logEnabled = true
            }
            while let event = app.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) {
                switch event.type {
                    case .keyUp, .keyDown:
                        let keyIsDown = event.type == .keyDown
                        let speed: Float = event.modifierFlags.contains(.shift) ? 2 : 1
                        switch event.characters(byApplyingModifiers: .shift) {
                            case "\u{1B}": isRunning = false // escape
                            case "A": input.left = keyIsDown ? speed : 0
                            case "D": input.right = keyIsDown ? speed : 0
                            case "W": input.up = keyIsDown ? speed : 0
                            case "S": input.down = keyIsDown ? speed : 0
                            default: break
                        }
                    case .leftMouseDown:
                        if cursorHidden {
                            cursorHidden = false
                            NSCursor.unhide()
                            CGAssociateMouseAndMouseCursorPosition(1)
                        } else if contentView.bounds.insetBy(dx: 5, dy: 5).contains(window.mouseLocationOutsideOfEventStream) {
                            cursorHidden = true
                            NSCursor.hide()
                            CGAssociateMouseAndMouseCursorPosition(0)
                        } else {
                            app.sendEvent(event)
                        }
                    case .mouseMoved:
                        if cursorHidden {
                            mouseX += Float(event.deltaX)
                            mouseY -= Float(event.deltaY)
                            input.mouseX = mouseX
                            input.mouseY = mouseY
                        }
                    default: app.sendEvent(event)
                }
            }
            pixelData.pixelBuffer = pixelBufferMemory + currentBufferIndex * Int(pixelData.width * pixelData.height)
            mark = CACurrentMediaTime()
            updateAndRender(&pixelData, &input)
            if logEnabled { print(String(format: "%.5f%%", 6000 * (CACurrentMediaTime() - mark))) }
            
            let ciImage = CIImage(bitmapData: Data(bytesNoCopy: pixelData.pixelBuffer, count: Int(pixelData.bufferSize), deallocator: .none),
                                  bytesPerRow: Int(pixelData.bytesPerPixel * pixelData.width),
                                  size: frameSize,
                                  format: .BGRA8,
                                  colorSpace: colorSpace)
            semaphore.wait()
            guard let currentDrawable = metalLayer.nextDrawable(),
                  let commandBuffer = commandQueue.makeCommandBuffer() else { return }
            ciContext.render(ciImage,
                             to: currentDrawable.texture,
                             commandBuffer: commandBuffer,
                             bounds: CGRect(origin: .zero, size: frameSize),
                             colorSpace: colorSpace)
            
            commandBuffer.present(currentDrawable)
            commandBuffer.addCompletedHandler {_ in semaphore.signal() }
            commandBuffer.commit()
            
            loopNr += 1
            logEnabled = false
            currentBufferIndex = (currentBufferIndex + 1) % 2
        }
    }
}

main()
