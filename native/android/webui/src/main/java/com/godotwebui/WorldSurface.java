package com.godotwebui;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.PixelFormat;
import android.media.Image;
import android.media.ImageReader;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.view.InputDevice;
import android.view.MotionEvent;
import android.view.Surface;
import android.view.View;
import android.webkit.ConsoleMessage;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;

import androidx.webkit.WebMessageCompat;
import androidx.webkit.WebViewAssetLoader;
import androidx.webkit.WebViewCompat;

import org.json.JSONObject;

import java.io.File;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.util.Collections;
import java.util.Set;

/**
 * A world-space page: an ordinary WebView that is attached to the window but kept off screen (it is never shown), drawn
 * into a pixel buffer at a modest rate and handed to Godot, which puts it on a 3D surface as a texture.
 *
 * Two ways of drawing it are implemented so they can be measured against each other on a device:
 *  - MODE_HARDWARE: the view draws into the Surface of an ImageReader through lockHardwareCanvas() (the technique
 *    Flutter's texture platform views use), then the frame is read from the ImageReader.
 *  - MODE_SOFTWARE: the view draws into a software Bitmap canvas. Chromium documents this path as deprecated, slow and
 *    without video or WebGL, so it is only the fallback.
 *
 * The page uses the same bridge as the overlay (window.Godot, same script), with window.__godotSurface set to its id.
 * Input is injected as touch events straight into the view; no touch ever reaches it from the screen.
 */
final class WorldSurface {
    static final int MODE_SOFTWARE = 0;
    static final int MODE_HARDWARE = 1;

    /** Callbacks into the plugin (called on the UI thread). */
    interface Host {
        void onMessage(String id, WebMessageCompat message);
        void onFrame(String id, int frame);
        void onLoaded(String id, String url);
        void onError(String code, String text);
        void onConsole(String level, String text);
    }

    final String id;
    final int width;
    final int height;
    private final Host host;
    private final WebView view;
    private final Handler ui = new Handler(Looper.getMainLooper());
    private final int mode;
    private final long intervalMs;

    private Bitmap bitmap;
    private Canvas softCanvas;
    private ImageReader reader;
    private Surface readerSurface;
    private final Object frameLock = new Object();
    private final byte[] latest;
    private int frame = 0;

    private boolean loaded = false;
    private boolean active = true;        // effective: wanted by Godot and the activity is running
    private boolean wanted = true;        // set by Godot (setActive)
    private boolean paused = false;       // the activity is paused
    private boolean destroyed = false;
    private long drawStartNs = 0;

    // measurements (UI thread writes, any thread reads through stats())
    private long captures = 0;
    private double drawMsSum = 0.0;
    private double copyMsSum = 0.0;
    private double latencyMsSum = 0.0;
    private long skipped = 0;

    @SuppressLint("SetJavaScriptEnabled")
    WorldSurface(Activity activity, Host host, String id, File root, String page, String bridgeScript,
                 String origin, String hostName, String uiPrefix, int width, int height, int fps, int mode) throws IOException {
        this.host = host;
        this.id = id;
        this.width = width;
        this.height = height;
        this.mode = mode;
        this.intervalMs = Math.max(1000L / Math.max(1, fps), 16L);
        this.latest = new byte[width * height * 4];

        final WebViewAssetLoader loader = new WebViewAssetLoader.Builder()
                .setDomain(hostName)
                .addPathHandler(uiPrefix, new LocalContentHandler(root))
                .build();

        view = new WebView(activity);
        view.setBackgroundColor(Color.BLACK);
        view.setOverScrollMode(View.OVER_SCROLL_NEVER);
        view.setVerticalScrollBarEnabled(false);
        view.setHorizontalScrollBarEnabled(false);
        view.setFocusable(false);
        view.setClickable(false);
        view.setHapticFeedbackEnabled(false);
        view.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS);
        // One physical pixel per CSS pixel, so the page is laid out at exactly width x height CSS pixels.
        view.setInitialScale(100);

        WebSettings s = view.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(false);
        s.setAllowFileAccess(false);
        s.setAllowContentAccess(false);
        s.setAllowFileAccessFromFileURLs(false);
        s.setAllowUniversalAccessFromFileURLs(false);
        s.setGeolocationEnabled(false);
        s.setJavaScriptCanOpenWindowsAutomatically(false);
        s.setSupportMultipleWindows(false);
        s.setBlockNetworkLoads(true);
        s.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        s.setSupportZoom(false);
        s.setBuiltInZoomControls(false);
        s.setMediaPlaybackRequiresUserGesture(true);
        s.setCacheMode(WebSettings.LOAD_NO_CACHE);

