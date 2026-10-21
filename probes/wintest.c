/* create a real top-level window, pump messages briefly, report what the driver did */
#include <windows.h>
#include <stdio.h>

static LRESULT CALLBACK proc(HWND h, UINT m, WPARAM w, LPARAM l)
{
    return DefWindowProcW(h, m, w, l);
}

int main(void)
{
    WNDCLASSW wc = {0};
    wc.lpfnWndProc = proc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"daeva_wintest";
    if (!RegisterClassW(&wc)) { printf("RegisterClass failed %lu\n", GetLastError()); return 1; }

    HWND hwnd = CreateWindowExW(0, wc.lpszClassName, L"daeva wintest", WS_OVERLAPPEDWINDOW,
                                100, 100, 320, 240, NULL, NULL, wc.hInstance, NULL);
    if (!hwnd) { printf("CreateWindowEx failed %lu\n", GetLastError()); return 1; }
    ShowWindow(hwnd, SW_SHOW);
    UpdateWindow(hwnd);

    DWORD end = GetTickCount() + 1500;
    MSG msg;
    while (GetTickCount() < end)
    {
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) DispatchMessageW(&msg);
        Sleep(10);
    }

    RECT rc;
    GetClientRect(hwnd, &rc);
    printf("hwnd=%p visible=%d client=%ldx%ld\n", (void *)hwnd, IsWindowVisible(hwnd),
           rc.right - rc.left, rc.bottom - rc.top);
    int ok = IsWindowVisible(hwnd) && rc.right > 0 && rc.bottom > 0;
    DestroyWindow(hwnd);
    printf("%s\n", ok ? "WINDOW OK" : "WINDOW FAIL");
    return ok ? 0 : 1;
}
