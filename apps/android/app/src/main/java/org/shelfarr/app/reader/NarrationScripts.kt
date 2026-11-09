package org.shelfarr.app.reader

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive

/**
 * The small scripts read-along runs in the page on screen (through Readium's
 * `evaluateJavascript`). They only read layout; they never change the document.
 * IDs travel as a JSON array, so no element ID can break out of the script.
 */
internal object NarrationScripts {
    /** "1" when the element [id] has any part inside the viewport, "0" otherwise. */
    fun isVisible(id: String): String = """
        (function(id){
          var e = document.getElementById(id); if (!e) return '0';
          var w = window.innerWidth, h = window.innerHeight, rs = e.getClientRects();
          for (var j = 0; j < rs.length; j++) {
            var r = rs[j];
            if ((r.width > 0 || r.height > 0) && r.right > 0 && r.left < w && r.bottom > 0 && r.top < h) return '1';
          }
          return '0';
        })(${JsonPrimitive(id)})
    """.trimIndent()

    /**
     * Of [ids] (narrated elements in document order), "v:<id>" for the first with any part in
     * view, else "a:<id>" for the first after the page, else "".
     */
    fun pageCues(ids: List<String>): String = """
        (function(ids){
          var w = window.innerWidth, h = window.innerHeight, after = null;
          for (var i = 0; i < ids.length; i++) {
            var e = document.getElementById(ids[i]); if (!e) continue;
            var rs = e.getClientRects();
            for (var j = 0; j < rs.length; j++) {
              var r = rs[j];
              if (r.width <= 0 && r.height <= 0) continue;
              if (r.right > 0 && r.left < w && r.bottom > 0 && r.top < h) return 'v:' + ids[i];
              if (after === null && (r.left >= w || r.top >= h)) after = ids[i];
            }
          }
          return after === null ? '' : 'a:' + after;
        })(${JsonArray(ids.map(::JsonPrimitive))})
    """.trimIndent()

    /** A WebView result is JSON (a quoted string); anything else is taken as it is. */
    fun decode(result: String?): String? {
        result ?: return null
        return runCatching { Json.parseToJsonElement(result).jsonPrimitive.contentOrNull }.getOrNull() ?: result
    }
}

/** The narration controls the reading screen offers. */
interface NarrationActions {
    fun toggle()
    fun skip(back: Boolean)
    fun setSpeed(speed: Float)
    fun setFollow(follow: Boolean)
    fun backToNarration()
    fun useAudiobookPlace()
    fun dismissAudiobookPlace()

    companion object {
        val None = object : NarrationActions {
            override fun toggle() = Unit
            override fun skip(back: Boolean) = Unit
            override fun setSpeed(speed: Float) = Unit
            override fun setFollow(follow: Boolean) = Unit
            override fun backToNarration() = Unit
            override fun useAudiobookPlace() = Unit
            override fun dismissAudiobookPlace() = Unit
        }
    }
}
