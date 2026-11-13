package org.shelfarr.app.core

import kotlinx.coroutines.delay

sealed interface AuthorizationOutcome {
    data class Approved(val token: TokenResponse) : AuthorizationOutcome
    data object Expired : AuthorizationOutcome
    data object Denied : AuthorizationOutcome
}

/**
 * Runs the token polling loop for one grant. There is exactly one sequential loop
 * per call and it stops at approval, expiry, denial or coroutine cancellation.
 */
class DeviceAuthorizer(
    private val api: ConsumerApi,
    private val now: () -> Long = System::currentTimeMillis,
) {
    suspend fun await(pending: PendingAuthorization): AuthorizationOutcome {
        var intervalSeconds = pending.grant.interval.coerceAtLeast(MIN_INTERVAL_SECONDS)
        var transientFailures = 0

        while (true) {
            val wait = intervalSeconds + backoffSeconds(transientFailures)
            delay(wait * 1_000)
            if (now() >= pending.expiresAtEpochMs) return AuthorizationOutcome.Expired

            try {
                val token = api.exchangeDeviceCode(pending.server, pending.grant.deviceCode)
                return AuthorizationOutcome.Approved(token)
            } catch (error: ApiException.Authorization) {
                transientFailures = 0
                when (error.code) {
                    "authorization_pending" -> Unit
                    "slow_down" -> intervalSeconds += SLOW_DOWN_STEP_SECONDS
                    "access_denied" -> return AuthorizationOutcome.Denied
                    else -> return AuthorizationOutcome.Expired
                }
            } catch (error: ApiException) {
                // A dropped connection must not cost the user their sign-in attempt.
                if (!error.isRetryable) throw error
                transientFailures++
            }
        }
    }

    private fun backoffSeconds(failures: Int): Long = when {
        failures <= 0 -> 0
        else -> minOf(MAX_BACKOFF_SECONDS, 1L shl minOf(failures, 5))
    }

    private companion object {
        const val MIN_INTERVAL_SECONDS = 1L
        const val SLOW_DOWN_STEP_SECONDS = 5L
        const val MAX_BACKOFF_SECONDS = 30L
    }
}
