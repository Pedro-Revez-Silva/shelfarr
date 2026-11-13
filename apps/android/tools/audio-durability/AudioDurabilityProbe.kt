package org.shelfarr.app.audiodurability

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Build
import android.os.Process
import android.os.SystemClock
import android.util.Log
import androidx.media3.common.Player
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.io.FileOutputStream
import java.net.BindException
import java.net.InetAddress
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.roundToLong
import kotlin.math.sin
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import okio.Buffer
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import org.shelfarr.app.ShelfarrApplication
import org.shelfarr.app.core.ActivityTime
import org.shelfarr.app.core.ApiJson
import org.shelfarr.app.core.Asset
import org.shelfarr.app.core.BookType
import org.shelfarr.app.core.ContinueList
import org.shelfarr.app.core.LibraryPage
import org.shelfarr.app.core.Me
import org.shelfarr.app.core.Progress
import org.shelfarr.app.core.ProgressEnvelope
import org.shelfarr.app.core.Publication
import org.shelfarr.app.core.ServerAddress
import org.shelfarr.app.core.Session
import org.shelfarr.app.core.SessionState
import org.shelfarr.app.core.StorageLayout
import org.shelfarr.app.playback.PlaybackController
import org.shelfarr.app.ui.MainActivity
import org.shelfarr.app.ui.player.PlayerViewModel

/**
 * Emulator-only durability probe for audiobook listening checkpoints. It is NOT part of
 * the app's test sources: `apps/android/tools/audio-durability-acceptance.py` documents
 * how a checkout temporarily compiles it into `androidTest` and then removes the copy.
 * Run only by that controller, one stage per instrumentation run:
 *
 *  - `play`: a fresh install signs in to a synthetic local fixture (the only fake),
 *    downloads an AAC file generated here with MediaCodec, and plays it through the
 *    production PlayerViewModel, PlaybackController, MediaController and
 *    PlaybackService (ExoPlayer decoding a real file) with MainActivity in front. It
 *    samples the production controller's position on the main thread against the
 *    real `progress.json` on disk and asserts the cadence. The fixture refuses progress
 *    (503), so places queue on the device. It then announces a kill window between two
 *    checkpoints and keeps sampling until the controller SIGKILLs this process from
 *    outside. Reaching the end of this stage is a failure: the process must die first.
 *  - `reopen`: a fresh process. It checks progress.json is byte-identical to what the
 *    controller pulled after the kill, restarts the fixture at the same origin and port
 *    (now accepting progress), brings the app to the foreground so it sends its queue,
 *    and checks each write carries the old listening time. It then reopens the book
 *    through PlayerViewModel and checks the single five-second resume rewind, that the
 *    replay is never saved as new activity, and the same once more after a pause.
 *
 * Synthetic data only. It refuses to run outside an emulator or over an existing session.
 */
@RunWith(AndroidJUnit4::class)
class AudioDurabilityProbe {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val arguments = InstrumentationRegistry.getArguments()
    private val app = ApplicationProvider.getApplicationContext<ShelfarrApplication>()
    private val container get() = app.container
    private val stage: String? = arguments.getString("shelfarrAudioStage")
    private val port: Int = arguments.getString("shelfarrFixturePort")?.toInt() ?: 0
    private val killAfterCheckpointMs: Long = arguments.getString("shelfarrKillAfterCheckpointMs")?.toLong() ?: 2_000L
    private val work get() = File(app.filesDir, "audio-durability").apply { mkdirs() }

    private data class Heard(val el: Long, val wall: Long, val pos: Long, val playing: Boolean, val media: String?, val state: Int)

    private data class Disk(val pos: Long?, val observed: Long?, val pending: String?, val pendingObserved: Long?, val dirty: Boolean, val readEl: Long) {
        fun place() = pos to observed
    }

    private data class Sample(val heard: Heard, val disk: Disk) {
        /** Listening that would be lost if the process died now. Nothing on disk reopens at the start. */
        val lag: Long get() = heard.pos - (disk.pos ?: 0)
        fun json(): JSONObject = JSONObject()
            .put("el", heard.el).put("wall", heard.wall).put("pos", heard.pos).put("playing", heard.playing)
            .put("state", heard.state).put("media", heard.media)
            .put("diskPos", disk.pos).put("diskObs", disk.observed).put("diskPending", disk.pending)
            .put("diskPendingObs", disk.pendingObserved).put("diskDirty", disk.dirty).put("diskReadEl", disk.readEl)
    }

    /** A position discontinuity reported by the production MediaController. */
    private data class Jump(val el: Long, val reason: Int, val from: Long, val to: Long) {
        fun json(): JSONObject = JSONObject().put("el", el).put("reason", reason).put("from", from).put("to", to)
    }

