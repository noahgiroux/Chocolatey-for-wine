/* Installs PowerShell Core, net48, chocolatey and ConEmu
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301, USA
 *
 * Compile: // For fun I changed code from standard main(argc,*argv[]) to something like https://nullprogram.com/blog/2016/01/31/)
 * x86_64-w64-mingw32-gcc -O2 -fno-ident -fno-stack-protector -fomit-frame-pointer -fno-unwind-tables -fno-asynchronous-unwind-tables -mconsole -municode -mno-stack-arg-probe -Xlinker --stack=0x200000,0x200000\
  -nostdlib  -Wall -Wextra  -finline-limit=64 -Wl,-gc-sections  installer.c -lurlmon -lkernel32 -lucrtbase -luser32 -nostdlib -ladvapi32 -lntdll -lshell32 -lole32 -luuid -s -o ChoCinstaller_0.5a.753.exe && strip -R .reloc ChoCinstaller_0.5a.753.exe
 */
 
#include <stdio.h>
#include <string.h>
#include <windows.h>
#include <winternl.h>
#include <shlobj.h>
#include <knownfolders.h>

struct paths {
    wchar_t pathW[MAX_PATH];
    wchar_t setupcache[MAX_PATH];
    wchar_t *filenameW;
    wchar_t sevenzippath[MAX_PATH];
    wchar_t cache_dir[MAX_PATH];
    wchar_t argv[32];
};

    /* __attribute__((section(".text")))   __attribute__((aligned(8))) */ static const WCHAR url[6][165] = {L"http://download.windowsupdate.com/msdownload/update/software/crup/2010/06/windows6.1-kb958488-v6001-x64_a137e4f328f01146dfa75d7b5a576090dee948dc.msu",
             L"https://github.com/mozilla/fxc2/raw/master/dll/d3dcompiler_47.dll",
             L"https://github.com/mozilla/fxc2/raw/master/dll/d3dcompiler_47_32.dll",
             L"https://github.com/Maximus5/ConEmu/releases/download/v23.07.24/ConEmuPack.230724.7z",
             L"https://globalcdn.nuget.org/packages/sevenzipextractor.1.0.19.nupkg",
             L"https://catalog.s.download.windowsupdate.com/msdownload/update/software/updt/2009/11/windowsserver2003-kb968930-x64-eng_8ba702aa016e4c5aed581814647f4d55635eff5c.exe"};

static BOOL install_succeeded(DWORD exit_code) {
    return exit_code == ERROR_SUCCESS || exit_code == ERROR_SUCCESS_REBOOT_REQUIRED;
}

static void log_stage(const char *message) {
    DWORD written = 0;
    HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
    if(output != NULL && output != INVALID_HANDLE_VALUE)
        WriteFile(output, message, (DWORD)strlen(message), &written, NULL);
}

static DWORD run_process(LPCWSTR application, LPWSTR command_line, DWORD creation_flags) {
    STARTUPINFOW startup = {0};
    PROCESS_INFORMATION process = {0};
    DWORD exit_code = ERROR_GEN_FAILURE;

    startup.cb = sizeof(startup);
    if(!CreateProcessW(application, command_line, 0, 0, 0, creation_flags, 0, 0, &startup, &process))
        return GetLastError();
    if(WaitForSingleObject(process.hProcess, INFINITE) != WAIT_OBJECT_0)
        exit_code = ERROR_GEN_FAILURE;
    else if(!GetExitCodeProcess(process.hProcess, &exit_code))
        exit_code = GetLastError();
    CloseHandle(process.hProcess);
    CloseHandle(process.hThread);
    return exit_code;
}

static DWORD download_file(LPCWSTR source, LPCWSTR destination) {
    HRESULT result;
    if(_wgetenv(L"CFW_OFFLINE")) return ERROR_FILE_NOT_FOUND;
    result = URLDownloadToFileW(NULL, source, destination, 0, NULL);
    return SUCCEEDED(result) ? ERROR_SUCCESS : (DWORD)result;
}

static DWORD validate_canonical_choco(void) {
    wchar_t canonical_choco[MAX_PATH] = L"";
    if(!ExpandEnvironmentStringsW(L"%ProgramData%\\chocolatey\\bin\\choco.exe", canonical_choco, MAX_PATH))
        return GetLastError();
    return GetFileAttributesW(canonical_choco) == INVALID_FILE_ATTRIBUTES
        ? ERROR_FILE_NOT_FOUND
        : ERROR_SUCCESS;
}
 
