/*
 * Deterministic Chocolatey finalizer for container/orchestrated Wine prefixes.
 *
 * This program does not install PowerShell and does not install a Windows
 * PowerShell wrapper. A verified pwsh engine and Synchro wrapper layer must
 * already exist. The caller must also stage the Chocolatey nupkg payload at:
 *
 *   %ProgramData%\tools\chocolateyInstall
 *
 * Required environment variables:
 *
 *   CFW_CONTAINER_BUILDER=1
 *   CFW_OFFLINE=1
 *   CFW_EXTERNAL_POWERSHELL=1
 *
 * Compile example:
 *
 *   x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -municode \
 *     compat/container-finalizer.c -ladvapi32 -o cfw-container-finalizer.exe
 */

#include <windows.h>
#include <wchar.h>
#include <string.h>

#define PATH_BUFFER 8192

static void log_stage(const char *message) {
    DWORD written = 0;
    HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
    if(output != NULL && output != INVALID_HANDLE_VALUE)
        WriteFile(output, message, (DWORD)strlen(message), &written, NULL);
}

static BOOL append_wide(wchar_t *destination, size_t capacity, const wchar_t *source) {
    size_t destination_length = wcslen(destination);
    size_t source_length = wcslen(source);
    size_t i;

    if(destination_length >= capacity || source_length >= capacity - destination_length)
        return FALSE;
    for(i = 0; i <= source_length; i++)
        destination[destination_length + i] = source[i];
    return TRUE;
}

static DWORD expand_path(const wchar_t *source, wchar_t *destination, DWORD capacity) {
    DWORD expanded = ExpandEnvironmentStringsW(source, destination, capacity);
    if(expanded == 0)
        return GetLastError();
    if(expanded > capacity)
        return ERROR_INSUFFICIENT_BUFFER;
    return ERROR_SUCCESS;
}

static DWORD require_directory(const wchar_t *path) {
    DWORD attributes = GetFileAttributesW(path);
    if(attributes == INVALID_FILE_ATTRIBUTES)
        return GetLastError();
    if(!(attributes & FILE_ATTRIBUTE_DIRECTORY) || (attributes & FILE_ATTRIBUTE_REPARSE_POINT))
        return ERROR_INVALID_DATA;
    return ERROR_SUCCESS;
}

static DWORD require_file(const wchar_t *path) {
    DWORD attributes = GetFileAttributesW(path);
    if(attributes == INVALID_FILE_ATTRIBUTES)
        return GetLastError();
    if((attributes & FILE_ATTRIBUTE_DIRECTORY) || (attributes & FILE_ATTRIBUTE_REPARSE_POINT))
        return ERROR_INVALID_DATA;
    return ERROR_SUCCESS;
}

static BOOL path_has_component(const wchar_t *path, const wchar_t *component) {
    const wchar_t *cursor = path;
    size_t component_length = wcslen(component);

    while(cursor && *cursor) {
        const wchar_t *end = wcschr(cursor, L';');
        size_t length = end ? (size_t)(end - cursor) : wcslen(cursor);

        while(length && (*cursor == L' ' || *cursor == L'\"')) {
            cursor++;
            length--;
        }
        while(length && (cursor[length - 1] == L' ' || cursor[length - 1] == L'\"' || cursor[length - 1] == L'\\'))
            length--;

        if(length == component_length && _wcsnicmp(cursor, component, length) == 0)
            return TRUE;
        cursor = end ? end + 1 : NULL;
    }
    return FALSE;
}

static DWORD validate_external_powershell(void) {
    wchar_t pwsh[MAX_PATH] = L"";
    wchar_t wrapper64[MAX_PATH] = L"";
    wchar_t wrapper32[MAX_PATH] = L"";
    DWORD result;

    if(!_wgetenv(L"CFW_CONTAINER_BUILDER") ||
       !_wgetenv(L"CFW_OFFLINE") ||
       !_wgetenv(L"CFW_EXTERNAL_POWERSHELL"))
        return ERROR_ACCESS_DENIED;

    log_stage("[cfw] stage=external-powershell-check-start\n");
    result = expand_path(L"%ProgramFiles%\\PowerShell\\7\\pwsh.exe", pwsh, MAX_PATH);
    if(result != ERROR_SUCCESS) return result;
    result = expand_path(L"%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", wrapper64, MAX_PATH);
    if(result != ERROR_SUCCESS) return result;
    result = expand_path(L"%SystemRoot%\\SysWOW64\\WindowsPowerShell\\v1.0\\powershell.exe", wrapper32, MAX_PATH);
    if(result != ERROR_SUCCESS) return result;

    result = require_file(pwsh);
    if(result != ERROR_SUCCESS) return result;
    result = require_file(wrapper64);
    if(result != ERROR_SUCCESS) return result;
    result = require_file(wrapper32);
    if(result != ERROR_SUCCESS) return result;

    log_stage("[cfw] stage=external-powershell-check-complete\n");
    return ERROR_SUCCESS;
}

