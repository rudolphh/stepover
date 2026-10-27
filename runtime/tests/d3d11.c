/* Direct3D 11 check for runtime/check-runtime.sh --metal: on a hidden 64x64 window, creates a device
 * and swap chain, clears the back buffer and presents one frame. Exits 0, or prints the failing call's
 * HRESULT and exits 1. Build: x86_64-w64-mingw32-gcc -O2 -o d3d11.exe d3d11.c -ld3d11 -ldxgi */
#define COBJMACROS
#include <initguid.h>
#include <windows.h>
#include <d3d11.h>
#include <stdio.h>

static int ok(HRESULT hr, const char *call)
{
    if (SUCCEEDED(hr)) return 1;
    printf("d3d11: %s failed: 0x%08lx\n", call, (unsigned long)hr);
    return 0;
}

int main(void)
{
    WNDCLASSA wc = {0};
    DXGI_SWAP_CHAIN_DESC desc = {0};
    ID3D11Device *device;
    ID3D11DeviceContext *context;
    IDXGISwapChain *swap;
    ID3D11Texture2D *back;
    ID3D11RenderTargetView *view;
    D3D_FEATURE_LEVEL level;
    const float color[4] = {0.0f, 0.5f, 1.0f, 1.0f};

    wc.lpfnWndProc = DefWindowProcA;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "stepover-d3d11";
    RegisterClassA(&wc);
    desc.OutputWindow = CreateWindowA("stepover-d3d11", "stepover-d3d11", WS_OVERLAPPEDWINDOW,
                                      0, 0, 64, 64, NULL, NULL, wc.hInstance, NULL);
    desc.BufferCount = 2;
    desc.BufferDesc.Width = 64;
    desc.BufferDesc.Height = 64;
    desc.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.SampleDesc.Count = 1;
    desc.Windowed = TRUE;
    desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;

    if (!ok(D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION,
                                          &desc, &swap, &device, &level, &context), "D3D11CreateDeviceAndSwapChain")) return 1;
    if (!ok(IDXGISwapChain_GetBuffer(swap, 0, &IID_ID3D11Texture2D, (void **)&back), "GetBuffer")) return 1;
    if (!ok(ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)back, NULL, &view), "CreateRenderTargetView")) return 1;
    ID3D11DeviceContext_ClearRenderTargetView(context, view, color);
    if (!ok(IDXGISwapChain_Present(swap, 0, 0), "Present")) return 1;
    printf("d3d11: ok (feature level 0x%x)\n", (unsigned)level);
    return 0;
}