DWORD WINAPI net48_install(void *ptr){
    wchar_t bufW[525]=L"", bufW1[MAX_PATH]=L"";
    DWORD exit_code;
    struct paths *p = (struct paths*)ptr;

    log_stage("[cfw] stage=net48-start\n");
    if(GetFileAttributesW(wcscat(wcscat(bufW1, p->cache_dir), L"v4.8.03761\\netfx_Full_x64.msi")) != INVALID_FILE_ATTRIBUTES)
        wcscat(wcscat(wcscat(bufW, L"msiexec.exe /i "), bufW1), L" MSIFASTINSTALL=2 DISABLEROLLBACK=1 /QN");
    else {
        wcscat(wcscat(wcscat(wcscat(wcscat(wcscat(bufW,p->sevenzippath), L" x -x!\"*.cab\" -x!\"netfx_c*\" -x!\"netfx_e*\" -x!\"NetFx4*\" -ms190M "), p->setupcache), L"\\ndp48-x86-x64-allos-enu.exe -o"), p->setupcache), L"\\v4.8.03761");
        exit_code = run_process(NULL, bufW, 0);
        if(!install_succeeded(exit_code)) return exit_code;

        bufW[0]=0;
        wcscat(wcscat(wcscat(bufW, L"msiexec.exe /i "), p->setupcache), L"\\v4.8.03761\\netfx_Full_x64.msi MSIFASTINSTALL=2 DISABLEROLLBACK=1 /QN");
    }

    exit_code = run_process(NULL, bufW, REALTIME_PRIORITY_CLASS);
    if(install_succeeded(exit_code)) log_stage("[cfw] stage=net48-complete\n");
    return install_succeeded(exit_code) ? ERROR_SUCCESS : exit_code;
}

DWORD WINAPI chocolatey_install(void *ptr){
    wchar_t dest[MAX_PATH], bufW[MAX_PATH]=L"", bufW1[525]=L"", url[] = L"https://packages.chocolatey.org/chocolatey.2.6.0.nupkg";
    DWORD exit_code;
    struct paths *p = (struct paths*)ptr;

    log_stage("[cfw] stage=chocolatey-payload-start\n");

    ExpandEnvironmentStringsW(L"%ProgramData%", dest, MAX_PATH + 1);

    if(GetFileAttributesW(wcscat(wcscat(bufW1, p->cache_dir), wcsrchr(url, L'/') + 1)) == INVALID_FILE_ATTRIBUTES) {
        bufW1[0] = 0;
        wcscat(wcscat(bufW, p->setupcache), wcsrchr(url, L'/') + 1);
        exit_code = download_file(url, bufW);
        if(exit_code != ERROR_SUCCESS) return exit_code;
    }
    else {
        wcscat(wcscat(bufW, p->cache_dir), wcsrchr(url, L'/') + 1);
    }

    bufW1[0] = 0;
    wcscat(wcscat(wcscat(wcscat(wcscat(bufW1, p->sevenzippath), L" x "), bufW), L" tools/chocolateyInstall/* -o"), dest);
    exit_code = run_process(NULL, bufW1, 0);
    if(install_succeeded(exit_code)) log_stage("[cfw] stage=chocolatey-payload-complete\n");
    return install_succeeded(exit_code) ? ERROR_SUCCESS : exit_code;
}