static DWORD set_chocolatey_environment(const wchar_t *canonical_root, const wchar_t *canonical_bin) {
    wchar_t machine_path[PATH_BUFFER] = L"";
    wchar_t process_path[PATH_BUFFER] = L"";
    DWORD path_bytes = sizeof(machine_path);
    DWORD path_type = 0;
    DWORD result;
    DWORD expanded;
    HKEY environment;

    result = RegCreateKeyExW(
        HKEY_LOCAL_MACHINE,
        L"SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment",
        0,
        NULL,
        REG_OPTION_NON_VOLATILE,
        KEY_QUERY_VALUE | KEY_SET_VALUE,
        NULL,
        &environment,
        NULL
    );
    if(result != ERROR_SUCCESS)
        return result;

    result = RegQueryValueExW(environment, L"Path", NULL, &path_type, (BYTE*)machine_path, &path_bytes);
    if(result == ERROR_FILE_NOT_FOUND) {
        machine_path[0] = 0;
        path_type = REG_EXPAND_SZ;
    }
    else if(result != ERROR_SUCCESS || (path_type != REG_SZ && path_type != REG_EXPAND_SZ)) {
        RegCloseKey(environment);
        return result == ERROR_SUCCESS ? ERROR_INVALID_DATA : result;
    }
    machine_path[(sizeof(machine_path) / sizeof(machine_path[0])) - 1] = 0;

    if(!path_has_component(machine_path, canonical_bin)) {
        if(machine_path[0] && machine_path[wcslen(machine_path) - 1] != L';' &&
           !append_wide(machine_path, sizeof(machine_path) / sizeof(machine_path[0]), L";")) {
            RegCloseKey(environment);
            return ERROR_INSUFFICIENT_BUFFER;
        }
        if(!append_wide(machine_path, sizeof(machine_path) / sizeof(machine_path[0]), canonical_bin)) {
            RegCloseKey(environment);
            return ERROR_INSUFFICIENT_BUFFER;
        }
    }

    result = RegSetValueExW(
        environment,
        L"ChocolateyInstall",
        0,
        REG_SZ,
        (const BYTE*)canonical_root,
        (DWORD)((wcslen(canonical_root) + 1) * sizeof(wchar_t))
    );
    if(result == ERROR_SUCCESS)
        result = RegSetValueExW(
            environment,
            L"Path",
            0,
            path_type,
            (const BYTE*)machine_path,
            (DWORD)((wcslen(machine_path) + 1) * sizeof(wchar_t))
        );
    RegCloseKey(environment);
    if(result != ERROR_SUCCESS)
        return result;

    if(!SetEnvironmentVariableW(L"ChocolateyInstall", canonical_root))
        return GetLastError();
    if(path_type == REG_EXPAND_SZ) {
        expanded = ExpandEnvironmentStringsW(
            machine_path,
            process_path,
            sizeof(process_path) / sizeof(process_path[0])
        );
        if(expanded == 0)
            return GetLastError();
        if(expanded > sizeof(process_path) / sizeof(process_path[0]))
            return ERROR_INSUFFICIENT_BUFFER;
    }
    else if(!append_wide(process_path, sizeof(process_path) / sizeof(process_path[0]), machine_path)) {
        return ERROR_INSUFFICIENT_BUFFER;
    }
    if(!SetEnvironmentVariableW(L"Path", process_path))
        return GetLastError();
    return ERROR_SUCCESS;
}

