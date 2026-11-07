package org.shelfarr.app.core

/** Where a publication should open, decided before anything is shown. */
sealed interface ResumeDecision {
    data object Beginning : ResumeDecision

    data class Continue(val position: SavedPosition, val baseVersion: Int) : ResumeDecision

    /** This device has unsent reading the server has since moved past. The reader decides. */
    data class Choose(val local: SavedPosition, val server: Progress) : ResumeDecision

    /** The saved place belongs to a file this publication no longer has. */
    data class EditionChanged(val staleVersion: Int) : ResumeDecision

    companion object {
        fun decide(publication: Publication, server: Progress?, local: LocalProgress?, offline: Boolean = false): ResumeDecision {
            val assets = publication.playableAssets.mapTo(HashSet()) { it.id }
            val serverVersion = server?.version ?: 0
            val serverUsable = server != null && serverVersion > 0 && server.isUsable && server.assetId in assets

            val localPosition = local?.position?.takeIf { it.assetId in assets }
            if (local != null && (local.hasUnsyncedChanges || offline) && localPosition != null) {
                return when {
                    offline || !serverUsable || serverVersion <= local.baseVersion ->
                        ResumeDecision.Continue(localPosition, maxOf(local.baseVersion, serverVersion))
                    samePlace(localPosition, server) -> ResumeDecision.Continue(localPosition, serverVersion)
                    else -> ResumeDecision.Choose(localPosition, server)
                }
            }

            return when {
                serverUsable -> ResumeDecision.Continue(SavedPosition.from(server), serverVersion)
                serverVersion > 0 -> ResumeDecision.EditionChanged(serverVersion)
                else -> ResumeDecision.Beginning
            }
        }

        private fun samePlace(local: SavedPosition, server: Progress): Boolean =
            local.assetId == server.assetId &&
                local.locator == server.locator &&
                local.positionSeconds == server.positionSeconds
    }
}
