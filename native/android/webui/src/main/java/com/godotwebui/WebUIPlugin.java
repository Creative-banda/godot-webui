package com.godotwebui;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.util.DisplayMetrics;
import android.util.Log;
import android.view.View;
import android.view.ViewGroup;
import android.webkit.ConsoleMessage;
import android.webkit.RenderProcessGoneDetail;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;

import androidx.annotation.NonNull;
import androidx.webkit.ScriptHandler;
import androidx.webkit.WebMessageCompat;
import androidx.webkit.WebViewAssetLoader;
import androidx.webkit.WebViewCompat;
import androidx.webkit.WebViewFeature;

import org.godotengine.godot.Godot;
import org.godotengine.godot.plugin.GodotPlugin;
import org.godotengine.godot.plugin.SignalInfo;
import org.godotengine.godot.plugin.UsedByGodot;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.File;
import java.io.IOException;
import java.util.Collections;
import java.util.HashMap;
import java.util.Map;
import java.util.HashSet;
import java.util.Set;

/**
 * Godot Android plugin that shows a full-screen transparent WebView above the game and bridges
 * messages between the page and GDScript.
 *
 * JS -> native: a single WebMessageListener object ("GodotNative", main frame of the local origin
 * only) accepting one string. Native does size/type checks and forwards the raw string to GDScript,
 * which does the authoritative schema validation. No other native method is reachable from JS.
 * Native -> JS: evaluateJavascript calling window.Godot.__receive(name, json).
 */
public class WebUIPlugin extends GodotPlugin {
    private static final String TAG = "WebUI";
    private static final String HOST = "appassets.androidplatform.net";
    private static final String ORIGIN = "https://" + HOST;
    private static final String UI_PREFIX = "/ui/";
    private static final String JS_OBJECT = "GodotNative";
    private static final int MAX_MESSAGE_CHARS = 64 * 1024;

    /** The UI scale never exceeds this, whatever the screen (a 4K TV at density 1.0 needs about 3). */
    private static final float MAX_UI_SCALE = 4f;
    private static final int MAX_SURFACES = 8;

    private OverlayWebView webView;
    private String uiRootDir = "";
    /** World-space pages (see WorldSurface), by id. */
    private final Map<String, WorldSurface> surfaces = Collections.synchronizedMap(new HashMap<>());
    private String bridgeScript = "";
    private ScriptHandler startScript;
    private volatile float uiReference = 720f;
    private float uiScale = 1f;
    private int uiPercent = 0;
    private float uiDensity = 0f;

    public WebUIPlugin(Godot godot) {
        super(godot);
    }

    @NonNull
    @Override
    public String getPluginName() {
        return "WebUI";
    }

    @NonNull
    @Override
    public Set<SignalInfo> getPluginSignals() {
        Set<SignalInfo> signals = new HashSet<>();
        signals.add(new SignalInfo("message", String.class));
        signals.add(new SignalInfo("error", String.class, String.class));
        signals.add(new SignalInfo("page_loaded", String.class));
        signals.add(new SignalInfo("console", String.class, String.class));
        signals.add(new SignalInfo("surface_message", String.class, String.class));
        signals.add(new SignalInfo("surface_frame", String.class, Integer.class));
        signals.add(new SignalInfo("surface_loaded", String.class, String.class));
        return signals;
    }

    // ---------------------------------------------------------------- Godot-facing API

    /**
     * @param rootDir absolute path of the staged UI directory served under /ui/
     * @param script  JavaScript (the Godot bridge client) injected before any page script runs
     */
    @UsedByGodot
    public void create(String rootDir, String script) {
        runOnUiThread(() -> createOnUi(rootDir, script));
    }

    @UsedByGodot
    public void load(String relativePath) {
        runOnUiThread(() -> {
            if (webView == null) {
                fail("not_created", "load() called before create().");
                return;
            }
            if (relativePath == null || relativePath.isEmpty() || relativePath.startsWith("/")
                    || relativePath.contains("..") || relativePath.contains(":")) {
                fail("bad_path", "Invalid UI path: " + relativePath);
                return;
            }
            webView.loadUrl(ORIGIN + UI_PREFIX + relativePath);
        });
    }