    /** A received progress write, with when it arrived. */
    private data class Write(val receivedWall: Long, val body: JSONObject, val code: Int)

    @Test
    fun probe() {
        assertTrue(
            "Emulator only: refusing on ${Build.FINGERPRINT}",
            Build.HARDWARE == "ranchu" || Build.HARDWARE == "goldfish" || Build.PRODUCT.startsWith("sdk_gphone"),
        )
        assertTrue("A fixed fixture port is required", port in 1024..65535)
        when (stage) {
            "play" -> play()
            "reopen" -> reopen()
            else -> fail("Only audio-durability-acceptance.py runs this probe (stage=$stage)")
        }
    }

    // ---------------------------------------------------------------------------------
    // Stage 1: listen, measure, die.

    private fun play() {
        assertEquals("Needs a fresh install, never a real session", SessionState.SignedOut, container.sessions.session.value)
        val audio = File(work, "generated.m4a")
        val generated = SystemClock.elapsedRealtime()
        generateAac(audio, AUDIO_SECONDS)
        val bytes = audio.readBytes()
        log("generated", JSONObject().put("bytes", bytes.size).put("sha256", sha256(bytes)).put("seconds", AUDIO_SECONDS)
            .put("encodeMs", SystemClock.elapsedRealtime() - generated))

        val writes = CopyOnWriteArrayList<Write>()
        val web = fixture(bytes, accept = false, writes = writes, stored = null)
        val server = (ServerAddress.parse(web.url("/").toString(), allowLocalHttp = true) as ServerAddress.ParseResult.Valid).address
        val session = Session(server, Me(USER_ID, "Durability Listener"), TOKEN)
        container.sessions.signIn(session)
        container.askedForNotifications = true
        val account = container.account(session)
        val progressFile = File(account.directory, StorageLayout.PROGRESS_FILE)
        runBlocking {
            account.ready.join()
            account.downloads.enqueue(book(bytes.size.toLong(), null))
        }
        await("the generated audiobook to download", 60_000) { account.downloads.ready(BOOK_ID) != null }
        val downloaded = account.downloads.filesFor(account.downloads.ready(BOOK_ID)!!)!!.getValue(TRACK_ID)
        assertEquals("The downloaded track is the generated file", sha256(bytes), sha256(downloaded.readBytes()))
        writeRun(JSONObject().put("accountKey", session.accountKey).put("server", server.display).put("port", port)
            .put("progressFile", progressFile.path).put("audioSha256", sha256(bytes)).put("audioBytes", bytes.size)
            .put("pid", Process.myPid()))

        // The app in front, as a listener with Shelfarr open; the kill comes while it is visible.
        ActivityScenario.launch(MainActivity::class.java)
        instrumentation.runOnMainSync { PlayerViewModel(container, BOOK_ID) }
        val samples = Sampler("play", progressFile)
        val started = samples.awaitPlaying(START_DEADLINE_MS)
        log("playing", started.json())

        // Steady state: at least STEADY_MS of real playback with checkpoints arriving.
        samples.runFor(STEADY_MS)
        val steady = samples.all()
        val checks = cadence(steady, label = "play")
        log("cadence", checks)
        assertTrue("No checkpoint was ever written during real playback", checks.getInt("checkpoints") >= STEADY_MS / 5_000)
        assertTrue("Fixture never saw a queued write attempt", writes.isNotEmpty())
        assertTrue("The fixture accepted a write during play", writes.all { it.code == 503 })

        // Between checkpoints: wait for the next on-disk checkpoint, then killAfterCheckpointMs more.
        assertTrue("Kill offset must fall between checkpoints", killAfterCheckpointMs in 500L..3_500L)
        val before = samples.last().disk.place()
        samples.runUntil(15_000) { it.disk.place() != before }
        val checkpointEl = samples.last().disk.readEl
        samples.runUntil(10_000) { it.heard.el - checkpointEl >= killAfterCheckpointMs }
        val window = samples.last()
        log("kill-window", window.json().put("checkpointEl", checkpointEl).put("pid", Process.myPid()))
        // Keep listening and sampling. The controller SIGKILLs this process from outside.
        samples.runFor(KILL_DEADLINE_MS)
        web.close()
        fail("Still alive ${KILL_DEADLINE_MS}ms after the kill window: the controller never killed the process")
    }

    // ---------------------------------------------------------------------------------
    // Stage 2: a fresh process after SIGKILL.

