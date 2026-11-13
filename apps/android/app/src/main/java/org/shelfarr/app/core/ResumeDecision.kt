package org.shelfarr.app.core

/** Where a publication should open, decided before anything is shown. */
sealed interface ResumeDecision {
    data object Beginning : ResumeDecision

    /** Open at [position]. [observedAtEpochMs] is when that place was reached, if known. */
    data class Continue(
        val position: SavedPosition,
        val baseVersion: Int,
        val observedAtEpochMs: Long? = null,
    ) : ResumeDecision

    /** The two places can't be ordered by when they were reached. The reader decides. */
    data class Choose(val local: SavedPosition, val server: Progress) : ResumeDecision

    /** The saved place belongs to a file this publication no longer has. */
    data class EditionChanged(val staleVersion: Int) : ResumeDecision

    companion object {
        fun decide(
            publication: Publication,
            server: Progress?,
            local: LocalProgress?,
            offline: Boolean = false,
            now: Long = System.currentTimeMillis(),
        ): ResumeDecision {
            val assets = publication.playableAssets.mapTo(HashSet()) { it.id }
            val serverVersion = server?.version ?: 0
            val serverUsable = server != null && serverVersion > 0 && server.isUsable && server.assetId in assets
            val serverTime = server?.observedAtEpochMs

            // Our queued write already reached the server; only the answer was lost.
            val acknowledged = local?.pending != null && server?.clientMutationId == local.pending.mutationId
            val localBase = if (acknowledged) serverVersion else local?.baseVersion ?: 0
            val unsynced = local != null && (local.dirty || (local.pending != null && !acknowledged))

            val localPosition = local?.position?.takeIf { it.assetId in assets }
            if (local != null && (unsynced || offline) && localPosition != null) {
                return when {
                    offline || !serverUsable || serverVersion <= localBase ->
                        ResumeDecision.Continue(localPosition, maxOf(localBase, serverVersion), local.observedAtEpochMs)
                    localPosition.samePlaceAs(server) ->
                        ResumeDecision.Continue(localPosition, serverVersion, local.observedAtEpochMs ?: serverTime)
                    // The server refused this place before: never settle it automatically.
                    local.rejected -> ResumeDecision.Choose(localPosition, server)
                    else -> byActivityTime(localPosition, local.observedAtEpochMs, server, now)
                }
            }

            return when {
                serverUsable -> ResumeDecision.Continue(SavedPosition.from(server), serverVersion, serverTime)
                serverVersion > 0 -> ResumeDecision.EditionChanged(serverVersion)
                else -> ResumeDecision.Beginning
            }
        }

        /** The later real activity wins, wherever it is in the book. Uncertain times ask. */
        private fun byActivityTime(local: SavedPosition, localTime: Long?, server: Progress, now: Long): ResumeDecision {
            val mine = localTime?.takeIf { ActivityTime.isPlausible(it, now) }
            val theirs = server.observedAtEpochMs?.takeIf { ActivityTime.isPlausible(it, now) }
            return when {
                mine == null || theirs == null || mine == theirs -> ResumeDecision.Choose(local, server)
                // Built again on the server's version when the session begins.
                mine > theirs -> ResumeDecision.Continue(local, server.version, mine)
                else -> ResumeDecision.Continue(SavedPosition.from(server), server.version, theirs)
            }
        }
    }
}