DWORD WINAPI pscore_install(void *ptr){
    wchar_t cmdlineW[1024]=L"", bufW[MAX_PATH] = L"", bufW1[MAX_PATH] = L"", pwsh_pathW[MAX_PATH];
    DWORD exit_code;
    int i, command_length;
    HKEY hKey;
    struct paths *p = (struct paths*)ptr;

    log_stage("[cfw] stage=powershell-start\n");

    ExpandEnvironmentStringsW(L"%ProgramFiles%\\Powershell\\7\\pwsh.exe", pwsh_pathW, MAX_PATH + 1);

    /* Download and install PowerShell before running the finalizer. */
    WCHAR versionW[] = L".....", msiW[MAX_PATH]=L"", downloadW[MAX_PATH]=L"";
    versionW[0] = p->filenameW[20]; versionW[2] = p->filenameW[21]; versionW[4] = p->filenameW[22];
    wcscat(wcscat(msiW, L"PowerShell-"), versionW);
    wcscat(msiW, L"-win-x64.msi");

    wchar_t *ps_url = wcscat(wcscat(wcscat(wcscat(downloadW, L"https://github.com/PowerShell/PowerShell/releases/download/v"), versionW), L"/"), msiW);
    if(GetFileAttributesW(wcscat(wcscat(bufW1, p->cache_dir), wcsrchr(ps_url, L'/') + 1)) == INVALID_FILE_ATTRIBUTES) {
        bufW1[0] = 0;
        wcscat(wcscat(bufW1, p->setupcache), wcsrchr(ps_url, L'/') + 1);
        exit_code = download_file(ps_url, bufW1);
        if(exit_code != ERROR_SUCCESS) return exit_code;
    }

    wcscat(wcscat(wcscat(bufW, L"msiexec.exe /i "), bufW1), L" DISABLE_TELEMETRY=1 ENABLE_PSREMOTING=1 REGISTER_MANIFEST=1 MSIFASTINSTALL=2 DISABLEROLLBACK=1 MSIDISABLEEEUI=1 /QN");
    exit_code = run_process(NULL, bufW, REALTIME_PRIORITY_CLASS);
    if(!install_succeeded(exit_code)) return exit_code;

    for(i=0; i<6; i++) {
        bufW[0]=0;
        if(GetFileAttributesW(wcscat(wcscat(bufW, p->cache_dir), wcsrchr(url[i], L'/') + 1)) == INVALID_FILE_ATTRIBUTES) {
            bufW[0]=0;
            wcscat(wcscat(bufW, p->setupcache), wcsrchr(url[i], L'/') + 1);
            exit_code = download_file(url[i], bufW);
            if(exit_code != ERROR_SUCCESS) return exit_code;
        }
    }

    WCHAR webview[] = L"--disable-dwm-composition --disable-gpu-sandbox --disable-d3d11  --disable-sandbox --use-angle=d3d9 --disable-gpu";
    if(RegCreateKeyExW(HKEY_CURRENT_USER, L"Environment", 0, NULL, REG_OPTION_NON_VOLATILE, KEY_SET_VALUE, NULL, &hKey, NULL) != ERROR_SUCCESS)
        return ERROR_CANTOPEN;
    exit_code = RegSetValueExW(hKey, L"PS7", 0, REG_SZ, (BYTE*)pwsh_pathW, sizeof(WCHAR)*wcslen(pwsh_pathW)+1);
    if(exit_code == ERROR_SUCCESS)
        exit_code = RegSetValueExW(hKey, L"WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS", 0, REG_SZ, (BYTE*)webview, sizeof(WCHAR)*wcslen(webview)+1);
    RegCloseKey(hKey);
    if(exit_code != ERROR_SUCCESS) return exit_code;

    command_length = swprintf(
        cmdlineW,
        sizeof(cmdlineW) / sizeof(cmdlineW[0]),
        L"\"%ls\" -NoLogo -NonInteractive -File \"%ls\\choc_install.ps1\" \"%ls\"%ls",
        pwsh_pathW,
        p->pathW,
        p->pathW,
        p->argv
    );
    if(command_length < 0 || command_length >= (int)(sizeof(cmdlineW) / sizeof(cmdlineW[0])))
        return ERROR_INSUFFICIENT_BUFFER;
    log_stage("[cfw] stage=finalizer-start\n");
    exit_code = run_process(pwsh_pathW, cmdlineW, 0);
    if(install_succeeded(exit_code)) log_stage("[cfw] stage=finalizer-complete\n");
    return install_succeeded(exit_code) ? ERROR_SUCCESS : exit_code;
}

DWORD WINAPI cdrive_install(void *ptr){
    wchar_t bufW[MAX_PATH]=L"";
    DWORD exit_code;
    struct paths *p = (struct paths*)ptr;
    log_stage("[cfw] stage=cdrive-start\n");
    wcscat(wcscat(wcscat(wcscat(bufW, p->sevenzippath), L" x -spf -aot "), p->pathW), L"\\c_drive.7z");

    exit_code = run_process(NULL, bufW, 0);
    if(install_succeeded(exit_code)) log_stage("[cfw] stage=cdrive-complete\n");
    return install_succeeded(exit_code) ? ERROR_SUCCESS : exit_code;
}

