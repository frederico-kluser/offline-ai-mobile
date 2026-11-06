package dev.offlineai.offline_ai_mobile

import android.app.ActivityManager
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.StatFs
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.max
import kotlin.math.min

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
     * Extrai frames a [fps] (2 fps por defeito) para JPEG em cacheDir e a
     * banda sonora para WAV PCM16 mono 16 kHz.
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
        val soundtrack = runCatching { extractSoundtrack(path) }.getOrNull()
        return mapOf(
            "frames" to frames,
            "soundtrack" to soundtrack,
            "fps" to fps,
            "duration_ms" to durationMs,
        )
    }

    /**
     * Extrai a faixa de áudio para WAV PCM16 mono 16 kHz.
     * Devolve null se o vídeo não tiver áudio ou o codec não descodificar.
     */
    private fun extractSoundtrack(path: String): String? {
        val extractor = MediaExtractor()
        extractor.setDataSource(path)
        var trackIndex = -1
        var format: MediaFormat? = null
        for (i in 0 until extractor.trackCount) {
            val f = extractor.getTrackFormat(i)
            val mime = f.getString(MediaFormat.KEY_MIME) ?: ""
            if (mime.startsWith("audio/")) {
                trackIndex = i
                format = f
                break
            }
        }
        if (trackIndex < 0 || format == null) {
            extractor.release()
            return null
        }
        extractor.selectTrack(trackIndex)
        val fmt = format ?: run { extractor.release(); return null }
        val mime = fmt.getString(MediaFormat.KEY_MIME)
            ?: run { extractor.release(); return null }
        val codec = MediaCodec.createDecoderByType(mime)
        codec.configure(fmt, null, null, 0)
        codec.start()

        val pcm = ByteArrayOutputStream()
        val info = MediaCodec.BufferInfo()
        var inputDone = false
        var outputDone = false
        var outputFormat: MediaFormat? = null
        while (!outputDone) {
            if (!inputDone) {
                val inIndex = codec.dequeueInputBuffer(10_000)
                if (inIndex >= 0) {
                    val buffer = codec.getInputBuffer(inIndex)!!
                    val size = extractor.readSampleData(buffer, 0)
                    if (size < 0) {
                        codec.queueInputBuffer(
                            inIndex, 0, 0, 0,
                            MediaCodec.BUFFER_FLAG_END_OF_STREAM
                        )
                        inputDone = true
                    } else {
                        codec.queueInputBuffer(inIndex, 0, size, extractor.sampleTime, 0)
                        extractor.advance()
                    }
                }
            }
            when (val outIndex = codec.dequeueOutputBuffer(info, 10_000)) {
                MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    outputFormat = codec.outputFormat
                }
                MediaCodec.INFO_TRY_AGAIN_LATER -> Unit
                else -> if (outIndex >= 0) {
                    val buffer = codec.getOutputBuffer(outIndex)!!
                    buffer.position(info.offset)
                    buffer.limit(info.offset + info.size)
                    val chunk = ByteArray(info.size)
                    buffer.get(chunk)
                    pcm.write(chunk)
                    codec.releaseOutputBuffer(outIndex, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        outputDone = true
                    }
                }
            }
        }
        codec.stop()
        codec.release()
        extractor.release()

        val outFormat = outputFormat ?: return null
        val rate = outFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        val channels = outFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        val encoding = if (outFormat.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
            outFormat.getInteger(MediaFormat.KEY_PCM_ENCODING)
        } else {
            AudioFormat.ENCODING_PCM_16BIT
        }
        val raw = pcm.toByteArray()
        if (raw.isEmpty() || channels <= 0 || rate <= 0) return null

        val src = FloatArray(raw.size / if (encoding == AudioFormat.ENCODING_PCM_FLOAT) 4 else 2)
        if (encoding == AudioFormat.ENCODING_PCM_FLOAT) {
            val bb = ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
            for (i in src.indices) src[i] = bb.get(i)
        } else {
            val bb = ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
            for (i in src.indices) src[i] = bb.get(i) / 32768f
        }
        // mono: média dos canais
        val frames = src.size / channels
        if (frames <= 0) return null
        val mono = FloatArray(frames)
        for (i in 0 until frames) {
            var sum = 0f
            for (c in 0 until channels) sum += src[i * channels + c]
            mono[i] = sum / channels
        }
        // resample linear para 16 kHz
        val targetRate = 16000
        val outFrames = max(1, (frames.toLong() * targetRate / rate).toInt())
        val resampled = FloatArray(outFrames)
        for (i in 0 until outFrames) {
            val pos = i.toDouble() * rate / targetRate
            val i0 = min(frames - 1, pos.toInt())
            val i1 = min(frames - 1, i0 + 1)
            val frac = (pos - i0).toFloat()
            resampled[i] = mono[i0] * (1f - frac) + mono[i1] * frac
        }

        val file = File(cacheDir, "video_soundtrack.wav")
        FileOutputStream(file).use { out ->
            val dataSize = outFrames * 2
            val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
            header.put("RIFF".toByteArray(Charsets.US_ASCII))
            header.putInt(36 + dataSize)
            header.put("WAVE".toByteArray(Charsets.US_ASCII))
            header.put("fmt ".toByteArray(Charsets.US_ASCII))
            header.putInt(16)
            header.putShort(1.toShort())
            header.putShort(1.toShort())
            header.putInt(targetRate)
            header.putInt(targetRate * 2)
            header.putShort(2.toShort())
            header.putShort(16.toShort())
            header.put("data".toByteArray(Charsets.US_ASCII))
            header.putInt(dataSize)
            out.write(header.array())
            val pcm16 = ByteBuffer.allocate(dataSize).order(ByteOrder.LITTLE_ENDIAN)
            for (v in resampled) {
                val s = (v.coerceIn(-1f, 1f) * 32767f).toInt().toShort()
                pcm16.putShort(s)
            }
            out.write(pcm16.array())
        }
        return file.absolutePath
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