    private fun reopen() {
        val run = JSONObject(File(work, "run.json").readText())
        val killedPid = arguments.getString("shelfarrKilledPid")!!.toInt()
        val killWall = arguments.getString("shelfarrKillWallMs")!!.toLong()
        val expectedSha = arguments.getString("shelfarrKilledProgressSha256")!!
        assertTrue("This is a new process", Process.myPid() != killedPid && Process.myPid() != run.getInt("pid"))
        val processStartWall = System.currentTimeMillis() - (SystemClock.elapsedRealtime() - Process.getStartElapsedRealtime())
        assertTrue("This process started after the kill", processStartWall > killWall)

        // Nothing has run but Application start-up: the file must be exactly what died with the process.
        val progressFile = File(run.getString("progressFile"))
        val startupBytes = progressFile.readBytes()
        assertEquals("progress.json changed between the kill and reopening", expectedSha, sha256(startupBytes))
        val killed = readDisk(progressFile)
        val savedPos = assertNotNull_("No place survived the kill", killed.pos)
        val savedObs = assertNotNull_("No activity time survived the kill", killed.observed)
        assertTrue("The surviving activity time predates the kill", savedObs < killWall)
        assertTrue("A queued write survived", killed.pending != null || killed.dirty)
        log("survived", JSONObject().put("pos", savedPos).put("obs", savedObs).put("pending", killed.pending)
            .put("pendingObs", killed.pendingObserved).put("dirty", killed.dirty).put("killWall", killWall)
            .put("processStartWall", processStartWall).put("pid", Process.myPid()).put("killedPid", killedPid))

        val session = assertNotNull_("The Keystore session did not survive", container.sessions.signedIn)
        assertEquals(run.getString("accountKey"), session.accountKey)
        val account = container.account(session)
        runBlocking { account.ready.join() }
        val bytes = File(work, "generated.m4a").readBytes()
        assertNotNull("The download survived", account.downloads.ready(BOOK_ID))

        val writes = CopyOnWriteArrayList<Write>()
        val stored = StoredProgress()
        val web = fixture(bytes, accept = true, writes = writes, stored = stored)
        assertEquals("Same origin as before the kill", run.getString("server"),
            (ServerAddress.parse(web.url("/").toString(), allowLocalHttp = true) as ServerAddress.ParseResult.Valid).address.display)
        val fixtureUpWall = System.currentTimeMillis()

        // Reopening the app sends what the dead process queued, with the time it was heard.
        ActivityScenario.launch(MainActivity::class.java)
        await("the queue to reach the fixture", 30_000) {
            val disk = readDisk(progressFile)
            disk.pending == null && !disk.dirty && writes.any { it.code == 200 }
        }
        val afterFlush = readDisk(progressFile)
        val queued = writes.toList()
        val queue = JSONArray()
        queued.forEach { queue.put(JSONObject().put("receivedWall", it.receivedWall).put("code", it.code).put("body", it.body)) }
        log("queue-sent", JSONObject().put("writes", queue).put("fixtureUpWall", fixtureUpWall))
        assertTrue("Every queued write was accepted", queued.all { it.code == 200 })
        queued.forEach {
            val observed = ActivityTime.parse(it.body.optString("observed_at"))
            assertNotNull("A queued write without its listening time: ${it.body}", observed)
            assertTrue("A queued write stamped after the kill: ${it.body}", observed!! < killWall)
            assertTrue("Sent at reopening, not before the kill", it.receivedWall >= fixtureUpWall)
        }
        val last = queued.last().body
        assertEquals("The last place before the kill reached the server", savedPos, seconds(last))
        assertEquals("…with the time it was heard, not the sync time", savedObs, ActivityTime.parse(last.getString("observed_at")))
        assertTrue("Sync came well after listening", queued.last().receivedWall - savedObs >= MIN_LISTEN_TO_SYNC_GAP_MS)
        assertEquals("Sending kept the place", savedPos, afterFlush.pos)
        assertEquals("Sending kept the activity time", savedObs, afterFlush.observed)

        // Reopen the book: one rewind, and the replay is not saved.
        val reopenWall = System.currentTimeMillis()
        instrumentation.runOnMainSync { PlayerViewModel(container, BOOK_ID) }
        val samples = Sampler("reopen", progressFile)
        val first = samples.awaitTrack(10_000)
        log("first-position", first.json())
        val expectedStart = (savedPos - REWIND_MS).coerceAtLeast(0)
        assertTrue("Resumed at ${first.heard.pos}, not one rewind before $savedPos", first.heard.pos in expectedStart..expectedStart + START_SLACK_MS)
        samples.awaitPlaying(START_DEADLINE_MS)
        // Through the replay and well past the saved place.
        samples.runUntil(20_000) { it.heard.pos >= savedPos + PAST_PLACE_MS }
        val firstLeg = samples.all()
        val replay = firstLeg.filter { it.heard.pos < savedPos }
        assertTrue("The replay was sampled", replay.size >= 40)
        replay.forEach {
            assertEquals("The replay was saved as a new place: ${it.json()}", savedPos to savedObs, it.disk.place())
        }
        val resumedCheckpoint = firstLeg.firstOrNull { it.disk.place() != (savedPos to savedObs) }
        assertNotNull("No checkpoint once playback passed the saved place", resumedCheckpoint)
        assertTrue("The first new checkpoint is past the saved place: ${resumedCheckpoint!!.json()}", resumedCheckpoint.disk.pos!! > savedPos)
        assertTrue("…and stamped with new listening time", resumedCheckpoint.disk.observed!! >= reopenWall)
        // Exactly one rewind: the open itself starts five seconds early. Nothing may seek again.
        val reopenSeeks = samples.seeks(0)
        assertTrue("reopen: the player sought after opening: ${reopenSeeks.map { it.json() }}", reopenSeeks.isEmpty())
        val reopenCorrection = noBackwardJump(firstLeg, "reopen")
        val reopenCadence = cadence(firstLeg.filter { it.heard.pos >= savedPos }, label = "reopen", minWindowMs = PAST_PLACE_MS - 1_000)
        log("reopen-cadence", reopenCadence)

        // A pause and an explicit play: one rewind again, replay not saved again.
        instrumentation.runOnMainSync { container.playback.pause() }
        samples.runUntil(10_000) { !it.heard.playing && it.disk.pos != null && abs(it.disk.pos - it.heard.pos) <= PAUSE_SLACK_MS }
        val paused = samples.last()
        val pausedPlace = paused.disk.place()
        log("paused", paused.json())
        samples.runFor(PAUSE_HOLD_MS)
        val settled = samples.last()
        assertEquals("Paused, nothing more was written", pausedPlace, settled.disk.place())
        // Going to the background while paused (what onBackground calls) is not listening,
        // even if the paused controller's position has settled a few ms from the checkpoint.
        instrumentation.runOnMainSync { container.playback.checkpointNow() }
        samples.runFor(BACKGROUND_HOLD_MS)
        val backgrounded = samples.last()
        log("paused-background", JSONObject().put("checkpoint", pausedPlace.first).put("settledPos", settled.heard.pos)
            .put("settleMs", pausedPlace.first!! - settled.heard.pos).put("after", backgrounded.json()))
        assertEquals("A paused place was re-stamped as new listening on backgrounding: ${backgrounded.json()}", pausedPlace, backgrounded.disk.place())
        val resumeMark = samples.all().size
        val resumeEl = SystemClock.elapsedRealtime()
        instrumentation.runOnMainSync { container.playback.togglePlay() }
        samples.runUntil(10_000) { it.heard.playing }
        samples.runUntil(20_000) { it.heard.pos >= pausedPlace.first!! + PAST_PLACE_MS }
        val secondLeg = samples.all().drop(resumeMark)
        val rewound = secondLeg.first { abs(it.heard.pos - paused.heard.pos) > 1_000 }
        val pauseTarget = (pausedPlace.first!! - REWIND_MS).coerceAtLeast(0)
        assertTrue("Play after a pause restarted at ${rewound.heard.pos}, not one rewind before ${pausedPlace.first}",
            rewound.heard.pos in pauseTarget - START_SLACK_MS..pauseTarget + START_SLACK_MS)
        secondLeg.filter { it.heard.pos < pausedPlace.first!! }.forEach {
            assertEquals("The post-pause replay was saved: ${it.json()}", pausedPlace, it.disk.place())
        }
        // Exactly one rewind for the resume: to five seconds before where it paused. A
        // MediaController reports its own seek once when it masks it and again, with the
        // service player's slightly later "from", when the session echoes it; both name the
        // same target. A second rewind would name a different, earlier one.
        val resumeSeeks = samples.seeks(resumeEl)
        assertTrue("after-pause: no rewind seek", resumeSeeks.isNotEmpty())
        val rewindTarget = resumeSeeks.first().to
        assertTrue("after-pause: more than one rewind: ${resumeSeeks.map { it.json() }}",
            resumeSeeks.all { abs(it.to - rewindTarget) <= SEEK_ECHO_SLACK_MS })
        assertTrue("after-pause: the rewind went to $rewindTarget, not ~$pauseTarget",
            rewindTarget in pauseTarget - START_SLACK_MS..pauseTarget + START_SLACK_MS)
        val lowest = secondLeg.dropWhile { it !== rewound }.minOf { it.heard.pos }
        assertTrue("after-pause: heard $lowest, below the one rewind to $rewindTarget", lowest >= rewindTarget - SEEK_ECHO_SLACK_MS)
        val pauseCorrection = noBackwardJump(secondLeg.dropWhile { it !== rewound }, "after-pause")
        assertTrue("A new checkpoint after passing the paused place", secondLeg.last().disk.pos!! > pausedPlace.first!!)

        runBlocking { container.playback.stop() }
        await("the final place to reach the fixture", 20_000) { readDisk(progressFile).let { it.pending == null && !it.dirty } }
        web.close()

        // Every write the server got: places only ever move forward, each stamped no later than it arrived.
        val all = writes.toList()
        val positions = all.map { seconds(it.body) }
        val observed = all.map { ActivityTime.parse(it.body.getString("observed_at"))!! }
        assertTrue("A write went backwards (replay resaved?): $positions", positions.zipWithNext().all { (a, b) -> b > a })
        assertTrue("Activity times went backwards: $observed", observed.zipWithNext().all { (a, b) -> b > a })
        all.forEach { assertTrue("observed_at after arrival: ${it.body}", ActivityTime.parse(it.body.getString("observed_at"))!! <= it.receivedWall) }
        val result = JSONObject()
            .put("savedPos", savedPos).put("savedObs", savedObs).put("killWall", killWall)
            .put("firstReopenPos", first.heard.pos).put("expectedStart", expectedStart)
            .put("resumedCheckpoint", resumedCheckpoint.json())
            .put("pausedPlace", JSONArray().put(pausedPlace.first).put(pausedPlace.second))
            .put("postPauseRestart", rewound.heard.pos).put("postPauseTarget", pauseTarget)
            .put("pauseSettleMs", pausedPlace.first!! - settled.heard.pos).put("backgroundedWhilePaused", backgrounded.json())
            .put("seeks", JSONArray().apply { samples.jumps.forEach { put(it.json()) } })
            .put("maxEstimateCorrectionMs", maxOf(reopenCorrection, pauseCorrection))
            .put("reopenCadence", reopenCadence)
            .put("serverWrites", JSONArray().apply { all.forEach { put(JSONObject().put("receivedWall", it.receivedWall).put("body", it.body)) } })
        File(work, "reopen-result.json").writeText(result.toString(2))
        log("result", result)
    }

