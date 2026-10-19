#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>

static int setup_failed(const char *operation)
{
    fprintf(stderr, "SETUP_FAILURE %s error=%lu\n", operation,
            (unsigned long)GetLastError());
    return 2;
}

int main(void)
{
    char root[128];
    snprintf(root, sizeof(root), "rename-win32-%lu-%llu",
             (unsigned long)GetCurrentProcessId(),
             (unsigned long long)GetTickCount64());
    if (!CreateDirectoryA(root, NULL) || !SetCurrentDirectoryA(root) ||
        !CreateDirectoryA("gcc", NULL) || !CreateDirectoryA("gcc/child", NULL))
        return setup_failed("directories");
    printf("Work directory: %s; operations=32; native Win32 only\n", root);
    fflush(stdout);

    for (int round = 1; round <= 100; ++round) {
        for (int operation = 1; operation <= 32; ++operation) {
            char path[128];
            snprintf(path, sizeof(path), "gcc/child/object-%d-%d", round, operation);
            HANDLE file = CreateFileA(path, GENERIC_WRITE,
                                     FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                                     NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
            if (file == INVALID_HANDLE_VALUE)
                return setup_failed("CreateFile");
            if (!CloseHandle(file))
                return setup_failed("CloseHandle");
        }
        const char *names[] = {"gcc", "stage1-gcc", "gcc"};
        for (int direction = 0; direction < 2; ++direction) {
            if (!MoveFileExA(names[direction], names[direction + 1], 0)) {
                DWORD error = GetLastError();
                fprintf(stderr, "RENAME_FAILURE %s -> %s round=%d error=%lu\n",
                        names[direction], names[direction + 1], round,
                        (unsigned long)error);
                return 1;
            }
        }
    }
    puts("NOT_REPRODUCED: 100 rounds after synchronous CloseHandle.");
    return 0;
}
