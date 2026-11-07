package org.shelfarr.app.ui.player

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.shelfarr.app.AppContainer
import org.shelfarr.app.core.ApiException
import org.shelfarr.app.core.Progress
import org.shelfarr.app.core.ProgressSync
import org.shelfarr.app.core.Publication
import org.shelfarr.app.core.ResumeDecision
import org.shelfarr.app.core.SavedPosition
import org.shelfarr.app.core.SyncStatus

sealed interface PlayerState {
    data object Loading : PlayerState
    data class ChooseResume(val publication: Publication, val local: SavedPosition, val server: Progress) : PlayerState
    data class Active(val notice: String? = null) : PlayerState
    data class Failed(val error: Throwable) : PlayerState
    data object NoAudio : PlayerState
}

class PlayerViewModel(private val container: AppContainer, private val publicationId: String) : ViewModel() {
    private val account = container.currentAccount()
    private val sync: ProgressSync? = account?.progress?.sync(publicationId)

    private val mutableState = MutableStateFlow<PlayerState>(PlayerState.Loading)
    val state: StateFlow<PlayerState> = mutableState.asStateFlow()

    val playback = container.playback.snapshot
    val syncStatus: StateFlow<SyncStatus> = sync?.status ?: MutableStateFlow(SyncStatus.Idle)

    init {
        start()
    }

    fun start() {
        if (container.playback.snapshot.value.publication?.id == publicationId) {
            mutableState.value = PlayerState.Active()
            return
        }
        val session = account?.session ?: return
        mutableState.value = PlayerState.Loading
        viewModelScope.launch {
            try {
                val publication = container.api.publication(session.server, publicationId)
                if (publication.audioAssets.isEmpty()) {
                    mutableState.value = PlayerState.NoAudio
                    return@launch
                }
                when (val decision = ResumeDecision.decide(publication, publication.progress, sync?.snapshot())) {
                    ResumeDecision.Beginning -> play(publication, null, 0)
                    is ResumeDecision.Continue -> play(publication, decision.position, decision.baseVersion)
                    is ResumeDecision.Choose ->
                        mutableState.value = PlayerState.ChooseResume(publication, decision.local, decision.server)
                    is ResumeDecision.EditionChanged -> play(
                        publication,
                        null,
                        decision.staleVersion,
                        "These audio files were replaced, so your old place doesn't apply. Starting from the beginning.",
                    )
                }
            } catch (error: ApiException) {
                mutableState.value = PlayerState.Failed(error)
            }
        }
    }

    fun chooseResume(keepLocal: Boolean) {
        val choice = mutableState.value as? PlayerState.ChooseResume ?: return
        viewModelScope.launch {
            val position = if (keepLocal) choice.local else SavedPosition.from(choice.server)
            sync?.chooseAtOpen(position, choice.server.version, keepLocal)
            play(choice.publication, position, choice.server.version)
        }
    }

    private suspend fun play(publication: Publication, start: SavedPosition?, baseVersion: Int, notice: String? = null) {
        val session = account?.session ?: return
        val target = sync ?: return
        target.begin(start, baseVersion)
        container.playback.load(publication, session.server, target, start)
        mutableState.value = PlayerState.Active(notice)
    }

    fun keepThisPlace() {
        val target = sync ?: return
        container.scope.launch { target.keepLocal() }
    }

    fun useOtherPlace() {
        val target = sync ?: return
        viewModelScope.launch { target.useServer()?.let(container.playback::jumpTo) }
    }
}
