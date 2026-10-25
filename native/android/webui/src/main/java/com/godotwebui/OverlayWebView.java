package com.godotwebui;

import android.content.Context;
import android.content.res.Configuration;
import android.view.MotionEvent;
import android.webkit.WebView;

/**
 * Transparent full-screen WebView that can optionally let touches fall through to the
 * view underneath (the Godot render surface).
 *
 * In pass-through mode a gesture is only handled by the WebView when its initial pointer lands
 * inside one of the interactive rectangles reported by the page. Otherwise the event is
 * reported as unhandled so the parent offers it to the next sibling (Godot). Further fingers that
 * arrive while a gesture is held are kept by the WebView (observed on a device); captured
 * pointers are tracked per id so that one finger going up never ends the gestures of the fingers
 * still down.
 */
final class OverlayWebView extends WebView {
    private volatile boolean passThrough = false;
    /** Flat array of [left, top, right, bottom] groups in CSS pixels. */
    private volatile float[] regions = new float[0];
    /** Pointer ids whose gestures this view has taken over (one entry per concurrent finger). */
    private final boolean[] captured = new boolean[32];
    /** Physical pixels per CSS pixel. The page can be laid out larger than the device density (UI scale). */
    private volatile float pxPerCss = 0f;
    private Runnable onSizeChange;

    OverlayWebView(Context context) {
        super(context);
    }

    void setPassThrough(boolean enabled) {
        passThrough = enabled;
        if (!enabled) {
            java.util.Arrays.fill(captured, false);
        }
    }

    void setPxPerCss(float value) {
        pxPerCss = value;
    }

    void setOnSizeChange(Runnable callback) {
        onSizeChange = callback;
    }

    @Override
    protected void onSizeChanged(int w, int h, int oldw, int oldh) {
        super.onSizeChanged(w, h, oldw, oldh);
        if (onSizeChange != null) {
            onSizeChange.run();
        }
    }

    /** A density or font-scale change keeps the pixel size but changes the dp size, so the UI scale needs redoing. */
    @Override
    protected void onConfigurationChanged(Configuration newConfig) {
        super.onConfigurationChanged(newConfig);
        if (onSizeChange != null) {
            post(onSizeChange);  // after the new resources are in place
        }
    }

    void setRegions(float[] cssRects) {
        regions = cssRects;
    }

    private boolean hitsRegion(float xPx, float yPx) {
        float density = pxPerCss > 0f ? pxPerCss : getResources().getDisplayMetrics().density;
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
        int pointerId = event.getPointerId(event.getActionIndex());
        boolean validId = pointerId >= 0 && pointerId < captured.length;
        switch (action) {
            case MotionEvent.ACTION_DOWN:
            case MotionEvent.ACTION_POINTER_DOWN:
                if (anyCaptured()) {
                    // This view already holds a gesture; Android hands further fingers to it as
                    // well (observed on a device), so the page sees them. Track the new pointer so
                    // its release never ends the gestures of the fingers still down.
                    if (validId) {
                        captured[pointerId] = true;
                    }
                } else if (validId && hitsRegion(event.getX(event.getActionIndex()), event.getY(event.getActionIndex()))) {
                    captured[pointerId] = true;
                } else {
                    return false;
                }
                break;
            case MotionEvent.ACTION_MOVE:
            case MotionEvent.ACTION_SCROLL:
                if (!anyCaptured()) {
                    return false;
                }
                break;
            case MotionEvent.ACTION_UP:
            case MotionEvent.ACTION_POINTER_UP:
                // Clear only this pointer: with motion event splitting every finger is its own
                // stream, and releasing one finger must not cut off the others (the old single
                // flag did exactly that and left the first control stuck).
                if (!validId || !captured[pointerId]) {
                    return false;
                }
                captured[pointerId] = false;
                break;
            case MotionEvent.ACTION_CANCEL:
                if (!anyCaptured()) {
                    return false;
                }
                java.util.Arrays.fill(captured, false);
                break;
            default:
                if (!anyCaptured()) {
                    return false;
                }
                break;
        }
        return super.dispatchTouchEvent(event);
    }

    private boolean anyCaptured() {
        for (boolean c : captured) {
            if (c) {
                return true;
            }
        }
        return false;
    }
}
