// Stands in for a redistributable installer that never finishes under Wine (built as vc_redist.x64.exe).
#include <windows.h>

int main(void) { Sleep(INFINITE); return 0; }