    // ---------------------------------------------------------------------------------
    // Measurements.

    /**
     * Samples the production MediaController's position on the main thread, paired with
     * the record in progress.json read just before it. The disk is read first, so a lag
     * computed from a pair can only overstate what was at risk, never understate it.
     */
    private inner class Sampler(private val name: String, private val file: File) {
        private val samples = ArrayList<Sample>()
        private val out = FileOutputStream(File(work, "$name-samples.jsonl"), true)
        private val controllerField = PlaybackController::class.java.getDeclaredField("controller").apply { isAccessible = true }
        private var watched: Player? = null

        /** Every discontinuity the production controller reports, from when it first exists. Main thread writes. */
        val jumps = CopyOnWriteArrayList<Jump>()
        private val listener = object : Player.Listener {
            override fun onPositionDiscontinuity(oldPosition: Player.PositionInfo, newPosition: Player.PositionInfo, reason: Int) {
                val jump = Jump(SystemClock.elapsedRealtime(), reason, oldPosition.positionMs, newPosition.positionMs)
                jumps += jump
                log("discontinuity", jump.json().put("sampler", name))
            }
        }

        /** Seeks (Media3 DISCONTINUITY_REASON_SEEK) at or after [sinceEl]. */
        fun seeks(sinceEl: Long): List<Jump> = jumps.filter { it.reason == Player.DISCONTINUITY_REASON_SEEK && it.el >= sinceEl }

        fun all(): List<Sample> = samples.toList()
        fun last(): Sample = samples.last()

        private fun take(): Sample {
            val disk = readDisk(file)
            var heard: Heard? = null
            instrumentation.runOnMainSync {
                val player = controllerField.get(container.playback) as Player?
                if (player != null && player !== watched) {
                    player.addListener(listener)
                    watched = player
                }
                heard = Heard(
                    el = SystemClock.elapsedRealtime(),
                    wall = System.currentTimeMillis(),
                    pos = player?.currentPosition ?: -1,
                    playing = player?.isPlaying == true,
                    media = player?.currentMediaItem?.mediaId,
                    state = player?.playbackState ?: -1,
                )
            }
            val sample = Sample(heard!!, disk)
            samples += sample
            // One write(2) per line: it survives SIGKILL of this process.
            out.write((sample.json().toString() + "\n").toByteArray())
            if (samples.size % 20 == 0) log("sample", sample.json())
            return sample
        }

        fun runUntil(timeoutMs: Long, why: () -> String = { "" }, done: (Sample) -> Boolean): Sample {
            val deadline = SystemClock.elapsedRealtime() + timeoutMs
            while (true) {
                val sample = take()
                if (done(sample)) return sample
                if (SystemClock.elapsedRealtime() > deadline) fail("$name: timed out after ${timeoutMs}ms at ${sample.json()} ${why()}")
                SystemClock.sleep(SAMPLE_MS)
            }
        }

        fun runFor(durationMs: Long) {
            val end = SystemClock.elapsedRealtime() + durationMs
            runUntil(durationMs + 5_000) { SystemClock.elapsedRealtime() >= end }
        }

        fun awaitTrack(timeoutMs: Long): Sample = runUntil(timeoutMs) { it.heard.media == TRACK_ID }

        /** Fails visibly unless real audio is playing and its position advancing. */
        fun awaitPlaying(timeoutMs: Long): Sample {
            val playing = runUntil(timeoutMs, { "Audio never started playing: ${container.playback.snapshot.value}" }) {
                it.heard.playing && it.heard.pos > 0
            }
            val later = runUntil(5_000) { it.heard.el - playing.heard.el >= 2_000 }
            assertTrue("Playback position did not advance: ${playing.json()} -> ${later.json()}", later.heard.pos - playing.heard.pos >= 1_500)
            return playing
        }
    }

