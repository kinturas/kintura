package de.kintura.app

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** Its own class, so that it does not clash with the FileProvider of a plugin. */
class UpdateFileProvider : FileProvider()

/**
 * Installs a new version of the app that the app downloaded itself into the cache, see
 * update_installer.dart: Android shows its dialog to install over this version.
 */
object UpdateInstaller {
    private const val CHANNEL = "de.kintura.app/update"

    fun register(activity: Activity, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "dir" -> result.success(dir(activity).absolutePath)
                "install" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("path", "path fehlt", null)
                    } else {
                        try {
                            result.success(install(activity, File(path)))
                        } catch (e: Exception) {
                            result.error("install", e.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /** As in res/xml/update_paths.xml. */
    private fun dir(activity: Activity) = File(activity.cacheDir, "updates").apply { mkdirs() }

    /**
     * "started" once the dialog opens; "permission" if the app may not install apps yet,
     * then the settings open for that, and the app asks to try again.
     */
    private fun install(activity: Activity, file: File): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !activity.packageManager.canRequestPackageInstalls()) {
            activity.startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}"))
            )
            return "permission"
        }
        val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.updates", file)
        activity.startActivity(
            Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        )
        return "started"
    }
}
