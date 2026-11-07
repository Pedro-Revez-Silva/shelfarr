package org.shelfarr.app.transfer

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import org.shelfarr.app.R
import org.shelfarr.app.core.DownloadRecord
import org.shelfarr.app.core.DownloadState
import org.shelfarr.app.ui.MainActivity
import org.shelfarr.app.ui.downloads.downloadCopy
import org.shelfarr.app.ui.formatBytes

/** What the progress notification says, worked out from the download records alone. */
data class TransferSummary(
    val title: String,
    val text: String,
    /** Null when the server didn't state every size, so no honest bar exists. */
    val fraction: Float?,
    /** The downloads a Cancel action stops, oldest first. */
    val activeIds: List<String>,
    val bytesDone: Long,
    val bytesTotal: Long?,
)

fun transferSummary(records: Collection<DownloadRecord>): TransferSummary? {
    val active = records.filter { it.isActive }.sortedBy { it.updatedAtEpochMs }
    if (active.isEmpty()) return null
    val title = if (active.size == 1) "Downloading “${active.single().publication.title}”" else "Downloading ${active.size} titles"
    val done = active.sumOf { it.bytesDone }
    val total = active.map { it.bytesTotal }.takeIf { totals -> totals.none { it == null } }?.sumOf { it ?: 0 }
    val amount = if (total != null && total > 0) "${formatBytes(done)} of ${formatBytes(total)}" else "${formatBytes(done)} so far"
    val transferring = active.any { it.state == DownloadState.DOWNLOADING }
    val text = if (transferring) amount else "Waiting to continue · $amount"
    val fraction = total?.takeIf { it > 0 }?.let { (done.toFloat() / it).coerceIn(0f, 1f) }
    return TransferSummary(title, text, fraction, active.map { it.publicationId }, done, total)
}

/** The outcome worth telling someone who left the app, or null when there is nothing to say. */
fun transferResult(finished: List<DownloadRecord>, stopped: List<DownloadRecord>): Pair<String, String>? = when {
    stopped.size == 1 && finished.isEmpty() -> downloadCopy(stopped.single()).let { "“${stopped.single().publication.title}”: ${it.title}" to it.detail }
    stopped.isNotEmpty() -> "${stopped.size + finished.size} downloads finished or stopped" to "${stopped.size} need attention. Open Downloads to see why."
    finished.size == 1 -> "Downloaded “${finished.single().publication.title}”" to "Ready to open without a connection."
    finished.size > 1 -> "${finished.size} downloads finished" to "Ready to open without a connection."
    else -> null
}

/**
 * The single downloads channel and its notifications. Posting is skipped, never
 * forced, when the person has turned notifications off: downloads still run, and the
 * system's Task Manager still lists the user-initiated transfer.
 */
class TransferNotifications(private val context: Context) {
    private val manager = NotificationManagerCompat.from(context)

    fun ensureChannel() {
        val channel = NotificationChannel(CHANNEL, "Downloads", NotificationManager.IMPORTANCE_LOW).apply {
            description = "Progress of books and audiobooks you chose to download"
            setShowBadge(false)
        }
        context.getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    /** True when a posted notification would actually be shown. */
    val canPost: Boolean
        get() = manager.areNotificationsEnabled() &&
            (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED)

    fun preparing(): Notification = base()
        .setContentTitle("Preparing downloads")
        .setProgress(0, 0, true)
        .build()

    fun progress(summary: TransferSummary?, accountKey: String?): Notification {
        if (summary == null) return base().setContentTitle("Finishing downloads").build()
        val builder = base()
            .setContentTitle(summary.title)
            .setContentText(summary.text)
        val fraction = summary.fraction
        if (fraction != null) builder.setProgress(PROGRESS_MAX, (fraction * PROGRESS_MAX).toInt(), false) else builder.setProgress(0, 0, true)
        if (accountKey != null) {
            builder.addAction(0, if (summary.activeIds.size > 1) "Cancel all" else "Cancel", cancelIntent(accountKey, summary.activeIds))
        }
        return builder.build()
    }

    fun show(notification: Notification) = post(PROGRESS_ID, notification)

    fun cancelProgress() = manager.cancel(PROGRESS_ID)

    fun showResult(title: String, text: String) = post(
        RESULT_ID,
        NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(openDownloads())
            .setAutoCancel(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .build(),
    )

    private fun post(id: Int, notification: Notification) {
        if (!canPost) return
        try {
            manager.notify(id, notification)
        } catch (error: SecurityException) {
            // Permission was withdrawn between the check and the post.
            Log.w(TAG, "Notification permission withdrawn", error)
        }
    }

    private fun base(): NotificationCompat.Builder = NotificationCompat.Builder(context, CHANNEL)
        .setSmallIcon(R.drawable.ic_notification)
        .setCategory(NotificationCompat.CATEGORY_PROGRESS)
        .setOngoing(true)
        .setOnlyAlertOnce(true)
        .setSilent(true)
        .setContentIntent(openDownloads())

    private fun openDownloads(): PendingIntent = PendingIntent.getActivity(
        context,
        0,
        Intent(context, MainActivity::class.java)
            .setAction(MainActivity.ACTION_OPEN_DOWNLOADS)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    private fun cancelIntent(accountKey: String, ids: List<String>): PendingIntent = PendingIntent.getBroadcast(
        context,
        1,
        Intent(context, DownloadActionReceiver::class.java)
            .setAction(DownloadActionReceiver.ACTION_CANCEL)
            .putExtra(DownloadActionReceiver.EXTRA_ACCOUNT, accountKey)
            .putExtra(DownloadActionReceiver.EXTRA_IDS, ids.toTypedArray()),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    companion object {
        private const val TAG = "ShelfarrTransfers"
        const val CHANNEL = "downloads"
        const val PROGRESS_ID = 4_101
        const val RESULT_ID = 4_102
        private const val PROGRESS_MAX = 1_000
    }
}