    /**
     * UI scale reference in CSS pixels (the project's design size, like Godot's stretch base). The shorter side of the
     * screen, in dp, is compared with it: at or below it the page is laid out at the device density (phones are
     * unchanged); above it everything is scaled up in proportion, so a 4K screen gets the same layout space as a
     * 720 dp-high one instead of a tiny interface. 0 turns it off.
     */
    @UsedByGodot
    public void setUiReference(float cssPixels) {
        uiReference = cssPixels;
        runOnUiThread(this::updateUiScale);
    }

    /** Delivers a named message to window.Godot.__receive in the page. */
    @UsedByGodot
    public void sendMessage(String name, String jsonPayload) {
        runOnUiThread(() -> {
            if (webView == null) {
                fail("not_created", "sendMessage() called before create().");
                return;
            }
            webView.evaluateJavascript("window.Godot&&window.Godot.__receive("
                    + JSONObject.quote(name) + "," + JSONObject.quote(jsonPayload) + ")", null);
        });
    }

    @UsedByGodot
    public void setVisible(boolean visible) {
        runOnUiThread(() -> {
            if (webView != null) {
                webView.setVisibility(visible ? View.VISIBLE : View.INVISIBLE);
                if (visible) {
                    // A WebView that loaded while invisible has painted nothing: wake the compositor and redraw.
                    webView.onResume();
                    webView.requestLayout();
                    webView.invalidate();
                }
            }
        });
    }

    /** "modal": WebView takes every touch. "regions": only page-reported rectangles take touches. */
    @UsedByGodot
    public void setTouchMode(String mode) {
        runOnUiThread(() -> {
            if (webView != null) {
                webView.setPassThrough("regions".equals(mode));
            }
        });
    }

    // ---------------------------------------------------------------- world-space surfaces (Godot-facing)

    /**
     * Creates a world-space page: `page` (relative to the overlay's UI folder) laid out at width x height CSS pixels in an
     * off-screen WebView and drawn into frames for Godot at about `fps`. Needs the overlay to exist (it supplies the UI
     * folder and the bridge script). `mode`: 1 = hardware canvas through an ImageReader, 0 = software Bitmap.
     */
    @UsedByGodot
    public void createSurface(String id, String page, int width, int height, int fps, int mode) {
        runOnUiThread(() -> createSurfaceOnUi(id, page, width, height, fps, mode));
    }

    @UsedByGodot
    public void destroySurface(String id) {
        runOnUiThread(() -> {
            WorldSurface surface = surfaces.remove(id);
            if (surface != null) {
                surface.destroy();
            }
        });
    }

    @UsedByGodot
    public void surfaceSend(String id, String name, String jsonPayload) {
        runOnUiThread(() -> {
            WorldSurface surface = surfaces.get(id);
            if (surface != null) {
                surface.send(name, jsonPayload);
            }
        });
    }

    @UsedByGodot
    public void surfaceTap(String id, float x, float y) {
        runOnUiThread(() -> {
            WorldSurface surface = surfaces.get(id);
            if (surface != null) {
                surface.tap(x, y);
            }
        });
    }

    @UsedByGodot
    public void surfaceSetActive(String id, boolean active) {
        runOnUiThread(() -> {
            WorldSurface surface = surfaces.get(id);
            if (surface != null) {
                surface.setActive(active);
            }
        });
    }

    /** The latest frame as RGBA bytes (width * height * 4), or an empty array. Safe to call from any thread. */
    @UsedByGodot
    public byte[] readSurfaceFrame(String id) {
        WorldSurface surface = surfaces.get(id);
        return surface == null ? new byte[0] : surface.readFrame();
    }

    @UsedByGodot
    public String getSurfaceStats(String id) {
        WorldSurface surface = surfaces.get(id);
        return surface == null ? "{}" : surface.stats();
    }

