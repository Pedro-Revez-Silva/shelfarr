package org.shelfarr.app.update

import android.content.pm.PackageInstaller
import java.io.File
import java.security.MessageDigest
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okhttp3.OkHttpClient
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import okio.Buffer

/** One test certificate for every HTTPS origin in these tests, trusted by [trustingClient]. */
object TestTls {
    private val certificate: HeldCertificate = HeldCertificate.Builder()
        .addSubjectAlternativeName("localhost")
        .addSubjectAlternativeName("127.0.0.1")
        .build()
    private val server = HandshakeCertificates.Builder().heldCertificate(certificate).build()
    private val client = HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()

    fun httpsServer(): MockWebServer = MockWebServer().apply {
        useHttps(server.sslSocketFactory())
        start()
    }

    /** The production updater client, changed only to trust the test certificate. */
    fun trustingClient(base: OkHttpClient = buildUpdateHttpClient()): OkHttpClient =
        base.newBuilder().sslSocketFactory(client.sslSocketFactory(), client.trustManager).build()
}

const val PACKAGE = "org.shelfarr.app.debug"
const val SIGNER = "aa11"
const val OTHER_SIGNER = "bb22"

fun sha256Hex(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

/** A feed document; [overrides] replace or add raw fields, and a null value removes one. */
fun feedJson(
    server: MockWebServer,
    apk: ByteArray,
    versionCode: Int = 3,
    versionName: String = "0.1.2-debug",
    apkPath: String = "/downloads/shelfarr-$versionCode.apk",
    overrides: Map<String, JsonElement?> = emptyMap(),
): String {
    val fields = linkedMapOf<String, JsonElement?>(
        "schema_version" to JsonPrimitive(1),
        "channel" to JsonPrimitive("development"),
        "package_name" to JsonPrimitive(PACKAGE),
        "version_code" to JsonPrimitive(versionCode),
        "version_name" to JsonPrimitive(versionName),
        "apk_url" to JsonPrimitive(server.url(apkPath).toString()),
        "size_bytes" to JsonPrimitive(apk.size),
        "sha256" to JsonPrimitive(sha256Hex(apk)),
        "release_notes" to JsonPrimitive("Faster library loading."),
    )
    fields.putAll(overrides)
    return buildJsonObject { fields.forEach { (key, value) -> if (value != null) put(key, value) } }.toString()
}

fun ok(body: String) = MockResponse.Builder().code(200).body(body).build()

fun ok(bytes: ByteArray) = MockResponse.Builder().code(200).body(Buffer().write(bytes)).build()

fun redirect(location: String, code: Int = 302) = MockResponse.Builder().code(code).addHeader("Location", location).build()

/**
 * Stands in for PackageManager. [archive] decides what a downloaded file claims to be;
 * by default, exactly the announced update signed like the installed app.
 */
class FakeInspector(
    var installed: AppIdentity = AppIdentity(PACKAGE, 2, "0.1.1-debug", setOf(SIGNER)),
    var archive: (File) -> AppIdentity? = { AppIdentity(PACKAGE, 3, "0.1.2-debug", setOf(SIGNER), minSdk = 26) },
) : PackageInspector {
    val inspected = mutableListOf<File>()
    override fun installed(): AppIdentity = installed
    override fun archive(file: File): AppIdentity? {
        inspected += file
        return archive.invoke(file)
    }
}

/** Stands in for PackageInstaller: records what was committed, and which sessions are open. */
class FakeInstaller(var allowed: Boolean = true) : PackageSessionInstaller {
    val committed = mutableListOf<ByteArray>()
    val open = mutableSetOf<Int>()
    val abandoned = mutableListOf<Int>()
    var nextSession = 41
    var failCommit: UpdateException? = null

    override fun canRequestInstalls(): Boolean = allowed

    override suspend fun commit(apk: File, onCreated: (Int) -> Unit) {
        val id = nextSession++
        onCreated(id)
        failCommit?.let { throw it }
        committed += apk.readBytes()
        open += id
    }

    override fun isOpen(sessionId: Int): Boolean = sessionId in open

    override fun abandon(sessionId: Int) {
        abandoned += sessionId
        open -= sessionId
    }

    override fun abandonOthers(keep: Int?) {
        open.filter { it != keep }.forEach(::abandon)
    }

    /** What Android would send when it finishes a session. */
    fun finish(sessionId: Int, code: Int = PackageInstaller.STATUS_SUCCESS): InstallStatus {
        open -= sessionId
        return InstallStatus(sessionId, code)
    }
}

class FakePlayback(var playing: Boolean = false) : PlaybackGuard {
    var pauses = 0
    override val isPlaying: Boolean get() = playing
    override fun pause() {
        pauses++
        playing = false
    }
}
