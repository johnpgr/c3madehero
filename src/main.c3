module main;

import win32;

bool running = true;

fn LResult mainWindowCallback(
    HWnd window_handle,
    uint message,
    WParam w_param,
    LParam l_param,
) {
    LResult result = 0;

    switch(message) {
    case win32::WM_SIZE:
        win32::outputDebugStringA("WM_SIZE\n");
        break;
    case win32::WM_CLOSE:
    case win32::WM_DESTROY:
        running = false;
        break;
    case win32::WM_ACTIVATEAPP:
        win32::outputDebugStringA("WM_ACTIVATEAPP\n");
        break;
    case win32::WM_ERASEBKGND:
        return 1;
    case win32::WM_PAINT:
        PaintStruct paint;
        Hdc hdc = win32::beginPaint(window_handle, &paint);
        defer win32::endPaint(window_handle, &paint);
        int width = paint.rcPaint.right - paint.rcPaint.left;
        int height = paint.rcPaint.bottom - paint.rcPaint.top;
        static RopCode rop = RopCode.WHITENESS;
        win32::patBlt(hdc, paint.rcPaint.left, paint.rcPaint.top, width, height, rop);
        if (rop == RopCode.WHITENESS) {
            rop = RopCode.BLACKNESS;
        } else {
            rop = RopCode.WHITENESS;
        }
        break;
    default:
        result = win32::defWindowProcA(window_handle, message, w_param, l_param);
    }

    return result;
}

fn int main() {
    HModule h_instance = win32::getModuleHandleW(null);
    WndClassA window_class = {
        .style = WndClassStyles.CS_OWNDC | WndClassStyles.CS_HREDRAW | WndClassStyles.CS_VREDRAW,
        .lpfnWndProc = &mainWindowCallback,
        .hInstance = h_instance,
        .lpszClassName = "C3MadeHeroWindowClass",
    };

    if (win32::registerClassA(&window_class) == 0) {
        win32::outputDebugStringA("Failed to register window_class");
        return -1;
    };

    win32::createWindowExA(
        (WindowExStyle)0,
        window_class.lpszClassName,
        "C3Made Hero",
        WindowStyle.WS_OVERLAPPEDWINDOW | WindowStyle.WS_VISIBLE,
        win32::CW_USEDEFAULT,
        win32::CW_USEDEFAULT,
        win32::CW_USEDEFAULT,
        win32::CW_USEDEFAULT,
        null,
        null,
        h_instance,
        null,
    );


    Msg message;
    while (running) {
        Bool message_result = win32::getMessageA(&message, null, 0, 0);
        if (message_result < 0) {
            continue;
        }

        win32::translateMessage(&message);
        win32::dispatchMessageA(&message);
    }

    return 0;
}
