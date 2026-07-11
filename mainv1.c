/* Wraps cmdline into correct syntax for pwsh.exe + code allowing calls to an exe (like wusa.exe) to be replaced by a function in profile.ps1
 *
 * This library is free software; you can redistribute it and/or modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License along with this library;
 * if not, write to the Free Software Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301, USA
 *
 * Legacy note: Cage and other deterministic consumers should use Synchro's
 * powershell-wrapper-for-wine as the Windows PowerShell compatibility provider.
 * This wrapper remains for the upstream-derived interactive installer path.
 *
 * Build: For fun code is changed from standard main(argc,*argv[]) to something like https://nullprogram.com/blog/2016/01/31/ and https://scorpiosoftware.net/2023/03/16/minimal-executables/)
 * https://gist.githubusercontent.com/pts/9ef2b1036d0b42508327559eeb2e0eb5/raw/971aeca2b1d0906ac67b68a4526bae58b67415be/tinygccpe.scr
 * echo 'SECTIONS { . = SIZEOF_HEADERS;  . = ALIGN(__section_alignment__);
   .idata __image_base__ + (__section_alignment__ < 0x1000 ? . : __section_alignment__) : { SORT(*)(.idata$2); SORT(*)(.idata$3);
     LONG (0); LONG (0); LONG (0); LONG (0); LONG (0); SORT(*)(.idata$4); __IAT_start__ = .; SORT(*)(.idata$5); __IAT_end__ = .; SORT(*)(.idata$6); SORT(*)(.idata$7); }
   .text BLOCK(__section_alignment__) : { *(.text) *(SORT(.text$*)) *(.text.*) *(.rdata) *(SORT(.rdata$*)) }  .reloc : { *(.reloc) } }' > linker.ld && x86_64-w64-mingw32-gcc -Oz -fno-asynchronous-unwind-tables -municode -Wall -Wextra -mno-stack-arg-probe -nostartfiles\
   -Wl,-gc-sections -Xlinker --stack=0x100000,0x100000 mainv1.c -nostdlib -lucrtbase -lkernel32 -lntdll -s -o powershell64.exe -Wl,--section-alignment,512,--file-alignment,512,-T,linker.ld && strip -R .reloc powershell64.exe
   i686-w64-mingw32-gcc -Oz -fno-asynchronous-unwind-tables -mno-stack-arg-probe -municode -Wall -Wextra -mno-stack-arg-probe -nostartfiles\
   -Wl,-gc-sections -Xlinker --stack=0x100000,0x100000 mainv1.c -nostdlib -lucrtbase -lkernel32 -lntdll -s -o powershell32.exe -Wl,--section-alignment,512,--file-alignment,512,-T,linker.ld && strip -R .reloc powershell32.exe
 */

#include <wchar.h>
#include <windows.h>
#include <winternl.h>

/* clbuf = incoming cmdline */
#define clbuf peb->ProcessParameters->CommandLine.Buffer
/* https://stackoverflow.com/questions/21880730/c-what-is-the-best-and-fastest-way-to-concatenate-strings; returns pointer to end of string */
static WCHAR* _wcscat(WCHAR* dest, const WCHAR* src) { while (*dest) dest++; while ((*dest++ = *src++)); return --dest; }
/* for e.g. -noprofile, -nologo , -mta etc */
static BOOL is_single_option(const WCHAR* s) { return !!wcschr(L"nNmMsS", s[1]); }
/* no new options may follow -c, -f , -e or - , (but not -ex(ecutionpolicy)! and -config for which a weak check is added) */
static BOOL is_last_option(const WCHAR* s) { return wcschr(L"cCfFeE\0", s[1]) ? (s[2] != L'x' && s[2] != L'X' && s[6] != L'g' && s[6] != L'G' ? 1 : 0) : 0; }
/* join strings with a space in between */
static WCHAR* join(WCHAR* string1, const WCHAR* string2) { return string2 ? _wcscat(_wcscat(string1, L" "), string2) : string1; }

static DWORD launch_child(LPWSTR command_line) {
    DWORD exitcode = ERROR_GEN_FAILURE;
    DWORD wait_result;
    STARTUPINFOW si = {0};
    PROCESS_INFORMATION pi = {0};

    si.cb = sizeof(si);
    if (!CreateProcessW(NULL, command_line, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi))
        return GetLastError();

    wait_result = WaitForSingleObject(pi.hProcess, INFINITE);
    if (wait_result == WAIT_OBJECT_0) {
        if (!GetExitCodeProcess(pi.hProcess, &exitcode))
            exitcode = GetLastError();
    }
    else if (wait_result == WAIT_FAILED) {
        exitcode = GetLastError();
    }

    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    return exitcode;
}

DWORD mainCRTStartup(PPEB peb) {
    wchar_t *file = peb->ProcessParameters->ImagePathName.Buffer;
    wchar_t *ptr;
    wchar_t *token = wcstok_s(file, L"\\", &ptr);
    wchar_t *cl = calloc(4095, sizeof(WCHAR));
    DWORD exitcode;

    if (!cl)
        return ERROR_NOT_ENOUGH_MEMORY;
    cl[0] = L'p'; /* cl = new outgoing cmdline */
    getenv("PS51") ? ((cl[1] = L's') && (cl[2] = L'5') && (cl[3] = L'1')) : ((cl[1] = L'w') && (cl[2] = L's') && (cl[3] = L'h'));

    WCHAR* cmd = (clbuf[0] == L'"') ? wcschr(clbuf + 1, L'"') : wcschr(clbuf, L' '); /* skip arg[0] to get the cmdline to be executed */
    if (cmd && clbuf[0] == L'"')
        cmd++;
    do { token = wcstok_s(NULL, L"\\", &ptr); } while (token && *ptr); /* get the filename */
    if (!token) {
        free(cl);
        return ERROR_BAD_PATHNAME;
    }
    wcstok_s(token, L".", &ptr);

    /* I can also act as a dummy program if my exe-name is not powershell, allows to replace a system exe (like wusa.exe, or any exe really) by a function in profile.ps1 */
    if (_wcsnicmp(token, L"Powershell", 10)) { /* note: set desired exitcode in the function in profile.ps1 */
        _wcscat(_wcscat(join(cl, L"-nop -c QPR."), token), cmd ? cmd : L""); /* execute it through pwsh so the profile can dispatch a replacement */
    }
    else {
        if (cmd && !_wcsnicmp(cmd + 1, L"-v", 2))
            cmd = (cmd = wcschr(++cmd, L' ')) ? wcschr(++cmd, L' ') : 0; /* skip incompatible version option, like '-version 3.0' */
        token = (cmd ? wcstok_s(cmd, L" ", &ptr) : 0); /* start breaking up cmdline to look for options */

        /* pwsh requires a command option '-c'; Windows PowerShell does not. */
        while (token) {
            if (token[0] == L'/') token[0] = L'-';

            if (token[0] != L'-' || is_last_option(token)) {
                if ((token[0] != L'-' && _waccess(token, 0)) || (token[0] == L'-' && !token[1]))
                    join(cl, L"-c");
                join(cl, token);
                join(cl, ptr);
                break;
            }

            if (_wcsnicmp(token, L"-nop -c QPR.", 4))
                join(cl, token);

            if (!is_single_option(token))
                join(cl, token = wcstok_s(NULL, L" ", &ptr));

            token = wcstok_s(NULL, L" ", &ptr);
        }
    }

    exitcode = launch_child(cl);
    free(cl);
    return exitcode;
}
