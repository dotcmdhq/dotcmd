#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

static HANDLE interrupt_event;
static DWORD interrupt_code;
enum SignalMode { ChildStartup, Controller, ControllerAfterWait };

static BOOL WINAPI ChildInterrupt(DWORD event) {
    if (event != CTRL_C_EVENT && event != CTRL_BREAK_EVENT) return FALSE;
    interrupt_code = event == CTRL_C_EVENT ? 130 : 131;
    SetEvent(interrupt_event);
    return TRUE;
}

static BOOL WINAPI IgnoreInterrupt(DWORD event) {
    return event == CTRL_C_EVENT || event == CTRL_BREAK_EVENT;
}

static bool Run(const wchar_t* binary, const wchar_t* launcher, const wchar_t* source,
                DWORD event, DWORD expected_code, const char* expected_output, SignalMode mode) {
    wchar_t command[32768];
    if (swprintf(command, sizeof(command) / sizeof(command[0]), L"\"%ls\" \"%ls\" --eval \"%ls\"",
                 binary, launcher, source) < 0) return false;
    SECURITY_ATTRIBUTES security = {sizeof(security), NULL, TRUE};
    HANDLE input = CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                               &security, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (input == INVALID_HANDLE_VALUE) return false;
    HANDLE read = NULL, write = NULL;
    if (!CreatePipe(&read, &write, &security, 0)) { CloseHandle(input); return false; }
    if (!SetHandleInformation(read, HANDLE_FLAG_INHERIT, 0)) {
        CloseHandle(input); CloseHandle(read); CloseHandle(write); return false;
    }
    STARTUPINFOW startup = {};
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESTDHANDLES;
    startup.hStdInput = input;
    startup.hStdOutput = startup.hStdError = write;
    PROCESS_INFORMATION process = {};
    bool started = CreateProcessW(binary, command, NULL, NULL, TRUE, 0, NULL, NULL, &startup, &process);
    CloseHandle(input);
    CloseHandle(write);
    if (!started) { CloseHandle(read); return false; }
    CloseHandle(process.hThread);

    char output[1024] = {};
    DWORD size = 0;
    ULONGLONG deadline = GetTickCount64() + 10000;
    bool ready = false;
    while (GetTickCount64() < deadline && size < sizeof(output) - 1) {
        DWORD available;
        if (!PeekNamedPipe(read, NULL, 0, NULL, &available, NULL)) break;
        if (!available) { Sleep(1); continue; }
        DWORD received;
        if (!ReadFile(read, output + size, 1, &received, NULL) || !received) break;
        size += received;
        if (output[size - 1] == '\n') { ready = true; break; }
    }
    // spawn is asynchronous; its child can publish readiness before the caller waits.
    if (mode == ControllerAfterWait) Sleep(100);
    bool signaled = ready && (mode == ChildStartup || GenerateConsoleCtrlEvent(event, 0));
    DWORD waited = WaitForSingleObject(process.hProcess, 10000);
    if (waited != WAIT_OBJECT_0) {
        TerminateProcess(process.hProcess, 99);
        WaitForSingleObject(process.hProcess, INFINITE);
    }
    DWORD code = 99;
    GetExitCodeProcess(process.hProcess, &code);
    while (size < sizeof(output) - 1) {
        DWORD received;
        if (!ReadFile(read, output + size, (DWORD)sizeof(output) - 1 - size, &received, NULL) || !received) break;
        size += received;
    }
    CloseHandle(read);
    CloseHandle(process.hProcess);
    bool passed = signaled && waited == WAIT_OBJECT_0 && code == expected_code
        && !strcmp(output, expected_output);
    if (!passed) fprintf(stderr, "console event %lu: exit %lu, output [%s]\n", event, code, output);
    return passed;
}

