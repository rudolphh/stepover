// A stand-in game for the add-a-game checks: one window for 3 seconds. It imports d3d11.dll (never
// called) so Stepover's checks see a program that loads graphics.
#include <windows.h>
#include <d3d11.h>

static LRESULT CALLBACK proc(HWND w, UINT m, WPARAM wp, LPARAM lp) {
    if (m == WM_TIMER || m == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcW(w, m, wp, lp);
}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE prev, PWSTR cmd, int show) {
    if (cmd && cmd[0] == L'?') D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_NULL, NULL, 0, NULL, 0, D3D11_SDK_VERSION, NULL, NULL, NULL);
    WNDCLASSW wc = {0};
    wc.lpfnWndProc = proc; wc.hInstance = inst; wc.lpszClassName = L"TinyGame";
    RegisterClassW(&wc);
    HWND w = CreateWindowW(L"TinyGame", L"Tiny Game", WS_OVERLAPPEDWINDOW | WS_VISIBLE, 100, 100, 640, 360, NULL, NULL, inst, NULL);
    SetTimer(w, 1, 3000, NULL);
    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0) > 0) { TranslateMessage(&msg); DispatchMessageW(&msg); }
    return 0;
}
