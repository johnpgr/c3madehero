module main;

import win32;

bool running = true;
void* bitmap_memory;
BitmapInfo bitmap_info;
HBitmap bitmap_handle;
Hdc device_context;

fn void resizeDIBSection(int width, int height) {
	if (bitmap_handle) {
		win32::deleteObject(bitmap_handle);
	} 
	if (!device_context) {
		device_context = win32::createCompatibleDC(null);
	}

    bitmap_info.bmiHeader.biSize = BitmapInfoHeader::size;
	bitmap_info.bmiHeader.biWidth = width;
	bitmap_info.bmiHeader.biHeight = height;
	bitmap_info.bmiHeader.biPlanes = 1;
	bitmap_info.bmiHeader.biBitCount = 32;
	bitmap_info.bmiHeader.biCompression = (uint)BiCompression.BI_RGB;

    bitmap_handle = win32::createDIBSection(
        device_context, &bitmap_info,
        DibUsage.DIB_RGB_COLORS,
        &bitmap_memory,
        null, 0,
    );
}

fn void updateWindow(int x, int y, int width, int height) {
    win32::stretchDIBits(
        device_context,
        x, y, width, height,
        x, y, width, height,
        bitmap_memory, &bitmap_info,
        DibUsage.DIB_RGB_COLORS,
        RopCode.SRCCOPY,
    );
}

fn LResult mainWindowCallback(
    HWnd window,
    uint message,
    WParam w_param,
    LParam l_param,
) {
    LResult result = 0;

    switch(message) {
        case win32::WM_SIZE: {
            Rect client_rect;
            win32::getClientRect(window, &client_rect);
            int width = client_rect.right - client_rect.left;
            int height = client_rect.bottom - client_rect.top;
            resizeDIBSection(width, height);
        } break;
        case win32::WM_CLOSE: case win32::WM_DESTROY: {
            running = false;
        } break;
        case win32::WM_ACTIVATEAPP: {
            win32::outputDebugStringA("WM_ACTIVATEAPP\n");
        } break;
        case win32::WM_ERASEBKGND: {
            result = 1;
        } break; 
        case win32::WM_PAINT: {
            PaintStruct paint;
            Hdc hdc = win32::beginPaint(window, &paint);
            defer win32::endPaint(window, &paint);
            int width = paint.rcPaint.right - paint.rcPaint.left;
            int height = paint.rcPaint.bottom - paint.rcPaint.top;
            static RopCode rop = RopCode.WHITENESS;
            win32::patBlt(hdc, paint.rcPaint.left, paint.rcPaint.top, width, height, rop);
            if (rop == RopCode.WHITENESS) {
                rop = RopCode.BLACKNESS;
            } else {
                rop = RopCode.WHITENESS;
            }
        } break;
        default: {
            result = win32::defWindowProcA(window, message, w_param, l_param);
        } 
    }

    return result;
}


fn int main() @winmain {
    HInstance h_instance = win32::getModuleHandleA(null);

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