int wmain(int argc, wchar_t** argv) {
    if (argc == 2 && (!wcscmp(argv[1], L"--child") || !wcscmp(argv[1], L"--default")
        || !wcscmp(argv[1], L"--startup"))) {
        bool startup = !wcscmp(argv[1], L"--startup");
        bool cleanup = startup || !wcscmp(argv[1], L"--child");
        if (cleanup) {
            interrupt_event = CreateEventW(NULL, TRUE, FALSE, NULL);
            if (!interrupt_event) return 99;
            if (!SetConsoleCtrlHandler(ChildInterrupt, TRUE)) { CloseHandle(interrupt_event); return 99; }
        }
        printf("ready\n"); fflush(stdout);
        if (startup && !GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0)) { CloseHandle(interrupt_event); return 99; }
        if (!cleanup) { Sleep(10000); return 99; }
        if (WaitForSingleObject(interrupt_event, 10000) != WAIT_OBJECT_0) { CloseHandle(interrupt_event); return 99; }
        Sleep(100);
        printf("cleanup\n"); fflush(stdout);
        CloseHandle(interrupt_event);
        return (int)interrupt_code;
    }
    if (argc != 3) return 99;
    HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE), error = GetStdHandle(STD_ERROR_HANDLE);
    // Keep generated console events away from CTest and the user's shell.
    FreeConsole();
    if (!AllocConsole() || !SetConsoleCtrlHandler(NULL, FALSE)
        || !SetConsoleCtrlHandler(IgnoreInterrupt, TRUE)) return 99;
    SetStdHandle(STD_OUTPUT_HANDLE, output);
    SetStdHandle(STD_ERROR_HANDLE, error);
    wchar_t executable[32768];
    if (!GetModuleFileNameW(NULL, executable, sizeof(executable) / sizeof(executable[0]))
        || !SetEnvironmentVariableW(L"DOTCMD_INTERRUPT_CHILD", executable)
        || !SetEnvironmentVariableW(L"DOTCMD_INTERRUPT_LAUNCHER", argv[2])) return 99;

    bool passed = true;
    for (int mode = 0; mode < 2; ++mode) {
        for (DWORD event = CTRL_C_EVENT; event <= CTRL_BREAK_EVENT; ++event) {
            for (int cleanup = 0; cleanup < 2; ++cleanup) {
                wchar_t source[2048];
                swprintf(source, sizeof(source) / sizeof(source[0]),
                    L"local command = {os.getenv('DOTCMD_INTERRUPT_CHILD'), '%ls'}; "
                    L"local result; %ls; io.write('parent:', result.exit_code, '\\n')",
                    cleanup ? L"--child" : L"--default",
                    mode == 0 ? L"command.check = false; result = exec(command)"
                              : L"local process <close> = spawn(command); result = process:wait {check = false}");
                char expected[128];
                sprintf(expected, "ready\r\n%sparent:%lu\r\n", cleanup ? "cleanup\r\n" : "",
                        cleanup ? (event == CTRL_C_EVENT ? 130UL : 131UL) : 0xC000013AUL);
                if (!Run(argv[1], argv[2], source, event, 0, expected,
                         mode == 0 ? Controller : ControllerAfterWait)) passed = false;
            }
        }
    }
    const wchar_t* startup = L"local result = exec {os.getenv('DOTCMD_INTERRUPT_CHILD'), '--startup', "
        L"check = false}; io.write('parent:', result.exit_code, '\\n')";
    for (int i = 0; i < 25; ++i) {
        if (!Run(argv[1], argv[2], startup, CTRL_C_EVENT, 0,
                 "ready\r\ncleanup\r\nparent:130\r\n", ChildStartup)) passed = false;
    }
    for (int status = 0; status < 2; ++status) {
        wchar_t source[2048];
        swprintf(source, sizeof(source) / sizeof(source[0]),
            L"pcall(exec, {host.executable, os.getenv('DOTCMD_INTERRUPT_LAUNCHER'), "
            L"'--eval', 'error {exit_code=%d}'}); io.write('ready\\n'); io.flush(); while true do end",
            status ? 17 : 0);
        if (!Run(argv[1], argv[2], source, CTRL_C_EVENT, 0xC000013AUL, "ready\r\n", Controller)) passed = false;
    }
    FreeConsole();
    return passed ? 0 : 1;
}