    /**
     * Asserts the five-second bound over [samples] (all while playing) and returns the
     * measurements: the lag between the position heard and the place on disk, the gaps
     * between checkpoints, the playback rate and how each checkpoint's activity time
     * compares with when its position was actually heard.
     */
    private fun cadence(samples: List<Sample>, label: String, minWindowMs: Long = STEADY_MS - 1_000): JSONObject {
        val playing = samples.filter { it.heard.playing && it.heard.media == TRACK_ID }
        assertTrue("$label: too few playing samples", playing.size >= 20)
        val window = playing.last().heard.el - playing.first().heard.el
        assertTrue("$label: sampled only ${window}ms of playback", window >= minWindowMs)
        val rate = (playing.last().heard.pos - playing.first().heard.pos).toDouble() / window
        assertTrue("$label: playback rate $rate is not real-time decoding", rate in 0.97..1.03)
        val worst = playing.maxBy { it.lag }
        assertTrue("$label: ${worst.lag}ms of listening was not on disk at ${worst.json()}", worst.lag <= LOSS_BOUND_MS)
        // Each change of the on-disk place, as first seen.
        val changes = playing.zipWithNext().filter { (a, b) -> a.disk.place() != b.disk.place() && b.disk.pos != null }.map { it.second }
        val gapsEl = changes.zipWithNext().map { (a, b) -> b.disk.readEl - a.disk.readEl }
        val gapsPos = changes.zipWithNext().map { (a, b) -> b.disk.pos!! - a.disk.pos!! }
        gapsPos.forEach { assertTrue("$label: checkpoints $it ms of audio apart", it in 1..LOSS_BOUND_MS) }
        gapsEl.forEach { assertTrue("$label: checkpoints $it ms apart on disk", it <= LOSS_BOUND_MS + SAMPLE_MS) }
        // When was each checkpoint's position actually heard, from the samples either side?
        val skew = changes.mapNotNull { change ->
            val target = change.disk.pos!!
            val pair = playing.zipWithNext().firstOrNull { (a, b) -> a.heard.pos <= target && b.heard.pos >= target } ?: return@mapNotNull null
            val (a, b) = pair
            val heardAt = if (b.heard.pos == a.heard.pos) a.heard.wall
            else a.heard.wall + ((target - a.heard.pos).toDouble() / (b.heard.pos - a.heard.pos) * (b.heard.wall - a.heard.wall)).roundToLong()
            change.disk.observed!! - heardAt
        }
        assertTrue("$label: no checkpoint could be matched to playback", skew.isNotEmpty())
        skew.forEach { assertTrue("$label: a checkpoint's activity time is ${it}ms off when it was heard", abs(it) <= OBSERVED_SKEW_MS) }
        return JSONObject()
            .put("samples", playing.size).put("windowMs", window).put("rate", rate)
            .put("maxLagMs", worst.lag).put("maxLagAt", worst.json())
            .put("checkpoints", changes.size)
            .put("maxGapElMs", gapsEl.maxOrNull()).put("maxGapPosMs", gapsPos.maxOrNull()).put("minGapPosMs", gapsPos.minOrNull())
            .put("observedSkewMs", JSONArray(skew)).put("maxAbsSkewMs", skew.maxOf { abs(it) })
    }

