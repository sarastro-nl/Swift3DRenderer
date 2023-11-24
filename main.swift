#if os(macOS)
import AppKit
typealias PlatformController = NSViewController
typealias PlatformApplicationDelegate = NSApplicationDelegate
#else
import UIKit
typealias PlatformController = UIViewController
typealias PlatformApplicationDelegate = UIApplicationDelegate
#endif
import simd

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
    var mouse: simd_float2
}
#endif

class ViewController: PlatformController {
    var lastTime = 0.0
    var loopNr = 0
    let timeInterval = 1.0
    var debug = false
    var totalTime = 0.0
    
    let frameTarget = 1 / 60.0
    var frameSize = CGSize.zero
    
    var currentBufferIndex = 0
    var pixelBufferMemory: UnsafeMutablePointer<UInt32> = .allocate(capacity: 0)
    var pixelData = PixelData(pixelBuffer: .allocate(capacity: 0), width: 0, height: 0, bytesPerPixel: 4, bufferSize: 0)
    var input = Input(up: 0, down: 0, left: 0, right: 0, mouse: simd_float2.zero)
    
    var ciContext: CIContext!
    var commandQueue: MTLCommandQueue!
    var metalLayer: CAMetalLayer!
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let inputController = InputController()

#if CPP
    typealias updateAndRenderFunc = @convention(c) (UnsafePointer<PixelData>, UnsafePointer<Input>) -> Void
    var updateAndRender: updateAndRenderFunc!
#endif

    func RGB(_ r: Float, _ g: Float, _ b: Float) -> UInt32 {
        guard r < 256, g < 256, b < 256 else { fatalError() }
        return (256 * UInt32(r) + UInt32(g)) * 256 + UInt32(b)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
#if os(macOS)
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.finishLaunching()
        guard let screen = NSScreen.main else { fatalError() }
        let size = CGSize(width: 960, height: 540)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: (screen.frame.width - size.width) / 2 + 500, y: (screen.frame.height - size.height) / 2), size: size),
                          styleMask: [.resizable, .miniaturizable, .closable, .titled],
                          backing: .buffered, defer: false)
        window.minSize = CGSize(width: 200, height: 200)
        window.orderFrontRegardless()
        window.makeFirstResponder(self)
        guard let contentView = window.contentView else { fatalError() }
        metalLayer = CAMetalLayer()
        contentView.layer = metalLayer
        inputController.mouseInWindow = { [weak self] in
            self?.metalLayer.bounds.insetBy(dx: 10, dy: 10).contains(window.mouseLocationOutsideOfEventStream) == true
        }
#else
        let contentView = MetalView(frame: UIScreen.main.bounds)
        view.addSubview(contentView)
        guard let ml = contentView.layer as? CAMetalLayer else { fatalError() }
        metalLayer = ml
#endif

        guard let device = MTLCreateSystemDefaultDevice(),
              let cq = device.makeCommandQueue() else { fatalError() }
        commandQueue = cq
        metalLayer.framebufferOnly = false
        metalLayer.device = device
        metalLayer.contentsGravity = .center
        ciContext = CIContext(mtlDevice: device)

#if CPP
        guard let frameworkPath = Bundle.main.privateFrameworksPath,
              let handle = dlopen(frameworkPath + "/render_dylib.framework/render_dylib", RTLD_NOW),
              let sym = dlsym(handle, "updateAndRender") else { fatalError() }
        updateAndRender = unsafeBitCast(sym, to: updateAndRenderFunc.self)
#endif

#if os(macOS)
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: nil, queue: .main) { [unowned self] _ in
            self.resize()
        }
#endif
        resize()
        inputController.setupInput()
        lastTime = CACurrentMediaTime()
        _ = Timer.scheduledTimer(withTimeInterval: frameTarget, repeats: true) { [unowned self] _ in self.main() }
    }

    func main() {
        if CACurrentMediaTime() > lastTime + timeInterval { lastTime += timeInterval; debug = true }

        inputController.updateInput(&input)
        
        pixelData.pixelBuffer = pixelBufferMemory + currentBufferIndex * Int(pixelData.width * pixelData.height)
        currentBufferIndex = (currentBufferIndex + 1) % 2

        let mark = CACurrentMediaTime()
        updateAndRender(&pixelData, &input)
        totalTime += CACurrentMediaTime() - mark
        if debug { print(String(format: "%.2f%%", 6000 * totalTime / Double(loopNr))) }

        let ciImage = CIImage(bitmapData: Data(bytesNoCopy: pixelData.pixelBuffer, count: Int(pixelData.bufferSize), deallocator: .none),
                          bytesPerRow: Int(pixelData.bytesPerPixel * pixelData.width),
                          size: frameSize,
                          format: .BGRA8,
                          colorSpace: colorSpace)
        
        guard let currentDrawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        
        ciContext.render(ciImage,
                         to: currentDrawable.texture,
                         commandBuffer: commandBuffer,
                         bounds: CGRect(origin: .zero, size: frameSize),
                         colorSpace: colorSpace)
        
        commandBuffer.present(currentDrawable)
        commandBuffer.commit()
        
        loopNr += 1
        if debug {
            debug = false
            print("# loops: \(loopNr)")
            totalTime = 0
            loopNr = 0
        }
    }
    
    func resize() {
        frameSize = metalLayer.frame.size
        //        frameSize.width *= screen.backingScaleFactor
        //        frameSize.height *= screen.backingScaleFactor
        metalLayer.drawableSize = frameSize
        pixelData.width = Int32(frameSize.width)
        pixelData.height = Int32(frameSize.height)
        pixelData.bufferSize = pixelData.bytesPerPixel * pixelData.width * pixelData.height
        pixelBufferMemory = unsafeBitCast(realloc(pixelBufferMemory, 2 * Int(pixelData.bufferSize)), to: UnsafeMutablePointer<UInt32>.self)
    }
}

class AppDelegate: NSObject, PlatformApplicationDelegate {
#if os(macOS)
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
#else
    var window: UIWindow?
    func applicationDidFinishLaunching(_ application: UIApplication) {
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = ViewController()
        window?.makeKeyAndVisible()
    }
#endif
}
extension ViewController {
#if os(macOS)
    override func keyDown(with event: NSEvent) {}
    override func keyUp(with event: NSEvent) {}
#else
    override var prefersHomeIndicatorAutoHidden: Bool { true }
#endif
}
#if os(macOS)
let vc = ViewController()
_ = vc.view
let appDelegate = AppDelegate()
NSApplication.shared.delegate = appDelegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
#else
class MetalView: UIView { override class var layerClass: AnyClass { CAMetalLayer.self } }
UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))
#endif