        view.setWebViewClient(new WebViewClient() {
            @Override
            public WebResourceResponse shouldInterceptRequest(WebView v, WebResourceRequest request) {
                WebResourceResponse local = loader.shouldInterceptRequest(request.getUrl());
                if (local != null) {
                    return local;
                }
                if (hostName.equals(request.getUrl().getHost())) {
                    return LocalContentHandler.notFound();
                }
                host.onError("blocked_request", "Blocked non-local request: " + request.getUrl());
                return LocalContentHandler.blocked();
            }

            @Override
            public boolean shouldOverrideUrlLoading(WebView v, WebResourceRequest request) {
                if (!hostName.equals(request.getUrl().getHost()) || !"https".equals(request.getUrl().getScheme())) {
                    host.onError("blocked_navigation", "Blocked navigation to " + request.getUrl());
                    return true;
                }
                return false;
            }

            @Override
            public void onPageFinished(WebView v, String url) {
                loaded = true;
                host.onLoaded(id, url);
                scheduleNext(0);
            }

            @Override
            public void onReceivedError(WebView v, WebResourceRequest request, WebResourceError error) {
                if (request.isForMainFrame()) {
                    host.onError("load_failed", error.getDescription() + " (" + request.getUrl() + ")");
                }
            }
        });
        view.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onConsoleMessage(ConsoleMessage m) {
                host.onConsole(m.messageLevel().name(), "[surface " + id + "] " + m.message()
                        + " (" + m.sourceId() + ":" + m.lineNumber() + ")");
                return true;
            }
        });

        Set<String> origins = Collections.singleton(origin);
        WebViewCompat.addDocumentStartJavaScript(view,
                "window.__godotSurface=" + JSONObject.quote(id) + ";window.__godotUiScale=1;" + bridgeScript, origins);
        WebViewCompat.addWebMessageListener(view, "GodotNative", origins,
                (v, message, sourceOrigin, isMainFrame, reply) -> {
                    if (isMainFrame) {
                        host.onMessage(id, message);
                    }
                });

        if (mode == MODE_HARDWARE) {
            reader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2);
            readerSurface = reader.getSurface();
            reader.setOnImageAvailableListener(r -> onImage(), ui);
        } else {
            bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
            softCanvas = new Canvas(bitmap);
        }

        // Attached to the window (a detached WebView does not paint) but placed completely off screen to the left.
        activity.addContentView(view, new FrameLayout.LayoutParams(width, height));
        view.setTranslationX(-(width + 64));
        view.loadUrl(origin + uiPrefix + page);
    }

    // ---------------------------------------------------------------- capture loop

    private void scheduleNext(long delayMs) {
        ui.removeCallbacks(tick);
        if (!destroyed && active && loaded) {
            ui.postDelayed(tick, delayMs);
        }
    }

    private final Runnable tick = new Runnable() {
        @Override
        public void run() {
            if (destroyed || !active || !loaded) {
                return;
            }
            capture();
            scheduleNext(intervalMs);
        }
    };

    private void capture() {
        if (view.getWidth() != width || view.getHeight() != height) {
            skipped++;  // not laid out yet
            return;
        }
        try {
            if (mode == MODE_HARDWARE) {
                drawStartNs = System.nanoTime();
                Canvas c = readerSurface.lockHardwareCanvas();
                try {
                    c.drawColor(Color.BLACK);
                    view.draw(c);
                } finally {
                    readerSurface.unlockCanvasAndPost(c);
                }
                drawMsSum += (System.nanoTime() - drawStartNs) / 1e6;
            } else {
                long t0 = System.nanoTime();
                bitmap.eraseColor(Color.BLACK);
                view.draw(softCanvas);
                long t1 = System.nanoTime();
                synchronized (frameLock) {
                    bitmap.copyPixelsToBuffer(ByteBuffer.wrap(latest));
                    frame++;
                }
                long t2 = System.nanoTime();
                drawMsSum += (t1 - t0) / 1e6;
                copyMsSum += (t2 - t1) / 1e6;
                latencyMsSum += (t2 - t0) / 1e6;
                captures++;
                host.onFrame(id, frame);
            }
        } catch (RuntimeException e) {
            host.onError("surface_capture_failed", String.valueOf(e.getMessage()));
        }
    }

    private void onImage() {
        Image image = null;
        try {
            image = reader.acquireLatestImage();
            if (image == null) {
                return;
            }
            long t0 = System.nanoTime();
            Image.Plane plane = image.getPlanes()[0];
            ByteBuffer buffer = plane.getBuffer();
            int rowStride = plane.getRowStride();
            int pixelStride = plane.getPixelStride();
            synchronized (frameLock) {
                if (pixelStride == 4 && rowStride == width * 4) {
                    buffer.get(latest, 0, latest.length);
                } else {
                    for (int y = 0; y < height; y++) {
                        int row = y * rowStride;
                        for (int x = 0; x < width; x++) {
                            int src = row + x * pixelStride;
                            int dst = (y * width + x) * 4;
                            latest[dst] = buffer.get(src);
                            latest[dst + 1] = buffer.get(src + 1);
                            latest[dst + 2] = buffer.get(src + 2);
                            latest[dst + 3] = buffer.get(src + 3);
                        }
                    }
                }
                frame++;
            }
            copyMsSum += (System.nanoTime() - t0) / 1e6;
            latencyMsSum += (System.nanoTime() - drawStartNs) / 1e6;
            captures++;
            host.onFrame(id, frame);
        } catch (RuntimeException e) {
            host.onError("surface_capture_failed", String.valueOf(e.getMessage()));
        } finally {
            if (image != null) {
                image.close();
            }
        }
    }

    // ---------------------------------------------------------------- Godot-facing operations

    byte[] readFrame() {
        synchronized (frameLock) {
            return latest.clone();
        }
    }

    String stats() {
        long n = Math.max(captures, 1);
        try {
            return new JSONObject()
                    .put("mode", mode == MODE_HARDWARE ? "hardware" : "software")
                    .put("frames", captures)
                    .put("skipped", skipped)
                    .put("draw_ms", drawMsSum / n)
                    .put("copy_ms", copyMsSum / n)
                    .put("latency_ms", latencyMsSum / n)
                    .put("interval_ms", intervalMs)
                    .toString();
        } catch (org.json.JSONException e) {
            return "{}";
        }
    }

    void send(String name, String json) {
        view.evaluateJavascript("window.Godot&&window.Godot.__receive(" + JSONObject.quote(name) + ","
                + JSONObject.quote(json) + ")", null);
    }

    /** A tap at (x, y) in page pixels: finger down now, up shortly after, so the page sees a normal click. */
    void tap(float x, float y) {
        final long down = SystemClock.uptimeMillis();
        dispatch(down, MotionEvent.ACTION_DOWN, x, y);
        ui.postDelayed(() -> dispatch(down, MotionEvent.ACTION_UP, x, y), 60);
    }

    private void dispatch(long downTime, int action, float x, float y) {
        if (destroyed) {
            return;
        }
        MotionEvent event = MotionEvent.obtain(downTime, SystemClock.uptimeMillis(), action, x, y, 0);
        event.setSource(InputDevice.SOURCE_TOUCHSCREEN);
        view.dispatchTouchEvent(event);
        event.recycle();
    }

    /** Godot's wish: stops or restarts drawing (a screen nobody can see needs no frames). Survives pause and resume. */
    void setActive(boolean value) {
        wanted = value;
        applyActive();
    }

    /** The activity's lifecycle: a paused app draws nothing, and on resume only the surfaces Godot still wants draw again. */
    void setPaused(boolean value) {
        paused = value;
        applyActive();
    }

    private void applyActive() {
        boolean now = wanted && !paused;
        if (now == active) {
            return;
        }
        active = now;
        if (now) {
            view.onResume();
            scheduleNext(0);
        } else {
            ui.removeCallbacks(tick);
            view.onPause();
        }
    }

    void destroy() {
        destroyed = true;
        ui.removeCallbacksAndMessages(null);
        if (view.getParent() instanceof android.view.ViewGroup) {
            ((android.view.ViewGroup) view.getParent()).removeView(view);
        }
        view.stopLoading();
        view.removeAllViews();
        view.destroy();
        if (reader != null) {
            reader.close();
        }
        if (bitmap != null) {
            bitmap.recycle();
        }
    }
}
