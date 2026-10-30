/* Console program for runtime/check-runtime.sh: watches a folder with ReadDirectoryChangesW, makes a file in it
 * and prints "notify: ok" once Wine reports it. Epic's launcher and its install helper talk through files this
 * way; a Wine built without inotify never reports a change, and installs stall. */
#include <windows.h>
#include <stdio.h>

int main(void)
{
    char dir[MAX_PATH], file[MAX_PATH + 16];
    DWORD buf[1024], got = 0;
    OVERLAPPED ov = {0};
    FILE_NOTIFY_INFORMATION *info = (FILE_NOTIFY_INFORMATION *)buf;
    HANDLE watch, f;

    GetTempPathA(sizeof(dir), dir);
    lstrcatA(dir, "stepover-notify");
    CreateDirectoryA(dir, NULL);
    snprintf(file, sizeof(file), "%s\\new.txt", dir);
    DeleteFileA(file);

    watch = CreateFileA(dir, FILE_LIST_DIRECTORY, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
                        OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED, NULL);
    if (watch == INVALID_HANDLE_VALUE)
    {
        printf("notify: can't open %s (error %lu)\n", dir, GetLastError());
        return 1;
    }
    ov.hEvent = CreateEventA(NULL, TRUE, FALSE, NULL);
    if (!ReadDirectoryChangesW(watch, buf, sizeof(buf), FALSE, FILE_NOTIFY_CHANGE_FILE_NAME, NULL, &ov, NULL))
    {
        printf("notify: ReadDirectoryChangesW failed (error %lu)\n", GetLastError());
        return 1;
    }

    f = CreateFileA(file, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
    if (f == INVALID_HANDLE_VALUE)
    {
        printf("notify: can't create %s (error %lu)\n", file, GetLastError());
        return 1;
    }
    CloseHandle(f);

    if (WaitForSingleObject(ov.hEvent, 5000) != WAIT_OBJECT_0)
    {
        puts("notify: Wine reported no folder change within 5 s (ReadDirectoryChangesW)");
        return 1;
    }
    if (!GetOverlappedResult(watch, &ov, &got, FALSE) || !got || info->Action != FILE_ACTION_ADDED ||
        info->FileNameLength != 7 * sizeof(WCHAR) || memcmp(info->FileName, L"new.txt", 7 * sizeof(WCHAR)))
    {
        printf("notify: a change came, but not the new file (%lu bytes)\n", got);
        return 1;
    }
    DeleteFileA(file);
    puts("notify: ok");
    return 0;
}
