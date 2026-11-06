package dev.offlineai.offline_ai_mobile

import android.app.ActivityManager
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.StatFs
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

/**
 * Canal nativo do perfilador de hardware (`offline_ai_mobile/hardware`).
 *
 * Lê RAM total/livre, disco, núcleos de performance, instruções ARM
 * (dotprod/i8mm) e aceleração GPU. Sem permissões especiais; nunca lança para
 * a UI — devolve sempre um mapa com valores seguros.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "offline_ai_mobile/hardware"
    private val mediaChannelName = "offline_ai_mobile/media"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getHardwareMetrics" -> result.success(hardwareMetrics())
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, mediaChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "extractVideoFrames" -> {
                        val path = call.argument<String>("path")
                        val fps = call.argument<Double>("fps") ?: 2.0
                        if (path == null) {
                            result.error("bad-args", "path em falta", null)
                        } else {
                            try {
                                result.success(extractVideoFrames(path, fps))
                            } catch (e: Exception) {
                                result.error("video-error", e.message, null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Extrai frames a [fps] (2 fps por defeito) para JPEG em cacheDir.
     * A banda sonora não é extraída nesta versão; o LFM3-Omni exige-a e a UI
     * mostra um erro explícito se o vídeo tiver áudio.
     */
    private fun extractVideoFrames(path: String, fps: Double): Map<String, Any?> {
        val retriever = MediaMetadataRetriever()
        retriever.setDataSource(path)
        val durationMs = retriever
            .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
            ?.toLongOrNull() ?: 0L
        if (durationMs <= 0) {
            retriever.release()
            throw IllegalArgumentException("duração de vídeo desconhecida")
        }
        val dir = File(cacheDir, "video_frames").apply {
            if (exists()) deleteRecursively()
            mkdirs()
        }
        val stepMs = (1000.0 / fps.coerceAtLeast(1.0)).toLong()
        val frames = mutableListOf<String>()
        var t = 0L
        var i = 0
        while (t < durationMs) {
            val bitmap: Bitmap = retriever.getFrameAtTime(
                t * 1000L,
                MediaMetadataRetriever.OPTION_CLOSEST_SYNC
            ) ?: break
            val file = File(dir, "frame_%03d.jpg".format(i))
            FileOutputStream(file).use { out ->
                bitmap.compress(Bitmap.CompressFormat.JPEG, 85, out)
            }
            bitmap.recycle()
            frames.add(file.absolutePath)
            t += stepMs
            i++
        }
        retriever.release()
        if (frames.isEmpty()) throw IllegalStateException("sem frames extraídos")
        return mapOf(
            "frames" to frames,
            "soundtrack" to null,
            "fps" to fps,
            "duration_ms" to durationMs,
        )
    }

    private fun hardwareMetrics(): Map<String, Any> {
        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val mi = ActivityManager.MemoryInfo()
        am.getMemoryInfo(mi)

        val stat = StatFs(filesDir.absolutePath)
        val freeStorageMb = (stat.availableBytes / (1024L * 1024L)).toInt()

        val cpuinfo = runCatching { File("/proc/cpuinfo").readText() }.getOrDefault("")
        val dotprod = cpuinfo.contains("asimddp") || cpuinfo.contains("ASIMDDP")
        val i8mm = cpuinfo.contains("i8mm") || cpuinfo.contains("I8MM")

        val glVersion = runCatching {
            am.deviceConfigurationInfo.reqGlEsVersion
        }.getOrDefault(0)
        val vulkan = packageManager.hasSystemFeature(
            PackageManager.FEATURE_VULKAN_HARDWARE_VERSION
        )
        val gpu = vulkan || glVersion >= 0x30000

        return mapOf(
            "totalRamMb" to (mi.totalMem / (1024L * 1024L)).toInt(),
            "availableRamMb" to (mi.availMem / (1024L * 1024L)).toInt(),
            "freeStorageMb" to freeStorageMb,
            "performanceCores" to performanceCores(),
            "logicalCores" to Runtime.getRuntime().availableProcessors(),
            "hasArmDotProd" to dotprod,
            "hasArmI8mm" to i8mm,
            "hasGpuAcceleration" to gpu,
            "hasMetal" to false,
            "isIosSimulator" to false,
            "platform" to "android",
            "sdkInt" to Build.VERSION.SDK_INT,
            "abis" to Build.SUPPORTED_ABIS.toList(),
        )
    }

    /**
     * Núcleos de performance: conta os CPUs cuja frequência máxima está a
     * >=80% do máximo global. Sem cpufreq, usa `availableProcessors - 2`
     * (big cores típicos) com mínimo 1.
     */
    private fun performanceCores(): Int {
        val n = Runtime.getRuntime().availableProcessors()
        val freqs = (0 until n).mapNotNull { i ->
            runCatching {
                File("/sys/devices/system/cpu/cpu$i/cpufreq/cpuinfo_max_freq")
                    .readText().trim().toLong()
            }.getOrNull()
        }
        if (freqs.isEmpty()) return maxOf(1, n - 2)
        val max = freqs.maxOrNull() ?: return maxOf(1, n - 2)
        val threshold = (max * 0.8).toLong()
        return freqs.count { it >= threshold }.coerceAtLeast(1)
    }
}
