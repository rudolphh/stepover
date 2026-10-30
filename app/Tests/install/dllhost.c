/* For dll-check.sh: loads dsound.dll and says whether it got the stub beside it (native) or Wine's own. */
#include <windows.h>
#include <stdio.h>

int main(void)
{
    HMODULE m = LoadLibraryA("dsound.dll");
    printf("dllhost: %s\n", !m ? "load failed" : GetProcAddress(m, "StepoverStub") ? "native" : "builtin");
    return 0;
}