    /**
     * Backstop to the exact seek count: no backward step anywhere near a rewind. A
     * MediaController extrapolates its position between session updates and can be
     * corrected back by a few hundred milliseconds when playback starts (seen: 179ms after
     * AudioTrack's stall correction). Returns the largest such correction.
     */
    private fun noBackwardJump(samples: List<Sample>, label: String): Long {
        var worst = 0L
        samples.filter { it.heard.media == TRACK_ID }.zipWithNext().forEach { (a, b) ->
            val back = a.heard.pos - b.heard.pos
            assertTrue("$label: position went back from ${a.heard.pos} to ${b.heard.pos} (a second rewind?)", back <= MAX_ESTIMATE_CORRECTION_MS)
            worst = maxOf(worst, back)
        }
        return worst
    }

    private fun readDisk(file: File): Disk {
        val readEl = SystemClock.elapsedRealtime()
        if (!file.isFile) return Disk(null, null, null, null, false, readEl)
        val record = JSONObject(file.readText()).optJSONObject(BOOK_ID) ?: return Disk(null, null, null, null, false, readEl)
        val position = record.optJSONObject("position")
        val pending = record.optJSONObject("pending")
        return Disk(
            pos = position?.takeIf { it.has("positionSeconds") }?.let { (it.getDouble("positionSeconds") * 1_000).roundToLong() },
            observed = record.takeIf { it.has("observedAtEpochMs") && !it.isNull("observedAtEpochMs") }?.getLong("observedAtEpochMs"),
            pending = pending?.getString("mutationId"),
            pendingObserved = pending?.takeIf { it.has("observedAtEpochMs") && !it.isNull("observedAtEpochMs") }?.getLong("observedAtEpochMs"),
            dirty = record.optBoolean("dirty", false),
            readEl = readEl,
        )
    }

