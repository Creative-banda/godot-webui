package com.godotwebui;

import android.content.Context;
import android.view.MotionEvent;
import android.webkit.WebView;

/**
 * Transparent full-screen WebView that can optionally let touches fall through to the
 * view underneath (the Godot render surface).
 *
 * In pass-through mode a gesture is only handled by the WebView when its initial pointer lands
 * inside one of the interactive rectangles reported by the page. Otherwise the event is
 * reported as unhandled so the parent offers it to the next sibling (Godot). Because Android
 * splits multi-touch per pointer, a second finger can still reach the WebView even if the first
 * finger went to the game.
 */
final class OverlayWebView extends WebView {
    private volatile boolean passThrough = false;
    /** Flat array of [left, top, right, bottom] groups in CSS pixels. */
    private volatile float[] regions = new float[0];
    private boolean capturing = false;

    OverlayWebView(Context context) {
        super(context);
    }

    void setPassThrough(boolean enabled) {
        passThrough = enabled;
    }

    void setRegions(float[] cssRects) {
        regions = cssRects;
    }

    private boolean hitsRegion(float xPx, float yPx) {
        float density = getResources().getDisplayMetrics().density;
        float x = xPx / density;
        float y = yPx / density;
        float[] r = regions;
        for (int i = 0; i + 3 < r.length; i += 4) {
            if (x >= r[i] && y >= r[i + 1] && x <= r[i + 2] && y <= r[i + 3]) {
                return true;
            }
        }
        return false;
    }

    @Override
    public boolean dispatchTouchEvent(MotionEvent event) {
        if (!passThrough) {
            return super.dispatchTouchEvent(event);
        }
        int action = event.getActionMasked();
        if (action == MotionEvent.ACTION_DOWN) {
            capturing = hitsRegion(event.getX(), event.getY());
            if (!capturing) {
                return false;
            }
        } else if (!capturing) {
            return false;
        }
        boolean handled = super.dispatchTouchEvent(event);
        if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) {
            capturing = false;
        }
        return handled;
    }
}
