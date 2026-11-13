package org.shelfarr.app.core

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/**
 * `shelfarr://connect?server=<percent-encoded https base URL>`, which a Shelfarr
 * server's download page offers once the app is installed, so the address never has
 * to be typed. It carries the server's public address only — never a credential —
 * and grants nothing by itself: signing in is still the server's own browser approval.
 *
 * Parsing is strict. Anything but exactly that shape is ignored: another scheme,
 * host, path, fragment, user info or port; a second or unknown query field; a value
 * that isn't fully percent-encoded or doesn't decode to a plain HTTPS address with
 * no credentials, query, fragment, dot segments or escapes of its own.
 */
object ConnectLink {
    const val SCHEME = "shelfarr"
    const val HOST = "connect"
    const val ACTION_VIEW = "android.intent.action.VIEW"
    private const val MAX_LINK_CHARS = 4_096
    private const val MAX_SERVER_CHARS = 2_048

    /** Only RFC 3986 unreserved characters and escapes, so `:`, `/`, `&`, `=`, `+`, `#` must all be encoded. */
    private val LINK = Regex("^shelfarr://connect\\?server=([A-Za-z0-9._~%-]+)$")
    private val SERVER_TEXT = Regex("^https://([A-Za-z0-9.-]+|\\[[0-9A-Fa-f:.]+\\])(:[0-9]{1,5})?(/[A-Za-z0-9._~-]*)*$")

    /** The server a link names, or null if [action] and [data] aren't a valid connect link. */
    fun parse(action: String?, data: String?): ServerAddress? {
        if (action != ACTION_VIEW || data == null || data.length > MAX_LINK_CHARS) return null
        val encoded = LINK.matchEntire(data)?.groupValues?.get(1) ?: return null
        val server = decode(encoded) ?: return null
        return server(server)
    }

    /** The link a server page would offer for [server]. Used by tests and documentation. */
    fun build(server: ServerAddress): String {
        val value = server.display
        val encoded = buildString {
            value.toByteArray(Charsets.UTF_8).forEach { byte ->
                val char = (byte.toInt() and 0xff).toChar()
                if (char.isLetterOrDigit() && char.code < 0x80 || char in "-._~") append(char) else append("%%%02X".format(byte.toInt() and 0xff))
            }
        }
        return "$SCHEME://$HOST?server=$encoded"
    }

    /** Checks the decoded address as text before any parser can tidy it. */
    private fun server(value: String): ServerAddress? {
        if (value.length > MAX_SERVER_CHARS || !SERVER_TEXT.matches(value)) return null
        // The pattern rules out user info, queries, fragments and escapes; the URL
        // parser also validates bracketed IPv6 literals.
        val rest = value.removePrefix("https://")
        val path = rest.substringAfter('/', "")
        val segments = if (path.isEmpty()) emptyList() else path.removeSuffix("/").split('/')
        if (segments.any { it.isEmpty() || it == "." || it == ".." }) return null
        val url = value.toHttpUrlOrNull() ?: return null
        if (!url.isHttps || url.username.isNotEmpty() || url.password.isNotEmpty() || url.query != null || url.fragment != null) return null
        val parsed = ServerAddress.parse(value, allowLocalHttp = false) as? ServerAddress.ParseResult.Valid ?: return null
        return parsed.address.takeUnless { it.isCleartext }
    }

    /** Strict percent-decoding into UTF-8; null on a broken escape or invalid UTF-8. */
    private fun decode(value: String): String? {
        val bytes = ByteArrayOutputStream()
        var index = 0
        while (index < value.length) {
            val char = value[index]
            if (char == '%') {
                if (index + 2 >= value.length) return null
                val high = Character.digit(value[index + 1], 16)
                val low = Character.digit(value[index + 2], 16)
                if (high < 0 || low < 0) return null
                bytes.write(high * 16 + low)
                index += 3
            } else {
                bytes.write(char.code)
                index++
            }
        }
        val decoder = Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        return try {
            decoder.decode(ByteBuffer.wrap(bytes.toByteArray())).toString()
        } catch (_: CharacterCodingException) {
            null
        }
    }
}

/** What to do with a connect link, given where the app is. Nothing here signs out or replaces anything. */
sealed interface ConnectDecision {
    /** Signed out and idle: start the usual browser approval for [server]. */
    data class Connect(val server: ServerAddress) : ConnectDecision

    /** Already connected to, or already signing in to, that server: just show the app. */
    data object AlreadyThere : ConnectDecision

    /** Something else is connected or under way; explain instead of switching. */
    data class Explain(val title: String, val message: String) : ConnectDecision
}

/** Where sign-in stands, as far as a link is concerned. */
enum class SignInActivity { IDLE, IN_PROGRESS }

object ConnectLinks {
    fun decide(
        requested: ServerAddress,
        session: SessionState,
        signIn: SignInActivity = SignInActivity.IDLE,
        signingInTo: ServerAddress? = null,
    ): ConnectDecision = when (session) {
        is SessionState.SignedIn -> if (session.session.server == requested) {
            ConnectDecision.AlreadyThere
        } else {
            ConnectDecision.Explain(
                title = "Connected to another server",
                message = "This link is for ${requested.display}, but Shelfarr is connected to " +
                    "${session.session.server.display}. Nothing was changed. To use the other server, " +
                    "disconnect this device in Settings, then open the link again. Disconnecting removes " +
                    "this server's downloads and saved places from this device.",
            )
        }
        is SessionState.Expired -> if (session.server != requested) {
            ConnectDecision.Explain(
                title = "Sign in again first",
                message = "This link is for ${requested.display}, but this device was last connected to " +
                    "${session.server.display} and still keeps its downloads and saved places. Nothing was changed. " +
                    "Sign in to ${session.server.host} again to carry on, or enter the other address yourself to switch.",
            )
        } else {
            whileSignedOut(requested, signIn, signingInTo)
        }
        SessionState.SignedOut -> whileSignedOut(requested, signIn, signingInTo)
    }

    private fun whileSignedOut(requested: ServerAddress, signIn: SignInActivity, signingInTo: ServerAddress?): ConnectDecision = when {
        signIn == SignInActivity.IDLE -> ConnectDecision.Connect(requested)
        signingInTo == requested -> ConnectDecision.AlreadyThere
        else -> ConnectDecision.Explain(
            title = "Finish signing in first",
            message = "This link is for ${requested.display}, but signing in to ${signingInTo?.host ?: "another server"} " +
                "is already under way. Nothing was changed. Cancel that sign-in first, then open the link again.",
        )
    }
}
