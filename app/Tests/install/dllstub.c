/* For dll-check.sh: a stand-in dsound.dll whose only export marks it as the native copy. */
__declspec(dllexport) int StepoverStub(void) { return 1; }
