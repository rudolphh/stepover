/* Direct3D 12 check for runtime/check-runtime.sh --metal: creates a device and a command queue, a DXGI
 * swap chain on a hidden 64x64 window, and presents one frame. Exits 0, or prints the failing call's
 * HRESULT and exits 1. Build: x86_64-w64-mingw32-gcc -O2 -o d3d12.exe d3d12.c -ld3d12 -ldxgi */
#define COBJMACROS
#include <initguid.h>
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <stdio.h>

static int ok(HRESULT hr, const char *call)
{
    if (SUCCEEDED(hr)) return 1;
    printf("d3d12: %s failed: 0x%08lx\n", call, (unsigned long)hr);
    return 0;
}

int main(void)
{
    WNDCLASSA wc = {0};
    D3D12_COMMAND_QUEUE_DESC queue_desc = {0};
    DXGI_SWAP_CHAIN_DESC1 desc = {0};
    ID3D12Device *device;
    ID3D12CommandQueue *queue;
    IDXGIFactory4 *factory;
    IDXGISwapChain1 *swap;
    HWND window;

    wc.lpfnWndProc = DefWindowProcA;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "stepover-d3d12";
    RegisterClassA(&wc);
    window = CreateWindowA("stepover-d3d12", "stepover-d3d12", WS_OVERLAPPEDWINDOW,
                           0, 0, 64, 64, NULL, NULL, wc.hInstance, NULL);

    if (!ok(D3D12CreateDevice(NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&device), "D3D12CreateDevice")) return 1;
    queue_desc.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
    if (!ok(ID3D12Device_CreateCommandQueue(device, &queue_desc, &IID_ID3D12CommandQueue, (void **)&queue), "CreateCommandQueue")) return 1;
    if (!ok(CreateDXGIFactory1(&IID_IDXGIFactory4, (void **)&factory), "CreateDXGIFactory1")) return 1;
    desc.Width = 64;
    desc.Height = 64;
    desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = 2;
    desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    if (!ok(IDXGIFactory4_CreateSwapChainForHwnd(factory, (IUnknown *)queue, window, &desc, NULL, NULL, &swap),
            "CreateSwapChainForHwnd")) return 1;
    if (!ok(IDXGISwapChain1_Present(swap, 0, 0), "Present")) return 1;
    printf("d3d12: ok\n");
    return 0;
}