//__attribute__((externally_visible)) /* for -fwhole-program */
int mainCRTStartup(void) {
    wchar_t bufW[MAX_PATH] = L"", bufW1[MAX_PATH] = L"", **argv, *ptr, subdir[] = L"Microsoft.NET\\Framework64\\v4.0.30319\\SetupCache\\", *token = wcstok_s(subdir, L"\\", &ptr), rootdir[MAX_PATH];
    int i, argc;
    DWORD exit_code = ERROR_SUCCESS, thread_exit = ERROR_SUCCESS;
    HKEY hKey;
    HANDLE hThread[3] = {0};
    struct paths p = {0};

    log_stage("[cfw] stage=bootstrap-start\n");
    argv = CommandLineToArgvW(GetCommandLineW(), &argc);

    RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Wine\\DllOverrides", 0, NULL, REG_OPTION_NON_VOLATILE, KEY_SET_VALUE, NULL, &hKey, NULL);
    const WCHAR info[] = L""; RegSetValueExW(hKey, L"mscorsvc", 0, REG_SZ, (BYTE*) info, sizeof(info)); RegCloseKey(hKey);

    wchar_t* path = 0;
    if(_wgetenv(L"CFW_CACHE")) wcscat( wcscat( p.cache_dir, _wgetenv(L"CFW_CACHE") ), L"\\choc_install_files\\" );
    else {
        HRESULT hr = SHGetKnownFolderPath(&FOLDERID_Documents, 0, 0, &path);
        if(FAILED(hr)) ExitProcess((DWORD)hr);
        wcscat(wcscat(p.cache_dir, path), L"\\Chocolatey-for-wine\\choc_install_files\\");
        if(path) { CoTaskMemFree(path); }
    }

    ExpandEnvironmentStringsW(L"%SystemRoot%\\Microsoft.NET\\Framework64\\v4.0.30319\\SetupCache\\", p.setupcache, MAX_PATH + 1);
    ExpandEnvironmentStringsW(L"%SystemRoot%\\", rootdir, MAX_PATH + 1);
    
    if( GetFileAttributesW( wcscat( rootdir, L"Microsoft.NET\\" ) ) == INVALID_FILE_ATTRIBUTES) {
        CreateDirectoryW( rootdir, 0 );  
        while ( token = wcstok_s( NULL, L"\\", &ptr) ) CreateDirectoryW( wcscat( wcscat( rootdir, token ), L"\\" ), 0 );
    } else {
        CreateDirectoryW(p.setupcache, 0);
    }
    GetModuleFileNameW(NULL, p.pathW, MAX_PATH);
   
    p.filenameW = wcsdup(wcsrchr(p.pathW, L'\\')); p.pathW[ wcslen(p.pathW) - 26] = 0;
    wcscat(wcscat(p.sevenzippath, p.pathW), L"\\7z.exe");
    for(int i = 1; i < argc; i++) {
        if(_wcsicmp(argv[i], L"/s") == 0 && wcsstr(p.argv, L" /s") == NULL)
            wcscat(p.argv, L" /s");
        else if(_wcsicmp(argv[i], L"/q") == 0 && wcsstr(p.argv, L" /q") == NULL)
            wcscat(p.argv, L" /q");
    }

    wchar_t url[] = L"https://download.visualstudio.microsoft.com/download/pr/7afca223-55d2-470a-8edc-6a1739ae3252/abd170b4b0ec15ad0222a809b761a036/ndp48-x86-x64-allos-enu.exe";

    if(GetFileAttributesW(wcscat(wcscat(bufW1, p.cache_dir), L"\\v4.8.03761\\netfx_Full_x64.msi")) == INVALID_FILE_ATTRIBUTES) {
        wchar_t cached_dotnet[MAX_PATH] = L"";
        wchar_t *dotnet_name = wcsrchr(url, L'/') + 1;
        wcscat(wcscat(cached_dotnet, p.cache_dir), dotnet_name);
        wcscat(wcscat(bufW, p.setupcache), dotnet_name);
        if(GetFileAttributesW(cached_dotnet) != INVALID_FILE_ATTRIBUTES) {
            if(!CopyFileW(cached_dotnet, bufW, FALSE)) ExitProcess(GetLastError());
        }
        else {
            exit_code = download_file(url, bufW);
            if(exit_code != ERROR_SUCCESS) ExitProcess(exit_code);
        }
    }

    /* Prerequisites may run concurrently, but finalization must wait for all. */
    hThread[0] = CreateThread(NULL, 0, net48_install, &p, 0, 0);
    hThread[1] = CreateThread(NULL, 0, chocolatey_install, &p, 0, 0);
    hThread[2] = CreateThread(NULL, 0, cdrive_install, &p, 0, 0);
    for(i=0; i<3; i++) {
        if(!hThread[i]) {
            exit_code = GetLastError();
            for(int j=0; j<3; j++) {
                if(hThread[j]) {
                    WaitForSingleObject(hThread[j], INFINITE);
                    CloseHandle(hThread[j]);
                }
            }
            ExitProcess(exit_code);
        }
    }
    SetThreadPriority(hThread[0], THREAD_PRIORITY_TIME_CRITICAL);
    if(WaitForMultipleObjects(3, hThread, TRUE, INFINITE) != WAIT_OBJECT_0)
        exit_code = ERROR_GEN_FAILURE;
    for(i=0; i<3; i++) {
        if(!GetExitCodeThread(hThread[i], &thread_exit) && exit_code == ERROR_SUCCESS)
            exit_code = GetLastError();
        else if(thread_exit != ERROR_SUCCESS && exit_code == ERROR_SUCCESS)
            exit_code = thread_exit;
        CloseHandle(hThread[i]);
    }

    if(exit_code == ERROR_SUCCESS) {
        log_stage("[cfw] stage=prerequisites-complete\n");
        exit_code = pscore_install(&p);
    }
    if(exit_code == ERROR_SUCCESS) {
        log_stage("[cfw] stage=canonical-check\n");
        exit_code = validate_canonical_choco();
    }
    if(exit_code == ERROR_SUCCESS)
        log_stage("[cfw] stage=bootstrap-complete\n");
    ExitProcess(exit_code);
}
