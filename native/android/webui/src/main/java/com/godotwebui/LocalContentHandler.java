package com.godotwebui;

import android.webkit.MimeTypeMap;
import android.webkit.WebResourceResponse;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.webkit.WebViewAssetLoader;

import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;

/**
 * Serves files from one directory (the staged UI folder) to the WebView, refusing anything that
 * resolves outside of it. Responses carry a CSP that blocks all non-local loads.
 */
final class LocalContentHandler implements WebViewAssetLoader.PathHandler {
    private static final String CSP = "default-src 'self' data: blob:; "
            + "script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; "
            + "connect-src 'self'; frame-src 'none'; object-src 'none'; base-uri 'self'; form-action 'none'";

    private final File root;

    LocalContentHandler(@NonNull File root) throws IOException {
        this.root = root.getCanonicalFile();
    }

    @Nullable
    @Override
    public WebResourceResponse handle(@NonNull String path) {
        try {
            File file = new File(root, path).getCanonicalFile();
            if (!file.getPath().startsWith(root.getPath() + File.separator) || !file.isFile()) {
                return notFound();
            }
            return new WebResourceResponse(mimeType(file.getName()), "utf-8", 200, "OK",
                    headers(), new FileInputStream(file));
        } catch (IOException e) {
            return notFound();
        }
    }

    static WebResourceResponse notFound() {
        return new WebResourceResponse("text/plain", "utf-8", 404, "Not Found", headers(), null);
    }

    static WebResourceResponse blocked() {
        return new WebResourceResponse("text/plain", "utf-8", 403, "Blocked", headers(), null);
    }

    private static Map<String, String> headers() {
        Map<String, String> h = new HashMap<>();
        h.put("Content-Security-Policy", CSP);
        h.put("X-Content-Type-Options", "nosniff");
        h.put("Cache-Control", "no-store");
        return h;
    }

    private static String mimeType(String name) {
        String ext = name.substring(name.lastIndexOf('.') + 1).toLowerCase(Locale.ROOT);
        switch (ext) {
            case "html": case "htm": return "text/html";
            case "js": case "mjs": return "text/javascript";
            case "css": return "text/css";
            case "json": return "application/json";
            case "svg": return "image/svg+xml";
            case "woff2": return "font/woff2";
            case "woff": return "font/woff";
            default:
                String m = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext);
                return m != null ? m : "application/octet-stream";
        }
    }
}