static DWORD finalize_chocolatey(void) {
    wchar_t raw_root[MAX_PATH] = L"";
    wchar_t stage_root[MAX_PATH] = L"";
    wchar_t canonical_root[MAX_PATH] = L"";
    wchar_t source_choco[MAX_PATH] = L"";
    wchar_t stage_bin[MAX_PATH] = L"";
    wchar_t stage_choco[MAX_PATH] = L"";
    wchar_t stage_part[MAX_PATH] = L"";
    wchar_t canonical_bin[MAX_PATH] = L"";
    wchar_t canonical_choco[MAX_PATH] = L"";
    DWORD result;
    DWORD canonical_attributes;
    DWORD stage_attributes;

    result = expand_path(L"%ProgramData%\\tools\\chocolateyInstall", raw_root, MAX_PATH);
    if(result != ERROR_SUCCESS) return result;
    result = expand_path(L"%ProgramData%\\chocolatey.cfw-stage", stage_root, MAX_PATH);
    if(result != ERROR_SUCCESS) return result;
    result = expand_path(L"%ProgramData%\\chocolatey", canonical_root, MAX_PATH);
    if(result != ERROR_SUCCESS) return result;

    if(!append_wide(canonical_bin, MAX_PATH, canonical_root) ||
       !append_wide(canonical_bin, MAX_PATH, L"\\bin") ||
       !append_wide(canonical_choco, MAX_PATH, canonical_bin) ||
       !append_wide(canonical_choco, MAX_PATH, L"\\choco.exe"))
        return ERROR_INSUFFICIENT_BUFFER;

    canonical_attributes = GetFileAttributesW(canonical_root);
    if(canonical_attributes != INVALID_FILE_ATTRIBUTES) {
        if(!(canonical_attributes & FILE_ATTRIBUTE_DIRECTORY) ||
           (canonical_attributes & FILE_ATTRIBUTE_REPARSE_POINT))
            return ERROR_INVALID_DATA;
        result = require_file(canonical_choco);
        if(result != ERROR_SUCCESS)
            return ERROR_INVALID_DATA;
        log_stage("[cfw] stage=canonical-reconcile\n");
        return set_chocolatey_environment(canonical_root, canonical_bin);
    }
    result = GetLastError();
    if(result != ERROR_FILE_NOT_FOUND && result != ERROR_PATH_NOT_FOUND)
        return result;

    stage_attributes = GetFileAttributesW(stage_root);
    if(stage_attributes == INVALID_FILE_ATTRIBUTES) {
        result = GetLastError();
        if(result != ERROR_FILE_NOT_FOUND && result != ERROR_PATH_NOT_FOUND)
            return result;
        result = require_directory(raw_root);
        if(result != ERROR_SUCCESS) return result;
        log_stage("[cfw] stage=stage-create\n");
        if(!MoveFileExW(raw_root, stage_root, MOVEFILE_COPY_ALLOWED | MOVEFILE_WRITE_THROUGH))
            return GetLastError();
    }
    else if(!(stage_attributes & FILE_ATTRIBUTE_DIRECTORY) ||
            (stage_attributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
        return ERROR_INVALID_DATA;
    }
    else {
        log_stage("[cfw] stage=stage-resume\n");
    }

    if(!append_wide(source_choco, MAX_PATH, stage_root) ||
       !append_wide(source_choco, MAX_PATH, L"\\choco.exe") ||
       !append_wide(stage_bin, MAX_PATH, stage_root) ||
       !append_wide(stage_bin, MAX_PATH, L"\\bin") ||
       !append_wide(stage_choco, MAX_PATH, stage_bin) ||
       !append_wide(stage_choco, MAX_PATH, L"\\choco.exe") ||
       !append_wide(stage_part, MAX_PATH, stage_choco) ||
       !append_wide(stage_part, MAX_PATH, L".cfw-part"))
        return ERROR_INSUFFICIENT_BUFFER;

    result = require_file(source_choco);
    if(result != ERROR_SUCCESS) return result;
    if(!CreateDirectoryW(stage_bin, NULL) && GetLastError() != ERROR_ALREADY_EXISTS)
        return GetLastError();
    result = require_directory(stage_bin);
    if(result != ERROR_SUCCESS) return result;

    DeleteFileW(stage_part);
    if(!CopyFileW(source_choco, stage_part, FALSE))
        return GetLastError();
    result = require_file(stage_part);
    if(result != ERROR_SUCCESS) {
        DeleteFileW(stage_part);
        return result;
    }
    if(!MoveFileExW(stage_part, stage_choco, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        result = GetLastError();
        DeleteFileW(stage_part);
        return result;
    }
    result = require_file(stage_choco);
    if(result != ERROR_SUCCESS) return result;

    log_stage("[cfw] stage=canonical-promote\n");
    if(!MoveFileExW(stage_root, canonical_root, MOVEFILE_WRITE_THROUGH))
        return GetLastError();
    result = require_file(canonical_choco);
    if(result != ERROR_SUCCESS) return result;

    result = set_chocolatey_environment(canonical_root, canonical_bin);
    if(result != ERROR_SUCCESS) return result;
    log_stage("[cfw] stage=container-finalizer-complete\n");
    return ERROR_SUCCESS;
}

int wmain(void) {
    DWORD result;

    log_stage("[cfw] stage=container-finalizer-start\n");
    result = validate_external_powershell();
    if(result == ERROR_SUCCESS)
        result = finalize_chocolatey();
    return (int)result;
}
