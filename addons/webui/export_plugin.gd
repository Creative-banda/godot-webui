@tool
extends EditorExportPlugin
## Adds the native WebUI Android library to Gradle-based Android exports.

const AAR_DEBUG := "res://addons/webui/bin/WebUI-debug.aar"
const AAR_RELEASE := "res://addons/webui/bin/WebUI-release.aar"
# Must match `webkitVersion` in native/android/webui/build.gradle.
const WEBKIT_DEPENDENCY := "androidx.webkit:webkit:1.12.1"


func _get_name() -> String:
	return "WebUI"


func _supports_platform(platform: EditorExportPlatform) -> bool:
	return platform is EditorExportPlatformAndroid


func _get_android_libraries(_platform: EditorExportPlatform, debug: bool) -> PackedStringArray:
	var aar := AAR_DEBUG if debug else AAR_RELEASE
	if not FileAccess.file_exists(aar):
		push_error("WebUI: %s is missing. Build it first (see README, 'Building the native plugin')." % aar)
		return PackedStringArray()
	return PackedStringArray([aar])


func _get_android_dependencies(_platform: EditorExportPlatform, _debug: bool) -> PackedStringArray:
	return PackedStringArray([WEBKIT_DEPENDENCY])
