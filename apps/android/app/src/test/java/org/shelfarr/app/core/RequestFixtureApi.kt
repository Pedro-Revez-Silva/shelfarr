package org.shelfarr.app.core

import java.util.concurrent.atomic.AtomicInteger
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest

/**
 * An in-process stand-in for the consumer API's requesting endpoints, following
 * docs/consumer-api.md. Synthetic data only: nothing is searched, bought or acquired.
 * A request moves one stage each time it is read, until a fixture publication appears.
 */
class RequestFixtureApi(
    /** Behave like a server that predates requesting. */
    var oldServer: Boolean = false,
) {
    enum class Decision { APPROVE, DENY, APPROVE_AS_OTHER_USER }

    val server = MockWebServer()
    @Volatile var decision = Decision.APPROVE
    @Volatile var searchFails = false
    /**
     * Where new requests end after searching: "available", "not_found" or "failed", or
     * "attention": still searching, flagged for the server's admin without a reason, as a
     * real server with no acquisition source reports it.
     */
    @Volatile var outcome = "available"

    val tokens = java.util.concurrent.ConcurrentHashMap<String, Pair<String, List<String>>>()
    val revoked = java.util.concurrent.CopyOnWriteArrayList<String>()
    val deviceRequests = java.util.concurrent.CopyOnWriteArrayList<RecordedRequest>()
    val createRequests = AtomicInteger()
    private val counter = AtomicInteger()
    private val devices = java.util.concurrent.ConcurrentHashMap<String, Device>()
    private val requests = java.util.LinkedHashMap<String, MutableMap<String, Any?>>()

    private data class Device(val scopes: List<String>, var polls: Int = 0)

    val address: ServerAddress
        get() = (ServerAddress.parse(server.url("/shelfarr").toString(), allowLocalHttp = true) as ServerAddress.ParseResult.Valid).address

    fun issue(scopes: List<String> = RequestScopes.BASE, user: String = "u1"): String =
        "tok-${counter.incrementAndGet()}".also { tokens[it] = user to scopes }

    fun start(): RequestFixtureApi {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = synchronized(this@RequestFixtureApi) { handle(request) }
        }
        server.start()
        return this
    }

    fun shutdown() = server.close()

    private fun json(code: Int, body: String) = MockResponse.Builder().code(code).addHeader("Content-Type", "application/json").body(body).build()

    private fun bearer(request: RecordedRequest) = request.headers["Authorization"]?.removePrefix("Bearer ")

    private fun handle(request: RecordedRequest): MockResponse {
        val url = request.url
        val path = url.encodedPath.removePrefix("/shelfarr/api/consumer/v1/")
        val body = request.body?.utf8().orEmpty()
        val token = bearer(request)
        if (path == "server.json") {
            return if (oldServer) json(200, """{"schema_version":1,"consumer_api_versions":[1]}""") else json(200, """{"schema_version":1,"consumer_api_versions":[1],"consumer_features":["requests"]}""")
        }
        if (path == "auth/device") {
            deviceRequests += request
            val fields = Json.parseToJsonElement(body).jsonObject
            val asked = fields["scope"]?.jsonPrimitive?.contentOrNull
            if (token != null && !oldServer && !tokens.containsKey(token)) return json(401, "{}")
            val scopes = if (!oldServer && asked != null && asked.split(" ").containsAll(RequestScopes.REQUESTING)) RequestScopes.BASE + RequestScopes.REQUESTING else RequestScopes.BASE
            val code = "dev-${counter.incrementAndGet()}"
            devices[code] = Device(scopes)
            val base = server.url("/shelfarr/consumer/connect").toString()
            return json(200, """{"device_code":"$code","user_code":"ABCD-EFGH","verification_uri":"$base","verification_uri_complete":"$base?user_code=ABCD-EFGH","expires_in":600,"interval":1}""")
        }
        if (path == "auth/token") {
            val code = Json.parseToJsonElement(body).jsonObject["device_code"]?.jsonPrimitive?.contentOrNull
            val device = devices[code] ?: return json(400, """{"error":"expired_token"}""")
            device.polls++
            if (device.polls < 2) return json(400, """{"error":"authorization_pending"}""")
            devices.remove(code)
            if (decision == Decision.DENY) return json(400, """{"error":"access_denied"}""")
            val issued = issue(device.scopes, if (decision == Decision.APPROVE_AS_OTHER_USER) "u2" else "u1")
            return json(200, """{"access_token":"$issued","token_type":"Bearer","scope":"${device.scopes.joinToString(" ")}","expires_in":2592000}""")
        }
        val owner = tokens[token] ?: return json(401, "{}")
        val (user, scopes) = owner
        fun need(scope: String) = if (scope in scopes) null else json(403, """{"error":"insufficient_scope","required_scope":"$scope"}""")
        return when {
            path == "auth/revoke" -> {
                tokens.remove(token)
                revoked += token!!
                MockResponse.Builder().code(204).build()
            }
            path == "me" -> json(200, if (oldServer) """{"id":"$user","name":"Ada"}""" else """{"id":"$user","name":"Ada","scopes":${scopes.joinToString(",", "[", "]") { "\"$it\"" }}}""")
            oldServer && (path == "discover" || path.startsWith("requests")) -> json(404, """{"error":"not_found"}""")
            path == "discover" -> need("search:read") ?: if (searchFails) {
                json(503, """{"error":"search_unavailable"}""")
            } else {
                val q = url.queryParameter("q").orEmpty().lowercase()
                json(200, """{"items":[${CATALOGUE.filter { q in it.second.lowercase() }.joinToString(",") { item(it) }}]}""")
            }
            path == "requests" && request.method == "POST" -> need("requests:write") ?: create(Json.parseToJsonElement(body).jsonObject)
            path == "requests" -> need("requests:read") ?: json(200, """{"items":[${requests.keys.reversed().joinToString(",") { view(advance(it)) }}]}""")
            path.startsWith("requests/") && request.method == "DELETE" -> need("requests:write") ?: run {
                val id = path.removePrefix("requests/")
                val r = requests[id] ?: return json(404, "{}")
                if (r["stage"] in setOf("processing", "available")) return json(422, """{"error":"cannot_cancel","message":"This request is being finished and can't be cancelled now."}""")
                r["stage"] = "failed"
                json(200, """{"request":${view(id)}}""")
            }
            path.startsWith("requests/") -> need("requests:read") ?: run {
                val id = path.removePrefix("requests/")
                if (id !in requests) json(404, "{}") else json(200, """{"request":${view(advance(id))}}""")
            }
            path.startsWith("library/") -> {
                val id = path.removePrefix("library/")
                val r = requests.values.firstOrNull { it["publication"] == id } ?: return json(404, "{}")
                json(200, """{"id":"$id","title":"${r["title"]}","book_type":"${r["type"]}","assets":[]}""")
            }
            else -> json(404, """{"error":"not_found"}""")
        }
    }

    private fun create(fields: JsonObject): MockResponse {
        createRequests.incrementAndGet()
        val work = fields["work_id"]?.jsonPrimitive?.contentOrNull
        val type = fields["book_type"]?.jsonPrimitive?.contentOrNull
        val entry = CATALOGUE.firstOrNull { it.first == work } ?: return json(422, """{"error":"invalid_request"}""")
        when (state(entry.first, type!!)) {
            "in_library" -> return json(409, """{"error":"already_in_library","message":"Already in the library.","publication_id":"lib-1"}""")
            "requested_by_someone" -> return json(409, """{"error":"already_requested","message":"Someone on this server has already requested this audiobook."}""")
        }
        requests.entries.firstOrNull { it.value["work"] == work && it.value["type"] == type && it.value["stage"] != "failed" }?.let {
            return json(200, """{"request":${view(it.key)},"existing":true}""")
        }
        val id = "r${counter.incrementAndGet()}"
        requests[id] = mutableMapOf("work" to work, "type" to type, "title" to entry.second, "stage" to "queued", "step" to 0)
        return json(201, """{"request":${view(id)},"warnings":[]}""")
    }

    private fun advance(id: String): String {
        val r = requests.getValue(id)
        val stage = r["stage"]
        if (stage in setOf("available", "failed", "not_found")) return id
        if (stage == "searching" && outcome == "attention") {
            r["attention"] = true
            return id
        }
        if (stage == "searching" && outcome != "available") {
            r["stage"] = outcome
            return id
        }
        val step = (r["step"] as Int) + 1
        r["step"] = step
        val (next, percent) = STEPS[minOf(step, STEPS.lastIndex)]
        r["stage"] = next
        r["percent"] = percent
        if (next == "available") r["publication"] = "pub-$id"
        return id
    }

    private fun view(id: String): String {
        val r = requests.getValue(id)
        val stage = r["stage"]
        val publication = if (stage == "available") "\"${r["publication"]}\"" else "null"
        val percent = if (stage == "downloading") r["percent"].toString() else "null"
        return """{"id":"$id","stage":"$stage","title":"${r["title"]}","author":"Fixture Author","book_type":"${r["type"]}","download_percent":$percent,"can_cancel":${stage !in setOf("available", "failed")},"attention_needed":${r["attention"] == true},"publication_id":$publication}"""
    }

    private fun state(work: String, type: String): String = when {
        work == "fx:in-library" && type == "ebook" -> "in_library"
        work == "fx:elsewhere" && type == "audiobook" -> "requested_by_someone"
        else -> "requestable"
    }

    private fun item(entry: Pair<String, String>): String {
        val formats = listOf("ebook", "audiobook").joinToString(",") { type ->
            val mine = requests.entries.firstOrNull { it.value["work"] == entry.first && it.value["type"] == type && it.value["stage"] != "failed" }
            when {
                mine != null && mine.value["stage"] == "available" -> """{"book_type":"$type","state":"in_library","publication_id":"${mine.value["publication"]}"}"""
                mine != null -> """{"book_type":"$type","state":"requested","request":${view(mine.key)}}"""
                state(entry.first, type) == "in_library" -> """{"book_type":"$type","state":"in_library","publication_id":"lib-1"}"""
                else -> """{"book_type":"$type","state":"${state(entry.first, type)}"}"""
            }
        }
        return """{"id":"${entry.first}","work_id":"${entry.first}","title":"${entry.second}","author":"Fixture Author","year":2019,"formats":[$formats]}"""
    }

    companion object {
        val CATALOGUE = listOf(
            "fx:lighthouse" to "The Lighthouse Keeper",
            "fx:in-library" to "A Book Already Here",
            "fx:elsewhere" to "Rivers Remember",
        )
        private val STEPS = listOf("queued" to null, "searching" to null, "downloading" to 30, "downloading" to 70, "processing" to null, "available" to null)
    }
}