    // ---------------------------------------------------------------------------------
    // The synthetic server: the only fake in this probe.

    private class StoredProgress {
        @Volatile var progress: Progress? = null
    }

    private fun book(size: Long, progress: Progress?) = Publication(
        id = BOOK_ID, title = "Durability Fixture", author = "Fixture Narrator", bookType = BookType.AUDIOBOOK,
        assets = listOf(Asset(TRACK_ID, "durability.m4a", "audio/mp4", "m4a", size, "/files/durability.m4a")),
        progress = progress,
    )

    private fun fixture(audio: ByteArray, accept: Boolean, writes: MutableList<Write>, stored: StoredProgress?): MockWebServer {
        val web = MockWebServer()
        web.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                if (request.headers["Authorization"] != "Bearer $TOKEN") return MockResponse.Builder().code(401).build()
                val path = request.target.substringBefore('?')
                return when {
                    path == "/api/consumer/v1/me" -> json(ApiJson.encodeToString(Me(USER_ID, "Durability Listener")))
                    path == "/api/consumer/v1/continue" -> json(ApiJson.encodeToString(ContinueList()))
                    path == "/api/consumer/v1/library" -> json(ApiJson.encodeToString(LibraryPage(listOf(book(audio.size.toLong(), stored?.progress)))))
                    path == "/api/consumer/v1/library/$BOOK_ID" -> json(ApiJson.encodeToString(book(audio.size.toLong(), stored?.progress)))
                    path == "/files/durability.m4a" ->
                        MockResponse.Builder().code(200).addHeader("ETag", "\"durability\"").addHeader("Content-Type", "audio/mp4").body(Buffer().write(audio)).build()
                    path == "/api/consumer/v1/library/$BOOK_ID/progress" && request.method == "PUT" -> progress(request, accept, writes, stored)
                    path == "/api/consumer/v1/library/$BOOK_ID/progress" -> json(ApiJson.encodeToString(ProgressEnvelope(stored?.progress)))
                    else -> MockResponse.Builder().code(404).build()
                }
            }
        }
        // The same origin and port as before the kill; the dead process's socket may take a moment to go.
        val deadline = SystemClock.elapsedRealtime() + 15_000
        while (true) {
            try {
                web.start(InetAddress.getByName("localhost"), port)
                break
            } catch (error: BindException) {
                if (SystemClock.elapsedRealtime() > deadline) throw error
                SystemClock.sleep(250)
            }
        }
        return web
    }

    private fun progress(request: RecordedRequest, accept: Boolean, writes: MutableList<Write>, stored: StoredProgress?): MockResponse {
        val body = JSONObject(request.body?.utf8().orEmpty())
        val receivedWall = System.currentTimeMillis()
        if (!accept) {
            writes += Write(receivedWall, body, 503)
            log("fixture-refused", body)
            return MockResponse.Builder().code(503).build()
        }
        val current = stored!!.progress
        val version = current?.version ?: 0
        // Accepted only when built on the current version, as a real server would. The test
        // asserts every write was accepted, so a refusal here fails it visibly.
        if (body.getInt("expected_version") != version) {
            writes += Write(receivedWall, body, 409)
            log("fixture-stale", body)
            return MockResponse.Builder().code(409).addHeader("Content-Type", "application/json")
                .body(ApiJson.encodeToString(ProgressEnvelope(current))).build()
        }
        val saved = Progress(
            assetId = body.getString("asset_id"),
            positionSeconds = body.getDouble("position_seconds"),
            version = version + 1,
            clientMutationId = body.getString("client_mutation_id"),
            observedAt = body.optString("observed_at").takeIf(String::isNotEmpty),
        )
        stored.progress = saved
        writes += Write(receivedWall, body, 200)
        log("fixture-accepted", body.put("receivedWall", receivedWall))
        return json(ApiJson.encodeToString(ProgressEnvelope(saved)))
    }

    private fun json(body: String) = MockResponse.Builder().code(200).addHeader("Content-Type", "application/json").body(body).build()

    // ---------------------------------------------------------------------------------
    // Generated audio: AAC-LC in MP4, encoded here with MediaCodec so ExoPlayer decodes a real file.

    private fun generateAac(file: File, seconds: Int) {
        val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, SAMPLE_RATE, 1).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, 64_000)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16_384)
        }
        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        codec.start()
        file.delete()
        val muxer = MediaMuxer(file.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        val total = SAMPLE_RATE.toLong() * seconds
        var written = 0L
        var track = -1
        var inputDone = false
        val info = MediaCodec.BufferInfo()
        while (true) {
            if (!inputDone) {
                val index = codec.dequeueInputBuffer(10_000)
                if (index >= 0) {
                    val buffer = codec.getInputBuffer(index)!!.order(ByteOrder.nativeOrder())
                    buffer.clear()
                    val count = minOf(buffer.capacity() / 2L, 2_048L, total - written).toInt()
                    val pts = written * 1_000_000 / SAMPLE_RATE
                    if (count <= 0) {
                        codec.queueInputBuffer(index, 0, 0, pts, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        inputDone = true
                    } else {
                        for (k in 0 until count) buffer.putShort(tone(written + k))
                        codec.queueInputBuffer(index, 0, count * 2, pts, 0)
                        written += count
                    }
                }
            }
            val out = codec.dequeueOutputBuffer(info, 10_000)
            if (out == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                track = muxer.addTrack(codec.outputFormat)
                muxer.start()
            } else if (out >= 0) {
                val data = codec.getOutputBuffer(out)!!
                if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) info.size = 0
                if (info.size > 0) {
                    check(track >= 0) { "Encoder output before its format" }
                    data.position(info.offset)
                    data.limit(info.offset + info.size)
                    muxer.writeSampleData(track, data, info)
                }
                codec.releaseOutputBuffer(out, false)
                if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
            }
        }
        codec.stop()
        codec.release()
        muxer.stop()
        muxer.release()
        assertTrue("Generated audio is empty", file.length() > seconds * 4_000L)
    }

    /** A quiet tone whose pitch steps every second, so every second of the file differs. */
    private fun tone(sample: Long): Short {
        val second = sample / SAMPLE_RATE
        val frequency = 220.0 + 15.0 * (second % 24)
        return (0.2 * Short.MAX_VALUE * sin(2 * PI * frequency * sample / SAMPLE_RATE)).toInt().toShort()
    }

    // ---------------------------------------------------------------------------------

    private fun writeRun(run: JSONObject) {
        File(work, "run.json").writeText(run.toString(2))
    }

    private fun seconds(body: JSONObject): Long = (body.getDouble("position_seconds") * 1_000).roundToLong()

    private fun <T : Any> assertNotNull_(message: String, value: T?): T {
        assertNotNull(message, value)
        return value!!
    }

    private fun log(event: String, fields: JSONObject) {
        Log.i(TAG, "$event ${fields.put("event", event).put("stage", stage)}")
    }

    private fun await(description: String, timeoutMs: Long, condition: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        while (SystemClock.elapsedRealtime() < deadline) {
            if (condition()) return
            SystemClock.sleep(100)
        }
        assertTrue("Timed out waiting for $description", condition())
    }

    private fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    companion object {
        private const val TAG = "ADUR"
        private const val BOOK_ID = "audio-durability-book"
        private const val TRACK_ID = "audio-durability-track"
        private const val USER_ID = "audio-durability-fixture"
        private const val TOKEN = "audio-durability-fixture-token"
        private const val SAMPLE_RATE = 44_100
        private const val AUDIO_SECONDS = 240

        /** The requirement: no more than five seconds of listening may be lost. */
        private const val LOSS_BOUND_MS = 5_000L
        private const val REWIND_MS = 5_000L
        private const val SAMPLE_MS = 50L
        private const val START_DEADLINE_MS = 20_000L
        private const val STEADY_MS = 40_000L
        private const val KILL_DEADLINE_MS = 15_000L
        private const val START_SLACK_MS = 750L
        private const val PAST_PLACE_MS = 13_000L
        private const val PAUSE_SLACK_MS = 300L
        private const val PAUSE_HOLD_MS = 2_000L
        private const val BACKGROUND_HOLD_MS = 1_000L
        private const val OBSERVED_SKEW_MS = 500L
        private const val MAX_ESTIMATE_CORRECTION_MS = 500L
        private const val SEEK_ECHO_SLACK_MS = 50L

        /** The controller waits longer than this between the kill and reopening. */
        private const val MIN_LISTEN_TO_SYNC_GAP_MS = 15_000L
    }
}
