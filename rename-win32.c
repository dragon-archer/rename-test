#define _WIN32_WINNT 0x0A00
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

static BOOL rename_directory(const char *source, const WCHAR *destination,
                             const char *method, const char **phase)
{
    WCHAR target[MAX_PATH];
    DWORD length = GetFullPathNameW(destination, MAX_PATH, target, NULL);
    *phase = "resolve-target";
    if (!length)
        return FALSE;
    if (length >= MAX_PATH) {
        SetLastError(ERROR_FILENAME_EXCED_RANGE);
        return FALSE;
    }
    if (strcmp(method, "movefile") == 0) {
        const char *target_name = wcscmp(destination, L"gcc") == 0 ? "gcc" : "stage1-gcc";
        *phase = "MoveFileEx";
        return MoveFileExA(source, target_name, 0);
    }
    *phase = "open-source";
    HANDLE directory = CreateFileA(source, DELETE,
                                  FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                                  NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
    if (directory == INVALID_HANDLE_VALUE)
        return FALSE;
    DWORD size = (DWORD)(sizeof(FILE_RENAME_INFO) + (length + 1) * sizeof(WCHAR));
    FILE_RENAME_INFO *info = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, size);
    if (!info) {
        CloseHandle(directory);
        SetLastError(ERROR_NOT_ENOUGH_MEMORY);
        return FALSE;
    }
    info->Flags = FILE_RENAME_FLAG_REPLACE_IF_EXISTS;
    if (strcmp(method, "posix") == 0)
        info->Flags |= FILE_RENAME_FLAG_POSIX_SEMANTICS;
    info->FileNameLength = length * (DWORD)sizeof(WCHAR);
    memcpy(info->FileName, target, (length + 1) * sizeof(WCHAR));
    *phase = "FileRenameInfoEx";
    BOOL renamed = SetFileInformationByHandle(directory, FileRenameInfoEx, info, size);
    DWORD error = renamed ? ERROR_SUCCESS : GetLastError();
    HeapFree(GetProcessHeap(), 0, info);
    if (!CloseHandle(directory) && renamed) {
        *phase = "close-source";
        return FALSE;
    }
    SetLastError(error);
    return renamed;
}

static int setup_failed(const char *operation)
{
    fprintf(stderr, "SETUP_FAILURE %s error=%lu\n", operation,
            (unsigned long)GetLastError());
    return 2;
}

static BOOL scan_directory(const char *path, ULONGLONG *entries, ULONGLONG *vanished)
{
    char pattern[MAX_PATH];
    int length = snprintf(pattern, sizeof(pattern), "%s/*", path);
    if (length < 0 || length >= (int)sizeof(pattern)) {
        SetLastError(ERROR_FILENAME_EXCED_RANGE);
        return FALSE;
    }
    WIN32_FIND_DATAA item;
    HANDLE search = FindFirstFileA(pattern, &item);
    if (search == INVALID_HANDLE_VALUE) {
        DWORD error = GetLastError();
        if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND) {
            ++*vanished;
            return TRUE;
        }
        return FALSE;
    }
    BOOL succeeded = TRUE;
    DWORD error = ERROR_SUCCESS;
    do {
        if (strcmp(item.cFileName, ".") == 0 || strcmp(item.cFileName, "..") == 0)
            continue;
        ++*entries;
        if ((item.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) &&
            !(item.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
            char child[MAX_PATH];
            length = snprintf(child, sizeof(child), "%s/%s", path, item.cFileName);
            if (length < 0 || length >= (int)sizeof(child)) {
                error = ERROR_FILENAME_EXCED_RANGE;
                succeeded = FALSE;
                break;
            }
            if (!scan_directory(child, entries, vanished)) {
                error = GetLastError();
                succeeded = FALSE;
                break;
            }
        }
    } while (FindNextFileA(search, &item));
    if (succeeded) {
        error = GetLastError();
        succeeded = error == ERROR_NO_MORE_FILES;
    }
    if (!FindClose(search) && succeeded) {
        error = GetLastError();
        succeeded = FALSE;
    }
    SetLastError(error);
    return succeeded;
}

static int scan_until_stopped(const char *root, const char *ready, const char *stop)
{
    ULONGLONG passes = 0, entries = 0, vanished = 0;
    ULONGLONG start = GetTickCount64();
    while (GetFileAttributesA(stop) == INVALID_FILE_ATTRIBUTES) {
        if (GetLastError() != ERROR_FILE_NOT_FOUND)
            return setup_failed("scanner stop check");
        if (!scan_directory(root, &entries, &vanished))
            return setup_failed("scanner enumeration");
        if (++passes == 1) {
            HANDLE signal = CreateFileA(ready, GENERIC_WRITE, FILE_SHARE_READ, NULL,
                                        CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
            if (signal == INVALID_HANDLE_VALUE)
                return setup_failed("scanner ready");
            if (!CloseHandle(signal))
                return setup_failed("scanner ready close");
        }
        if (GetTickCount64() - start > 120000) {
            fputs("SETUP_FAILURE scanner exceeded 120 seconds\n", stderr);
            return 2;
        }
    }
    printf("SCAN_RESULT passes=%llu entries=%llu vanished=%llu\n", passes, entries, vanished);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc == 5 && strcmp(argv[1], "scan") == 0)
        return scan_until_stopped(argv[2], argv[3], argv[4]);
    const char *method = argc == 2 ? argv[1] : "movefile";
    if (argc > 2 || (strcmp(method, "movefile") != 0 &&
                     strcmp(method, "infoex") != 0 && strcmp(method, "posix") != 0)) {
        fputs("Usage: rename-win32.exe [movefile|infoex|posix]\n", stderr);
        return 2;
    }
    char root[128];
    snprintf(root, sizeof(root), "rename-win32-%lu-%llu",
             (unsigned long)GetCurrentProcessId(),
             (unsigned long long)GetTickCount64());
    if (!CreateDirectoryA(root, NULL) || !SetCurrentDirectoryA(root) ||
        !CreateDirectoryA("gcc", NULL) || !CreateDirectoryA("gcc/child", NULL))
        return setup_failed("directories");
    printf("Work directory: %s; operations=32; method=%s; native Win32 only\n", root, method);
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
        const WCHAR *destinations[] = {L"stage1-gcc", L"gcc"};
        for (int direction = 0; direction < 2; ++direction) {
            const char *phase = NULL;
            if (!rename_directory(names[direction], destinations[direction], method, &phase)) {
                DWORD error = GetLastError();
            BOOL unsupported = strcmp(method, "movefile") != 0 &&
                strcmp(phase, "FileRenameInfoEx") == 0 &&
                (error == ERROR_INVALID_FUNCTION || error == ERROR_NOT_SUPPORTED ||
                 error == ERROR_INVALID_PARAMETER);
            fprintf(stderr, "%s %s -> %s round=%d error=%lu method=%s phase=%s\n",
                unsupported ? "UNSUPPORTED" : "RENAME_FAILURE",
                        names[direction], names[direction + 1], round,
                (unsigned long)error, method, phase);
            return unsupported ? 3 : 1;
            }
        }
    }
    puts("NOT_REPRODUCED: 100 rounds after synchronous CloseHandle.");
    return 0;
}
