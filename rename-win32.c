#define _WIN32_WINNT 0x0A00
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void fail(const char *operation)
{
    fprintf(stderr, "SETUP_FAILURE %s error=%lu\n", operation, (unsigned long)GetLastError());
    exit(2);
}

static void create_file(const char *path)
{
    HANDLE file = CreateFileA(path, GENERIC_WRITE,
                             FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                             NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE)
        fail("CreateFile");
    if (!CloseHandle(file))
        fail("CloseHandle");
}

static unsigned long long entries;

static void scan_directory(const char *path)
{
    char child[MAX_PATH];
    if (snprintf(child, sizeof(child), "%s/*", path) >= (int)sizeof(child)) {
        SetLastError(ERROR_FILENAME_EXCED_RANGE);
        fail("scanner path");
    }
    WIN32_FIND_DATAA item;
    HANDLE search = FindFirstFileA(child, &item);
    if (search == INVALID_HANDLE_VALUE) {
        DWORD error = GetLastError();
        if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND)
            return;
        fail("FindFirstFile");
    }
    do {
        if (!strcmp(item.cFileName, ".") || !strcmp(item.cFileName, ".."))
            continue;
        ++entries;
        if ((item.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) &&
            !(item.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
            if (snprintf(child, sizeof(child), "%s/%s", path, item.cFileName) >= (int)sizeof(child)) {
                SetLastError(ERROR_FILENAME_EXCED_RANGE);
                fail("scanner path");
            }
            scan_directory(child);
        }
    } while (FindNextFileA(search, &item));
    DWORD error = GetLastError();
    if (!FindClose(search))
        fail("FindClose");
    if (error != ERROR_NO_MORE_FILES) {
        SetLastError(error);
        fail("FindNextFile");
    }
}

static BOOL rename_directory(const char *source, const char *destination,
                             const char *method, const char **phase)
{
    if (!strcmp(method, "movefile")) {
        *phase = "MoveFileEx";
        return MoveFileExA(source, destination, 0);
    }
    union {
        FILE_RENAME_INFO info;
        BYTE space[sizeof(FILE_RENAME_INFO) + MAX_PATH * sizeof(WCHAR)];
    } buffer = {0};
    FILE_RENAME_INFO *info = &buffer.info;
    const WCHAR *target = !strcmp(destination, "gcc") ? L"gcc" : L"stage1-gcc";
    DWORD length = GetFullPathNameW(target, MAX_PATH, info->FileName, NULL);
    if (!length || length >= MAX_PATH) {
        SetLastError(ERROR_FILENAME_EXCED_RANGE);
        fail("rename target");
    }
    info->Flags = FILE_RENAME_FLAG_REPLACE_IF_EXISTS;
    if (!strcmp(method, "posix"))
        info->Flags |= FILE_RENAME_FLAG_POSIX_SEMANTICS;
    info->FileNameLength = length * (DWORD)sizeof(WCHAR);
    *phase = "open-source";
    HANDLE directory = CreateFileA(source, DELETE,
                                  FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                                  NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
    if (directory == INVALID_HANDLE_VALUE)
        return FALSE;
    *phase = "FileRenameInfoEx";
    BOOL renamed = SetFileInformationByHandle(directory, FileRenameInfoEx, info,
                                              (DWORD)sizeof(buffer));
    DWORD error = GetLastError();
    if (!CloseHandle(directory))
        fail("rename handle close");
    SetLastError(error);
    return renamed;
}

int main(int argc, char **argv)
{
    if (argc == 5 && !strcmp(argv[1], "scan")) {
        unsigned long long passes = 0;
        ULONGLONG start = GetTickCount64();
        while (GetFileAttributesA(argv[4]) == INVALID_FILE_ATTRIBUTES) {
            if (GetLastError() != ERROR_FILE_NOT_FOUND)
                fail("scanner stop check");
            scan_directory(argv[2]);
            if (++passes == 1)
                create_file(argv[3]);
            if (GetTickCount64() - start > 120000) {
                SetLastError(ERROR_TIMEOUT);
                fail("scanner timeout");
            }
        }
        printf("SCAN_RESULT passes=%llu entries=%llu\n", passes, entries);
        return 0;
    }
    const char *method = argc == 2 ? argv[1] : "movefile";
    if (argc > 2 || (strcmp(method, "movefile") && strcmp(method, "infoex") && strcmp(method, "posix"))) {
        fputs("Usage: rename-win32.exe [movefile|infoex|posix]\n", stderr);
        return 2;
    }
    char root[128], path[128];
    snprintf(root, sizeof(root), "rename-win32-%lu-%llu",
             (unsigned long)GetCurrentProcessId(), (unsigned long long)GetTickCount64());
    if (!CreateDirectoryA(root, NULL) || !SetCurrentDirectoryA(root) ||
        !CreateDirectoryA("gcc", NULL) || !CreateDirectoryA("gcc/child", NULL))
        fail("directories");
    printf("Work directory: %s; method=%s; attempts=100; files_per_attempt=32\n", root, method);
    fflush(stdout);
    const char *names[] = {"gcc", "stage1-gcc"};
    unsigned denied = 0, other = 0, current = 0;
    for (unsigned attempt = 1; attempt <= 100; ++attempt) {
        for (unsigned file = 1; file <= 32; ++file) {
            snprintf(path, sizeof(path), "%s/child/object-%u-%u", names[current], attempt, file);
            create_file(path);
        }
        const char *phase = NULL;
        if (rename_directory(names[current], names[1 - current], method, &phase)) {
            current = 1 - current;
            continue;
        }
        DWORD error = GetLastError();
        BOOL unsupported = !strcmp(phase, "FileRenameInfoEx") &&
            (error == ERROR_INVALID_FUNCTION || error == ERROR_NOT_SUPPORTED || error == ERROR_INVALID_PARAMETER);
        fprintf(stderr, "%s %s -> %s attempt=%u error=%lu method=%s phase=%s\n",
                unsupported ? "UNSUPPORTED" : "RENAME_FAILURE", names[current], names[1 - current],
                attempt, (unsigned long)error, method, phase);
        if (unsupported)
            return 3;
        if (error == ERROR_ACCESS_DENIED)
            ++denied;
        else
            ++other;
    }
    printf("RENAME_RESULT attempts=100 succeeded=%u denied=%u other=%u\n", 100 - denied - other, denied, other);
    return denied || other ? 1 : 0;
}