    @UsedByGodot
    public void destroy() {
        runOnUiThread(this::destroyOnUi);
    }

    // ---------------------------------------------------------------- lifecycle

    @Override
    public void onMainPause() {
        for (WorldSurface surface : new java.util.ArrayList<>(surfaces.values())) {
            surface.setPaused(true);
        }
        OverlayWebView view = webView;
        if (view != null) {
            view.evaluateJavascript("window.Godot&&window.Godot.__lifecycle('pause')", null);
            view.onPause();
        }
    }

    @Override
    public void onMainResume() {
        for (WorldSurface surface : new java.util.ArrayList<>(surfaces.values())) {
            surface.setPaused(false);
        }
        OverlayWebView view = webView;
        if (view != null) {
            view.onResume();
            view.evaluateJavascript("window.Godot&&window.Godot.__lifecycle('resume')", null);
        }
    }

    @Override
    public void onMainDestroy() {
        destroyOnUi();
    }

    // ---------------------------------------------------------------- implementation (UI thread)

    @SuppressLint("SetJavaScriptEnabled")
    private void createOnUi(String rootDir, String script) {
        if (webView != null) {
            fail("already_created", "create() called twice; call destroy() first.");
            return;
        }
        Activity activity = getActivity();
        if (activity == null) {
            fail("no_activity", "No Android activity available.");
            return;
        }
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)
                || !WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            fail("webview_too_old", "System WebView lacks WEB_MESSAGE_LISTENER / DOCUMENT_START_SCRIPT. "
                    + "Update Android System WebView.");
            return;
        }

        WebViewAssetLoader loader;
        try {
            loader = new WebViewAssetLoader.Builder()
                    .setDomain(HOST)
                    .addPathHandler(UI_PREFIX, new LocalContentHandler(new File(rootDir)))
                    .build();
        } catch (IOException e) {
            fail("bad_root", "Cannot open UI directory: " + e.getMessage());
            return;
        }

        OverlayWebView view = new OverlayWebView(activity);
        view.setBackgroundColor(Color.TRANSPARENT);
        view.setOverScrollMode(View.OVER_SCROLL_NEVER);
        view.setVerticalScrollBarEnabled(false);
        view.setHorizontalScrollBarEnabled(false);
        view.setLongClickable(false);
        view.setHapticFeedbackEnabled(false);

        WebSettings s = view.getSettings();
        s.setJavaScriptEnabled(true);          // required: the HUD is JavaScript
        s.setDomStorageEnabled(false);
        s.setAllowFileAccess(false);
        s.setAllowContentAccess(false);
        s.setAllowFileAccessFromFileURLs(false);
        s.setAllowUniversalAccessFromFileURLs(false);
        s.setGeolocationEnabled(false);
        s.setJavaScriptCanOpenWindowsAutomatically(false);
        s.setSupportMultipleWindows(false);
        s.setBlockNetworkLoads(true);          // everything is served from the local handler
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
                if (HOST.equals(request.getUrl().getHost())) {
                    return LocalContentHandler.notFound();
                }
                fail("blocked_request", "Blocked non-local request: " + request.getUrl());
                return LocalContentHandler.blocked();
            }

            @Override
            public boolean shouldOverrideUrlLoading(WebView v, WebResourceRequest request) {
                if (!HOST.equals(request.getUrl().getHost()) || !"https".equals(request.getUrl().getScheme())) {
                    fail("blocked_navigation", "Blocked navigation to " + request.getUrl());
                    return true;
                }
                return false;
            }

            @Override
            public void onPageStarted(WebView v, String url, Bitmap favicon) {
                // New page: touch regions reported by the previous one no longer apply.
                ((OverlayWebView) v).setRegions(new float[0]);
            }

            @Override
            public void onPageFinished(WebView v, String url) {
                emitSignal("page_loaded", url);
            }

            @Override
            public void onReceivedError(WebView v, WebResourceRequest request, WebResourceError error) {
                if (request.isForMainFrame()) {
                    fail("load_failed", error.getDescription() + " (" + request.getUrl() + ")");
                }
            }

            @Override
            public boolean onRenderProcessGone(WebView v, RenderProcessGoneDetail detail) {
                fail("render_process_gone", "WebView renderer "
                        + (detail.didCrash() ? "crashed" : "was killed") + "; call destroy() and create() again.");
                destroyOnUi();
                return true;
            }
        });

        view.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onConsoleMessage(ConsoleMessage m) {
                emitSignal("console", m.messageLevel().name(),
                        m.message() + " (" + m.sourceId() + ":" + m.lineNumber() + ")");
                return true;
            }
        });

        Set<String> origins = Collections.singleton(ORIGIN);
        bridgeScript = script;
        uiRootDir = rootDir;
        webView = view;
        view.setOnSizeChange(this::updateUiScale);
        updateUiScale();  // before the first page loads: sets the initial scale and the start script
        WebViewCompat.addWebMessageListener(view, JS_OBJECT, origins,
                (v, message, sourceOrigin, isMainFrame, reply) -> {
                    if (isMainFrame) {
                        onPageMessage((OverlayWebView) v, message);
                    }
                });

        activity.addContentView(view, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        // Lets a finger on the game and a finger on the HUD be routed independently.
        if (view.getParent() instanceof ViewGroup) {
            ((ViewGroup) view.getParent()).setMotionEventSplittingEnabled(true);
        }
    }

    /**
     * Works out the UI scale from the overlay size and applies it. WebView.setInitialScale(p) lays the page out at
     * p/100 physical pixels per CSS pixel, with real re-layout (innerWidth, media queries and vw change) and sharp
     * rendering; the default is the device density. The page learns the factor through Godot.uiScale.
     */
    private void updateUiScale() {
        OverlayWebView view = webView;
        Activity activity = getActivity();
        if (view == null || activity == null) {
            return;
        }
        DisplayMetrics dm = activity.getResources().getDisplayMetrics();
        int w = view.getWidth() > 0 ? view.getWidth() : dm.widthPixels;
        int h = view.getHeight() > 0 ? view.getHeight() : dm.heightPixels;
        float scale = 1f;
        if (uiReference > 0f) {
            float shortCss = Math.min(w, h) / dm.density;
            scale = Math.max(1f, Math.min(MAX_UI_SCALE, shortCss / uiReference));
        }
        int percent = scale > 1.005f ? Math.round(dm.density * scale * 100f) : 0;
        Log.i(TAG, "ui scale: view " + w + "x" + h + " px, density " + dm.density + ", reference " + uiReference + " -> x" + scale + " (initial scale " + percent + "%)");
        boolean first = startScript == null;
        // The WebView stores the initial scale relative to the density it was given at that moment, so a density change
        // needs the call repeated even when the percentage is the same.
        if (!first && percent == uiPercent && dm.density == uiDensity) {
            return;
        }
        int previousPercent = uiPercent;
        uiPercent = percent;
        uiDensity = dm.density;
        uiScale = percent > 0 ? percent / (dm.density * 100f) : 1f;
        if (!first && percent > 0 && percent == previousPercent) {
            view.setInitialScale(percent + 1);  // same number, new density: make the WebView see a change and lay out again
        }
        view.setInitialScale(percent);
        view.setPxPerCss(percent > 0 ? percent / 100f : 0f);
        if (startScript != null) {
            startScript.remove();
        }
        startScript = WebViewCompat.addDocumentStartJavaScript(view,
                "window.__godotUiScale=" + uiScale + ";" + bridgeScript, Collections.singleton(ORIGIN));
        if (!first) {
            view.evaluateJavascript("window.Godot&&window.Godot.__uiScale(" + uiScale + ")", null);
        }
    }

    private void createSurfaceOnUi(String id, String page, int width, int height, int fps, int mode) {
        Activity activity = getActivity();
        if (webView == null || uiRootDir.isEmpty() || activity == null) {
            fail("surface_no_overlay", "createSurface() needs the overlay to be started first.");
            return;
        }
        if (id == null || !id.matches("[A-Za-z][A-Za-z0-9_.:-]{0,63}") || surfaces.containsKey(id)) {
            fail("surface_bad_id", "Invalid or duplicate surface id: " + id);
            return;
        }
        if (page == null || page.isEmpty() || page.startsWith("/") || page.contains("..") || page.contains(":")) {
            fail("bad_path", "Invalid UI path: " + page);
            return;
        }
        if (surfaces.size() >= MAX_SURFACES) {
            fail("surface_limit", "At most " + MAX_SURFACES + " world-space pages can exist at once; destroy one first.");
            return;
        }
        if (width < 64 || height < 64 || width > 2048 || height > 2048) {
            fail("surface_bad_size", "Surface size must be 64..2048 pixels, got " + width + "x" + height);
            return;
        }
        try {
            surfaces.put(id, new WorldSurface(activity, surfaceHost, id, new File(uiRootDir), page, bridgeScript,
                    ORIGIN, HOST, UI_PREFIX, width, height, Math.max(1, Math.min(fps, 30)), mode));
        } catch (IOException | RuntimeException e) {
            fail("surface_create_failed", String.valueOf(e.getMessage()));
        }
    }

    private final WorldSurface.Host surfaceHost = new WorldSurface.Host() {
        @Override
        public void onMessage(String id, WebMessageCompat message) {
            String data = message.getType() == WebMessageCompat.TYPE_STRING ? message.getData() : null;
            if (data == null || data.length() > MAX_MESSAGE_CHARS) {
                fail("bad_message", "Ignored a non-string or oversized message from surface " + id + ".");
                return;
            }
            if (data.startsWith("{\"t\":\"regions\"")) {
                return;  // touch regions belong to the overlay
            }
            emitSignal("surface_message", id, data);
        }

        @Override
        public void onFrame(String id, int frame) {
            emitSignal("surface_frame", id, frame);
        }

        @Override
        public void onLoaded(String id, String url) {
            emitSignal("surface_loaded", id, url);
        }

        @Override
        public void onError(String code, String text) {
            fail(code, text);
        }

        @Override
        public void onConsole(String level, String text) {
            emitSignal("console", level, text);
        }
    };

    private void onPageMessage(OverlayWebView v, WebMessageCompat message) {
        String data = message.getType() == WebMessageCompat.TYPE_STRING ? message.getData() : null;
        if (data == null) {
            fail("bad_message", "Ignored non-string message from page.");
            return;
        }
        if (data.length() > MAX_MESSAGE_CHARS) {
            fail("message_too_large", "Ignored page message of " + data.length() + " chars (max "
                    + MAX_MESSAGE_CHARS + ").");
            return;
        }
        // Touch regions are consumed natively; everything else goes to GDScript.
        if (data.startsWith("{\"t\":\"regions\"")) {
            try {
                JSONArray arr = new JSONObject(data).getJSONArray("rects");
                float[] flat = new float[arr.length()];
                for (int i = 0; i < flat.length; i++) {
                    flat[i] = (float) arr.getDouble(i);
                }
                v.setRegions(flat);
            } catch (JSONException e) {
                fail("bad_regions", "Malformed touch regions: " + e.getMessage());
            }
            return;
        }
        emitSignal("message", data);
    }

    private void destroyOnUi() {
        OverlayWebView view = webView;
        if (view == null) {
            return;
        }
        webView = null;
        startScript = null;
        uiRootDir = "";
        for (WorldSurface surface : new java.util.ArrayList<>(surfaces.values())) {
            surface.destroy();
        }
        surfaces.clear();
        ViewGroup parent = (ViewGroup) view.getParent();
        if (parent != null) {
            parent.removeView(view);
        }
        view.stopLoading();
        view.removeAllViews();
        view.destroy();
    }

    private void fail(String code, String message) {
        Log.w(TAG, code + ": " + message);
        emitSignal("error", code, message);
    }
}
