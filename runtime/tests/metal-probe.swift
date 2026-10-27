// Prints whether this Mac (or CI runner) has a usable Metal device, for runtime CI's spike:
// metal=<device name> and metal-queue=ok, or metal=none. Always exits 0.
import Metal

if let device = MTLCreateSystemDefaultDevice() {
    print("metal=\(device.name)")
    print(device.makeCommandQueue() != nil ? "metal-queue=ok" : "metal-queue=none")
} else {
    print("metal=none")
}
